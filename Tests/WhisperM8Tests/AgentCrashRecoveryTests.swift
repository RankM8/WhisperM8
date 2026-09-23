import XCTest
@testable import WhisperM8

/// Wiederaufnahme nach Absturz (Vorfall 23.09.2026: SIGPIPE beendete die App,
/// alle Chats standen danach still).
final class AgentCrashRecoveryMarkerTests: XCTestCase {
    private var markerURL: URL!

    override func setUp() {
        super.setUp()
        markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-crash-\(UUID().uuidString)")
            .appendingPathComponent("running-sessions.json")
    }

    private func marker(pid: Int32, alive: Set<Int32> = []) -> AgentCrashRecoveryMarker {
        AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: pid, isProcessAlive: { alive.contains($0) })
    }

    func testFirstStartHasNothingToResume() {
        XCTAssertEqual(marker(pid: 100).beginRun(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testCrashLeavesMarkerAndNextStartGetsRunningSessions() {
        let a = UUID(), b = UUID()
        let crashed = marker(pid: 100)
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [a, b])
        // Kein endRunCleanly — Prozess 100 ist tot.

        let next = marker(pid: 200)
        XCTAssertEqual(Set(next.beginRun()), [a, b])
        // Der neue Lauf übernimmt den Marker leer: ein zweiter Absturz direkt
        // nach dem Start fährt nichts doppelt hoch.
        XCTAssertEqual(marker(pid: 300).beginRun(), [])
    }

    func testCleanQuitRemovesMarkerSoNothingResumes() {
        let first = marker(pid: 100)
        _ = first.beginRun()
        first.record(runningSessionIDs: [UUID()])
        first.endRunCleanly()   // Cmd+Q bzw. SIGTERM von make dev

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(marker(pid: 200).beginRun(), [])
    }

    func testStoppedChatIsDroppedFromMarker() {
        let kept = UUID(), stopped = UUID()
        let first = marker(pid: 100)
        _ = first.beginRun()
        first.record(runningSessionIDs: [kept, stopped])
        first.record(runningSessionIDs: [kept])   // `close --stop` / selbst beendet

        XCTAssertEqual(marker(pid: 200).beginRun(), [kept])
    }

    func testSecondInstanceNeitherStealsNorDeletesRunningAppsMarker() {
        let a = UUID()
        let running = marker(pid: 100)
        _ = running.beginRun()
        running.record(runningSessionIDs: [a])

        // Zweite Instanz (Single-Instance-Check beendet sie gleich wieder).
        let second = marker(pid: 200, alive: [100])
        XCTAssertEqual(second.beginRun(), [])
        second.record(runningSessionIDs: [])
        second.endRunCleanly()

        // Marker der laufenden App unverändert → ihr Absturz bleibt erkennbar.
        XCTAssertEqual(marker(pid: 300).beginRun(), [a])
    }

    func testRecordAfterCleanEndDoesNotRecreateMarker() {
        let first = marker(pid: 100)
        _ = first.beginRun()
        first.endRunCleanly()
        first.record(runningSessionIDs: [UUID()])   // PTY-Exit während des Quits

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }
}

final class AgentCrashRecoveryPlannerTests: XCTestCase {
    private func session(
        status: AgentChatStatus = .running,
        kind: AgentSessionKind? = nil
    ) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: UUID(), title: "t", status: status, kind: kind)
    }

    func testKeepsChatsAndBackgroundChatsInOrder() {
        let chat = session(), background = session(kind: .backgroundChat), codexChat = session(kind: .chat)
        let result = AgentCrashRecoveryPlanner.sessionsToResume(
            previouslyRunning: [codexChat.id, chat.id, background.id],
            sessions: [chat, background, codexChat]
        )
        XCTAssertEqual(result, [codexChat.id, chat.id, background.id])
    }

    func testDropsArchivedUnknownDuplicatesAndNonResumableKinds() {
        let chat = session()
        let archived = session(status: .archived)
        let shell = session(kind: .terminal)
        let agentView = session(kind: .agentView)
        let subagent = session(kind: .subagentJob)
        let result = AgentCrashRecoveryPlanner.sessionsToResume(
            previouslyRunning: [archived.id, shell.id, UUID(), chat.id, agentView.id, subagent.id, chat.id],
            sessions: [chat, archived, shell, agentView, subagent]
        )
        XCTAssertEqual(result, [chat.id])
    }
}

@MainActor
final class AgentCrashRecoveryCoordinatorTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-crashcoord-\(prefix)-\(UUID().uuidString).json")
    }

    func testAfterCrashFlagsResumeAndReopensMissingTabWithoutStealingSelection() throws {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let windowStore = AgentWindowStore(persistence: persistence)
        let project = UUID()
        let openTab = try persistence.upsertSession(
            AgentChatSession(provider: .claude, projectID: project, title: "offen", status: .running))
        let closedTab = try persistence.upsertSession(
            AgentChatSession(provider: .codex, projectID: project, title: "ohne Tab", status: .running))
        let archived = try persistence.upsertSession(
            AgentChatSession(provider: .claude, projectID: project, title: "archiviert", status: .archived))
        windowStore.openTab(openTab.id, in: windowStore.primaryWindowID, select: true)

        let markerURL = tempURL("marker")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [openTab.id, closedTab.id, archived.id])

        AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(),
            windowStore: windowStore,
            store: persistence,
            isEnabled: true
        )

        let sessions = Dictionary(uniqueKeysWithValues: persistence.loadWorkspace().sessions.map { ($0.id, $0) })
        XCTAssertEqual(sessions[openTab.id]?.shouldLaunchOnOpen, true)
        XCTAssertEqual(sessions[closedTab.id]?.shouldLaunchOnOpen, true)
        XCTAssertNotEqual(sessions[archived.id]?.shouldLaunchOnOpen, true)
        let tabs = windowStore.openTabIDs(in: windowStore.primaryWindowID)
        XCTAssertTrue(tabs.contains(closedTab.id))
        XCTAssertFalse(tabs.contains(archived.id))
        XCTAssertEqual(windowStore.selectedSession(in: windowStore.primaryWindowID), openTab.id)
    }

    func testKillSwitchLeavesChatsStopped() throws {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let chat = try persistence.upsertSession(
            AgentChatSession(provider: .claude, projectID: UUID(), title: "c", status: .running))
        let markerURL = tempURL("marker")
        let crashed = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = crashed.beginRun()
        crashed.record(runningSessionIDs: [chat.id])

        AgentCrashRecoveryCoordinator.start(
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            registry: AgentTerminalRegistry(),
            windowStore: AgentWindowStore(persistence: persistence),
            store: persistence,
            isEnabled: false
        )

        XCTAssertNotEqual(persistence.loadWorkspace().sessions.first?.shouldLaunchOnOpen, true)
    }
}
