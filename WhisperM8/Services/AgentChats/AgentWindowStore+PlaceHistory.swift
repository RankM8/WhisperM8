import Foundation

/// Verlauf der Orte je Fenster (`ChatPlaceHistory`) für L2 am Controller:
/// „zurück dorthin, wo ich vorher war“ — ein einzelner Chat oder ein
/// Workspace im Raster.
///
/// Festgehalten wird im Store nach jeder Änderung des Zustands, nicht in der
/// View: So zählen alle Wege gleich (Maus, Tastatur, Controller, CLI), und
/// auch ein Workspace-Wechsel ohne neue Auswahl (ein Chat in zwei Workspaces)
/// wird ein Ortswechsel. Flüchtig, nur für diesen App-Start.
extension AgentWindowStore {
    /// Ort eines Fensters im gegebenen Zustand.
    static func place(of window: AgentChatWindowState, in state: AgentUIState) -> ChatPlace? {
        let entity = window.activeWorkspaceID.flatMap { id in state.gridWorkspaces.first { $0.id == id } }
        return ChatPlace.of(
            selectedSessionID: window.selectedSessionID,
            showsGrid: window.showsGrid,
            workspaceID: entity?.id,
            isWorkspaceMember: { entity?.slotIndex(of: $0) != nil }
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
    static func isPlaceAvailable(
        _ place: ChatPlace, window: AgentChatWindowState?, in state: AgentUIState
    ) -> Bool {
        switch place {
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
        for window in state.windows {
            var history = placeHistories[window.id] ?? ChatPlaceHistory()
            if placeHistories[window.id] == nil,
               let old = before.windows.first(where: { $0.id == window.id }) {
                history.record(Self.place(of: old, in: before), isAvailable: { _ in true })
            }
            history.record(Self.place(of: window, in: state)) { place in
                Self.isPlaceAvailable(place, window: window, in: state)
            }
            if placeHistories[window.id] != history { placeHistories[window.id] = history }
        }
        if placeHistories.count > state.windows.count {
            let ids = Set(state.windows.map(\.id))
            placeHistories = placeHistories.filter { ids.contains($0.key) }
        }
    }

    /// Ziel von L2 in diesem Fenster: der vorige Ort, sofern es ihn noch gibt.
    func previousPlace(in windowID: UUID) -> ChatPlace? {
        guard let history = placeHistories[windowID] else { return nil }
        let window = state.windows.first { $0.id == windowID }
        return history.target { Self.isPlaceAvailable($0, window: window, in: state) }
    }
}
