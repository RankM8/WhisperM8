import Foundation

/// Letzter bekannter Verbrauch je Konto (5-Stunden-Fenster und Woche), für
/// den Controller: Konto-Menü mit Prozenten (Runde 5), Kopf und Limits-Karte
/// der Dynamic Island (Insel-Paket). Die Limits-Popovers tragen ihre
/// Ergebnisse hier ein. Der Controller stößt höchstens einmal je Minute
/// denselben passiven Abruf an wie das Öffnen des Popovers (nur lesen, nie
/// Tokens erneuern) — beim Öffnen der Konto-Ebene und der Limits-Karte, nie
/// beim bloßen Halten von R1. Nur ✕ in der Karte nimmt den Weg von ↻. Kein
/// I/O auf dem Main Thread, nichts läuft dauerhaft.
@MainActor
final class AccountLimitsStore {
    static let shared = AccountLimitsStore()

    struct Limit: Equatable {
        /// Verbraucht in Prozent; `nil`, wenn unbekannt.
        var fiveHour: Double?
        var week: Double?
        var fiveHourResetsAt: Date? = nil
        var weekResetsAt: Date? = nil
        /// Warum der letzte Abruf nichts oder nur alte Zahlen brachte.
        var problem: Problem? = nil
    }

    enum Problem: Equatable {
        case claude(ClaudeUsageFetchProblem)
        /// GPT-Backend: keine Zahlen (Token in der Datei veraltet).
        case gptUnavailable
    }

    private(set) var claude: [String: Limit] = [:]
    private(set) var gpt: [String: Limit] = [:]
    private(set) var updatedAt: Date?
    /// Letzter Abruf-Versuch, unabhängig vom Ergebnis: Auch nach Fehlern geht
    /// der nächste frühestens nach `maxAge` (sonst hieße jedes Öffnen
    /// Keychain und HTTP je Konto; Review Runde 5, Befund 5).
    private(set) var lastAttemptAt: Date?
    private(set) var isLoading = false
    /// Neue Zahlen sind da oder ein Abruf beginnt bzw. endet (ein offenes
    /// Konto-Menü und eine offene Insel ziehen nach).
    var onChange: (() -> Void)?

    func limit(kind: ControllerAccountChoice.Kind, name: String) -> Limit? {
        switch kind {
        case .claude: return claude[name]
        case .gpt: return gpt[name]
        }
    }

    func record(claude name: String, usage: ClaudeAccountUsage) {
        guard usage.hasLimitData || usage.liveFetchProblem != nil else { return }
        claude[name] = Self.limit(usage)
        changed()
    }

    func record(gpt name: String, usage: CodexUsage) {
        gpt[name] = Self.limit(usage)
        changed()
    }

    /// GPT-Konto ohne Zahlen (wie „Limits nicht verfügbar“ im Popover).
    func recordFailure(gpt name: String) {
        gpt[name] = Limit(fiveHour: nil, week: nil, problem: .gptUnavailable)
        changed()
    }

    static func limit(_ usage: ClaudeAccountUsage) -> Limit {
        Limit(
            fiveHour: usage.fiveHourPercent, week: usage.sevenDayPercent,
            fiveHourResetsAt: usage.fiveHourResetsAt, weekResetsAt: usage.sevenDayResetsAt,
            problem: usage.liveFetchProblem.map { .claude($0) })
    }

    static func limit(_ usage: CodexUsage) -> Limit {
        let windows = [usage.primary, usage.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.windowMinutes == 300 }
        let week = windows.first { $0.windowMinutes == 10080 }
        return Limit(
            fiveHour: fiveHour?.usedPercent, week: week?.usedPercent,
            fiveHourResetsAt: fiveHour?.resetsAt, weekResetsAt: week?.resetsAt)
    }

    private func changed() {
        updatedAt = Date()
        onChange?()
    }

    // MARK: - Konten

    /// Angemeldete Claude-Konten, wie das Claude-Popover sie zeigt (aus dem
    /// kurzlebigen Cache des Kontextmenüs).
    static func claudeAccountNames() -> [String] {
        AccountMenuData.claudeProfiles.value.filter(\.isLoggedIn).map(\.name)
    }

