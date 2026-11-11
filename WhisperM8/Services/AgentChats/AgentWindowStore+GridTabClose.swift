import Foundation

/// Tab schließen passt das Raster an: ein geschlossener Chat verlässt die
/// Workspaces, die gerade in einem Fenster offen sind. Doku:
/// docs/features/agent-chats/ui/grid.md, Abschnitt „Wenn Chats wegfallen".
extension AgentWindowStore {
    // MARK: - Grid-Workspaces: Tab geschlossen

    /// Ein vom User geschlossener Tab verlässt jeden Workspace, der gerade in
    /// einem Fenster offen ist (sichtbar oder als Rücksprungziel) — das
    /// Raster passt sich an, statt eine „Tab was closed"-Kachel stehen zu
    /// lassen (Nutzerbefund 11.11.2026). Eigene Workspaces verlieren die
    /// Mitgliedschaft (Wiederöffnen per ⌘⇧T nimmt sie zurück); in
    /// Projekt-Views wird ein weiterlaufender Chat als weggeschlossen
    /// gemerkt, sonst holte ihn der Live-Sync sofort zurück.
    ///
    /// Bleibt unberührt: Workspaces, die in keinem Fenster offen sind
    /// (Playlist — Öffnen materialisiert die Tabs wieder), und Tabs, die nur
    /// in ein anderes Fenster wandern (Kachel bietet „Move here").
    ///
    /// - Returns: je Session die eigenen Workspaces, die sie verlassen hat.
    /// Pane-Fokus VOR dem Schließen — das Schließen selbst verschiebt die
    /// Selektion schon auf einen Nachbar-Tab, der Nachfolger soll aber vom
    /// Platz der geschlossenen Pane aus gesucht werden.
    func gridFocusBeforeClosing(in windowID: UUID) -> UUID? {
        let window = window(for: windowID)
        guard window.activeWorkspaceID != nil else { return nil }
        return window.gridFocusSessionID ?? window.selectedSessionID
    }

    @discardableResult
    func releaseClosedTabsFromOpenGrids(
        _ sessionIDs: [UUID],
        closingWindowID: UUID? = nil,
        focusBefore: UUID? = nil
    ) -> [UUID: [UUID]] {
        guard !sessionIDs.isEmpty else { return [:] }
        // Ein Tab, der noch in irgendeinem Fenster lebt, ist nicht zu.
        let stillOpen = allWindowOpenTabIDs
        let closed = sessionIDs.filter { !stillOpen.contains($0) }
        guard !closed.isEmpty else { return [:] }
        let compacting = isGridAutoCompactEnabled()
        var released: [UUID: [UUID]] = [:]
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
                if compacting {
                    entity = WorkspaceSlotOps.compacted(entity)
                } else if entity.sourceProjectID != nil {
                    let trimmed = WorkspaceSlotOps.trimmedProjectTail(entity.slots)
                    entity.slots = trimmed.slots
                    entity.capacity = trimmed.capacity
                }
                entity.normalize()
                state.gridWorkspaces[entityIndex] = entity
                state.upsertWindow(window)

                if entity.sourceProjectID != nil {
                    dismissed[workspaceID, default: []].formUnion(leaving)
                } else {
                    for sessionID in leaving { released[sessionID, default: []].append(workspaceID) }
                }
            }
        }
        if dismissed != dismissedProjectViewSessionIDs {
            dismissedProjectViewSessionIDs = dismissed
        }
        return released
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
