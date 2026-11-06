import Foundation
import os

// Limit-Verlauf für die Statistik-Seite — ohne eine einzige zusätzliche
// Netzwerkabfrage. Zwei Quellen:
//
// 1. Alle 15 Minuten liest der `StatisticsLimitCollector` die Cache-Dateien der
//    Claude-Profile (`$TMPDIR/claude-usage-cache-<profil>.json`, geschrieben von
//    Statuszeile und App) und den Codex-Protokoll-Schwanz der letzten zwei Tage.
// 2. Wo die App ohnehin live abfragt (Claude-Fetcher, Codex-Fetcher für
//    GPT-Profile und Codex-CLI), meldet sie das Ergebnis über den
//    `StatisticsLimitRecorder` gleich mit.
//
// Kontoschlüssel in `StatsDatabase.limits`: Claude-Profilname (`main`,
// `RankM8`, …), `chatgpt:<profil>` für GPT-Konten des Proxys, `codex` für die
// Codex-CLI.

/// Ein Limit-Stand, bereit für `StatsDatabase.limits`.
struct StatisticsLimitEntry: Equatable, Sendable {
    var account: String
    /// `claude` oder `chatgpt`.
    var provider: String
    var plan: String?
    var snapshot: LimitSnapshot
}

/// Abbildung der vorhandenen Usage-Typen auf `LimitSnapshot`. Pur und testbar.
enum StatisticsLimitMapping {
    static let codexCLIAccount = "codex"

    static func gptAccountKey(profile: String) -> String { "chatgpt:\(profile)" }

    static func entry(claude usage: ClaudeAccountUsage, profile: String, plan: String?) -> StatisticsLimitEntry? {
        // Reiner Fehler-Stand (kein Cache, kein Live-Wert) ist kein Messpunkt.
        guard usage.fiveHourPercent != nil || usage.sevenDayPercent != nil else { return nil }
        return StatisticsLimitEntry(
            account: profile,
            provider: "claude",
            plan: plan,
            snapshot: LimitSnapshot(
                fiveHourPercent: usage.fiveHourPercent,
                fiveHourResetsAt: usage.fiveHourResetsAt,
                weekPercent: usage.sevenDayPercent,
                weekResetsAt: usage.sevenDayResetsAt,
                capturedAt: usage.fetchedAt
            )
        )
    }

    /// Codex meldet zwei Fenster ohne feste Rolle; zugeordnet wird über die
    /// Fensterlänge (bis 10 h = 5h-Fenster, ab 6 Tagen = Woche).
    static func entry(codex usage: CodexUsage, account: String, now: Date = Date()) -> StatisticsLimitEntry? {
        var fiveHour: CodexUsage.Window?
        var week: CodexUsage.Window?
        for window in [usage.primary, usage.secondary].compactMap({ $0 }) {
            if window.windowMinutes <= 600, fiveHour == nil {
                fiveHour = window
            } else if window.windowMinutes >= 6 * 24 * 60, week == nil {
                week = window
            }
        }
        guard fiveHour != nil || week != nil else { return nil }
        return StatisticsLimitEntry(
            account: account,
            provider: "chatgpt",
            plan: planLabel(usage.planType),
            snapshot: LimitSnapshot(
                fiveHourPercent: fiveHour?.usedPercent,
                fiveHourResetsAt: fiveHour?.resetsAt,
                weekPercent: week?.usedPercent,
                weekResetsAt: week?.resetsAt,
                capturedAt: usage.capturedAt ?? now
            )
        )
    }

    /// `pro` → „Pro“, `plus` → „Plus“. Leere Werte zählen nicht.
    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Kontoschlüssel eines Proxy-Stores aus dem Pfad seiner `auth.json`:
    /// Zusatzprofile liegen unter `~/.gpt-profiles/<name>/codex/auth.json`,
    /// alles andere ist der Default-Store von `main`.
    static func gptAccountKey(proxyAuthFile: URL) -> String {
        let configDir = proxyAuthFile.deletingLastPathComponent().deletingLastPathComponent()
        if configDir.deletingLastPathComponent().lastPathComponent == ".gpt-profiles" {
            return gptAccountKey(profile: configDir.lastPathComponent)
        }
        return gptAccountKey(profile: GPTAccountProfiles.mainProfileName)
    }

    /// Trägt einen Stand in die Datenbank ein. Provider und Plan folgen dem
    /// neuesten Stand; der Wochen-Höchstwert wächst nur (`LimitHistory.record`).
    static func apply(_ entry: StatisticsLimitEntry, to db: inout StatsDatabase, calendar: Calendar = .current) {
        var history = db.limits[entry.account] ?? LimitHistory(provider: entry.provider)
        history.provider = entry.provider
        if let plan = entry.plan { history.plan = plan }
        history.record(entry.snapshot, calendar: calendar)
        db.limits[entry.account] = history
    }
}

