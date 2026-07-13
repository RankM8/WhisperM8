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

    static func forTabCount(_ count: Int) -> AgentGridAutoLayout {
        switch count {
        case ...1: .single
        case 2: .cols2
        case 3: .twoPlusOne
        default: .grid2x2
        }
    }

    var paneCount: Int {
        switch self {
        case .single: 1
        case .cols2: 2
        case .twoPlusOne: 3
        case .grid2x2: 4
        }
    }
}
