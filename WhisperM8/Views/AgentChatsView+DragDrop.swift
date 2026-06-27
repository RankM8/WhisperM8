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
