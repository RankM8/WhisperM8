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
        // Fensterweite Werte für das Kontextmenü der Zeilen, einmal je Body
        // gelesen (Schlüssel der Gruppen, siehe `SidebarGroupMenuState`).
        let menuMultiSelection = multiSelection
        let menuPinned = pinnedSessionIDs
        let menuWorkspaces = windowStore.gridWorkspaces
        let menuVisibleGrid = isGridActive ? activeGridWorkspaceEntity : nil
        let menuClaudeProfiles = AccountMenuData.claudeProfiles.value
        let menuGPTProfiles = AccountMenuData.gptProfiles.value
        let menuBulkMove = AppPreferences.shared.isAccountBulkMoveEnabled
        let menuGPTAccounts = AppPreferences.shared.claudeGPTBackendEnabled
            && AppPreferences.shared.isGPTAccountProfilesEnabled
        let menuPendingSwitches = AccountSwitchCoordinator.shared.pending.mapValues(\.targetName)
        let menuUndoable = hasUndoableAccountMove
        let menuStoppableJobs = Set(jobRuntimeModel.snapshotsBySessionID.compactMap { id, state in
            state.isActive && state.supervisorPid != nil ? id : nil
        })
        ForEach(Array(snapshot.visibleProjects.enumerated()), id: \.element.id) { index, project in
            if index == snapshot.firstCalmProjectIndex {
                SidebarCalmProjectsBand()
            }
            let blocks = snapshot.projectBlocks[project.id] ?? SidebarProjectBlocks()
            // Nur, was diese Gruppe zeigt (WM8-101): Eine Gruppe, die weder die
            // alte noch die neue Auswahl enthält, behält ihre Eingaben und wird
            // übersprungen statt bei jedem Wechsel neu ausgewertet.
            let inputs = SidebarProjectGroupInputs.narrowed(
                blocks: blocks,
                selectedSessionID: selectedSessionID,
                multiSelection: multiSelection,
                openTabIDs: openTabIDSet,
                autoRenamingSessionIDs: autoRenamingSessionIDs,
                missingTranscriptSessionIDs: missingTranscriptIDs,
                subagentChildrenByParent: snapshot.subagentChildrenByParent,
                workingSubagentSessionIDs: workingSubagentIDs,
                erroredSubagentSessionIDs: erroredSubagentIDs,
                unreadSubagentSessionIDs: windowStore.unreadSubagentSessionIDs,
                expandedSubagentParentIDs: windowStore.expandedSubagentParentIDs
            )
            let isExpanded = expandedProjectIDs.contains(project.id) || !searchText.isEmpty
            let activeIDs = snapshot.activeSessionIDsByProject[project.id] ?? []
            let worktrees = snapshot.worktreesByProject[project.id] ?? []
            let isWorkspaceOpen = isGridActive && activeGridWorkspaceEntity?.sourceProjectID == project.id
            let occupancyLabel = projectViewOccupancyLabel(for: project, activeCount: activeIDs.count)
            let groupIDs = SidebarProjectGroupInputs.sessionIDs(
                blocks: blocks, subagentChildrenByParent: snapshot.subagentChildrenByParent)
            let menuState = SidebarGroupMenuState.make(
                groupSessionIDs: groupIDs, multiSelection: menuMultiSelection, pinnedSessionIDs: menuPinned,
                gridWorkspaces: menuWorkspaces, visibleGrid: menuVisibleGrid,
                claudeProfiles: menuClaudeProfiles, gptProfiles: menuGPTProfiles,
                accountBulkMoveEnabled: menuBulkMove, gptAccountMenuEnabled: menuGPTAccounts,
                pendingAccountSwitches: menuPendingSwitches,
                hasUndoableAccountMove: menuUndoable, pendingLifecycle: pendingLifecycleSessions,
                takenOverJobs: Set(groupIDs.filter { jobRuntimeModel.isTakenOver($0) }),
                stoppableJobs: menuStoppableJobs
            )
            SidebarSkippingGroup(key: SidebarProjectGroupKey(
                project: project, blocks: blocks, inputs: inputs, isExpanded: isExpanded,
                worktreeProjects: worktrees, activeSessionIDs: activeIDs, isWorkspaceOpen: isWorkspaceOpen,
                workspaceOccupancyLabel: occupancyLabel, sidebarScope: effectiveScope,
                isSearching: isSearching, stoppedFoldOverride: foldOverrides[project.id], menu: menuState
            )) {
            ProjectChatGroup(
                project: project,
                blocks: blocks,
                isExpanded: isExpanded,
                selectedSessionID: inputs.selectedSessionID,
                multiSelection: inputs.multiSelection,
                openTabIDs: inputs.openTabIDs,
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
                }, worktreeProjects: worktrees,
                canOpenAsWorkspace: !activeIDs.isEmpty,
                isWorkspaceOpen: isWorkspaceOpen,
                workspaceOccupancyLabel: occupancyLabel,
                onOpenAsWorkspace: {
                    openProjectAsWorkspace(project, activeSessionIDs: activeIDs)
                },
                onCloseSession: { closeSelectionFromSidebar(forID: $0.id) },
                sidebarScope: effectiveScope,
                onRename: renameSession,
                sessionMenu: { AnyView(sessionContextMenu($0, context: .sidebarRow)) },
                subagentChildMenu: { AnyView(sessionContextMenu($0, context: .subagentChild)) },
                statusStore: runtimeStatusStore,
                autoRenamingSessionIDs: inputs.autoRenamingSessionIDs,
                missingTranscriptSessionIDs: inputs.missingTranscriptSessionIDs,
                subagentChildrenByParent: inputs.subagentChildrenByParent,
                workingSubagentSessionIDs: inputs.workingSubagentSessionIDs,
                erroredSubagentSessionIDs: inputs.erroredSubagentSessionIDs,
                unreadSubagentSessionIDs: inputs.unreadSubagentSessionIDs,
                expandedSubagentParentIDs: inputs.expandedSubagentParentIDs,
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
            .equatable()
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
