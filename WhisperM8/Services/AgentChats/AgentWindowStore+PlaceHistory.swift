import Foundation

/// Verlauf der Orte je Fenster (`ChatPlaceHistory`) für L2 am Controller:
/// „zurück dorthin, wo ich vorher war“ — ein einzelner Chat, ein Workspace im
/// Raster oder das Ticket-Board (WM8-91).
///
/// Festgehalten wird im Store nach jeder Änderung des Zustands, nicht in der
/// View: So zählen alle Wege gleich (Maus, Tastatur, Controller, CLI), und
/// auch ein Workspace-Wechsel ohne neue Auswahl (ein Chat in zwei Workspaces)
/// wird ein Ortswechsel. Flüchtig, nur für diesen App-Start.
extension AgentWindowStore {
    /// Ort eines Fensters im gegebenen Zustand. `ticketsMode`: Das Fenster
    /// zeigt die Tickets; dann ist das Board des gewählten Projekts der Ort.
    static func place(of window: AgentChatWindowState, in state: AgentUIState, ticketsMode: Bool = false) -> ChatPlace? {
        let entity = window.activeWorkspaceID.flatMap { id in state.gridWorkspaces.first { $0.id == id } }
        return ChatPlace.of(
            selectedSessionID: window.selectedSessionID,
            showsGrid: window.showsGrid,
            workspaceID: entity?.id,
            isWorkspaceMember: { entity?.slotIndex(of: $0) != nil },
            ticketsProjectID: ticketsMode ? .some(window.selectedProjectID) : nil
        )
    }

    /// Ist der Ort für dieses Fenster ein brauchbares Ziel?
    ///
    /// Ein Workspace, solange er angelegt ist und kein anderes Fenster ihn
    /// zeigt oder als Rücksprungziel hält — sonst holte L2 ein fremdes
    /// Fenster nach vorn. Ein Chat, solange er hier als Tab offen ist (ein
    /// geschlossener, archivierter oder in ein anderes Fenster gewanderter
    /// Chat ist kein Ziel) und nicht im Workspace liegt, den das Fenster
    /// gerade referenziert: Ihn zu wählen ergäbe wieder diesen Workspace
    /// (Kachel-Fokus statt Ortswechsel), L2 hinge dann auf der Stelle.
    ///
    /// Das Board, solange die Ticket-Ansicht eingeschaltet ist
    /// (`ticketBoardEnabled`). Ob es das Projekt noch gibt, prüft wie beim
    /// Chat die Ansicht (`backPlace()`), die den Workspace kennt.
    static func isPlaceAvailable(
        _ place: ChatPlace, window: AgentChatWindowState?, in state: AgentUIState,
        ticketBoardEnabled: Bool = true
    ) -> Bool {
        switch place {
        case .tickets:
            return ticketBoardEnabled && window != nil
        case .workspace(let id):
            guard state.gridWorkspaces.contains(where: { $0.id == id }) else { return false }
            let owner = state.windows.first { $0.activeWorkspaceID == id }?.id
            return owner == nil || owner == window?.id
        case .chat(let id):
            guard let window, window.openTabIDs.contains(id) else { return false }
            let referenced = window.activeWorkspaceID.flatMap { workspaceID in
                state.gridWorkspaces.first { $0.id == workspaceID }
            }
            return referenced?.slotIndex(of: id) == nil
        }
    }

