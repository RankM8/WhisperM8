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
}
