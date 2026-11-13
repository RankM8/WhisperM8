import Foundation

/// Zeilen der Limits-Karte aus dem `AccountLimitsStore`. Pur bis auf
/// `liveAccounts`, das die Konten über den kurzlebigen Cache des
/// Kontextmenüs liest (Profile auf der Platte) — nur einmal, wenn die Karte
/// aufgeht. Neue Zahlen ordnen sich danach nur noch zu (`live`).
enum ControllerLimitRows {
    static func rows(
        claude: [String], gpt: [String],
        limit: (ControllerAccountChoice.Kind, String) -> AccountLimitsStore.Limit?
    ) -> [ControllerAccountLimitRow] {
        func row(_ kind: ControllerAccountChoice.Kind, _ name: String) -> ControllerAccountLimitRow {
            let value = limit(kind, name)
            return ControllerAccountLimitRow(
                kind: kind, name: name, fiveHour: value?.fiveHour, week: value?.week,
                fiveHourResetsAt: value?.fiveHourResetsAt, weekResetsAt: value?.weekResetsAt,
                problem: value.flatMap { limit in
                    limit.problem?.displayText(hasNumbers: limit.fiveHour != nil || limit.week != nil)
                },
                problemReplacesNumbers: value?.problem?.replacesNumbers ?? false)
        }
        return claude.map { row(.claude, $0) } + gpt.map { row(.gpt, $0) }
    }

    @MainActor
    static func liveAccounts() -> ControllerLimitAccounts {
        ControllerLimitAccounts(
            claude: AccountLimitsStore.claudeAccountNames(), gpt: AccountLimitsStore.gptAccountNames())
    }

    @MainActor
    static func live(_ accounts: ControllerLimitAccounts) -> [ControllerAccountLimitRow] {
        let store = AccountLimitsStore.shared
        return rows(claude: accounts.claude, gpt: accounts.gpt, limit: { store.limit(kind: $0, name: $1) })
    }
}

extension ControllerUsageAccount {
    /// Konto, dessen Limits der Chat belastet: GPT-Chats (über das
    /// GPT-Backend) ihr GPT-Konto, Claude-Chats ihr Claude-Konto, Codex und
    /// Shells keins. Dieselben Schalter wie beim Start (`AgentCommandBuilder`):
    /// Ist das GPT-Backend aus, läuft ein GPT-gestempelter Chat als Claude
    /// über sein Claude-Konto; sind GPT-Konten aus, über das GPT-Hauptkonto.
    static func of(
        _ session: AgentChatSession, gptBackendEnabled: Bool, gptProfilesEnabled: Bool
    ) -> ControllerUsageAccount? {
        guard session.provider == .claude, !session.isTerminal else { return nil }
        let stamp = session.claudeBackendModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if gptBackendEnabled, !stamp.isEmpty {
            let name = gptProfilesEnabled ? session.gptProfileName : nil
            return ControllerUsageAccount(kind: .gpt, name: name ?? GPTAccountProfiles.mainProfileName)
        }
        return ControllerUsageAccount(
            kind: .claude, name: session.claudeProfileName ?? ClaudeAccountProfiles.mainProfileName)
    }
}

extension ControllerAlertStage {
    init(_ level: AgentAlertLevel) {
        switch level {
        case .all: self = .all
        case .soundOff: self = .soundOff
        case .off: self = .off
        }
    }
}

extension ControllerAwakeStage {
    init(_ mode: StayAwakeMode) {
        switch mode {
        case .off: self = .off
        case .whileWorking: self = .whileWorking
        case .always: self = .always
        }
    }
}
