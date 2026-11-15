import Foundation

/// Pure Reihenfolge-Regeln der Tab-Leiste: welche Tabs in welcher Reihenfolge
/// stehen, welche bei eingeklappten Gruppen sichtbar bleiben und welche Tabs
/// ein Ziehen mitnimmt. Aus `AgentChatsView` herausgelöst (WM8-80, Paket 1),
/// damit die Regeln getestet sind, bevor die Leiste umgebaut wird. Die View
/// reicht nur Werte herein.
enum AgentTabOrder {
    /// Kanonische Anzeige-Reihenfolge nach dem Zusammenziehen der Herkunfts-
    /// gruppen. Shift-Klick, Mausrad, Umschalter und ⌘1–9 nutzen sie alle.
    static func orderIDs(of items: [AgentTabGroupingItem]) -> [UUID] {
        items.flatMap { item in
            switch item {
            case .single(let id): [id]
            case .group(_, let sessionIDs): sessionIDs
            }
        }
    }

    /// Von einer Gruppe sichtbare Tabs: aufgeklappt alle, eingeklappt nur
    /// der aktive Tab (falls er dazugehört), sonst keiner.
    static func visibleMemberIDs(
        _ sessionIDs: [UUID],
        collapsed: Bool,
        selectedID: UUID?
    ) -> [UUID] {
        guard collapsed else { return sessionIDs }
        guard let selectedID, sessionIDs.contains(selectedID) else { return [] }
        return [selectedID]
    }

    /// Reihenfolge der tatsächlich sichtbaren Tabs (Shift-Klick-Bereich).
    static func visibleOrderIDs(
        items: [AgentTabGroupingItem],
        collapsedKeys: Set<AgentTabGroupingKey>,
        selectedID: UUID?
    ) -> [UUID] {
        items.flatMap { item -> [UUID] in
            switch item {
            case .single(let id):
                return [id]
            case .group(let key, let sessionIDs):
                return visibleMemberIDs(
                    sessionIDs,
                    collapsed: collapsedKeys.contains(key),
                    selectedID: selectedID
                )
            }
        }
    }

    /// Welche Tabs ein Ziehen mitnimmt, in sichtbarer Reihenfolge.
    /// - Griff war ein Gruppen-Chip (`groupMemberIDs`): die ganze Gruppe.
    /// - Gezogener Tab ist Teil einer Mehrfachauswahl: die Auswahl, solange sie
    ///   nicht aus verschiedenen Herkunftsgruppen stammt (die Leiste könnte sie
    ///   dann nicht zusammenhängend zeigen; das Ziehen gilt dann nur ihm).
    /// - Sonst nur der gezogene Tab.
    static func dragGroup(
        droppedID: UUID,
        groupMemberIDs: [UUID]?,
        sourceOrder: [UUID],
        sourceSelection: Set<UUID>,
        groupingEnabled: Bool,
        keyOf: (UUID) -> AgentTabGroupingKey?
    ) -> [UUID] {
        if let members = groupMemberIDs, !members.isEmpty {
            let ordered = sourceOrder.filter(Set(members).contains)
            return ordered.isEmpty ? members : ordered
        }
        guard sourceSelection.count > 1, sourceSelection.contains(droppedID) else {
            return [droppedID]
        }
        var selectedIDs = sourceOrder.filter(sourceSelection.contains)
        // Eine Sidebar-Session kann ausgewählt, aber noch nicht als Tab offen
        // sein und fehlt dann in `sourceOrder`. Der gezogene Eintrag muss
        // trotzdem Teil der Gruppe bleiben.
        if !selectedIDs.contains(droppedID) {
            selectedIDs.append(droppedID)
        }
        let selectedKeys = Set(selectedIDs.compactMap(keyOf))
        if groupingEnabled, selectedKeys.count > 1 {
            return [droppedID]
        }
        return selectedIDs
    }
}
