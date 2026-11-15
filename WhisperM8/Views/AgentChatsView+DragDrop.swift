import SwiftUI

/// Sidebar-Drag&Drop-Koordinatoren der AgentChatsView: Session-Reorder
/// (inkl. Cross-Project-Move) und Projekt-Reorder. Aus AgentChatsView.swift
/// ausgelagert (Phase-2-Split). Tab-Drag liegt in AgentChatsView+Tabs.swift.
extension AgentChatsView {
    // MARK: - Drag-and-Drop coordinators

    /// Reordert die Sessions eines Projekts: Row-Drops werden vom Planner
    /// richtungsabhaengig eingeordnet, `nil` bedeutet ans Ende anhaengen.
    /// Cross-Project: wenn `droppedSession.sourceProjectID != projectID`,
    /// wird die Session zusätzlich in das Ziel-Projekt verschoben.
    func dropSession(
        _ dropped: DraggableSession,
        in projectID: UUID,
        beforeSessionID: UUID?
    ) {
        // Ein Chat aus einem Arbeitsordner neben dem Projekt (WM8-102) steht
        // nur zur Anzeige unter dem Haupt-Projekt. Ziehen innerhalb dieser
        // Gruppe darf ihn nicht ins Haupt-Projekt verschieben, sonst startete
        // er dort statt in seinem Ordner.
        if let source = workspace.sessions.first(where: { $0.id == dropped.sessionID }),
           AgentProjectDisplay.parentByProjectID(projects: workspace.projects)[source.projectID] == projectID {
            return
        }
        switch AgentDragDropPlanner.sessionDropPlan(
            dropped: dropped,
            targetProjectID: projectID,
            beforeSessionID: beforeSessionID,
            workspace: workspace
        ) {
        case .reorder(let projectID, let orderedIDs):
            do {
                try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .move(let sessionID, let newProjectID, let targetIndex):
            do {
                try store.moveSessionToProject(
                    sessionID: sessionID,
                    newProjectID: newProjectID,
                    targetIndex: targetIndex
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        case .none:
            return
        }
    }

    /// Reordert die Projekt-Reihenfolge in der Sidebar — `droppedProject`
    /// wird vor `beforeProjectID` einsortiert (`nil` = ans Ende).
    func dropProject(
        _ dropped: DraggableProject,
        beforeProjectID: UUID?
    ) {
        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: dropped,
            beforeProjectID: beforeProjectID,
            visibleProjects: manualProjects
        )
        guard case .reorder(let orderedIDs) = plan else { return }
        do {
            try store.reorderProjects(orderedIDs: orderedIDs)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
