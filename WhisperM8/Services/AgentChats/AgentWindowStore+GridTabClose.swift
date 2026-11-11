import Foundation

/// Tab schließen passt das Raster an: ein geschlossener Chat verlässt die
/// Workspaces, die gerade in einem Fenster offen sind. Doku:
/// docs/features/agent-chats/ui/grid.md, Abschnitt „Wenn Chats wegfallen".
extension AgentWindowStore {
    // MARK: - Grid-Workspaces: Tab geschlossen

    /// Pane-Fokus VOR dem Schließen — das Schließen selbst verschiebt die
    /// Selektion schon auf einen Nachbar-Tab, der Nachfolger soll aber vom
    /// Platz der geschlossenen Pane aus gesucht werden.
    func gridFocusBeforeClosing(in windowID: UUID) -> UUID? {
        let window = window(for: windowID)
        guard window.activeWorkspaceID != nil else { return nil }
        return window.gridFocusSessionID ?? window.selectedSessionID
    }

    /// Ein vom User geschlossener Tab verlässt jeden Workspace, der gerade in
    /// einem Fenster offen ist (sichtbar oder als Rücksprungziel) — das
    /// Raster passt sich an, statt eine „Tab was closed"-Kachel stehen zu
    /// lassen (Nutzerbefund 11.11.2026). Eigene Workspaces verlieren die
    /// Mitgliedschaft (Wiederöffnen per ⌘⇧T nimmt sie zurück); in
    /// Projekt-Views wird ein weiterlaufender Chat als weggeschlossen
    /// gemerkt, sonst holte ihn der Live-Sync sofort zurück.
    ///
    /// Nur mit „Close gaps…" (`gridAutoCompactEnabled`). Ist der Schalter
    /// aus, gilt das alte Verhalten: Mitgliedschaft bleibt, die Kachel zeigt
    /// „Tab was closed · Reopen".
    ///
    /// Bleibt unberührt: Workspaces, die in keinem Fenster offen sind
    /// (Playlist — Öffnen materialisiert die Tabs wieder), und Tabs, die nur
    /// in ein anderes Fenster wandern (Kachel bietet „Move here").
    ///
    /// - Returns: je Session die eigenen Workspaces, die sie verlassen hat,
    ///   samt Stelle (für ⇧⌘T).
    @discardableResult
    func releaseClosedTabsFromOpenGrids(
        _ sessionIDs: [UUID],
        closingWindowID: UUID? = nil,
        focusBefore: UUID? = nil
    ) -> [UUID: [ReleasedSlot]] {
        guard !sessionIDs.isEmpty, isGridAutoCompactEnabled() else { return [:] }
        // Ein Tab, der noch in irgendeinem Fenster lebt, ist nicht zu.
        let stillOpen = allWindowOpenTabIDs
        let closed = sessionIDs.filter { !stillOpen.contains($0) }
        guard !closed.isEmpty else { return [:] }
        var released: [UUID: [ReleasedSlot]] = [:]
        var dismissed = dismissedProjectViewSessionIDs

        mutate { state in
            for windowIndex in state.windows.indices {
                guard let workspaceID = state.windows[windowIndex].activeWorkspaceID,
                      let entityIndex = state.gridWorkspaces.firstIndex(where: { $0.id == workspaceID })
                else { continue }
                var entity = state.gridWorkspaces[entityIndex]
                let leaving = closed.filter { entity.slotIndex(of: $0) != nil }
                guard !leaving.isEmpty else { continue }

                var window = state.windows[windowIndex]
                let focus = window.id == closingWindowID
                    ? focusBefore
                    : window.gridFocusSessionID ?? window.selectedSessionID
                let focusIndex = focus.flatMap { leaving.contains($0) ? entity.slotIndex(of: $0) : nil }
                // Stelle für ⇧⌘T merken: belegte Plätze VOR dem Chat.
                var orders: [UUID: Int] = [:]
                for sessionID in leaving {
                    if let index = entity.slotIndex(of: sessionID) {
                        orders[sessionID] = entity.slots[..<index].compactMap { $0 }.count
                    }
                }
                for sessionID in leaving {
                    if let index = entity.slotIndex(of: sessionID) { entity.slots[index] = nil }
                }
                // Fokus-Nachfolger VOR dem Verdichten bestimmen: nächster
                // eigener Slot nach der geschlossenen Pane, sonst der davor.
                if let focusIndex {
                    let ownTabs = Set(window.openTabIDs)
                    let after = entity.slots[focusIndex...].compactMap { $0 }.filter(ownTabs.contains)
                    let before = entity.slots[..<focusIndex].compactMap { $0 }.filter(ownTabs.contains)
                    let fallback = after.first ?? before.last
                    window.gridFocusSessionID = fallback
                    if window.showsGrid { window.selectedSessionID = fallback }
                }
                entity = WorkspaceSlotOps.compacted(entity)
                entity.normalize()
                state.gridWorkspaces[entityIndex] = entity
                state.upsertWindow(window)

                if entity.sourceProjectID != nil {
                    dismissed[workspaceID, default: []].formUnion(leaving)
                } else {
                    for sessionID in leaving {
                        released[sessionID, default: []].append(
                            ReleasedSlot(workspaceID: workspaceID, order: orders[sessionID] ?? 0)
                        )
                    }
                }
            }
        }
        if dismissed != dismissedProjectViewSessionIDs {
            dismissedProjectViewSessionIDs = dismissed
        }
        return released
    }

