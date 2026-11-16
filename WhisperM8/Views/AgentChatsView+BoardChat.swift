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
    /// Dazu Jarvis und Produkt-Chat für die Knöpfe im Kopf.
    ///
    /// Kosten: Gesucht wird nur unter offenen Tabs, laufenden Chats und dem
    /// zuletzt gefundenen Jarvis (einige Dutzend), nachgeschlagen über
    /// den Index des Workspace (`session(id:)`), nie über alle Chats.
    func boardChatPick(projectID: UUID) -> BoardChatPickResult {
        let preferences = BoardChatPreferencesStore.shared.preferences(for: projectID)
        // Eine gespeicherte Wahl zählt nur, wenn sie noch erlaubt ist: Die
        // Datei kann einen alten Shell-Tab oder einen Chat eines anderen Projekts enthalten.
        let chosen = preferences.chosenSessionID
            .flatMap { workspaceModel.session(id: $0) }
            .flatMap { boardChatRejection(of: $0, projectID: projectID) == nil ? $0 : nil }
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
                isArchived: session.status == .archived, kind: session.effectiveKind)
        }
        let jarvis = BoardChatRules.automaticJarvis(in: candidates, projectID: projectID).flatMap { workspaceModel.session(id: $0) }
        let product = BoardChatRules.automaticProduct(in: candidates, projectID: projectID).flatMap { workspaceModel.session(id: $0) }
        return BoardChatPickResult(current: chosen ?? jarvis, isAutomatic: chosen == nil, jarvis: jarvis, product: product,
                                   chosen: chosen)
    }

    /// Pur über `BoardChatRules.rejection`; Projekt wie bei Jarvis und Produkt-Chat
    /// nach dem Haupt-Projekt (Arbeitsordner zählen dazu).
    func boardChatRejection(of session: AgentChatSession, projectID: UUID, groupSize: Int = 1) -> BoardChatRejection? {
        BoardChatRules.rejection(
            kind: session.effectiveKind, isArchived: session.status == .archived,
            projectID: AgentProjectDisplay.displayProjectID(session.projectID, parents: projectParents),
            boardProjectID: projectID, groupSize: groupSize)
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
                    BoardChatCollapsedRail(title: pick.current?.title, expand: {
                        preferencesStore.setCollapsed(false, for: projectID)
                    }) {
                        if let current = pick.current { boardChatStatusDot(current) }
                    }
                } else {
                    boardChatExpanded(pick: pick, projectID: projectID)
                }
            }
            .modifier(BoardChatColumnFrame(
                storedWidth: preferences.width,
                isCollapsed: preferences.isCollapsed == true,
                available: available,
                setWidth: { preferencesStore.setWidth($0, for: projectID) }))
            .task { preferencesStore.preload() }
            // Einmal je gefundenem Jarvis merken (nicht im Body schreiben).
            .task(id: "\(pick.jarvis?.id.uuidString ?? "-")|\(preferencesStore.isLoaded)") {
                if let jarvis = pick.jarvis, preferencesStore.isLoaded {
                    preferencesStore.setLastJarvis(jarvis.id, for: projectID)
                }
            }
            // Klick außerhalb des Terminals gibt den Fokus ans Fenster zurück.
            .background(BoardChatFocusGuard())
        }
    }

    @ViewBuilder
    private func boardChatExpanded(pick: BoardChatPickResult, projectID: UUID) -> some View {
        let session = pick.current
        let placement = session.map { boardChatPlacement(of: $0.id) } ?? .notOpen
        let isRunning = session.map { terminalRegistry.controller(for: $0.id)?.isRunning == true } ?? false
        let state = BoardChatColumnState(
            title: session?.title,
            isAutomatic: pick.isAutomatic,
            content: Self.boardChatContent(hasChat: session != nil, placement: placement),
            isRunning: isRunning,
            canResume: session?.externalSessionID != nil,
            choices: BoardChatRules.choices(
                jarvis: pick.jarvis.map(Self.boardChatChoiceChat), product: pick.product.map(Self.boardChatChoiceChat),
                chosen: pick.chosen.map(Self.boardChatChoiceChat), current: session?.id))
        BoardChatColumnView(
            state: state,
            actions: boardChatActions(session: session, placement: placement, projectID: projectID,
                                      automaticJarvis: pick.jarvis?.id),
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

    nonisolated static func boardChatChoiceChat(_ session: AgentChatSession) -> BoardChatChoice.Chat {
        BoardChatChoice.Chat(id: session.id, name: BoardChatText.callName(session.title), title: session.title)
    }

    private func boardChatActions(session: AgentChatSession?, placement: BoardChatPlacement,
                                  projectID: UUID, automaticJarvis: UUID?) -> BoardChatColumnActions {
        let preferencesStore = BoardChatPreferencesStore.shared
        var actions = BoardChatColumnActions()
        actions.setCollapsed = { preferencesStore.setCollapsed($0, for: projectID) }
        // Wahl je Projekt, gespeichert (Teil c). Der automatische Jarvis heißt
        // „keine Wahl“: Ein neuer Jarvis übernimmt dann von selbst.
        let choose: (UUID) -> Void = { id in
            preferencesStore.setChosenSession(BoardChatRules.storedChoice(after: id, automaticJarvis: automaticJarvis), for: projectID)
        }
        actions.choose = choose
        let projectName = selectedProject?.name ?? ""
        actions.drop = { [workspaceModel, windowID] id, groupSize in
            guard let dropped = workspaceModel.session(id: id) else { return false }
            // Nur echte Agent-Chats dieses Projekts, einzeln; sonst sichtbar sagen, warum nicht.
            if let rejection = boardChatRejection(of: dropped, projectID: projectID, groupSize: groupSize) {
                BoardChatInputs.shared.showNotice(
                    BoardChatInputRules.message(rejection, chatName: dropped.title, projectName: projectName), in: windowID)
                return false
            }
            choose(id)
            return true
        }
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

/// Wer in der Spalte steht, und wer im Kopf zur Wahl steht.
struct BoardChatPickResult {
    var current: AgentChatSession?
    var isAutomatic: Bool
    var jarvis: AgentChatSession?
    var product: AgentChatSession?
    var chosen: AgentChatSession?
}

