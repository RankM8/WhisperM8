import SwiftUI
import AppKit

/// Anbindung der AgentChatsView an den Befehls-Katalog
/// (`AgentChatsCommandCenter`): Anmeldung des Fensters und Ausführung der
/// Befehle über dieselben Funktionen, die auch Tastatur und Maus nutzen.
extension AgentChatsView {
    // MARK: - Anmeldung

    /// Meldet dieses Fenster am Befehls-Katalog an. Idempotent, wie die
    /// Monitore in `onAppear`.
    func registerCommandHandler() {
        guard commandState.token == nil else { return }
        commandState.history.record(selectedSessionID)
        commandState.token = AgentChatsCommandCenter.shared.register(
            windowID: windowID,
            handler: AgentChatsCommandCenter.Handler(
                perform: { performCommand($0) },
                snapshot: { commandSnapshot() },
                listRows: { controllerListRows() }
            )
        )
    }

    func unregisterCommandHandler() {
        guard let token = commandState.token else { return }
        AgentChatsCommandCenter.shared.unregister(token)
        commandState.token = nil
    }

    // MARK: - Schnappschuss

    /// Zustand dieses Fensters für den Befehls-Katalog. Nur im Ereignis-Pfad
    /// aufrufen, nie aus einem Body.
    func commandSnapshot() -> AgentChatsWindowSnapshot {
        AgentChatsWindowSnapshot(
            windowID: windowID,
            isKeyWindow: hostWindow?.isKeyWindow == true,
            selectedSessionID: selectedSession?.id,
            isGridActive: isGridActive,
            canReturnToWorkspace: !showsGrid && activeGridWorkspaceEntity != nil,
            isSwitcherOpen: tabSwitcher != nil,
            hasSheet: hostWindow?.attachedSheet != nil,
            isSidebarVisible: isSidebarVisible,
            hasMultiSelection: !multiSelection.isEmpty,
            isArchiveMode: archiveModeActive
        )
    }

    // MARK: - Ausführung

    /// Führt einen Befehl in diesem Fenster aus.
    /// - Returns: `true`, wenn er etwas bewirkt hat. `false` heißt „ging hier
    ///   nicht“ (kein Nachbar, kein wartender Chat, kein Raster) — der
    ///   Aufrufer kann das zurückmelden.
    @discardableResult
    func performCommand(_ command: AgentChatsCommand) -> Bool {
        switch command {
        case .previousTab:
            return changingSelection { selectAdjacentTab(-1) }
        case .nextTab:
            return changingSelection { selectAdjacentTab(+1) }
        case .nextWaitingChat:
            return selectNextWaitingChat()
        case .lastChat:
            let sessions = workspace.sessions
            guard let target = commandState.history.lastChat(isAvailable: { id in
                sessions.contains { $0.id == id && $0.status != .archived }
            }) else { return false }
            selectedSessionID = target
            multiSelection = []
            return true
        case .gridFocus(let direction):
            guard isGridActive else { return false }
            return changingSelection { moveGridFocus(direction) }
        case .toggleMaximize:
            if isGridActive, let sessionID = selectedSession?.id {
                maximizePane(sessionID)
                return true
            }
            guard !showsGrid, activeGridWorkspaceEntity != nil else { return false }
            returnToWorkspace()
            return true
        case .closeSelectedTab:
            guard let session = selectedSession else { return false }
            closeTabByUser(session)
            return true
        case .newChatInCurrentProject:
            guard selectedProject != nil else { return false }
            createDefaultSession()
            return true
        case .newChat(let projectID):
            guard let project = workspace.projects.first(where: { $0.id == projectID }) else { return false }
            startNewChat(in: project)
            return true
        case .selectSession(let sessionID):
            guard workspace.sessions.contains(where: { $0.id == sessionID }) else { return false }
            selectedSessionID = sessionID
            multiSelection = []
            return true
        case .activateWorkspace(let workspaceID):
            guard let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
            activateWorkspaceFromSidebar(entity)
            return true
        case .openProjectAsWorkspace(let projectID, let activeSessionIDs):
            guard let project = workspace.projects.first(where: { $0.id == projectID }) else { return false }
            openProjectAsWorkspace(project, activeSessionIDs: activeSessionIDs)
            return true
        case .setSidebarVisible(let visible):
            guard isSidebarVisible != visible else { return false }
            isSidebarVisible = visible
            return true
        case .sidebarFilter(let step):
            let scopes = SidebarScope.allCases
            guard let index = scopes.firstIndex(of: sidebarScope) else { return false }
            let target = min(max(index + step, 0), scopes.count - 1)
            guard target != index else { return false }
            sidebarScope = scopes[target]
            return true
        case .switcherBegin:
            guard tabSwitcher == nil else { return false }
            return beginTabSwitcher(direction: 0, modifiers: [])
        case .switcherMove(let direction):
            guard tabSwitcher != nil else { return false }
            moveTabSwitcher(direction)
            return true
        case .switcherCommit:
            guard tabSwitcher != nil else { return false }
            commitTabSwitcher()
            return true
        case .switcherCancel:
            guard tabSwitcher != nil else { return false }
            cancelTabSwitcher()
            return true
        case .clearMultiSelection:
            guard !multiSelection.isEmpty else { return false }
            multiSelection = []
            return true
        }
    }

    /// Führt `action` aus und meldet, ob sich die Auswahl dadurch geändert hat.
    private func changingSelection(_ action: () -> Void) -> Bool {
        let before = selectedSessionID
        action()
        return selectedSessionID != before
    }
}
