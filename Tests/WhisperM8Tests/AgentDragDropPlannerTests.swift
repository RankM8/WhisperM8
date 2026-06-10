import Foundation
import XCTest
@testable import WhisperM8

final class AgentDragDropPlannerTests: XCTestCase {
    // MARK: - Drag-and-drop reordering

    func testReorderProjectsAssignsSequentialSortIndices() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        // Drei Test-Projekte mit unterschiedlichen Pfaden anlegen.
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "p2", name: "B", createdManually: true)
        let p3 = try store.upsertProject(path: NSTemporaryDirectory() + "p3", name: "C", createdManually: true)

        // C, A, B — eine vom Default-Order abweichende Reihenfolge.
        try store.reorderProjects(orderedIDs: [p3.id, p1.id, p2.id])

        let sorted = AgentSessionStore.sortedProjects(store.loadWorkspace().projects)
        XCTAssertEqual(sorted.map(\.id), [p3.id, p1.id, p2.id])
        XCTAssertEqual(sorted.map(\.sortIndex), [0, 1, 2])
    }

    func testReorderSessionsAffectsOnlyTargetProject() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "drag-p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "drag-p2", name: "B", createdManually: true)
        let s1 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S1")
        let s2 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S2")
        let s3 = try store.createSession(provider: .claude, projectPath: p1.path, title: "S3")
        let other = try store.createSession(provider: .claude, projectPath: p2.path, title: "Other")

        // Innerhalb p1 umordnen: S3, S1, S2
        try store.reorderSessions(in: p1.id, orderedIDs: [s3.id, s1.id, s2.id])

        let workspace = store.loadWorkspace()
        let p1Sessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == p1.id }
        )
        XCTAssertEqual(p1Sessions.map(\.id), [s3.id, s1.id, s2.id])
        // Andere Projekt-Session unverändert.
        let otherSnapshot = workspace.sessions.first { $0.id == other.id }
        XCTAssertNotNil(otherSnapshot)
        XCTAssertEqual(otherSnapshot?.projectID, p2.id)
    }

    func testReorderSessionsWithSameOrderIsNoOpAfterSortIndicesExist() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "noop-p1", name: "A", createdManually: true)
        let first = try store.createSession(provider: .claude, projectPath: project.path, title: "S1")
        let second = try store.createSession(provider: .claude, projectPath: project.path, title: "S2")
        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])
        let before = store.loadWorkspace()

        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testReorderAndMoveIgnoreStaleIDs() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "stale-p1", name: "A", createdManually: true)
        let session = try store.createSession(provider: .claude, projectPath: project.path, title: "S1")
        let before = store.loadWorkspace()

        try store.reorderSessions(in: project.id, orderedIDs: [UUID()])
        try store.moveSessionToProject(sessionID: session.id, newProjectID: UUID(), targetIndex: 0)

        XCTAssertEqual(store.loadWorkspace(), before)
    }

    func testAgentDragDropPlannerBuildsSessionReorderPlanForLowerToUpperDrop() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: second.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: first.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .reorder(projectID: project.id, orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerBuildsSessionReorderPlanForUpperToLowerDrop() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: second.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .reorder(projectID: project.id, orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerPersistsUpperToLowerSessionReorder() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let project = try store.upsertProject(path: NSTemporaryDirectory() + "dnd-down", name: "Repo", createdManually: true)
        let first = try store.createSession(provider: .claude, projectPath: project.path, title: "First")
        let second = try store.createSession(provider: .claude, projectPath: project.path, title: "Second")
        try store.reorderSessions(in: project.id, orderedIDs: [first.id, second.id])
        let workspace = store.loadWorkspace()

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: second.id,
            workspace: workspace
        )

        guard case .reorder(let projectID, let orderedIDs) = plan else {
            return XCTFail("Expected reorder plan for downward session drop")
        }
        try store.reorderSessions(in: projectID, orderedIDs: orderedIDs)

        let reloaded = store.loadWorkspace()
        let sortedIDs = AgentSessionStore.sortedSessions(reloaded.sessions.filter { $0.projectID == project.id }).map(\.id)
        XCTAssertEqual(sortedIDs, [second.id, first.id])
    }

    func testAgentDragDropPlannerTreatsSelfDropAsNoOp() {
        let project = AgentProject(name: "Repo", path: "/tmp/repo")
        let first = AgentChatSession(provider: .claude, projectID: project.id, title: "First", sortIndex: 0)
        let second = AgentChatSession(provider: .claude, projectID: project.id, title: "Second", sortIndex: 1)
        let workspace = AgentWorkspace(projects: [project], sessions: [first, second])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: first.id, sourceProjectID: project.id),
            targetProjectID: project.id,
            beforeSessionID: first.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .none)
    }

    func testAgentDragDropPlannerBuildsCrossProjectMovePlan() {
        let source = AgentProject(name: "Source", path: "/tmp/source")
        let target = AgentProject(name: "Target", path: "/tmp/target")
        let mover = AgentChatSession(provider: .claude, projectID: source.id, title: "Mover")
        let targetSession = AgentChatSession(provider: .claude, projectID: target.id, title: "Target", sortIndex: 0)
        let workspace = AgentWorkspace(projects: [source, target], sessions: [mover, targetSession])

        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: mover.id, sourceProjectID: source.id),
            targetProjectID: target.id,
            beforeSessionID: targetSession.id,
            workspace: workspace
        )

        XCTAssertEqual(plan, .move(sessionID: mover.id, newProjectID: target.id, targetIndex: 0))
    }

    func testAgentDragDropPlannerBuildsProjectReorderPlan() {
        let first = AgentProject(name: "First", path: "/tmp/first", sortIndex: 0)
        let second = AgentProject(name: "Second", path: "/tmp/second", sortIndex: 1)

        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: DraggableProject(projectID: second.id),
            beforeProjectID: first.id,
            visibleProjects: [first, second]
        )

        XCTAssertEqual(plan, .reorder(orderedIDs: [second.id, first.id]))
    }

    func testAgentDragDropPlannerBuildsProjectReorderPlanForUpperToLowerDrop() {
        let first = AgentProject(name: "First", path: "/tmp/first", sortIndex: 0)
        let second = AgentProject(name: "Second", path: "/tmp/second", sortIndex: 1)

        let plan = AgentDragDropPlanner.projectDropPlan(
            dropped: DraggableProject(projectID: first.id),
            beforeProjectID: second.id,
            visibleProjects: [first, second]
        )

        XCTAssertEqual(plan, .reorder(orderedIDs: [second.id, first.id]))
    }

    func testMoveSessionToProjectInsertsAtTargetIndex() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        let p1 = try store.upsertProject(path: NSTemporaryDirectory() + "move-p1", name: "A", createdManually: true)
        let p2 = try store.upsertProject(path: NSTemporaryDirectory() + "move-p2", name: "B", createdManually: true)
        let s1 = try store.createSession(provider: .claude, projectPath: p2.path, title: "T1")
        let s2 = try store.createSession(provider: .claude, projectPath: p2.path, title: "T2")
        let mover = try store.createSession(provider: .claude, projectPath: p1.path, title: "Mover")
        try store.reorderSessions(in: p2.id, orderedIDs: [s1.id, s2.id])

        // Mover von p1 nach p2 verschieben, an Position 1 (zwischen T1 und T2).
        try store.moveSessionToProject(sessionID: mover.id, newProjectID: p2.id, targetIndex: 1)

        let workspace = store.loadWorkspace()
        let p2Sessions = AgentSessionStore.sortedSessions(
            workspace.sessions.filter { $0.projectID == p2.id }
        )
        XCTAssertEqual(p2Sessions.map(\.id), [s1.id, mover.id, s2.id])

        let updatedMover = workspace.sessions.first { $0.id == mover.id }
        XCTAssertEqual(updatedMover?.projectID, p2.id)
    }

    func testSortedProjectsPrefersExplicitSortIndex() {
        let now = Date()
        let p1 = AgentProject(id: UUID(), name: "Latest", path: "/a", createdAt: now, updatedAt: now, sortIndex: nil)
        let p2 = AgentProject(id: UUID(), name: "Pinned", path: "/b", createdAt: now.addingTimeInterval(-1000), updatedAt: now.addingTimeInterval(-1000), sortIndex: 0)
        let sorted = AgentSessionStore.sortedProjects([p1, p2])
        // Explizit gesetzter sortIndex schlägt jüngeres updatedAt.
        XCTAssertEqual(sorted.first?.id, p2.id)
    }
}
