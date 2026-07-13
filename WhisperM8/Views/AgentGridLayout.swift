import Foundation

/// Automatisch gewähltes Grid-Layout — abgeleitet aus der Workspace-
/// Kapazität (2 = 1×2 · 3 = „2 oben + 1 breit" · 4 = 2×2; die Stufen 6/9
/// kommen mit Paket 3). Die frühere Tab-Anzahl-Ableitung samt
/// Mitgliedschafts-/Verdrängungs-Logik (`AgentGridLayout`) ist mit den
/// Workspace-Entities (Schema v4) ersatzlos entfallen — Slots sind jetzt
/// explizit und positionsstabil (`AgentGridWorkspace` + `WorkspaceSlotOps`).
enum AgentGridAutoLayout: Equatable {
    /// 1 Pane: Einzelansicht (Grid zeigt dasselbe wie maximiert).
    case single
    /// Kapazität 2: zwei Spalten.
    case cols2
    /// Kapazität 3: zwei oben, einer unten in voller Breite.
    case twoPlusOne
    /// Kapazität 4: 2×2.
    case grid2x2
    /// Kapazität 6: 3×2 (Paket 3).
    case grid3x2
    /// Kapazität 9: 3×3 (Paket 3).
    case grid3x3

    static func forTabCount(_ count: Int) -> AgentGridAutoLayout {
        switch count {
        case ...1: .single
        case 2: .cols2
        case 3: .twoPlusOne
        default: .grid2x2
        }
    }

    /// Layout aus der Workspace-Kapazität (erlaubte Stufen 2/3/4/6/9).
    static func forCapacity(_ capacity: Int) -> AgentGridAutoLayout {
        switch capacity {
        case ...2: .cols2
        case 3: .twoPlusOne
        case 4: .grid2x2
        case 6: .grid3x2
        default: .grid3x3
        }
    }

    var paneCount: Int {
        switch self {
        case .single: 1
        case .cols2: 2
        case .twoPlusOne: 3
        case .grid2x2: 4
        case .grid3x2: 6
        case .grid3x3: 9
        }
    }

    /// Spalten-/Zeilen-Geometrie (deckungsgleich mit
    /// `AgentGridWorkspace.columns/rows(forCapacity:)`).
    var columns: Int {
        switch self {
        case .single: 1
        case .cols2, .twoPlusOne, .grid2x2: 2
        case .grid3x2, .grid3x3: 3
        }
    }

    var rows: Int {
        switch self {
        case .single, .cols2: 1
        case .twoPlusOne, .grid2x2, .grid3x2: 2
        case .grid3x3: 3
        }
    }

    /// Zell-Geometrie eines Slot-Index: Zeile + Spaltenbereich (der
    /// twoPlusOne-Slot 2 spannt beide Spalten).
    func cell(forSlot index: Int) -> (row: Int, cols: ClosedRange<Int>)? {
        if self == .twoPlusOne {
            switch index {
            case 0: return (0, 0 ... 0)
            case 1: return (0, 1 ... 1)
            case 2: return (1, 0 ... 1)
            default: return nil
            }
        }
        guard index >= 0, index < paneCount else { return nil }
        let column = index % columns
        return (index / columns, column ... column)
    }
}

/// Tastatur-Fokusnavigation im Slot-Raster (⌃⌘-Pfeile, Plan F9) — GEOMETRISCH
/// statt linear: rechts/links bleiben in der Zeile, oben/unten folgen der
/// Spalte (Spann-Slots zählen für jede überdeckte Spalte). Leere Slots
/// werden IN der gewählten Richtung übersprungen. Unit-getestet in
/// `GridFocusNavigatorTests`.
enum GridFocusDirection {
    case left, right, up, down
}

enum GridFocusNavigator {
    /// Ziel-Slot für eine Richtung — `nil`, wenn es in dieser Richtung
    /// keinen belegten Slot (mehr) gibt. `occupied[i]` = Slot i ist belegt.
    static func target(
        from index: Int,
        direction: GridFocusDirection,
        layout: AgentGridAutoLayout,
        occupied: [Bool]
    ) -> Int? {
        guard let current = layout.cell(forSlot: index) else { return nil }
        let candidates = (0 ..< layout.paneCount).compactMap { slot -> (slot: Int, row: Int, cols: ClosedRange<Int>)? in
            guard slot != index, let cell = layout.cell(forSlot: slot) else { return nil }
            return (slot, cell.row, cell.cols)
        }

        let ordered: [(slot: Int, row: Int, cols: ClosedRange<Int>)]
        switch direction {
        case .right:
            ordered = candidates
                .filter { $0.row == current.row && $0.cols.lowerBound > current.cols.upperBound }
                .sorted { $0.cols.lowerBound < $1.cols.lowerBound }
        case .left:
            ordered = candidates
                .filter { $0.row == current.row && $0.cols.upperBound < current.cols.lowerBound }
                .sorted { $0.cols.upperBound > $1.cols.upperBound }
        case .down:
            // Spalten-Anker: linke Kante der aktuellen Zelle. Spann-Slots
            // treffen, wenn sie den Anker überdecken.
            ordered = candidates
                .filter { $0.row > current.row && $0.cols.contains(current.cols.lowerBound) }
                .sorted { $0.row < $1.row }
        case .up:
            ordered = candidates
                .filter { $0.row < current.row && $0.cols.contains(current.cols.lowerBound) }
                .sorted { $0.row > $1.row }
        }

        return ordered.first { occupied.indices.contains($0.slot) && occupied[$0.slot] }?.slot
    }
}
