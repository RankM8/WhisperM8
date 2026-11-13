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
}
