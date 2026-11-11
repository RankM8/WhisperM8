import Foundation
import Observation
import UserNotifications

/// Entscheidet, wofür gewarnt wird — pur, damit die Regel testbar bleibt.
///
/// Gewarnt wird einmal je Frist und Stufe: wenn ein Login innerhalb von drei
/// Tagen endet, und noch einmal, wenn er beendet ist. Mehrere Konten landen in
/// einer gemeinsamen Mitteilung.
enum ClaudeLoginExpiryWarningPlanner {
    struct Warning: Equatable {
        var endingSoon: [String]
        var ended: [String]

        var title: String { String(localized: "Claude logins need renewal") }

        var body: String {
            var parts: [String] = []
            if !endingSoon.isEmpty {
                parts.append(String(localized: "Ending within 3 days: \(endingSoon.joined(separator: ", "))."))
            }
            if !ended.isEmpty {
                parts.append(String(localized: "Already ended: \(ended.joined(separator: ", "))."))
            }
            return parts.joined(separator: " ")
        }
    }

    struct Plan: Equatable {
        var warning: Warning?
        /// Neuer Merker-Stand; ersetzt den alten vollständig.
        var markers: [String: String]
    }

    /// `unreadable`: Konten, deren Eintrag gerade nicht lesbar war — ihr
    /// Merker bleibt stehen, sonst käme dieselbe Warnung später noch einmal.
    static func plan(
        entries: [String: ClaudeLoginExpiry],
        now: Date,
        notified: [String: String],
        unreadable: Set<String> = []
    ) -> Plan {
        var markers: [String: String] = [:]
        for name in unreadable {
            if let kept = notified[name] { markers[name] = kept }
        }
        var endingSoon: [String] = []
        var ended: [String] = []
        for name in entries.keys.sorted() {
            guard let entry = entries[name] else { continue }
            let stage: String
            switch entry.urgency(now: now) {
            case .none, .soon:
                // Kein Merker: nach einer Erneuerung beginnt die Frist neu.
                continue
            case .urgent:
                stage = "urgent"
            case .ended:
                stage = "ended"
            }
            // „Beendet“ gilt je Login nur einmal, auch wenn Claude beim Leeren
            // der Tokens das Enddatum verändert oder entfernt.
            if stage == "ended", let previous = notified[name], previous.hasSuffix(":ended") {
                markers[name] = previous
                continue
            }
            let marker = "\(Int(entry.endsAt?.timeIntervalSince1970 ?? 0)):\(stage)"
            markers[name] = marker
            guard notified[name] != marker else { continue }
            if stage == "ended" { ended.append(name) } else { endingSoon.append(name) }
        }
        let warning = endingSoon.isEmpty && ended.isEmpty
            ? nil
            : Warning(endingSoon: endingSoon, ended: ended)
        return Plan(warning: warning, markers: markers)
    }
}

/// Hält den Login-Zustand aller Claude-Konten für die Oberfläche bereit und
/// prüft ihn im Hintergrund nach. Ansichten lesen nur diesen Store — das
/// Auslesen des Keychains (ein `security`-Aufruf je Konto) läuft nie in einem
/// View-Body.
@MainActor
@Observable
final class ClaudeLoginExpiryStore {
    static let shared = ClaudeLoginExpiryStore()

    /// Mitteilungen tragen diese Route, damit ein Klick die Konten-Seite öffnet.
    nonisolated static let windowRequestUserInfoKey = "whisperm8.windowRequest"

    private(set) var entries: [String: ClaudeLoginExpiry] = [:]
    /// Dringlichkeit zum Zeitpunkt der letzten Prüfung, fertig gerechnet.
    private(set) var urgencies: [String: ClaudeLoginExpiry.Urgency] = [:]
    private(set) var lastCheckedAt: Date?

