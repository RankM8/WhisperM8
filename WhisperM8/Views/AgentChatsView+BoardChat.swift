import SwiftUI

/// Seitenspalte „Board-Chat“ im Ticket-Modus (WM8-113).
///
/// Die Spalte zeigt keinen zweiten Chat, sondern denselben an einem anderen
/// Ort: Sie baut die Detailansicht über `sessionDetailContent`, genau wie
/// Einzelansicht und Kachel. Das Terminal eines Controllers ist ein einziges
/// NSView; `AgentTerminalContainerView` übernimmt es in den Host, der gerade
/// im Fenster hängt. Weil die Tickets im Fenster Einzelansicht und Raster
/// ersetzen, hängt es während der Tickets in der Spalte und danach wieder an
/// seinem Platz. Prozess, Verlauf, Raster und Übergabe merken davon nichts.
///
/// Das Terminal steht nur hier, wenn der Chat ein Tab DIESES Fensters ist
/// (dieselbe Regel wie im Raster): Zwei Fenster, die dasselbe Terminal
/// zeigen wollten, zögen es sich bei jedem Layout gegenseitig weg.
extension AgentChatsView {
    /// Haupt-Projekt des Boards; Arbeitsordner zählen dazu (WM8-102).
    var boardChatProjectID: UUID? {
        selectedProject.map { AgentProjectDisplay.displayProjectID($0.id, parents: projectParents) }
    }

    /// Der Chat in der Spalte: von Hand gewählt, sonst der Jarvis des Projekts.
    ///
    /// Kosten: Gesucht wird nur unter offenen Tabs und laufenden Chats (einige
    /// Dutzend), nachgeschlagen über den Index des Workspace (`session(id:)`),
    /// nie über alle Chats.
    func boardChatPick(projectID: UUID) -> (session: AgentChatSession, isAutomatic: Bool)? {
        let preferences = BoardChatPreferencesStore.shared.preferences(for: projectID)
        if let chosen = preferences.chosenSessionID,
           let session = workspaceModel.session(id: chosen), session.status != .archived {
            return (session, false)
        }
        var ids = Set(windowStore.state.windows.flatMap(\.openTabIDs))
        ids.formUnion(terminalRegistry.activeSessionIDs)
        // Der zuletzt gefundene Jarvis zählt mit, auch gestoppt und ohne Tab.
        if let last = preferences.lastJarvisSessionID { ids.insert(last) }
        let running = terminalRegistry.activeSessionIDs
        let candidates = ids.compactMap { id -> BoardChatCandidate? in
            guard let session = workspaceModel.session(id: id) else { return nil }
            return BoardChatCandidate(
                id: session.id, title: session.title,
                projectID: AgentProjectDisplay.displayProjectID(session.projectID, parents: projectParents),
                isRunning: running.contains(session.id), lastActivityAt: session.lastActivityAt,
                isArchived: session.status == .archived)
        }
        guard let id = BoardChatRules.automaticJarvis(in: candidates, projectID: projectID),
              let session = workspaceModel.session(id: id) else { return nil }
        return (session, true)
    }

    /// Spalte samt Breite. `available`: Breite von Board und Spalte zusammen.
    @ViewBuilder
    func boardChatColumn(available: Double) -> some View {
        if let projectID = boardChatProjectID {
            let preferencesStore = BoardChatPreferencesStore.shared
            let preferences = preferencesStore.preferences(for: projectID)
            let pick = boardChatPick(projectID: projectID)
            Group {
                if !preferencesStore.isLoaded {
                    // Ein, zwei Frames beim allerersten Öffnen: erst die
                    // gespeicherte Breite und „zugeklappt“, dann das Terminal.
                    AgentTheme.background
                } else if preferences.isCollapsed == true {
                    BoardChatCollapsedRail(title: pick?.session.title, expand: {
                        preferencesStore.setCollapsed(false, for: projectID)
                    }) {
                        if let pick { boardChatStatusDot(pick.session) }
                    }
                } else {
                    boardChatExpanded(pick: pick, projectID: projectID)
                }
            }
            .modifier(BoardChatColumnFrame(
                isTriage: { [windowID] in TicketBoardControllers.shared.controller(for: windowID).viewModel.triage != nil },
                storedWidth: preferences.width,
                isCollapsed: preferences.isCollapsed == true,
                available: available,
                setWidth: { preferencesStore.setWidth($0, for: projectID) }))
            .task { preferencesStore.preload() }
            // Einmal je gefundenem Jarvis merken (nicht im Body schreiben).
            .task(id: "\(pick.flatMap { $0.isAutomatic ? $0.session.id.uuidString : nil } ?? "-")|\(preferencesStore.isLoaded)") {
                if let pick, pick.isAutomatic, preferencesStore.isLoaded {
                    preferencesStore.setLastJarvis(pick.session.id, for: projectID)
                }
            }
            // Klick außerhalb des Terminals gibt den Fokus ans Fenster zurück.
            .background(BoardChatFocusGuard())
        }
    }

