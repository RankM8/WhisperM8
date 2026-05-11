import Foundation

enum AgentSessionDropPlan: Equatable {
    case reorder(projectID: UUID, orderedIDs: [UUID])
    case move(sessionID: UUID, newProjectID: UUID, targetIndex: Int)
    case none
}

enum AgentProjectDropPlan: Equatable {
    case reorder(orderedIDs: [UUID])
    case none
}

struct AgentDragDropPlanner {
    static func sessionDropPlan(
        dropped: DraggableSession,
        targetProjectID: UUID,
        beforeSessionID: UUID?,
        workspace: AgentWorkspace
    ) -> AgentSessionDropPlan {
        guard workspace.projects.contains(where: { $0.id == targetProjectID }),
              workspace.sessions.contains(where: { $0.id == dropped.sessionID }) else {
            return .none
        }

        if dropped.sourceProjectID == targetProjectID {
            let sorted = AgentSessionStore.sortedSessions(
                workspace.sessions.filter { $0.projectID == targetProjectID && $0.status != .archived }
            )
            let currentIDs = sorted.map(\.id)
            guard currentIDs.contains(dropped.sessionID) else { return .none }

            var orderedIDs = currentIDs.filter { $0 != dropped.sessionID }
            let insertAt: Int
            if let beforeSessionID, let index = orderedIDs.firstIndex(of: beforeSessionID) {
                insertAt = index
            } else {
                insertAt = orderedIDs.count
            }
            orderedIDs.insert(dropped.sessionID, at: insertAt)
            guard orderedIDs != currentIDs else { return .none }
            return .reorder(projectID: targetProjectID, orderedIDs: orderedIDs)
        }

        let sortedTargetSessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == targetProjectID && $0.status != .archived }
        )
        let targetIndex: Int
        if let beforeSessionID, let index = sortedTargetSessions.firstIndex(where: { $0.id == beforeSessionID }) {
            targetIndex = index
        } else {
            targetIndex = sortedTargetSessions.count
        }
        return .move(
            sessionID: dropped.sessionID,
            newProjectID: targetProjectID,
            targetIndex: targetIndex
        )
    }

    static func projectDropPlan(
        dropped: DraggableProject,
        beforeProjectID: UUID?,
        visibleProjects: [AgentProject]
    ) -> AgentProjectDropPlan {
        let currentIDs = visibleProjects.map(\.id)
        guard currentIDs.contains(dropped.projectID) else { return .none }
        var orderedIDs = currentIDs.filter { $0 != dropped.projectID }
        let insertAt: Int
        if let beforeProjectID, let index = orderedIDs.firstIndex(of: beforeProjectID) {
            insertAt = index
        } else {
            insertAt = orderedIDs.count
        }
        orderedIDs.insert(dropped.projectID, at: insertAt)
        guard orderedIDs != currentIDs else { return .none }
        return .reorder(orderedIDs: orderedIDs)
    }
}
