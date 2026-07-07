import Foundation

/// Pure State-Machine des Ctrl+Tab-Switchers: hält die Tab-Reihenfolge und
/// das aktuell hervorgehobene Highlight während eines Durchlaufs (Control
/// gehalten). Ephemer — lebt als `@State` in der `AgentChatsView` und wird
/// nie persistiert. Window-frei → unit-testbar.
///
/// Die Reihenfolge wird bei jedem Schritt frisch hereingereicht
/// (`headerTabs` kann sich extern ändern, z. B. durch Archivierung oder
/// Workspace-Prune) — verschwindet der hervorgehobene Tab, fällt das
/// Highlight über `adjacentTabID` auf den ersten Tab zurück statt zu hängen.
struct TabSwitcherModel: Equatable {
    private(set) var highlightedID: UUID?

    /// Aktivierung: braucht ≥ 2 Tabs (mit einem Tab gibt es nichts
    /// umzuschalten). Das Highlight startet beim aktuellen Tab und macht
    /// sofort einen Schritt in `direction` — so wirkt der schnelle „Tap"
    /// (Ctrl+Tab drücken, sofort loslassen) als direkter Nachbar-Wechsel.
    static func begin(order: [UUID], current: UUID?, direction: Int) -> TabSwitcherModel? {
        guard order.count >= 2 else { return nil }
        var model = TabSwitcherModel(highlightedID: current ?? order.first)
        model.advance(direction, order: order)
        return model
    }

    /// Ein Schritt weiter/zurück mit Wrap-around (gleiche Mathematik wie
    /// ⌘⌥←/→, siehe `adjacentTabID`).
    mutating func advance(_ direction: Int, order: [UUID]) {
        highlightedID = adjacentTabID(in: order, current: highlightedID, direction: direction)
    }

    /// Commit-Ziel beim Loslassen von Control — `nil`, wenn der hervorgehobene
    /// Tab inzwischen nicht mehr existiert (dann bleibt die Selektion, wie
    /// sie ist, statt auf einen willkürlichen Tab zu springen).
    func commitTarget(order: [UUID]) -> UUID? {
        guard let highlightedID, order.contains(highlightedID) else { return nil }
        return highlightedID
    }
}
