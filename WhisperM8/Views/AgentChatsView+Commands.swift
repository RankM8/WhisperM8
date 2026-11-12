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
        commandState.token = AgentChatsCommandCenter.shared.register(
            windowID: windowID,
            handler: AgentChatsCommandCenter.Handler(
                perform: { performCommand($0) },
                snapshot: { commandSnapshot() },
                listRows: { controllerListRows() },
                chatActionInfo: { controllerChatActionInfo(for: $0) },
                workspaceChoices: { controllerWorkspaceChoices() }
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
            isArchiveMode: archiveModeActive,
            isNewChatPickerOpen: showNewChatProjectPicker,
            isConfirmationOpen: sessionsPendingEnd != nil || sessionsPendingArchive != nil,
            screenDisplayID: (hostWindow?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber)?.uint32Value,
            backTarget: controllerBackTarget()
        )
    }

    // MARK: - Zurück (L2 getippt)

    /// Voriger Ort dieses Fensters, sofern es ihn noch gibt: der Workspace
    /// angelegt, der Chat hier als Tab offen und nicht archiviert.
    func backPlace() -> ChatPlace? {
        let place = windowStore.previousPlace(in: windowID)
        if case .chat(let id) = place,
           !workspace.sessions.contains(where: { $0.id == id && $0.status != .archived }) {
            return nil
        }
        return place
    }

    /// Ziel von L2 für die Legende, aus demselben `backPlace()` wie der Befehl.
    private func controllerBackTarget() -> ControllerBackTarget? {
        switch backPlace() {
        case .chat(let id)?:
            let title = workspace.sessions.first { $0.id == id }?.title ?? String(localized: "Chat")
            return ControllerBackTarget(kind: .chat, title: title, id: id)
        case .workspace(let id)?:
            return windowStore.gridWorkspace(id: id).map { ControllerBackTarget(kind: .workspace, title: $0.name, id: id) }
        case nil:
            return nil
        }
    }

    /// Zurück an den vorigen Ort. Ein Chat öffnet wie der Klick in der
    /// Seitenleiste, ein Workspace wie der Klick auf seinen Kopf — als Raster,
    /// mit der Kachel, auf der man dort zuletzt war (merkt der Store beim
    /// Verlassen). Danach ist der verlassene Ort das nächste Ziel. Ein
    /// Konflikt (Workspace gehört inzwischen einem anderen Fenster) holt
    /// nichts nach vorn und zeigt keinen Dialog: Der Controller vibriert
    /// „geht nicht“.
    private func goBack() -> Bool {
        switch backPlace() {
        case .chat(let id)?:
            selectedSessionID = id
        case .workspace(let id)?:
            guard let entity = windowStore.gridWorkspace(id: id),
                  activateWorkspaceFromSidebar(entity, reportConflicts: false) else { return false }
        case nil:
            return false
        }
        multiSelection = []
        return true
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
        case .lastChat:
            return goBack()
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
        case .closeListRow(let row):
            return closeListRowFromCommand(row)
        case .renameChat(let sessionID):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return false }
            beginRename(session)
            return true
        case .forkChat(let sessionID):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
                  session.isForkable else { return false }
            forkSession(session)
            return true
        case .setGPTAccount(let sessionID, let profileName):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
                  canSwitchGPTAccount(session),
                  let profile = AccountMenuData.gptProfiles.value.first(where: { $0.name == profileName }),
                  profile.isLoggedIn else { return false }
            setGPTAccount([session], toProfile: profile)
            return true
        case .togglePin(let sessionID):
            guard workspace.sessions.contains(where: { $0.id == sessionID }) else { return false }
            togglePin(sessionID)
            return true
        case .archiveChat(let sessionID):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
                  session.status != .archived else { return false }
            requestArchive([session])
            return true
        case .moveChatToAccount(let sessionID, let profileName):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
                  canMoveToAccount(session) else { return false }
            requestAccountMove([session], toProfileNamed: profileName)
            return true
        case .newChatInCurrentProject:
            guard selectedProject != nil else { return false }
            createDefaultSession()
            return true
        case .newChat(let projectID):
            guard let project = workspace.projects.first(where: { $0.id == projectID }) else { return false }
            startNewChat(in: project)
            return true
        case .showNewChatPicker(let preferredProjectID):
            return showNewChatPickerFromCommand(preferredProjectID: preferredProjectID)
        case .startChat(let sessionID):
            return startChatFromCommand(sessionID)
        case .selectSession(let sessionID):
            guard workspace.sessions.contains(where: { $0.id == sessionID }) else { return false }
            selectedSessionID = sessionID
            multiSelection = []
            return true
        case .selectWorkspaceChat(let sessionID, let workspaceID):
            guard workspace.sessions.contains(where: { $0.id == sessionID }),
                  let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
            return openWorkspaceChatRow(sessionID, in: entity, source: .controller)
        case .activateWorkspace(let workspaceID):
            guard let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
            activateWorkspaceFromSidebar(entity)
            return true
        case .switchToWorkspace(let workspaceID):
            guard let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
            return activateWorkspaceFromSidebar(entity, reportConflicts: false)
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
        case .nextWaitingChat:
            return selectNextWaitingChat()
        case .openProjectOfChat, .revealProjectInFinder, .refreshChatTitle, .restartChat, .toggleTileNote,
             .toggleNotes, .removeChatFromWorkspace, .addChatToWorkspace, .moveChatToNewWindow, .backgroundLogs,
             .backgroundStop, .backgroundRespawn, .stopSubagentJob, .cancelAccountSwitch, .undoLastAccountSwitch:
            return performControllerChatCommand(command)
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

    /// Öffnet die Projekt-Auswahl „Neuer Chat“ wie ⌘N, mit dem gewünschten
    /// Projekt vorausgewählt (`onAppear` der Auswahl liest es). Die Auswahl
    /// hängt als Popover am Knopf der Seitenleiste: Ist die Seitenleiste zu,
    /// wird sie erst eingeblendet und die Auswahl kurz danach geöffnet, wenn
    /// der Knopf im Fenster steht. Im Archiv gibt es den Knopf nicht.
    private func showNewChatPickerFromCommand(preferredProjectID: UUID?) -> Bool {
        guard !archiveModeActive, !showNewChatProjectPicker else { return false }
        commandState.preferredNewChatProjectID = preferredProjectID ?? selectedProjectID
        guard isSidebarVisible else {
            isSidebarVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                showNewChatProjectPicker = true
            }
            return true
        }
        showNewChatProjectPicker = true
        return true
    }

    /// „−“/„×“ einer Zeile der Liste, mit denselben Funktionen wie die
    /// Seitenleiste: Chat-Zeilen über `performSidebarCloseAction` (Filter
    /// entscheidet), Workspace-Zeilen beenden und nehmen den Chat aus genau
    /// diesem Workspace. Kopfzeilen haben kein „−“/„×“.
    private func closeListRowFromCommand(_ row: SidebarNavigationRow) -> Bool {
        switch row {
        case .chat(let sessionID):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return false }
            performSidebarCloseAction([session])
            return true
        case .workspaceChat(let sessionID, let workspaceID):
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
                  let entity = windowStore.gridWorkspace(id: workspaceID) else { return false }
            requestEndSession([session], removingFrom: entity)
            return true
        case .workspace, .project:
            return false
        }
    }

    /// Führt `action` aus und meldet, ob sich die Auswahl dadurch geändert hat.
    private func changingSelection(_ action: () -> Void) -> Bool {
        let before = selectedSessionID
        action()
        return selectedSessionID != before
    }
}
