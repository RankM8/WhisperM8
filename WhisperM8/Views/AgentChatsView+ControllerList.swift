import SwiftUI

/// Zeilen der Liste links für die Navigation ohne Maus (Controller).
extension AgentChatsView {
    /// Die Zeilen, die die Seitenleiste gerade zeigt, in Anzeige-Reihenfolge.
    ///
    /// Baut dasselbe Modell wie die Seitenleiste (`AgentSidebarModelBuilder`),
    /// aber nur im Ereignis-Pfad — nie aus einem Body. Was eine Projektgruppe
    /// über „N weitere anzeigen“ zusätzlich aufgeklappt hat, kennt nur die
    /// Gruppe selbst; die Navigation reicht deshalb bis zu ihrem Startlimit
    /// (und immer bis zum ausgewählten Chat).
    func controllerListRows() -> [AgentChatsListRow] {
        guard !archiveModeActive else { return [] }
        let runningSessionIDs = terminalRegistry.activeSessionIDs
            .union(jobRuntimeModel.runningCountByParentSessionID.filter { $0.value > 0 }.keys)
            .union(jobRuntimeModel.activeSubagentSessionIDs)
        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: pinnedSessionIDs,
            scope: makeScopeFilter(openTabIDs: Set(openTabIDs), runningSessionIDs: runningSessionIDs),
            layout: sidebarLayout,
            query: searchText,
            flatVisibleLimit: flatVisibleSessionLimit,
            selectedSessionID: selectedSessionID,
            globalOpenTabIDs: windowStore.allWindowOpenTabIDs,
            gridWorkspaces: windowStore.gridWorkspaces
        )
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let sessionsByID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var input = AgentChatsListRowsBuilder.Input()
        input.pinned = snapshot.visiblePinned.map { .init(id: $0.id, projectID: $0.projectID) }
        input.isPinnedCollapsed = pinnedSectionCollapsed
        input.workspaces = windowStore.gridWorkspaces
            .filter { $0.sourceProjectID == nil }
            .map { entity in
                AgentChatsListRowsBuilder.Workspace(
                    id: entity.id,
                    isCollapsed: windowStore.isGridWorkspaceCollapsed(entity.id),
                    chats: entity.slots.compactMap { $0 }.compactMap { sessionsByID[$0] }
                        .map { .init(id: $0.id, projectID: $0.projectID) }
                )
            }
        input.isWorkspacesCollapsed = workspacesSectionCollapsed
        input.isChatListHidden = chatsSectionCollapsed && !isSearching
        if sidebarLayout == .flat {
            input.flatChats = snapshot.visibleFlatSessions.map { .init(id: $0.id, projectID: $0.projectID) }
        } else {
            let foldOverrides = windowStore.stoppedFoldOverrides
            input.projects = snapshot.visibleProjects.map { project in
                // Seitenleiste A (WM8-80): laufende, dann gestoppte, so weit
                // die Faltzeile „N gestoppt“ sie ohne Klick zeigt.
                let visible = ProjectChatGroup.defaultVisibleRowIDs(
                    blocks: snapshot.projectBlocks[project.id] ?? SidebarProjectBlocks(),
                    scope: effectiveScope,
                    isSearching: isSearching,
                    selectedSessionID: selectedSessionID,
                    stoppedFoldOverride: foldOverrides[project.id]
                )
                return AgentChatsListRowsBuilder.Project(
                    id: project.id,
                    isExpanded: expandedProjectIDs.contains(project.id) || !searchText.isEmpty,
                    visibleChats: visible,
                    activeSessionIDs: snapshot.activeSessionIDsByProject[project.id] ?? []
                )
            }
        }
        return AgentChatsListRowsBuilder.rows(input)
    }
}
