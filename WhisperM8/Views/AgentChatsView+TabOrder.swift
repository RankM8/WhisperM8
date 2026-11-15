import SwiftUI

// MARK: - Tab-Leiste: Reihenfolge, Gruppen und Ziehen

/// Aus `AgentChatsView.swift` ausgelagert (WM8-80, Paket 1), ohne Änderung am
/// Verhalten: welche Tabs offen sind, ihre sichtbare Reihenfolge, Gruppen,
/// Drop-Slots und was ein Ziehen mitnimmt. Die Regeln selbst liegen pur und
/// getestet in `AgentTabOrder` und `AgentTabGrouping`; hier reicht die View
/// nur ihren Zustand hinein.
extension AgentChatsView {
    /// Globale Tab-Bar: alle offenen Tabs über alle Projekte, in der
    /// Reihenfolge von `openTabIDs`.
    var headerTabs: [AgentChatSession] {
        let byID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return openTabIDs.compactMap { byID[$0] }.filter { $0.status != .archived }
    }

    /// Erste Workspace-Zugehörigkeit in der persistierten Sidebar-Reihenfolge.
    /// Ein Chat kann technisch in mehreren Workspaces liegen; für die visuelle
    /// Tab-Herkunft gewinnt deterministisch der erste — und jeder Workspace
    /// gewinnt vor der Projektzugehörigkeit.
    /// Arbeitsordner neben dem Projekt gruppieren unter ihrem Haupt-Projekt
    /// (WM8-102), wie in der Seitenleiste.
    var tabProjectParents: [UUID: UUID] { projectParents }

    /// Projekt, unter dem ein Chat angezeigt wird (Symbol an Tab und Zeile):
    /// bei Arbeitsordnern neben dem Projekt das Haupt-Projekt (WM8-102).
    func displayProject(for session: AgentChatSession) -> AgentProject? {
        let shownID = AgentProjectDisplay.displayProjectID(session.projectID, parents: tabProjectParents)
        return workspace.projects.first { $0.id == shownID }
    }

    var tabWorkspaceBySession: [UUID: UUID] {
        // Gleiche Quelle wie `chats order --tabs`.
        windowStore.tabGroupWorkspaceBySession
    }

    var tabGroupingItems: [AgentTabGroupingItem] {
        tabGroupingItems(for: headerTabs)
    }

    /// Wie `tabGroupingItems`, aber aus bereits gebauten `headerTabs` — der
    /// Key-Event-Pfad des Ctrl+Tab-Switchers baut sie so nur einmal.
    func tabGroupingItems(for tabs: [AgentChatSession]) -> [AgentTabGroupingItem] {
        let parents = tabProjectParents
        return AgentTabGrouping.items(
            entries: tabs.map {
                AgentTabOrder.groupingEntry(sessionID: $0.id, projectID: $0.projectID, projectParents: parents)
            },
            workspaceBySession: tabWorkspaceBySession,
            enabled: tabGroupingEnabled
        )
    }

    /// Kanonische Anzeige-Reihenfolge nach dem Zusammenziehen der Herkunfts-
    /// gruppen. Alle Browser-Interaktionen (Shift, Wheel, Switcher, ⌘1–9)
    /// müssen dieselbe Reihenfolge nutzen, sonst springt der Fokus entgegen der
    /// sichtbaren Leiste.
    var visualTabOrderIDs: [UUID] {
        AgentTabOrder.orderIDs(of: tabGroupingItems)
    }

