import Foundation

/// Reihenfolge für ⌃⌥Tab „Sprung zum nächsten wartenden Chat"
/// (docs/plans/tab-switcher-workspace.md, Abschnitt „Offen / später").
/// Pur, window-frei → unit-testbar.
///
/// - **Umfang:** alle nicht archivierten Chats des Workspace mit Status
///   `.awaitingInput` — nicht nur offene Tabs.
/// - **Reihenfolge:** am längsten wartender zuerst (`statusSince`
///   aufsteigend). Ohne `statusSince` ans Ende; Gleichstände behalten die
///   Eingangsreihenfolge (stabil).
/// - **Rotation:** Ist der aktuelle Chat selbst wartend, kommt der nächste
///   in dieser Reihenfolge (mit Wrap-around) — wiederholtes ⌃⌥Tab geht so
///   alle Wartenden durch. Sonst der am längsten wartende.
///
/// Wird nur im Key-Event-Pfad ausgewertet, nie im View-Body
/// (Performance-Regeln des Plans).
enum NextWaitingChatResolver {
    struct Candidate: Equatable {
        var id: UUID
        var isArchived: Bool
        var status: AgentSessionRuntimeStatus?
        var statusSince: Date?
    }

    /// Wartende Chats in Sprung-Reihenfolge.
    static func order(_ candidates: [Candidate]) -> [UUID] {
        candidates.enumerated()
            .filter { !$0.element.isArchived && $0.element.status == .awaitingInput }
            .sorted { lhs, rhs in
                switch (lhs.element.statusSince, rhs.element.statusSince) {
                case let (l?, r?) where l != r:
                    return l < r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    // Gleicher Zeitpunkt oder beide ohne: Eingangsreihenfolge.
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element.id)
    }

    /// Ziel des nächsten Sprungs; `nil`, wenn kein (anderer) Chat wartet.
    /// Ist der aktuelle Chat der einzige wartende, gibt es kein Ziel.
    static func next(candidates: [Candidate], current: UUID?) -> UUID? {
        let order = order(candidates)
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return order.first
        }
        let next = order[(index + 1) % order.count]
        return next == current ? nil : next
    }
}
