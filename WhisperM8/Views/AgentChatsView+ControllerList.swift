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
            globalOpenTabIDs: windowStore.allWindowOpenTabIDs
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
            let limit = ProjectChatGroup.initialVisibleSessionLimit(for: effectiveScope)
            input.projects = snapshot.visibleProjects.map { project in
                let sessions = snapshot.sessionsByProject[project.id] ?? []
                let visible = ProjectChatGroup.visibleSlice(
                    of: sessions, limit: limit, mustIncludeID: selectedSessionID
                ).visible
                return AgentChatsListRowsBuilder.Project(
                    id: project.id,
                    isExpanded: expandedProjectIDs.contains(project.id) || !searchText.isEmpty,
                    visibleChats: visible.map(\.id),
                    activeSessionIDs: snapshot.activeSessionIDsByProject[project.id] ?? []
                )
            }
        }
        return AgentChatsListRowsBuilder.rows(input)
    }
}
