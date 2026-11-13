import Foundation

/// Zeilen der Limits-Karte aus dem `AccountLimitsStore`. Pur bis auf `live`,
/// das die Kontenlisten aus dem kurzlebigen Cache des Kontextmenüs liest —
/// nur im Ereignis-Pfad, wenn die Karte aufgeht oder neue Zahlen kommen.
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
                problem: value?.problem?.displayText,
                problemReplacesNumbers: value?.problem?.replacesNumbers ?? false)
        }
        return claude.map { row(.claude, $0) } + gpt.map { row(.gpt, $0) }
    }

    @MainActor
    static func live() -> [ControllerAccountLimitRow] {
        let store = AccountLimitsStore.shared
        return rows(
            claude: AccountLimitsStore.claudeAccountNames(), gpt: AccountLimitsStore.gptAccountNames(),
            limit: { store.limit(kind: $0, name: $1) })
    }
}

extension AccountLimitsStore.Problem {
    /// Ohne gültigen Login sagen alte Zahlen nichts mehr.
    var replacesNumbers: Bool {
        switch self {
        case .claude(.loginExpired), .claude(.noCredentials), .gptUnavailable: return true
        case .claude: return false
        }
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
