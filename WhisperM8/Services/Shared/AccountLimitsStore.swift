import Foundation

/// Letzter bekannter Verbrauch je Konto (5-Stunden-Fenster und Woche), für
/// den Controller (Konto-Menü mit Prozenten, Runde 5). Die Limits-Popovers
/// tragen ihre Ergebnisse hier ein; der Controller stößt beim Öffnen des
/// Konto-Menüs höchstens einmal je Minute denselben passiven Abruf an wie das
/// Öffnen des Popovers (nur lesen, nie Tokens erneuern). Kein I/O auf dem Main
/// Thread, nichts läuft dauerhaft.
@MainActor
final class AccountLimitsStore {
    static let shared = AccountLimitsStore()

    struct Limit: Equatable {
        /// Verbraucht in Prozent; `nil`, wenn unbekannt.
        var fiveHour: Double?
        var week: Double?
    }

    private(set) var claude: [String: Limit] = [:]
    private(set) var gpt: [String: Limit] = [:]
    private(set) var updatedAt: Date?
    /// Letzter Abruf-Versuch, unabhängig vom Ergebnis: Auch nach Fehlern geht
    /// der nächste frühestens nach `maxAge` (sonst hieße jedes Öffnen
    /// Keychain und HTTP je Konto; Review Runde 5, Befund 5).
    private(set) var lastAttemptAt: Date?
    private var isLoading = false
    /// Neue Zahlen sind da (ein offenes Konto-Menü zieht nach).
    var onChange: (() -> Void)?

    func limit(kind: ControllerAccountChoice.Kind, name: String) -> Limit? {
        switch kind {
        case .claude: return claude[name]
        case .gpt: return gpt[name]
        }
    }

    func record(claude name: String, usage: ClaudeAccountUsage) {
        guard usage.hasLimitData else { return }
        claude[name] = Limit(fiveHour: usage.fiveHourPercent, week: usage.sevenDayPercent)
        changed()
    }

    func record(gpt name: String, usage: CodexUsage) {
        gpt[name] = Self.limit(usage)
        changed()
    }

    static func limit(_ usage: CodexUsage) -> Limit {
        let windows = [usage.primary, usage.secondary].compactMap { $0 }
        return Limit(
            fiveHour: windows.first { $0.windowMinutes == 300 }?.usedPercent,
            week: windows.first { $0.windowMinutes == 10080 }?.usedPercent)
    }

    private func changed() {
        updatedAt = Date()
        onChange?()
    }

    /// Passiver Abruf wie beim Öffnen der Popovers, wenn der Stand älter als
    /// `maxAge` ist. Die Kontenlisten kommen aus dem Cache des Kontextmenüs.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !isLoading else { return }
        let now = Date()
        if let updatedAt, now.timeIntervalSince(updatedAt) < maxAge { return }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < maxAge { return }
        lastAttemptAt = now
        isLoading = true
        let claudeNames = AccountMenuData.claudeProfiles.value.filter(\.isLoggedIn).map(\.name)
        let gptNames = AppPreferences.shared.claudeGPTBackendEnabled
            ? AccountMenuData.gptProfiles.value.filter(\.isLoggedIn).map(\.name) : []
        Task { @MainActor [weak self] in
            let claudeResults = await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
                for name in claudeNames {
                    group.addTask { (name, await ClaudeAccountUsageFetcher().fetchUsage(forProfile: name)) }
                }
                var collected: [(String, ClaudeAccountUsage?)] = []
                for await result in group { collected.append(result) }
                return collected
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
            self.isLoading = false
            for (name, usage) in claudeResults { if let usage { self.record(claude: name, usage: usage) } }
            for (name, usage) in gptResults { if let usage { self.record(gpt: name, usage: usage) } }
        }
    }
}
