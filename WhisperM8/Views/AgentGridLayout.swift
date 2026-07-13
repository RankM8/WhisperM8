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
    /// Harte Obergrenze der gleichzeitig sichtbaren Panes — mehr ist bei
    /// roher TUI nicht mehr lesbar.
    static let maxPanes = 4

    /// Die sichtbaren Panes: Präfix der (gefilterten) Tab-Liste.
    static func visibleIDs(_ orderedTabIDs: [UUID], paneCount: Int) -> [UUID] {
        Array(orderedTabIDs.prefix(max(0, paneCount)))
    }

    /// Sichtbare Panes unter Berücksichtigung der expliziten Mitgliedschaft:
    /// Mitglieder in **Tab-Reihenfolge** (Reorder der Leiste ordnet auch das
    /// Grid), gekappt auf `cap`. Leere ODER degenerierte (≤ 1 Treffer)
    /// Mitgliedschaft fällt auf den Default „alle offenen Tabs" zurück —
    /// das heilt auch verwaiste Reste, wenn Mitglieds-Tabs geschlossen wurden.
    static func visibleMembers(
        orderedTabIDs: [UUID],
        membership: [UUID],
        cap: Int = AgentGridLayout.maxPanes
    ) -> [UUID] {
        let memberSet = Set(membership)
        let filtered = orderedTabIDs.filter { memberSet.contains($0) }
        guard filtered.count > 1 else { return Array(orderedTabIDs.prefix(cap)) }
        return Array(filtered.prefix(cap))
    }

    /// Mitgliedschaft nach „Hinzufügen": das neue Mitglied kommt ans Ende;
    /// bei voller Kapazität weicht das älteste Mitglied, das weder das neue
    /// noch das fokussierte ist (die Pane, mit der gerade gearbeitet wird,
    /// verschwindet nie durch eine Aufnahme).
    static func membershipAdding(
        _ id: UUID,
        membership: [UUID],
        focused: UUID?,
        cap: Int = AgentGridLayout.maxPanes
    ) -> [UUID] {
        var members = membership.filter { $0 != id }
        members.append(id)
        while members.count > cap {
            guard let evictIndex = members.firstIndex(where: { $0 != id && $0 != focused }) else { break }
            members.remove(at: evictIndex)
        }
        return members
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
