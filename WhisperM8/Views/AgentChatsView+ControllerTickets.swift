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
    func performTicketCommand(_ command: ControllerTicketCommand) -> ControllerTicketOutcome {
        guard isTicketsModeActive, TicketBoardControllers.shared.hasController(for: windowID) else { return .rejected }
        let controller = TicketBoardControllers.shared.controller(for: windowID)
        let model = controller.viewModel
        if command == .refresh {
            controller.refresh()
            if model.triage != nil { model.reloadComments() }
            return .done
        }
        guard controller.phase == .ready else {
            if case .move(.left) = command { return .leftEdge }
            return .rejected
        }
        // Erster Druck ohne Auswahl: die Start-Auswahl zeigen, noch nicht bewegen.
        let hadSpot = model.triage != nil || controllerHasSelection(model)
        switch command {
        case .move(let direction):
            if !hadSpot, direction != .left {
                model.ensureControllerSelection(preferringChat: selectedSessionID)
                return controllerHasSelection(model) ? .done : .nothing
            }
            return model.controllerMove(TicketBoardMove(direction))
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
        case .refresh, .dictationUnavailable:
            return .rejected
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
        performCommand(.selectSession(chatID)) ? .done : .rejected
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