    /// ⇧⌘T: Chat an seine alte Stelle im eigenen Workspace zurück
    /// (`WorkspaceSlotOps.reinsert`). Gehört der Workspace einem Fenster und
    /// hält kein anderes Fenster den Tab, wird der Tab dort materialisiert —
    /// wie bei `addSession`. Projekt-Views verwalten ihre Mitglieder selbst.
    @discardableResult
    func reinsertSession(
        _ sessionID: UUID,
        intoGridWorkspace workspaceID: UUID,
        atOrder order: Int
    ) -> WorkspaceSlotOps.AddResult {
        guard let entity = gridWorkspace(id: workspaceID), entity.sourceProjectID == nil else {
            return .rejected(.workspaceUnknown)
        }
        let (updated, result) = WorkspaceSlotOps.reinsert(sessionID, into: entity, atOrder: order)
        guard case .added = result else { return result }
        mutate { state in
            guard let index = state.gridWorkspaces.firstIndex(where: { $0.id == workspaceID })
            else { return }
            state.gridWorkspaces[index] = updated
            guard let ownerID = state.windows.first(where: { $0.activeWorkspaceID == workspaceID })?.id,
                  !state.windows.contains(where: { $0.id != ownerID && $0.openTabIDs.contains(sessionID) })
            else { return }
            var window = state.windowState(for: ownerID)
            if !window.openTabIDs.contains(sessionID) { window.openTabIDs.append(sessionID) }
            state.upsertWindow(window)
        }
        return result
    }

    /// Hat ein weggeschlossener Chat wieder einen Tab (egal in welchem
    /// Fenster), gehört er wieder in seine Projekt-View — der Live-Sync
    /// nimmt ihn auf, weil sich diese Liste ändert.
    func clearDismissalsOfReopenedTabs() {
        guard !dismissedProjectViewSessionIDs.isEmpty else { return }
        let open = allWindowOpenTabIDs
        var cleaned = dismissedProjectViewSessionIDs
        for (workspaceID, ids) in cleaned {
            let remaining = ids.subtracting(open)
            cleaned[workspaceID] = remaining.isEmpty ? nil : remaining
        }
        if cleaned != dismissedProjectViewSessionIDs {
            dismissedProjectViewSessionIDs = cleaned
        }
    }
}
