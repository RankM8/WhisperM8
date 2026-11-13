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
        /// GPT-Backend: Der Live-Abruf brachte keine Zahlen. Warum, sagt er
        /// nicht (Token fehlt oder veraltet, offline, Zeitüberschreitung).
        case gptFetchFailed

        /// Ohne gültigen Login sagen alte Zahlen nichts mehr. Bei allen
        /// anderen Problemen bleiben die letzten Zahlen stehen.
        var replacesNumbers: Bool {
            switch self {
            case .claude(.loginExpired), .claude(.noCredentials): return true
            case .claude, .gptFetchFailed: return false
            }
        }
    }

    private(set) var claude: [String: Limit] = [:]
    private(set) var gpt: [String: Limit] = [:]
    /// Wann zuletzt echte Zahlen kamen (live abgerufen); ein gescheiterter
    /// Abruf ändert das nicht.
    private(set) var updatedAt: Date?
    /// Letzter Abruf-Versuch, unabhängig vom Ergebnis: Auch nach Fehlern geht
    /// der nächste frühestens nach `maxAge` (sonst hieße jedes Öffnen
    /// Keychain und HTTP je Konto; Review Runde 5, Befund 5).
    private(set) var lastAttemptAt: Date?
    private(set) var isLoading = false
    /// Neue Zahlen sind da oder ein Abruf beginnt bzw. endet (ein offenes
    /// Konto-Menü und eine offene Insel ziehen nach).
    var onChange: (() -> Void)?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func limit(kind: ControllerAccountChoice.Kind, name: String) -> Limit? {
        switch kind {
        case .claude: return claude[name]
        case .gpt: return gpt[name]
        }
    }

    /// Ein Claude-Abruf. Mit Problem (offline, Token abgelaufen …) bleiben
    /// die letzten Zahlen samt Rücksetzzeiten stehen, wo der Abruf keine
    /// eigenen bringt — außer das Problem macht sie wertlos (Login beendet).
    func record(claude name: String, usage: ClaudeAccountUsage) {
        guard usage.hasLimitData || usage.liveFetchProblem != nil else { return }
        claude[name] = Self.merged(Self.limit(usage), previous: claude[name])
        changed(freshNumbers: usage.liveFetchProblem == nil && usage.hasLimitData)
    }

    func record(gpt name: String, usage: CodexUsage) {
        gpt[name] = Self.limit(usage)
        changed(freshNumbers: true)
    }

    /// GPT-Abruf ohne Zahlen: Die letzten bleiben stehen (mit Hinweis), der
    /// Stand-Zeitpunkt auch.
    func recordFailure(gpt name: String) {
        var limit = gpt[name] ?? Limit(fiveHour: nil, week: nil)
        limit.problem = .gptFetchFailed
        gpt[name] = limit
        changed(freshNumbers: false)
    }

    /// Neuer Stand über dem alten: Bringt er ein Problem, das die Zahlen
    /// nicht ersetzt, füllen die alten Zahlen und Rücksetzzeiten seine Lücken.
    static func merged(_ fresh: Limit, previous: Limit?) -> Limit {
        guard let previous, let problem = fresh.problem, !problem.replacesNumbers else { return fresh }
        var result = fresh
        if result.fiveHour == nil {
            result.fiveHour = previous.fiveHour
            result.fiveHourResetsAt = previous.fiveHourResetsAt
        }
        if result.week == nil {
            result.week = previous.week
            result.weekResetsAt = previous.weekResetsAt
        }
        return result
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

    private func changed(freshNumbers: Bool) {
        if freshNumbers { updatedAt = now() }
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
        let current = now()
        if let updatedAt, current.timeIntervalSince(updatedAt) < maxAge { return }
        if let lastAttemptAt, current.timeIntervalSince(lastAttemptAt) < maxAge { return }
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
        lastAttemptAt = now()
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
        case .gptFetchFailed: return Self.gptFetchFailedText(hasNumbers: false)
        }
    }

    /// Text für die Limits-Karte: Mit alten Zahlen sagt er, dass sie alt sind.
    func displayText(hasNumbers: Bool) -> String {
        switch self {
        case .claude(let problem): return problem.displayText
        case .gptFetchFailed: return Self.gptFetchFailedText(hasNumbers: hasNumbers)
        }
    }

    /// Auch im GPT-Popover. Der Abruf nennt keinen Grund, der Text rät keinen.
    static func gptFetchFailedText(hasNumbers: Bool) -> String {
        hasNumbers
            ? String(localized: "Live fetch failed — last known state")
            : String(localized: "Limits unavailable (live fetch failed)")
    }
}
