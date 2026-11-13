import XCTest
@testable import WhisperM8

/// Sammel-Starts starten je Sitzung höchstens einen Chat (Paket b zum
/// Befund 13.11.2026: nie zwei Prozesse auf einer Sitzung).
@MainActor
final class AgentCollectiveStartPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ id: String?, provider: AgentProvider = .claude, active: TimeInterval = 0) -> AgentChatSession {
        AgentChatSession(provider: provider, projectID: UUID(), externalSessionID: id, title: "t",
                         lastActivityAt: t0.addingTimeInterval(active))
    }

    func testOnlyMostRecentlyActiveChatOfASessionStarts() {
        // Fall aus dem echten Workspace: laufender Fin und ein später angelegter Eintrag auf derselben ID.
        let fin = chat("1f353dce", active: 100), stale = chat("1F353DCE", active: 10), other = chat("aa82d0ba")
        let plan = AgentCollectiveStartPlanner.plan([stale.id, fin.id, other.id], sessions: [fin, stale, other])
        XCTAssertEqual(plan.start, [fin.id, other.id])
        XCTAssertEqual(plan.skipped, [stale.id])
    }

    func testTieKeepsFirstAndOrderIsPreserved() {
        let first = chat("x"), second = chat("x"), unbound = chat(nil), alsoUnbound = chat(nil)
        let plan = AgentCollectiveStartPlanner.plan([unbound.id, first.id, alsoUnbound.id, second.id],
                                                    sessions: [first, second, unbound, alsoUnbound])
        XCTAssertEqual(plan.start, [unbound.id, first.id, alsoUnbound.id], "ungebundene Chats starten immer")
        XCTAssertEqual(plan.skipped, [second.id])
    }

    func testSameIDUnderDifferentProvidersIsNoConflict() {
        let claude = chat("x"), codex = chat("x", provider: .codex)
        let plan = AgentCollectiveStartPlanner.plan([claude.id, codex.id], sessions: [claude, codex])
        XCTAssertEqual(plan.start, [claude.id, codex.id])
        XCTAssertTrue(plan.skipped.isEmpty)
    }

    func testCrashRecoveryResumesOnlyOneChatPerSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm8-sammelstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = AgentSessionStore(fileURL: dir.appendingPathComponent("ws.json"),
                                            uiStateFileURL: dir.appendingPathComponent("ui.json"))
        let project = UUID()
        let owner = try persistence.upsertSession(AgentChatSession(
            provider: .claude, projectID: project, externalSessionID: "cd00c6c0", title: "soak bash",
            status: .running, lastActivityAt: t0.addingTimeInterval(60)))
        let wrong = try persistence.upsertSession(AgentChatSession(
            provider: .claude, projectID: project, externalSessionID: "cd00c6c0", title: "soak question",
            status: .running, lastActivityAt: t0))
        let markerURL = dir.appendingPathComponent("marker.json")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [wrong.id, owner.id])

        let resumed = AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(),
            windowStore: AgentWindowStore(persistence: persistence),
            store: persistence,
            isEnabled: true
        )

        XCTAssertEqual(resumed, [owner.id])
        let sessions = Dictionary(uniqueKeysWithValues: persistence.loadWorkspace().sessions.map { ($0.id, $0) })
        XCTAssertEqual(sessions[owner.id]?.shouldLaunchOnOpen, true)
        XCTAssertNotEqual(sessions[wrong.id]?.shouldLaunchOnOpen, true)
    }
}
