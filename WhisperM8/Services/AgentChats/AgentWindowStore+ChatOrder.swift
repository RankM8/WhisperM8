import Foundation

// MARK: - Projekt-Ansicht folgt `chats order`

/// Plätze einer Projekt-Ansicht vor und nach `chats order`.
struct ProjectViewOrderChange: Equatable {
    var workspaceID: UUID
    var name: String
    var before: [UUID?]
    var after: [UUID?]
}

extension AgentWindowStore {
    /// Setzt die belegten Plätze jeder Projekt-Ansicht dieses Projekts in die
    /// Folge `order`. Sonst bleiben die Plätze positionsstabil
    /// (`syncProjectGridWorkspace`), auch beim Umsortieren mit der Maus; nur
    /// dieser Befehl setzt sie bewusst um. Mit `dryRun` nur die Vorschau.
    @discardableResult
    func reorderProjectViews(projectID: UUID, order: [UUID], dryRun: Bool = false) -> [ProjectViewOrderChange] {
        let changes = state.gridWorkspaces
            .filter { $0.sourceProjectID == projectID }
            .map { entity in
                ProjectViewOrderChange(
                    workspaceID: entity.id, name: entity.name, before: entity.slots,
                    after: WorkspaceSlotOps.reorderedSlots(entity.slots, order: order))
            }
        let changed = changes.filter { $0.before != $0.after }
        guard !dryRun, !changed.isEmpty else { return changes }
        mutate { state in
            for change in changed {
                guard let index = state.gridWorkspaces.firstIndex(where: { $0.id == change.workspaceID }) else { continue }
                state.gridWorkspaces[index].slots = change.after
                state.gridWorkspaces[index].normalize()
            }
        }
        return changes
    }

    /// Setzt die Tab-Folge eines Fensters (`chats order --tabs`). Nur eine
    /// Umordnung derselben Tabs; Auswahl und Fenster bleiben. Mit `dryRun`
    /// nur die Vorschau. `nil`, wenn das Fenster fehlt oder `order` nicht
    /// genau seine Tabs enthält.
    @discardableResult
    func setTabOrder(_ order: [UUID], in windowID: UUID, dryRun: Bool = false) -> (before: [UUID], after: [UUID])? {
        guard hasWindow(windowID) else { return nil }
        let before = openTabIDs(in: windowID)
        guard before.count == order.count, Set(before) == Set(order) else { return nil }
        guard !dryRun, before != order else { return (before, order) }
        mutate { state in
            var window = state.windowState(for: windowID)
            window.openTabIDs = order
            state.upsertWindow(window)
        }
        return (before, openTabIDs(in: windowID))
    }
}