    /// Liest den Zustand aller Konten mit Kontodaten. Läuft abseits des Main Threads.
    @ObservationIgnored var reader: @Sendable () -> [String: ClaudeLoginExpiryReading] = { ClaudeLoginExpiryStore.readAllProfiles() }
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var preferences: () -> AppPreferences = { AppPreferences.shared }
    @ObservationIgnored var postNotification: (ClaudeLoginExpiryWarningPlanner.Warning) -> Void = ClaudeLoginExpiryStore.post

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isRefreshing = false
    /// Während eines Laufs kam ein weiterer Wunsch — danach noch einmal lesen.
    @ObservationIgnored private var needsAnotherPass = false

    /// Stündlich reicht: die Frist ändert sich in Tagen, und jede Prüfung
    /// startet je Konto einen kurzen `security`-Prozess.
    static let checkInterval: TimeInterval = 60 * 60

    init() {}

    /// Konten, die Aufmerksamkeit brauchen (endet in drei Tagen oder beendet),
    /// alphabetisch. Ob die Vorwarnung eingeschaltet ist, prüft die Ansicht.
    var attentionNames: [String] {
        urgencies.filter { $0.value >= .urgent }.keys.sorted()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refresh() }
    }

    /// Liest neu und warnt bei Bedarf. Kommt ein Aufruf, während schon gelesen
    /// wird, folgt danach ein weiterer Durchgang — der laufende könnte das
    /// betroffene Konto schon hinter sich haben (z. B. direkt nach einer Erneuerung).
    func refresh() async {
        guard !isRefreshing else {
            needsAnotherPass = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherPass = false
            await readOnce()
        } while needsAnotherPass
    }

    private func readOnce() async {
        let read = reader
        let readings = await Task.detached(priority: .utility) { read() }.value
        let moment = now()

        var fresh: [String: ClaudeLoginExpiry] = [:]
        var unreadable: Set<String> = []
        for (name, reading) in readings {
            switch reading {
            case .login(let expiry):
                fresh[name] = expiry
            case .noLogin:
                break
            case .unreadable:
                // Letzten bekannten Stand behalten statt die Frist auszublenden.
                unreadable.insert(name)
                if let previous = entries[name] { fresh[name] = previous }
            }
        }
        entries = fresh
        urgencies = fresh.mapValues { $0.urgency(now: moment) }
        lastCheckedAt = moment

        let prefs = preferences()
        let plan = ClaudeLoginExpiryWarningPlanner.plan(
            entries: fresh,
            now: moment,
            notified: prefs.claudeLoginExpiryNotifiedMarkers,
            unreadable: unreadable
        )
        // Merker auch bei abgeschalteter Vorwarnung führen — sonst käme beim
        // Wiedereinschalten ein Schwall alter Meldungen.
        prefs.claudeLoginExpiryNotifiedMarkers = plan.markers
        if let warning = plan.warning, prefs.isClaudeLoginExpiryWarningEnabled {
            postNotification(warning)
            Logger.agentStore.notice(
                "claude_login_expiry_warned soon=\(warning.endingSoon.count) ended=\(warning.ended.count)"
            )
        }
    }

    nonisolated static func readAllProfiles() -> [String: ClaudeLoginExpiryReading] {
        let service = ClaudeAccountProfiles()
        var result: [String: ClaudeLoginExpiryReading] = [:]
        for profile in service.profiles() where profile.isLoggedIn {
            result[profile.name] = service.readLoginExpiry(forProfile: profile.name)
        }
        return result
    }

    nonisolated static func post(_ warning: ClaudeLoginExpiryWarningPlanner.Warning) {
        let content = UNMutableNotificationContent()
        content.title = warning.title
        content.body = warning.body
        content.userInfo = [windowRequestUserInfoKey: WindowRequest.settingsClaudeAccounts.rawValue]
        let request = UNNotificationRequest(
            identifier: "claude-login-expiry",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.agentStore.warning("claude_login_expiry_notification_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