    @ViewBuilder
    private func boardChatExpanded(pick: (session: AgentChatSession, isAutomatic: Bool)?, projectID: UUID) -> some View {
        let session = pick?.session
        let placement = session.map { boardChatPlacement(of: $0.id) } ?? .notOpen
        let isRunning = session.map { terminalRegistry.controller(for: $0.id)?.isRunning == true } ?? false
        let state = BoardChatColumnState(
            title: session?.title,
            isAutomatic: pick?.isAutomatic ?? true,
            content: Self.boardChatContent(hasChat: session != nil, placement: placement),
            isRunning: isRunning,
            canResume: session?.externalSessionID != nil)
        BoardChatColumnView(
            state: state,
            actions: boardChatActions(session: session, placement: placement, projectID: projectID),
            inputBar: AnyView(BoardChatInputBar(windowID: windowID)),
            statusDot: { if let session { boardChatStatusDot(session) } },
            terminal: {
                if let session, placement == .here,
                   let project = workspace.projects.first(where: { $0.id == session.projectID }) {
                    // Nie den Fokus ziehen und nie von selbst starten: Wer die
                    // Tickets öffnet, liest das Board. Ein Klick ins Terminal
                    // gibt ihm den Fokus, gestartet wird über den Kopf.
                    sessionDetailContent(for: session, project: project, suppressesAutoActivation: true)
                        .id(session.id)
                        // Sichtbar: Ziel für Diktat und „→ Jarvis“ (Teil b).
                        .modifier(BoardChatRegistrationModifier(
                            windowID: windowID, sessionID: session.id,
                            name: BoardChatText.callName(session.title),
                            changed: { syncActiveAgentChat() }))
                }
            })
    }

    nonisolated static func boardChatContent(hasChat: Bool, placement: BoardChatPlacement) -> BoardChatColumnState.Content {
        guard hasChat else { return .noChat }
        switch placement {
        case .here: return .terminal
        case .otherWindow(let number, _): return .otherWindow(number: number)
        case .notOpen: return .notOpen
        }
    }

    private func boardChatPlacement(of sessionID: UUID) -> BoardChatPlacement {
        BoardChatRules.placement(
            windowID: windowID,
            hostWindowID: windowStore.windowID(containingTab: sessionID),
            windowOrder: [windowStore.primaryWindowID] + windowStore.secondaryWindowIDs)
    }

    private func boardChatStatusDot(_ session: AgentChatSession) -> some View {
        SessionLiveStatusDot(
            sessionID: session.id,
            isProcessRunning: terminalRegistry.controller(for: session.id)?.isRunning == true,
            statusStore: runtimeStatusStore)
    }

    private func boardChatActions(session: AgentChatSession?, placement: BoardChatPlacement,
                                  projectID: UUID) -> BoardChatColumnActions {
        let preferencesStore = BoardChatPreferencesStore.shared
        var actions = BoardChatColumnActions()
        actions.setCollapsed = { preferencesStore.setCollapsed($0, for: projectID) }
        guard let session else { return actions }
        let sessionID = session.id
        actions.moveHere = { [windowStore, windowID] in
            // Nur auf Klick, und nur wenn der Chat noch dort ist, wo der
            // Hinweis es sagt.
            guard case .otherWindow(_, let host) = placement,
                  windowStore.windowID(containingTab: sessionID) == host else { return }
            windowStore.moveTab(sessionID, from: host, to: windowID, before: nil)
        }
        actions.openHere = { [windowStore, windowID] in
            guard windowStore.windowID(containingTab: sessionID) == nil else { return }
            windowStore.openTab(sessionID, in: windowID, select: false)
        }
        actions.openAsTab = { [windowStore, windowID] in
            windowStore.navigateToSession(sessionID, in: windowID)
        }
        actions.start = {
            sessionActionRequest = AgentSessionActionRequest(sessionID: sessionID, kind: .start)
        }
        return actions
    }
}

/// Board links, Spalte rechts. Misst die verfügbare Breite, damit die Spalte
/// dem Board seinen Platz lässt.
struct BoardChatSplit<Board: View, Column: View>: View {
    @ViewBuilder let board: () -> Board
    @ViewBuilder let column: (_ available: Double) -> Column

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                board()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                column(proxy.size.width)
            }
        }
    }
}

// MARK: - Diktat-Kontext (Teil b)

extension AgentChatsView {
    /// Im Ticket-Modus ist der sichtbare Board-Chat der Chat „vor mir“: Ziel
    /// und Kontext des Diktats. Ohne sichtbaren Board-Chat gibt es keinen.
    func syncBoardChatAsActiveChat() {
        guard let registration = BoardChatInputs.shared.boardChat(in: windowID),
              let session = workspaceModel.session(id: registration.sessionID),
              session.status != .archived,
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            if AppState.shared.activeAgentChat != nil { AppState.shared.activeAgentChat = nil }
            return
        }
        let ref = AgentChatContextRef(
            sessionID: session.id,
            provider: session.provider,
            projectName: project.name,
            projectPath: project.path,
            title: session.title,
            externalSessionID: session.externalSessionID,
            kind: session.effectiveKind,
            backgroundShortID: session.backgroundShortID
        )
        if AppState.shared.activeAgentChat != ref { AppState.shared.activeAgentChat = ref }
    }
}
