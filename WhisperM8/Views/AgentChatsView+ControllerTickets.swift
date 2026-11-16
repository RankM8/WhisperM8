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
    func controllerTicketsPlace() -> ControllerTicketsPlace? {
        guard isTicketsModeActive else { return nil }
        let project = selectedProject
        return ControllerTicketsPlace(
            projectID: project?.id, team: TicketTeamDirectory.shared.team(of: project?.id), projectName: project?.name)
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
