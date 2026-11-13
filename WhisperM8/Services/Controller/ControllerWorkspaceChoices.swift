import Foundation

extension ControllerWorkspaceChoice {
    /// Einträge der Workspace-Auswahl aus den Workspaces des Stores: nur
    /// angelegte (keine versteckten Projekt-Ansichten), in der Reihenfolge der
    /// Seitenleiste. „Wartet“ ist derselbe Status (`awaitingInput`), den die
    /// Status-Punkte zeigen — keine eigene Heuristik.
    /// - Parameter currentID: Workspace, dessen Raster das Fenster gerade zeigt.
    static func choices(
        from workspaces: [AgentGridWorkspace],
        currentID: UUID?,
        status: (UUID) -> AgentSessionRuntimeStatus?
    ) -> [ControllerWorkspaceChoice] {
        workspaces
            .filter { $0.sourceProjectID == nil }
            .map { entity in
                let sessionIDs = entity.occupiedSessionIDs
                return ControllerWorkspaceChoice(
                    id: entity.id,
                    name: entity.name,
                    colorHex: entity.colorHex,
                    chatCount: sessionIDs.count,
                    hasWaitingChat: sessionIDs.contains { status($0) == .awaitingInput },
                    isCurrent: entity.id == currentID
                )
            }
    }

    /// Projekte für den Reiter „Workspaces & Projekte“: in der Reihenfolge
    /// der Seitenleiste, nur mit aktiven Chats (sonst öffnete der ⊞ dort
    /// nichts) oder wenn ihr Raster gerade sichtbar ist.
    static func projectChoices(
        from projects: [(id: UUID, name: String, colorHex: String)],
        active: [UUID: Set<UUID>],
        shownProjectID: UUID?,
        views: [UUID: UUID],
        status: (UUID) -> AgentSessionRuntimeStatus?
    ) -> [ControllerWorkspaceChoice] {
        projects.compactMap { project in
            let sessionIDs = active[project.id] ?? []
            let isCurrent = project.id == shownProjectID
            guard !sessionIDs.isEmpty || isCurrent else { return nil }
            return ControllerWorkspaceChoice(
                id: project.id, name: project.name, colorHex: project.colorHex,
                chatCount: sessionIDs.count,
                hasWaitingChat: sessionIDs.contains { status($0) == .awaitingInput },
                isCurrent: isCurrent, kind: .project, viewWorkspaceID: views[project.id])
        }
    }
}