/// Einhakstelle für die vorhandenen Fetcher. Solange kein Sammler läuft (und
/// in Tests), ist kein Ziel gesetzt und jeder Aufruf kostet nur einen Lock.
enum StatisticsLimitRecorder {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var sink: (@Sendable (StatisticsLimitEntry) -> Void)?
    }

    private static let box = Box()

    static func install(_ sink: @escaping @Sendable (StatisticsLimitEntry) -> Void) {
        box.lock.lock(); defer { box.lock.unlock() }
        box.sink = sink
    }

    static func uninstall() {
        box.lock.lock(); defer { box.lock.unlock() }
        box.sink = nil
    }

    static var isActive: Bool { currentSink() != nil }

    private static func currentSink() -> (@Sendable (StatisticsLimitEntry) -> Void)? {
        box.lock.lock(); defer { box.lock.unlock() }
        return box.sink
    }

    /// `plan` wird nur ausgewertet, wenn tatsächlich aufgezeichnet wird.
    static func recordClaude(_ usage: ClaudeAccountUsage, profile: String, plan: () -> String? = { nil }) {
        guard let sink = currentSink(),
              let entry = StatisticsLimitMapping.entry(claude: usage, profile: profile, plan: plan())
        else { return }
        sink(entry)
    }

    static func recordCodex(_ usage: CodexUsage, account: String) {
        guard let sink = currentSink(),
              let entry = StatisticsLimitMapping.entry(codex: usage, account: account)
        else { return }
        sink(entry)
    }
}

/// Liest periodisch die lokalen Limit-Stände. Keine eigene Netzwerkabfrage:
/// nur Cache-Dateien und Codex-Protokolle.
final class StatisticsLimitCollector: @unchecked Sendable {
    static let shared = StatisticsLimitCollector()

    static let interval: TimeInterval = 15 * 60

    private let queue = DispatchQueue(label: "com.whisperm8.statistics.limits", qos: .background)
    private let logger = os.Logger(subsystem: "com.whisperm8.app", category: "statistics")

    /// Test-Nähte.
    var claudeProfiles: () -> [ClaudeAccountProfile] = { ClaudeAccountProfiles().profiles() }
    var claudeCache: (String) -> ClaudeAccountUsage? = { ClaudeAccountUsageFetcher().cachedUsage(forProfile: $0) }
    var codexSnapshot: () -> CodexUsage? = { StatisticsLimitCollector.recentCodexUsage() }
    var store: StatisticsStore = .shared

    // Nur auf `queue`.
    private var timer: DispatchSourceTimer?
    // Nur auf dem Main-Thread.
    private var registeredRuntimeHandler = false

    init() {}

    /// Startet den Sammler (idempotent) und hängt ihn an den Hauptschalter.
    @MainActor
    func start() {
        if !registeredRuntimeHandler {
            registeredRuntimeHandler = true
            StatisticsRuntime.onEnabledChanged { [weak self] enabled in
                if enabled { self?.resume() } else { self?.pause() }
            }
        }
        if StatisticsSettings.isEnabled() { resume() } else { pause() }
    }

    @MainActor
    func stop() {
        pause()
    }

    private func resume() {
        let store = self.store
        StatisticsLimitRecorder.install { entry in
            store.update { db in StatisticsLimitMapping.apply(entry, to: &db) }
        }
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            // Erster Lauf mit Abstand zum App-Start, danach alle 15 Minuten.
            // Große Toleranz, damit macOS den Timer mit anderen bündeln kann.
            source.schedule(
                deadline: .now() + 90,
                repeating: Self.interval,
                leeway: .seconds(Int(Self.interval / 3))
            )
            source.setEventHandler { [weak self] in self?.collectNow() }
            source.resume()
            timer = source
        }
    }

    private func pause() {
        StatisticsLimitRecorder.uninstall()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Ein Durchgang über alle lokalen Quellen. Läuft auf der Sammler-Queue.
    func collectNow() {
        guard StatisticsSettings.isEnabled() else { return }
        let entries = Self.entries(
            profiles: claudeProfiles(),
            cache: claudeCache,
            codex: codexSnapshot()
        )
        guard !entries.isEmpty else { return }
        store.update { db in
            for entry in entries { StatisticsLimitMapping.apply(entry, to: &db) }
        }
        logger.debug("statistics_limits_collected accounts=\(entries.count)")
    }

    /// Pur: angemeldete Claude-Profile → Cache-Stände, dazu der Codex-Stand.
    static func entries(
        profiles: [ClaudeAccountProfile],
        cache: (String) -> ClaudeAccountUsage?,
        codex: CodexUsage?
    ) -> [StatisticsLimitEntry] {
        var result: [StatisticsLimitEntry] = []
        for profile in profiles where profile.isLoggedIn {
            guard let usage = cache(profile.name),
                  let entry = StatisticsLimitMapping.entry(claude: usage, profile: profile.name, plan: profile.planDisplayName)
            else { continue }
            result.append(entry)
        }
        if let codex, let entry = StatisticsLimitMapping.entry(codex: codex, account: StatisticsLimitMapping.codexCLIAccount) {
            result.append(entry)
        }
        return result
    }

    /// Jüngster Codex-Stand aus den Protokollen von heute und gestern. Codex
    /// legt sie unter `sessions/JJJJ/MM/TT/` ab — so bleibt der Lauf billig,
    /// egal wie groß die Historie ist.
    static func recentCodexUsage(
        sessionsRoot: URL = AppInstance.home.appendingPathComponent(".codex/sessions", isDirectory: true),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CodexUsage? {
        for offset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessionsRoot
                .appendingPathComponent(String(format: "%04d", c.year ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", c.month ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", c.day ?? 0), isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            if let usage = CodexUsageReader(sessionsRoot: folder).latestUsage(maxFiles: 3) {
                return usage
            }
        }
        return nil
    }
}
