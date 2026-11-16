import AppKit
import Foundation

/// Das Ticket-Board am Controller (WM8-91, Paket 1 „Öffnen und Umschalten“):
/// was das Fenster dem Controller über das Board sagt und die Befehle, die es
/// öffnen und schließen. Alles im Ereignis-Pfad, nie aus einem Body; das
/// Team eines Projekts kommt aus dem Zwischenspeicher `TicketTeamDirectory`.
extension AgentChatsView {
    private var ticketBoardEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKeys.ticketBoardEnabled)
    }

    /// Projekte der App für den Zwischenspeicher. Nur bei eingeschalteter
    /// Ticket-Ansicht; sonst liest niemand das Ergebnis.
    func refreshTicketTeams() {
        guard ticketBoardEnabled else { return }
        let projects = workspace.projects.map {
            TicketTeamDirectory.Project(id: $0.id, path: $0.path, name: $0.name, colorHex: $0.color)
        }
        TicketTeamDirectory.shared.refresh(projects: projects)
    }

    /// Das Board, das dieses Fenster zeigt; `nil`, solange es die Chats zeigt.
    /// Kosten je Eingabe im Board: eine Suche über die Projekte und ein Blick
    /// in das schon gerechnete Modell der Ansicht (kein Abruf, kein Durchlauf
    /// über die Chats).
    func controllerTicketsPlace() -> ControllerTicketsPlace? {
        guard isTicketsModeActive else { return nil }
        let project = selectedProject
        var place = ControllerTicketsPlace(
            projectID: project?.id, team: TicketTeamDirectory.shared.team(of: project?.id), projectName: project?.name)
        // Was „Zu den Chats“ zeigt: die sichtbare Auswahl (fällt auf den ersten Tab zurück).
        place.chatBehind = selectedSession?.id
        // Board-Chat nur, solange die Spalte ihn zeigt (angemeldet; ein Blick
        // in ein kleines Wörterbuch, Paket 3a).
        if let boardChat = BoardChatInputs.shared.boardChat(in: windowID) {
            place.boardChatID = boardChat.sessionID
            place.boardChatName = boardChat.name
        }
        guard TicketBoardControllers.shared.hasController(for: windowID) else { return place }
        let controller = TicketBoardControllers.shared.controller(for: windowID)
        let model = controller.viewModel
        place.view = model.controllerView(isReady: controller.phase == .ready)
        place.hasTicket = model.detail != nil
        place.ticketHasChats = !model.chatLines.isEmpty
        if place.view == .chatLine, let index = model.focusedChatLine, model.chatLines.indices.contains(index),
           model.chatLines[index].chatID != nil {
            place.chatLineTitle = model.chatLines[index].name
            place.chatLineChatID = model.chatLines[index].chatID
        }
        return place
    }

    /// Angaben für die Menü-Karte am Ticket.
    func controllerTicketMenuInfo() -> ControllerTicketMenuInfo? {
        guard isTicketsModeActive, TicketBoardControllers.shared.hasController(for: windowID) else { return nil }
        let model = TicketBoardControllers.shared.controller(for: windowID).viewModel
        return ControllerTicketMenuInfo(
            key: model.detail?.entry.ticket.key,
            chats: model.chatLines.compactMap { line in line.chatID.map { .init(id: $0, title: line.name) } },
            hasURL: model.detail?.url != nil,
            waitingFilterOn: model.filter.waitingForMe)
    }

    /// Befehl des Controllers an das Board dieses Fensters (WM8-91, Paket 2).
    /// Liest nur; „Zum Chat“ wechselt sichtbar wie der Knopf am Ticket.
    /// `keepsTerminalFocus`: Die Taste kam per Tastatur aus dem Terminal des
    /// Board-Chats (⌘⌥←/→, ⌘J, Paket 3c); der Fokus bleibt dort. Sonst holt
    /// jede Board-Aktion ihn zurück ans Fenster (WM8-113).
    func performTicketCommand(_ command: ControllerTicketCommand,
                              keepsTerminalFocus: Bool = false) -> ControllerTicketOutcome {
        guard isTicketsModeActive, TicketBoardControllers.shared.hasController(for: windowID) else { return .rejected }
        if !keepsTerminalFocus { ControllerTicketFocus.prepare(for: command, in: hostWindow) }
        let controller = TicketBoardControllers.shared.controller(for: windowID)
        let model = controller.viewModel
        if command == .refresh {
            controller.refresh()
            if model.triage != nil { model.reloadComments() }
            return .done
        }
        // Kopf und Filter (Paket 3d): Bewegen wählt nur, Kreuz schaltet, Kreis zurück.
        let header = TicketHeaderContext(hasBack: true, hasBoardChat: BoardChatInputs.shared.boardChat(in: windowID) != nil)
        if model.headerFocus != nil, let outcome = performHeaderCommand(command, model: model, header: header) {
            return outcome
        }
        guard controller.phase == .ready else {
            if case .move(.left) = command { return .leftEdge }
            // Auch ohne Stand: ▲ in den Kopf (Filter, Aktualisieren).
            if case .move(.up) = command { return model.enterHeader(header) ? .done : .rejected }
            return .rejected
        }
        // Erster Druck ohne Auswahl: die Start-Auswahl zeigen, noch nicht bewegen.
        let hadSpot = model.triage != nil || controllerHasSelection(model)
        switch command {
        case .move(let direction), .repeatMove(let direction):
            if !hadSpot, direction != .left {
                model.ensureControllerSelection(preferringChat: selectedSessionID)
                if controllerHasSelection(model) { return .done }
                // Leeres Board (etwa durch Filter): ▲ führt trotzdem in den Kopf,
                // sonst käme man an die Filter nicht mehr heran.
                if direction == .up, case .move = command { return model.enterHeader(header) ? .done : .nothing }
                return .nothing
            }
            let outcome = model.controllerMove(TicketBoardMove(direction))
            // Gehalten rutscht die Auswahl nie über den Rand in den Board-Chat
            // und nie in den Kopf.
            if case .repeatMove = command, outcome == .rightEdge { return .nothing }
            if outcome == .topEdge {
                if case .move = command { return model.enterHeader(header) ? .done : .nothing }
                return .nothing
            }
            return outcome
        case .open:
            if model.triage != nil {
                guard let chatID = model.focusedChatID else { return .rejected }
                return openChatFromTicket(chatID)
            }
            if !hadSpot { model.ensureControllerSelection(preferringChat: selectedSessionID) }
            return model.controllerOpen()
        case .back:
            return model.controllerBack()
        case .adjacent(let step):
            if !hadSpot {
                model.ensureControllerSelection(preferringChat: selectedSessionID)
                return controllerHasSelection(model) ? .done : .nothing
            }
            return model.controllerAdjacent(step)
        case .copyLink:
            return model.copyLink() ? .done : .rejected
        case .openInLinear:
            guard let url = model.detail?.url else { return .rejected }
            NSWorkspace.shared.open(url)
            return .done
        case .scroll(let lines):
            guard model.triage != nil else { return .nothing }
            return TicketTextScrollRegistry.shared.scroll(lines: lines, in: hostWindow) ? .done : .nothing
        case .toggleWaitingFilter:
            model.toggleWaitingFilter()
            return .done
        case .copyList:
            let title = TicketTeamDirectory.shared.team(of: selectedProject?.id) ?? selectedProject?.name ?? ""
            model.copyList(title: model.triage?.title ?? (model.filter.waitingForMe
                ? title + " · " + String(localized: "Waiting for me") : title))
            return .done
        case .goToChat(let chatID):
            guard model.chatLines.contains(where: { $0.chatID == chatID }) else { return .rejected }
            return openChatFromTicket(chatID)
        case .handOff:
            // Das gewählte Ticket: in der Triage das große (key nil), auf dem
            // Board die Karte, in der Liste die Zeile. Die Regeln (Board-Chat
            // sichtbar, keine offene Frage) prüft `BoardChatInputs`.
            guard hadSpot else { return .rejected }
            var key: String?
            if model.triage == nil {
                switch model.mode {
                // Nur eine sichtbar gewählte Karte; „N weitere“ gibt kein
                // verborgenes Ticket weiter.
                case .board: if case .card(let card) = model.boardSpot { key = card }
                case .list: key = model.selectedKey.flatMap { model.listKeys.contains($0) ? $0 : nil }
                }
                guard key != nil else { return .rejected }
            }
            return BoardChatInputs.shared.handOff(key: key, in: windowID) ? .done : .rejected
        case .refresh, .dictationUnavailable, .leaveBoardChat:
            return .rejected
        }
    }

    /// Befehle, solange die Auswahl im Kopf steht. `nil`: wie sonst auch
    /// (L1/R1, Link, Linear …).
    private func performHeaderCommand(_ command: ControllerTicketCommand, model: TicketBoardViewModel,
                                      header: TicketHeaderContext) -> ControllerTicketOutcome? {
        switch command {
        case .move(let direction), .repeatMove(let direction):
            return model.headerMove(TicketBoardMove(direction), header)
        case .open:
            switch model.headerActivate(header) {
            case .done: return .done
            case .rejected: return .rejected
            case .goBack: return .goBack
            case .copyList: return performTicketCommand(.copyList)
            case .refresh: return performTicketCommand(.refresh)
            case .copyLink: return performTicketCommand(.copyLink)
            case .handOff: return performTicketCommand(.handOff)
            case .openInLinear: return performTicketCommand(.openInLinear)
            }
        case .back:
            model.headerBack()
            return .done
        default:
            return nil
        }
    }

    private func controllerHasSelection(_ model: TicketBoardViewModel) -> Bool {
        switch model.mode {
        case .board: return TicketBoardSelection.place(of: model.boardSpot, in: model.boardColumns) != nil
        case .list: return model.selectedKey.map(model.listKeys.contains) ?? false
        }
    }

    /// „Zum Chat“: Der Chat wird sichtbar gewählt wie mit einem Klick in der
    /// Seitenleiste, die Tickets gehen zu. Es wird nichts in ihn geschickt; im
    /// Ziel warten Kreuz und Kreis die Ankunftssperre ab.
    private func openChatFromTicket(_ chatID: UUID) -> ControllerTicketOutcome {
        guard performCommand(.selectSession(chatID)) else { return .rejected }
        // Auch per Tastatur (Return auf der Chat-Zeile): Return und Esc warten
        // im Ziel-Terminal 1 s (Paket 3c).
        KeyboardArrivalLock.shared.arrive(at: chatID)
        return .done
    }

    /// Projekt gewechselt: Diktat-Ziel nachziehen und die Leiste neu lesen.
    func selectedProjectChanged() {
        syncActiveAgentChat()
        controllerLegendMayHaveChanged()
    }

    /// Das Fenster ist Key geworden: Diktat-Ziel nachziehen und die Leiste neu
    /// lesen. Sie zeigt sofort, aber sonst mit dem Zusammenhang des vorigen
    /// Key-Fensters (dessen Team und Rückweg), bis zur nächsten Eingabe
    /// (WM8-91). Erst nachdem der Store das Fenster als Key kennt, sonst läse
    /// sie wieder das alte. Ein Schnappschuss je Fensterwechsel, nur mit
    /// laufender Controller-Steuerung.
    func windowBecameKey() {
        windowStore.windowDidBecomeKey(windowID)
        syncActiveAgentChat()
        controllerLegendMayHaveChanged()
    }

    /// Ort per Maus oder Tastatur gewechselt (Ticket-Modus, Projekt, Board/
    /// Liste, Triage auf oder zu): Die Leiste des Controllers liest neu. Sonst
    /// stand dort bis zum nächsten Statuswechsel eines Chats der alte Ort
    /// (WM8-91, Bild vom 16.11.2026: das Team eines anderen Boards unter diesem).
    /// Kosten: ein Schnappschuss des Fensters je Wechsel, nie im Takt.
    func controllerLegendMayHaveChanged() {
        guard let feedback = ControllerRuntime.shared.feedback else { return }
        if isTicketsModeActive {
            TicketBoardControllers.shared.controller(for: windowID).viewModel.onControllerViewChange = { [weak feedback] in
                feedback?.refresh()
            }
        }
        feedback.refresh()
    }

    /// Zeilen des Reiters „Tickets“. Die Zahl „wartet auf dich“ steht nur
    /// beim Board, dessen Stand dieses Fenster schon geladen hat; dafür wird
    /// nichts abgerufen.
    func controllerTicketBoards() -> ControllerTicketBoards? {
        guard ticketBoardEnabled else { return nil }
        // Für das nächste Öffnen; dieses zeigt den Stand von vorher.
        refreshTicketTeams()
        let directory = TicketTeamDirectory.shared
        let here = selectedProject
        let last = windowStore.lastTicketsProjectID(in: windowID)
        let loadedTeam = directory.team(of: last)
        let board = TicketBoardControllers.shared.hasController(for: windowID)
            ? TicketBoardControllers.shared.controller(for: windowID) : nil
        let waitingHere = board?.phase == .ready ? board?.viewModel.presentation.counts.waitingForMe : nil
        return ControllerTicketBoards.make(
            teams: directory.resolved.teams, hereProjectID: here?.id, hereProjectName: here?.name,
            hereTeam: directory.team(of: here?.id), inTickets: isTicketsModeActive, lastProjectID: last,
            teamOfProject: { directory.team(of: $0) },
            waiting: { team in
                guard let loadedTeam, loadedTeam.caseInsensitiveCompare(team) == .orderedSame else { return nil }
                return waitingHere
            })
    }

    /// Board des Projekts dieses Chats für den Eintrag im Options-Menü.
    func controllerTicketBoardTarget(for sessionID: UUID) -> ControllerTicketBoardTarget? {
        guard ticketBoardEnabled,
              let projectID = workspaceModel.session(id: sessionID)?.projectID,
              let team = TicketTeamDirectory.shared.team(of: projectID) else { return nil }
        return ControllerTicketBoardTarget(projectID: projectID, team: team)
    }

    /// Zeigt das Board von `projectID` (ohne: des gewählten Projekts), wie der
    /// Ticket-Knopf in der Titelzone. Das Board kommt so wieder, wie es
    /// verlassen wurde (Ansicht und Auswahl hält sein Controller je Fenster).
    /// `false`, wenn es nichts zu tun gab oder die Ticket-Ansicht aus ist.
    func showTicketsFromController(projectID: UUID?) -> Bool {
        guard ticketBoardEnabled else { return false }
        if let projectID {
            guard workspace.projects.contains(where: { $0.id == projectID }) else { return false }
            if isTicketsModeActive, selectedProject?.id == projectID { return false }
            // Erst das Projekt, dann der Modus: So ist der neue Ort gleich das
            // richtige Board (der Wechsel des Projekts allein ist kein Ortswechsel).
            if selectedProjectID != projectID { selectedProjectID = projectID }
        } else if isTicketsModeActive {
            return false
        }
        windowStore.setTicketsMode(true, in: windowID)
        multiSelection = []
        return true
    }

    /// Zurück zu den Chats, wie der Ticket-Knopf.
    func showChatsFromController() -> Bool {
        guard isTicketsModeActive else { return false }
        windowStore.setTicketsMode(false, in: windowID)
        return true
    }

    /// Ziel von L2 für Leiste und Insel, wenn der vorige Ort das Board ist.
    func controllerTicketsBackTarget(projectID: UUID?) -> ControllerBackTarget {
        let project = projectID.flatMap { id in workspace.projects.first { $0.id == id } }
        let title = TicketTeamDirectory.shared.team(of: projectID) ?? project?.name ?? ""
        return ControllerBackTarget(kind: .tickets, title: title, id: projectID)
    }
}

/// Tastaturfokus vor einer Board-Aktion des Controllers (WM8-91 mit WM8-113):
/// Der Controller erzeugt keine Mausklicks, also greift der Wächter der
/// Board-Spalte nicht. Deshalb hier, vor jeder Aktion außer „Zum Chat“.
enum ControllerTicketFocus {
    @MainActor
    static func prepare(for command: ControllerTicketCommand, in window: NSWindow?) {
        guard command.actsOnBoard else { return }
        BoardChatFocusRule.releaseTerminalFocus(in: window)
    }
}
