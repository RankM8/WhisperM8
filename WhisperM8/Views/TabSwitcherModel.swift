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

/// Berechnetes Karten-Grid des Switchers.
struct TabSwitcherGridMetrics: Equatable {
    var columns: Int
    var rows: Int
    /// Reihen, die ohne Scrollen ins Overlay passen.
    var visibleRows: Int
    var gridWidth: CGFloat
    var gridHeight: CGFloat

    var needsScroll: Bool { rows > visibleRows }
}

/// Pure Layout-Mathematik des Karten-Grids: Kartenmaß ist fix (Lesbarkeit),
/// Spalten-/Reihenzahl leitet sich aus Tab-Anzahl und verfügbarem Platz ab.
/// Alle Tabs werden mit Umbruch gezeigt; erst wenn die Reihen den verfügbaren
/// Platz sprengen, scrollt das Grid vertikal (`needsScroll`). Window-frei →
/// unit-testbar.
enum TabSwitcherGridLayout {
    static let cardWidth: CGFloat = 236
    static let cardHeight: CGFloat = 128
    static let spacing: CGFloat = 10
    /// Obergrenze — mehr als 4 Spalten liest niemand mehr im Block.
    static let maxColumns = 4
    /// Chrome um das Grid: Overlay-Padding + Karten-Padding + Footer-Zeile.
    /// Wird vom verfügbaren Platz abgezogen, bevor Spalten/Reihen berechnet
    /// werden.
    static let horizontalChrome: CGFloat = 96
    static let verticalChrome: CGFloat = 132

    static func metrics(count: Int, availableSize: CGSize) -> TabSwitcherGridMetrics {
        guard count > 0 else {
            return TabSwitcherGridMetrics(columns: 0, rows: 0, visibleRows: 0, gridWidth: 0, gridHeight: 0)
        }

        let availableWidth = max(0, availableSize.width - horizontalChrome)
        let fittingColumns = Int((availableWidth + spacing) / (cardWidth + spacing))
        let columns = max(1, min(count, maxColumns, fittingColumns))
        let rows = (count + columns - 1) / columns

        let availableHeight = max(0, availableSize.height - verticalChrome)
        let fittingRows = Int((availableHeight + spacing) / (cardHeight + spacing))
        let visibleRows = max(1, min(rows, fittingRows))

        return TabSwitcherGridMetrics(
            columns: columns,
            rows: rows,
            visibleRows: visibleRows,
            gridWidth: CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing,
            gridHeight: CGFloat(visibleRows) * cardHeight + CGFloat(visibleRows - 1) * spacing
        )
    }
}