    /// Berechnet dieselbe Anzeige-Reihenfolge für ein beliebiges Fenster.
    /// Benötigt für Cross-Window-Drags, deren Quellfenster eine andere
    /// persistierte Tab-Reihenfolge besitzt.
    func visualTabOrderIDs(for orderedIDs: [UUID]) -> [UUID] {
        let sessionsByID = Dictionary(
            workspace.sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let parents = tabProjectParents
        let entries = orderedIDs.compactMap { id -> AgentTabGroupingEntry? in
            guard let session = sessionsByID[id], session.status != .archived else {
                return nil
            }
            return AgentTabOrder.groupingEntry(
                sessionID: session.id, projectID: session.projectID, projectParents: parents)
        }
        return AgentTabOrder.orderIDs(of: AgentTabGrouping.items(
            entries: entries,
            workspaceBySession: tabWorkspaceBySession,
            enabled: tabGroupingEnabled
        ))
    }

    func tabGroupingKey(for sessionID: UUID) -> AgentTabGroupingKey? {
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return AgentTabGrouping.key(
            for: AgentTabOrder.groupingEntry(
                sessionID: session.id, projectID: session.projectID, projectParents: tabProjectParents),
            workspaceBySession: tabWorkspaceBySession
        )
    }

    func draggedTabIDs(for dropped: DraggableSession) -> [UUID] {
        let source = dropped.sourceWindowID ?? windowID
        let sourceOrder = visualTabOrderIDs(
            for: windowStore.openTabIDs(in: source)
        )
        return AgentTabOrder.dragGroup(
            droppedID: dropped.sessionID,
            groupMemberIDs: dropped.groupMemberIDs,
            sourceOrder: sourceOrder,
            sourceSelection: windowStore.multiSelection(in: source),
            groupingEnabled: tabGroupingEnabled,
            keyOf: { tabGroupingKey(for: $0) }
        )
    }

    /// Schnappt einen rohen geometrischen Index auf die nächste erlaubte
    /// Slot-Grenze — die Einfügelinie zeigt danach exakt das, was der Drop
    /// auch tut.
    func snappedTabDropIndex(
        for dropped: DraggableSession,
        rawIndex: Int
    ) -> Int {
        let moving = draggedTabIDs(for: dropped)
        // Gemischte Herkunft (nur bei ausgeschalteter Gruppierung möglich)
        // hat keinen Zielcluster — dann gilt allein die Grundregel.
        return AgentTabGrouping.snappedInsertionIndex(
            requested: rawIndex,
            slots: tabStripSlots,
            movingIDs: Set(moving),
            movingOrigin: AgentTabOrder.movingOrigin(moving, keyOf: { tabGroupingKey(for: $0) }),
            originOfSession: { tabGroupingKey(for: $0) },
            groupingEnabled: tabGroupingEnabled
        )
    }

    func tabDropTargetID(atSlotIndex index: Int, moving: Set<UUID>) -> UUID? {
        AgentTabGrouping.dropTargetID(
            atSlotIndex: index,
            in: tabStripSlots,
            movingIDs: moving
        )
    }

    var visibleTabOrderIDs: [UUID] {
        AgentTabOrder.visibleOrderIDs(
            items: tabGroupingItems,
            collapsedKeys: collapsedTabGroups,
            selectedID: selectedSessionID
        )
    }

    /// Drop-Einheiten der Leiste. Eine eingeklappte Gruppe ist EIN Slot —
    /// dadurch bleibt sie beim Ziehen ein gültiges Ziel, ohne aufzuklappen.
    var tabStripSlots: [AgentTabStripSlot] {
        AgentTabGrouping.slots(items: tabGroupingItems, collapsedKeys: collapsedTabGroups)
    }

    /// Geometrie-Schlüssel der Slots (ein Eintrag je Drop-Einheit).
    var tabSlotOrderIDs: [UUID] { tabStripSlots.map(\.leadingID) }

    var visualHeaderTabs: [AgentChatSession] {
        visualHeaderTabs(from: headerTabs)
    }

    /// `visualHeaderTabs` aus bereits gebauten `headerTabs`. Die computed
    /// Property baute `headerTabs` (Dictionary über ALLE Sessions) zweimal —
    /// einmal direkt, einmal über `visualTabOrderIDs`. Der Ctrl+Tab-Pfad
    /// (`refreshTabSwitcherScope`, pro Taste) nutzt diese Variante.
    func visualHeaderTabs(from tabs: [AgentChatSession]) -> [AgentChatSession] {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AgentTabOrder.orderIDs(of: tabGroupingItems(for: tabs)).compactMap { byID[$0] }
    }

    var visibleHeaderTabs: [AgentChatSession] {
        let byID = Dictionary(headerTabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return visibleTabOrderIDs.compactMap { byID[$0] }
    }

    func tabGroupMetadata(
        for key: AgentTabGroupingKey
    ) -> (title: String, colorHex: String) {
        switch key {
        case .workspace(let id):
            if let entity = windowStore.gridWorkspace(id: id) {
                return (entity.name, entity.colorHex)
            }
        case .project(let id):
            if let project = workspace.projects.first(where: { $0.id == id }) {
                return (project.name, project.color)
            }
        }
        return ("Gruppe", AgentGridWorkspace.defaultColorHex)
    }

    /// `true`, wenn der Tab-Strip-Inhalt breiter ist als sein sichtbarer
    /// Bereich — dann blenden wir das Chevron-Overflow-Menü ein. Im Fullscreen
    /// (alle Tabs passen rein) ist das `false`.
    var hasTabOverflow: Bool {
        stripContentWidth > stripViewportWidth + 1
    }
}
