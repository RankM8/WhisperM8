import Foundation

/// Automatisch gewähltes Grid-Layout — abgeleitet aus der Tab-Anzahl,
/// kein manuelles Preset mehr (Maximize/Minimize-Konzept 2026-07-13).
enum AgentGridAutoLayout: Equatable {
    /// 1 Tab: Einzelansicht (Grid zeigt dasselbe wie maximiert).
    case single
    /// 2 Tabs: zwei Spalten.
    case cols2
    /// 3 Tabs: zwei oben, einer unten in voller Breite.
    case twoPlusOne
    /// 4+ Tabs: 2×2 (mehr Tabs laufen über den Bring-into-View-Swap).
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

/// Pure Slot-Logik der Grid-Ansicht: die Panes zeigen die ersten N offenen
/// Tabs in Anzeige-Reihenfolge. Kein eigener Slot-Zustand — alles leitet
/// sich aus `openTabIDs` ab (eine Wahrheit, persistiert wie bisher).
/// Unit-getestet in `AgentGridLayoutTests`.
enum AgentGridLayout {
    /// Die sichtbaren Panes: Präfix der (gefilterten) Tab-Liste.
    static func visibleIDs(_ orderedTabIDs: [UUID], paneCount: Int) -> [UUID] {
        Array(orderedTabIDs.prefix(max(0, paneCount)))
    }

    /// Reihenfolge, die einen NICHT sichtbaren selektierten Tab ins
    /// Sichtfenster holt: er tauscht den Platz mit dem zuvor selektierten
    /// Tab (falls der sichtbar ist), sonst mit dem letzten sichtbaren Slot.
    /// `nil` = nichts zu tun (schon sichtbar, unbekannt oder kein Slot).
    ///
    /// Identity-Swap statt Index-Mathematik: `visibleIDs` kann eine
    /// GEFILTERTE Sicht sein (z. B. ohne archivierte Tabs), `openTabIDs`
    /// die rohe Store-Liste — der Tausch über die beiden UUIDs ist gegen
    /// diese Differenz robust.
    static func orderBringingIntoView(
        selected: UUID,
        openTabIDs: [UUID],
        visibleIDs: [UUID],
        previousSelected: UUID?
    ) -> [UUID]? {
        guard !visibleIDs.isEmpty,
              !visibleIDs.contains(selected),
              openTabIDs.contains(selected) else { return nil }
        let slotID = previousSelected.flatMap { visibleIDs.contains($0) ? $0 : nil }
            ?? visibleIDs[visibleIDs.count - 1]
        guard let selectedIndex = openTabIDs.firstIndex(of: selected),
              let slotIndex = openTabIDs.firstIndex(of: slotID) else { return nil }
        var order = openTabIDs
        order.swapAt(selectedIndex, slotIndex)
        return order
    }
}