    /// Nach jeder Änderung des Zustands: Ort je Fenster nachführen. Ein
    /// Fenster ohne Verlauf beginnt mit seinem Ort von vor der Änderung,
    /// damit auch der erste Wechsel nach dem Start ein Ziel hat. Billig:
    /// eine Suche je Fenster.
    func recordPlaces(before: AgentUIState) {
        let boardEnabled = ticketPlaces.isBoardEnabled()
        for window in state.windows {
            let ticketsMode = ticketsModeWindowIDs.contains(window.id)
            var history = placeHistories[window.id] ?? ChatPlaceHistory()
            if placeHistories[window.id] == nil,
               let old = before.windows.first(where: { $0.id == window.id }) {
                history.record(Self.place(of: old, in: before, ticketsMode: ticketsMode), isAvailable: { _ in true })
            }
            history.record(Self.place(of: window, in: state, ticketsMode: ticketsMode)) { place in
                Self.isPlaceAvailable(place, window: window, in: state, ticketBoardEnabled: boardEnabled)
            }
            if placeHistories[window.id] != history { placeHistories[window.id] = history }
            noteShownBoard(history.current, in: window.id)
        }
        if placeHistories.count > state.windows.count {
            let ids = Set(state.windows.map(\.id))
            placeHistories = placeHistories.filter { ids.contains($0.key) }
            ticketPlaces.lastProjectIDs = ticketPlaces.lastProjectIDs.filter { ids.contains($0.key) }
        }
    }

    /// Ort eines Fensters jetzt festhalten, außerhalb einer Änderung des
    /// Zustands: Die Ticket-Ansicht liegt neben dem Zustand
    /// (`ticketsModeWindowIDs`), ihr Umschalten ist trotzdem ein Ortswechsel.
    func recordPlace(of windowID: UUID) {
        guard let window = state.windows.first(where: { $0.id == windowID }) else { return }
        let boardEnabled = ticketPlaces.isBoardEnabled()
        var history = placeHistories[windowID] ?? ChatPlaceHistory()
        let place = Self.place(of: window, in: state, ticketsMode: ticketsModeWindowIDs.contains(windowID))
        history.record(place) { Self.isPlaceAvailable($0, window: window, in: state, ticketBoardEnabled: boardEnabled) }
        if placeHistories[windowID] != history { placeHistories[windowID] = history }
        noteShownBoard(history.current, in: windowID)
    }

    /// Eine Navigation verlässt die Tickets und zeigt gleich einen Chat oder
    /// Workspace. Bis dahin gilt „kein Ort“: Das Board wird so zum
    /// Rücksprungziel und nicht der Chat, der hinter den Tickets gewählt war
    /// und gleich ersetzt wird. Den neuen Ort hält die Änderung des Zustands
    /// fest; ändert sie nichts (derselbe Chat), holt `previousPlace` ihn nach.
    func recordLeavingTickets(in windowID: UUID) {
        guard var history = placeHistories[windowID], case .tickets = history.current else { return }
        history.record(nil, isAvailable: { _ in true })
        placeHistories[windowID] = history
        // Wo die Navigation endet: Hat sie den Zustand nicht geändert
        // (derselbe Chat wie hinter den Tickets), holt das den Ort nach.
        // Gelesen wird der Verlauf ohne Schreiben (bei jedem Schnappschuss).
        DispatchQueue.main.async { [weak self] in self?.recordPlace(of: windowID) }
    }

    private func noteShownBoard(_ place: ChatPlace?, in windowID: UUID) {
        guard case let .tickets(projectID?)? = place, ticketPlaces.lastProjectIDs[windowID] != projectID else { return }
        ticketPlaces.lastProjectIDs[windowID] = projectID
    }

    /// Ziel von L2 in diesem Fenster: der vorige Ort, sofern es ihn noch gibt.
    /// Nur lesen: Läuft bei jedem Schnappschuss des Controllers.
    func previousPlace(in windowID: UUID) -> ChatPlace? {
        guard let history = placeHistories[windowID] else { return nil }
        let window = state.windows.first { $0.id == windowID }
        let boardEnabled = ticketPlaces.isBoardEnabled()
        return history.target { Self.isPlaceAvailable($0, window: window, in: state, ticketBoardEnabled: boardEnabled) }
    }

    /// Zuletzt gezeigtes Board dieses Fensters (Projekt), für „vorher“ im
    /// Reiter „Tickets“ der Insel.
    func lastTicketsProjectID(in windowID: UUID) -> UUID? {
        ticketPlaces.lastProjectIDs[windowID]
    }
}