    /// Angemeldete Konten des GPT-Backends, wie das GPT-Popover sie zeigt
    /// (ohne das Codex-CLI-Konto des Diktats).
    static func gptAccountNames() -> [String] {
        let profiles = CodexUsagePopoverTargets.displayedProfiles(
            backendEnabled: AppPreferences.shared.claudeGPTBackendEnabled,
            profilesEnabled: AppPreferences.shared.isGPTAccountProfilesEnabled,
            all: { AccountMenuData.gptProfiles.value },
            main: {
                AccountMenuData.gptProfiles.value.first { $0.name == GPTAccountProfiles.mainProfileName }
                    ?? GPTAccountProfiles().profile(named: GPTAccountProfiles.mainProfileName)
            })
        return CodexUsagePopoverTargets.fetchTargets(profiles).map(\.name)
    }

    // MARK: - Abrufen

    /// Passiver Abruf wie beim Öffnen der Popovers, wenn der Stand älter als
    /// `maxAge` ist.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !isLoading else { return }
        let now = Date()
        if let updatedAt, now.timeIntervalSince(updatedAt) < maxAge { return }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < maxAge { return }
        load(renewing: false)
    }

    /// Derselbe Weg wie ↻ in den Popovers: Claude über den Update-Flow
    /// (abgelaufene Tokens per CLI-Ping, seriell), GPT neu abfragen. Nur auf
    /// ausdrücklichen Druck (✕ in der Limits-Karte).
    func refresh() {
        guard !isLoading else { return }
        load(renewing: true)
    }

    private func load(renewing: Bool) {
        lastAttemptAt = Date()
        isLoading = true
        onChange?()
        let claudeNames = Self.claudeAccountNames()
        let gptNames = Self.gptAccountNames()
        Task { @MainActor [weak self] in
            if renewing {
                _ = await ClaudeUsageUpdateFlow.run(profileNames: claudeNames) { name, usage in
                    self?.record(claude: name, usage: usage)
                }
            } else {
                let claudeResults = await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
                    for name in claudeNames {
                        group.addTask { (name, await ClaudeAccountUsageFetcher().fetchUsage(forProfile: name)) }
                    }
                    var collected: [(String, ClaudeAccountUsage?)] = []
                    for await result in group { collected.append(result) }
                    return collected
                }
                for (name, usage) in claudeResults { if let usage { self?.record(claude: name, usage: usage) } }
            }
            let gptResults = await withTaskGroup(of: (String, CodexUsage?).self) { group in
                for name in gptNames {
                    group.addTask {
                        let file = GPTAccountProfiles().authFileURL(forProfile: name)
                        return (name, await CodexUsageFetcher(proxyAuthFile: file).fetchLiveUsage())
                    }
                }
                var collected: [(String, CodexUsage?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            guard let self else { return }
            for (name, usage) in gptResults {
                if let usage { self.record(gpt: name, usage: usage) } else { self.recordFailure(gpt: name) }
            }
            self.isLoading = false
            self.onChange?()
        }
    }
}

extension ClaudeUsageFetchProblem {
    /// Text für Popover und Limits-Karte der Dynamic Island.
    var displayText: String {
        switch self {
        case .noCredentials:
            return String(localized: "No login token — sign in again in the account settings")
        case .loginExpired:
            return String(localized: "Login expired — sign in again in the account settings")
        case .refreshBlockedBySession:
            return String(localized: "Token expired — the running session will renew it shortly")
        case .tokenExpired:
            return String(localized: "Token expired — ↻ renews it via CLI ping")
        case .refreshCoolingDown(let until):
            return String(localized: "Just pinged — next attempt from \(AgentChatsClaudeAccountsTab.timeText(until))")
        case .httpStatus(429):
            return String(localized: "Rate limit from Anthropic — try again shortly")
        case .httpStatus(let status):
            return String(localized: "Live fetch failed (HTTP \(status))")
        case .network:
            return String(localized: "Offline — last known state")
        }
    }
}

extension AccountLimitsStore.Problem {
    var displayText: String {
        switch self {
        case .claude(let problem): return problem.displayText
        case .gptUnavailable: return String(localized: "Limits unavailable (token in the file is stale)")
        }
    }
}
