import SwiftUI

/// Die Projektgruppen der Seitenleiste (gruppierte Ansicht). Seit WM8-80 nach
/// Seitenleiste A: Projekte mit laufenden Chats zuerst, danach der Trenner
/// „Ohne laufende Chats“; in jeder Gruppe laufende vor gestoppten Chats und
/// Workspace-Chats nur als Hinweis. Die Ordnung liefert der Snapshot
/// (`AgentSidebarSorting`), hier wird nur gezeichnet.
extension AgentChatsView {
    @ViewBuilder
    func sidebarProjectGroups(
        snapshot: AgentSidebarSnapshot,
        openTabIDs openTabIDSet: Set<UUID>,
        workingSubagentIDs: Set<UUID>,
        erroredSubagentIDs: Set<UUID>,
        listProxy: ScrollViewProxy
    ) -> some View {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let foldOverrides = windowStore.stoppedFoldOverrides
        ForEach(Array(snapshot.visibleProjects.enumerated()), id: \.element.id) { index, project in
            if index == snapshot.firstCalmProjectIndex {
                SidebarCalmProjectsBand()
            }
            let blocks = snapshot.projectBlocks[project.id] ?? SidebarProjectBlocks()
            ProjectChatGroup(
                project: project,
                blocks: blocks,
                isExpanded: expandedProjectIDs.contains(project.id) || !searchText.isEmpty,
                selectedSessionID: selectedSessionID,
                multiSelection: multiSelection,
                openTabIDs: openTabIDSet,
                onSelectProject: {
                    selectProject(project.id)
                },
                onToggleExpanded: {
                    toggleProject(project.id)
                },
                onSelectSession: { sessionID in
                    handleSidebarSessionClick(
                        sessionID,
                        project: project,
                        orderedSessionIDs: blocks.rows.map(\.id)
                    )
                },
                onNewChat: { target in
                    selectedProjectID = target.id; expandedProjectIDs.insert(project.id)
                    createDefaultSession()
                }, worktreeProjects: snapshot.worktreesByProject[project.id] ?? [],
                canOpenAsWorkspace: !(snapshot.activeSessionIDsByProject[project.id]?.isEmpty ?? true),
                isWorkspaceOpen: isGridActive
                    && activeGridWorkspaceEntity?.sourceProjectID == project.id,
                workspaceOccupancyLabel: projectViewOccupancyLabel(
                    for: project,
                    activeCount: snapshot.activeSessionIDsByProject[project.id]?.count ?? 0
                ),
                onOpenAsWorkspace: {
                    openProjectAsWorkspace(
                        project,
                        activeSessionIDs: snapshot.activeSessionIDsByProject[project.id] ?? []
                    )
                },
                onCloseSession: { closeSelectionFromSidebar(forID: $0.id) },
                sidebarScope: effectiveScope,
                onRename: renameSession,
                sessionMenu: { AnyView(sessionContextMenu($0, context: .sidebarRow)) },
                subagentChildMenu: { AnyView(sessionContextMenu($0, context: .subagentChild)) },
                statusStore: runtimeStatusStore,
                autoRenamingSessionIDs: autoRenamingSessionIDs,
                missingTranscriptSessionIDs: missingTranscriptIDs,
                subagentChildrenByParent: snapshot.subagentChildrenByParent,
                workingSubagentSessionIDs: workingSubagentIDs,
                erroredSubagentSessionIDs: erroredSubagentIDs,
                unreadSubagentSessionIDs: windowStore.unreadSubagentSessionIDs,
                expandedSubagentParentIDs: windowStore.expandedSubagentParentIDs,
                onToggleSubagentChildren: { windowStore.toggleSubagentChildren($0) },
                onRenameProjectRequest: { beginRenameProject($0) },
                onSetProjectColor: setProjectColor,
                onChooseProjectIcon: { chooseProjectIcon($0) },
                onAutoDetectProjectIcon: { reAutoDetectProjectIcon($0) },
                onClearProjectIcon: { clearProjectIcon($0) },
                onDeleteProject: { projectPendingDeletion = $0 },
                onSessionDrop: { dropped, beforeID, targetProjectID in
                    dropSession(dropped, in: targetProjectID, beforeSessionID: beforeID)
                },
                onProjectDrop: { dropped, beforeID in
                    dropProject(dropped, beforeProjectID: beforeID)
                },
                onJumpToWorkspace: { jumpToSidebarWorkspace($0, proxy: listProxy) },
                isSearching: isSearching,
                stoppedFoldOverride: foldOverrides[project.id],
                onSetStoppedFold: { windowStore.setStoppedFold(open: $0, for: project.id) }
            )
        }
    }

    /// Klick auf „N im Workspace …“: Abschnitt und Gruppe aufklappen und
    /// den Workspace-Kopf nach oben holen.
    func jumpToSidebarWorkspace(_ workspaceID: UUID, proxy: ScrollViewProxy) {
        workspacesSectionCollapsed = false
        if windowStore.isGridWorkspaceCollapsed(workspaceID) {
            windowStore.toggleGridWorkspaceCollapsed(workspaceID)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(SidebarNavigationRow.workspace(workspaceID), anchor: .top)
        }
    }
}
