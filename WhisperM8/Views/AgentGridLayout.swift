import Foundation

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
