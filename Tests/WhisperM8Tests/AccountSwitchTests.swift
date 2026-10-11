import Darwin
import XCTest
@testable import WhisperM8

/// Slice 2 (Plan claude-account-switch-ohne-stopp.md): Kontowechsel ohne
/// Stoppen — Entscheidung pur, Ausführung über eine Fake-Welt ohne Terminals.
final class AccountSwitchPlannerTests: XCTestCase {
    private func candidate(_ title: String, running: Bool = false, conflict: Bool = false) -> AccountMovePlanner.Candidate {
        AccountMovePlanner.Candidate(
            sessionID: UUID(), title: title, currentProfile: nil, provider: .claude,
            kind: .chat, isRunning: running, hasTargetConflict: conflict)
    }

    private func decide(
        _ candidates: [AccountMovePlanner.Candidate],
        status: [UUID: AgentSessionRuntimeStatus] = [:],
        drafts: Set<UUID> = [],
        caller: UUID? = nil,
        untrusted: Set<UUID> = []
    ) -> AccountSwitchPlanner.Decision {
        let plan = AccountMovePlanner.plan(candidates: candidates, targetProfile: "ai2", targetIsLoggedIn: true)
        return AccountSwitchPlanner.decide(
            plan: plan,
            isCaller: { $0 == caller },
            status: { status[$0] },
            mayHaveUnsentInput: { drafts.contains($0) },
            targetTrustsProject: { !untrusted.contains($0) })
    }

    func testStoppedChatMovesNowAndIdleRunningChatSwitchesNow() {
        let stopped = candidate("aus")
        let idle = candidate("ruht", running: true)
        let decision = decide([stopped, idle], status: [idle.sessionID: .idle])
        XCTAssertEqual(decision.moveNow.map(\.title), ["aus"])
        XCTAssertEqual(decision.switchNow.map(\.title), ["ruht"])
        XCTAssertTrue(decision.waitForTurn.isEmpty)
    }

    func testBusyChatsWaitWithReason() {
        let working = candidate("arbeitet", running: true)
        let asking = candidate("fragt", running: true)
        let drafting = candidate("entwurf", running: true)
        let unknown = candidate("unbekannt", running: true)
        let decision = decide(
            [working, asking, drafting, unknown],
            status: [working.sessionID: .working, asking.sessionID: .awaitingInput, drafting.sessionID: .idle],
            drafts: [drafting.sessionID])
        XCTAssertEqual(decision.waitForTurn.map(\.candidate.title), ["arbeitet", "fragt", "entwurf", "unbekannt"])
        XCTAssertEqual(decision.waitForTurn.map(\.reason), [.turnRunning, .awaitingInput, .unsentInput, .turnRunning])
        XCTAssertTrue(decision.switchNow.isEmpty)
    }

    func testMissingTrustBlocksOnlyTheUnwatchedSwitch() {
        let idle = candidate("ruht", running: true)
        let working = candidate("arbeitet", running: true)
        let decision = decide(
            [idle, working],
            status: [idle.sessionID: .idle, working.sessionID: .working],
            untrusted: [idle.sessionID, working.sessionID])
        XCTAssertEqual(decision.switchNow.map(\.title), ["ruht"], "ruhend = User schaut hin, Trust-Dialog ist ok")
        XCTAssertEqual(decision.blocked.map(\.reason), [.trustMissing])
    }

    func testOwnSessionIsNeverStopped() {
        let me = candidate("ich", running: true)
        let decision = decide([me], status: [me.sessionID: .idle], caller: me.sessionID)
        XCTAssertEqual(decision.blocked.map(\.reason), [.ownSession])
        XCTAssertTrue(decision.switchNow.isEmpty)
    }

    func testOtherSkipReasonsWinBeforeStopping() {
        let conflicting = candidate("kollidiert", running: true, conflict: true)
        let decision = decide([conflicting], status: [conflicting.sessionID: .idle])
        XCTAssertEqual(decision.skipped.map(\.reason), [.targetConflict], "nie anhalten, was danach nicht umziehen darf")
        XCTAssertEqual(decision.actionableCount, 0)
    }
}

@MainActor
final class AccountSwitchCoordinatorTests: XCTestCase {
    /// Fake-Welt: Prozesse, Status, Entwürfe und was die Kette mit ihnen tut.
    @MainActor
    final class World {
        var project = AgentProject(name: "app", path: "/Users/x/app")
        var sessions: [AgentChatSession] = []
        var running: Set<UUID> = []
        var status: [UUID: AgentSessionRuntimeStatus] = [:]
        var drafts: Set<UUID> = []
        var backgroundTasks: [UUID: Int] = [:]
        /// Prozesse, die sich trotz Terminate nicht beenden.
        var hanging: Set<UUID> = []
        var pids: [UUID: pid_t] = [:]
        var terminated: [UUID] = []
        var terminateCalls = 0
        var moved: [AccountMoveService.Move] = []
        var batchIDs: Set<UUID> = []
        var resumed: [UUID] = []
        var enabled = true

        func addSession(_ title: String, running isRunning: Bool, status: AgentSessionRuntimeStatus? = nil) -> UUID {
            let session = AgentChatSession(
                provider: .claude, projectID: project.id, externalSessionID: UUID().uuidString, title: title)
            sessions.append(session)
            pids[session.id] = pid_t(1000 + sessions.count)
            if isRunning { running.insert(session.id) }
            if let status { self.status[session.id] = status }
            return session.id
        }

        var dependencies: AccountSwitchCoordinator.Dependencies {
            AccountSwitchCoordinator.Dependencies(
                isRunning: { [unowned self] in running.contains($0) },
                processID: { [unowned self] in pids[$0] },
                terminate: { [unowned self] ids in
                    terminateCalls += 1
                    for id in ids {
                        terminated.append(id)
                        if !hanging.contains(id) { running.remove(id) }
                    }
                },
                waitForExit: { [unowned self] pid in
                    await MainActor.run {
                        guard let id = self.pids.first(where: { $0.value == pid })?.key else { return true }
                        return !self.running.contains(id)
                    }
                },
                status: { [unowned self] in status[$0] },
                mayHaveUnsentInput: { [unowned self] in drafts.contains($0) },
                openBackgroundTasks: { [unowned self] in backgroundTasks[$0] ?? 0 },
                workspace: { [unowned self] in AgentWorkspace(projects: [project], sessions: sessions) },
                plan: { [unowned self] sessions, _, targetName in
                    AccountMovePlanner.plan(
                        candidates: sessions.map {
                            AccountMovePlanner.Candidate(
                                sessionID: $0.id, title: $0.title, currentProfile: $0.claudeProfileName,
                                provider: $0.provider, kind: $0.effectiveKind,
                                isRunning: running.contains($0.id), hasTargetConflict: false)
                        },
                        targetProfile: AccountMovePlanner.normalize(targetName),
                        targetIsLoggedIn: true)
                },
                perform: { [unowned self] moves, batchID in
                    moved += moves
                    batchIDs.insert(batchID)
                    return AccountMoveService.Outcome()
                },
                scheduleResume: { [unowned self] in resumed.append($0) },
                isEnabled: { [unowned self] in enabled })
        }

        func plan(_ ids: [UUID]) -> AccountMovePlanner.Plan {
            dependencies.plan(sessions.filter { ids.contains($0.id) }, [project], "ai2")
        }
    }

    private func decideAndRun(_ world: World, _ coordinator: AccountSwitchCoordinator, _ ids: [UUID]) async -> AccountSwitchPlanner.Decision {
        let decision = coordinator.decide(plan: world.plan(ids), targetTrustsProject: { _ in true })
        _ = await coordinator.execute(decision, targetName: "ai2")
        return decision
    }

    func testIdleRunningChatIsStoppedMovedAndResumed() async {
        let world = World()
        let id = world.addSession("ruht", running: true, status: .idle)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        _ = await decideAndRun(world, coordinator, [id])

        XCTAssertEqual(world.terminated, [id])
        XCTAssertEqual(world.moved.map(\.sessionID), [id])
        XCTAssertEqual(world.moved.first?.toProfile, "ai2")
        XCTAssertEqual(world.resumed, [id])
        XCTAssertTrue(coordinator.pending.isEmpty)
    }

    func testSeveralIdleChatsAreStoppedTogether() async {
        let world = World()
        let ids = (1...4).map { world.addSession("ruht \($0)", running: true, status: .idle) }
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        _ = await decideAndRun(world, coordinator, ids)

        XCTAssertEqual(world.terminateCalls, 1, "eine gemeinsame Ctrl+C-Wartezeit statt einer pro Chat")
        XCTAssertEqual(Set(world.terminated), Set(ids))
        XCTAssertEqual(Set(world.resumed), Set(ids))
    }

    func testStoppedAndIdleChatsShareOneJournalBatch() async {
        let world = World()
        let stopped = world.addSession("aus", running: false)
        let idle = world.addSession("ruht", running: true, status: .idle)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        _ = await decideAndRun(world, coordinator, [stopped, idle])

        XCTAssertEqual(Set(world.moved.map(\.sessionID)), [stopped, idle])
        XCTAssertEqual(world.batchIDs.count, 1, "ein „Rückgängig“ nimmt die ganze Aktion zurück")
        XCTAssertEqual(world.resumed, [idle], "ein gestoppter Chat wird nicht ungefragt gestartet")
    }

    func testWorkingChatWaitsForTurnEnd() async {
        let world = World()
        let id = world.addSession("arbeitet", running: true, status: .working)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        _ = await decideAndRun(world, coordinator, [id])
        XCTAssertEqual(coordinator.pending[id]?.reason, .turnRunning)
        XCTAssertTrue(world.terminated.isEmpty)

        await coordinator.recheckPending()
        XCTAssertTrue(world.terminated.isEmpty, "noch working → weiter warten")

        world.status[id] = .awaitingInput
        await coordinator.recheckPending()
        XCTAssertEqual(coordinator.pending[id]?.reason, .awaitingInput)
        XCTAssertTrue(world.terminated.isEmpty, "Rückfrage offen → nie mitten hinein beenden")

        world.status[id] = .idle
        await coordinator.recheckPending()
        XCTAssertEqual(world.terminated, [id])
        XCTAssertEqual(world.moved.map(\.sessionID), [id])
        XCTAssertEqual(world.resumed, [id])
        XCTAssertNil(coordinator.pending[id])
    }

    func testDraftKeepsWaitingUntilSubmitted() async {
        let world = World()
        let id = world.addSession("entwurf", running: true, status: .idle)
        world.drafts.insert(id)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        _ = await decideAndRun(world, coordinator, [id])
        await coordinator.recheckPending()
        XCTAssertEqual(coordinator.pending[id]?.reason, .unsentInput)
        XCTAssertTrue(world.terminated.isEmpty)

        world.drafts.remove(id)
        await coordinator.recheckPending()
        XCTAssertEqual(world.terminated, [id])
    }

    func testCancelDropsPendingSwitch() async {
        let world = World()
        let id = world.addSession("arbeitet", running: true, status: .working)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)
        _ = await decideAndRun(world, coordinator, [id])

        coordinator.cancel(sessionID: id)
        world.status[id] = .idle
        await coordinator.recheckPending()

        XCTAssertTrue(world.terminated.isEmpty)
        XCTAssertTrue(world.moved.isEmpty)
    }

    func testChatStoppedByUserWhilePendingMovesWithoutRestart() async {
        let world = World()
        let id = world.addSession("arbeitet", running: true, status: .working)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)
        _ = await decideAndRun(world, coordinator, [id])

        world.running.remove(id)
        await coordinator.recheckPending()

        XCTAssertEqual(world.moved.map(\.sessionID), [id])
        XCTAssertTrue(world.terminated.isEmpty)
        XCTAssertTrue(world.resumed.isEmpty)
    }

    func testHangingProcessIsNeitherMovedNorRestarted() async {
        let world = World()
        let id = world.addSession("hängt", running: true, status: .idle)
        world.hanging.insert(id)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        let decision = coordinator.decide(plan: world.plan([id]), targetTrustsProject: { _ in true })
        let outcome = await coordinator.execute(decision, targetName: "ai2")

        XCTAssertEqual(world.terminated, [id])
        XCTAssertTrue(world.moved.isEmpty, "Prozess lebt noch — er könnte weiter in die alte Datei schreiben")
        XCTAssertTrue(world.resumed.isEmpty)
        XCTAssertEqual(outcome.failed.map(\.title), ["hängt"])
    }

    func testIdleChatWithBackgroundTasksWaitsUntilTheyFinish() async {
        let world = World()
        let id = world.addSession("bg-task", running: true, status: .idle)
        world.backgroundTasks[id] = 1
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        _ = await decideAndRun(world, coordinator, [id])
        XCTAssertEqual(coordinator.pending[id]?.reason, .backgroundTasks)
        XCTAssertTrue(world.terminated.isEmpty, "Hintergrund-Task stürbe mit dem Prozess")

        world.backgroundTasks[id] = 0
        await coordinator.recheckPending()
        XCTAssertEqual(world.terminated, [id])
    }

    func testDisabledFeatureKeepsOldSkipBehavior() async {
        let world = World()
        world.enabled = false
        let id = world.addSession("ruht", running: true, status: .idle)
        let coordinator = AccountSwitchCoordinator(dependencies: world.dependencies)

        let decision = await decideAndRun(world, coordinator, [id])

        XCTAssertEqual(decision.skipped.map(\.reason), [.running])
        XCTAssertTrue(world.terminated.isEmpty)
    }
}

final class ClaudeAccountPreflightTests: XCTestCase {
    func testTrustIsInheritedFromParentAndMissingFileMeansNo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: [
            "projects": [
                "/Users/x/repos": ["hasTrustDialogAccepted": true],
                "/Users/x/other": ["hasTrustDialogAccepted": false],
            ],
            "mcpServers": ["akquise": [:], "playwright": [:]],
        ]).write(to: json)

        XCTAssertTrue(ClaudeAccountPreflight.trustsProject(cwd: "/Users/x/repos/app", claudeJSON: json))
        XCTAssertFalse(ClaudeAccountPreflight.trustsProject(cwd: "/Users/x/other/app", claudeJSON: json))
        XCTAssertFalse(ClaudeAccountPreflight.trustsProject(
            cwd: "/Users/x/repos/app", claudeJSON: dir.appendingPathComponent("fehlt.json")))
        XCTAssertEqual(ClaudeAccountPreflight.userMCPServers(claudeJSON: json), ["akquise", "playwright"])
    }

    func testMissingMCPServersIncludeLocalScopeOfTheProject() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)")
        let profileDir = home.appendingPathComponent(".claude-profiles/ai2")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["atlassian": [:]],
            "projects": ["/Users/x/repos/app": ["mcpServers": ["rankm8": [:]]],
                         "/Users/x/repos/other": ["mcpServers": ["fremd": [:]]]],
        ]).write(to: home.appendingPathComponent(".claude.json"))
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["atlassian": [:]]])
            .write(to: profileDir.appendingPathComponent(".claude.json"))

        let missing = ClaudeAccountPreflight.missingMCPServers(
            sourceProfiles: [nil], targetProfile: "ai2", cwds: ["/Users/x/repos/app"],
            profiles: ClaudeAccountProfiles(homeDirectory: home))
        XCTAssertEqual(missing, ["rankm8"], "Local-Scope des Projekts zählt, fremde Projekte nicht")
    }
}

/// E2E-Befund 11.10.2026: Turn fertig ≠ Arbeit fertig — Hintergrund-Tasks.
final class ClaudeBackgroundTaskTrackerTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    private func bashStart(_ id: String, at ts: String = "2026-10-11T13:47:10.000Z") -> String {
        line(["type": "user", "timestamp": ts,
              "message": ["role": "user", "content": [["type": "tool_result", "content": "Command running in background with ID: \(id)"]]],
              "toolUseResult": ["stdout": "", "backgroundTaskId": id]])
    }

    private func agentStart(_ id: String) -> String {
        line(["type": "user", "timestamp": "2026-10-11T13:47:11.000Z",
              "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": id]])
    }

    private func notification(_ ids: [String], status: String = "completed", asQueue: Bool = true) -> String {
        let text = "<task-notification>\n" + ids.map { "<task-id>\($0)</task-id>\n" }.joined() + "<status>\(status)</status>\n</task-notification>"
        return asQueue
            ? line(["type": "queue-operation", "operation": "enqueue", "content": text])
            : line(["type": "user", "message": ["role": "user", "content": text]])
    }

    func testStartedMinusFinishedIsOpen() {
        var tracker = ClaudeBackgroundTaskTracker()
        tracker.consume(Data((bashStart("ba1") + agentStart("ag1") + notification(["ba1"], status: "killed")).utf8))
        XCTAssertEqual(tracker.openTaskIDs(), ["ag1"])
        tracker.consume(Data(notification(["ag1"], asQueue: false).utf8))
        XCTAssertEqual(tracker.openTaskIDs(), [])
    }

    func testToolOutputMentioningTaskIDsIsNoNotification() {
        var tracker = ClaudeBackgroundTaskTracker()
        let quoted = line(["type": "user", "message": ["role": "user", "content": [[
            "type": "tool_result", "content": "<task-notification><task-id>ba1</task-id></task-notification>"]]]])
        tracker.consume(Data((bashStart("ba1") + quoted).utf8))
        XCTAssertEqual(tracker.openTaskIDs(), ["ba1"], "zitierte Meldung in einer Tool-Ausgabe beendet nichts")
    }

    func testLineSplitAcrossReadsIsParsedOnce() {
        var tracker = ClaudeBackgroundTaskTracker()
        let data = Data(bashStart("ba1").utf8)
        tracker.consume(data.prefix(40))
        XCTAssertEqual(tracker.openTaskIDs(), [])
        tracker.consume(data.dropFirst(40))
        XCTAssertEqual(tracker.openTaskIDs(), ["ba1"])
    }

    func testTasksOfEarlierProcessAreIgnored() {
        var tracker = ClaudeBackgroundTaskTracker()
        tracker.consume(Data(bashStart("alt", at: "2026-10-11T10:00:00.000Z").utf8))
        let processStart = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!
        XCTAssertEqual(tracker.openTaskIDs(startedAfter: processStart), [])
    }

    func testIncrementalFileReadAndReset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try bashStart("ba1").write(to: url, atomically: false, encoding: .utf8)
        var tracker = ClaudeBackgroundTaskTracker()
        tracker.update(from: url)
        XCTAssertEqual(tracker.openTaskIDs(), ["ba1"])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(notification(["ba1"]).utf8))
        try handle.close()
        tracker.update(from: url)
        XCTAssertEqual(tracker.openTaskIDs(), [])
    }

    func testIdleChatWithBackgroundTasksWaits() {
        XCTAssertEqual(
            AccountSwitchPlanner.waitReason(status: .idle, mayHaveUnsentInput: false, openBackgroundTasks: 1),
            .backgroundTasks)
        XCTAssertNil(AccountSwitchPlanner.waitReason(status: .idle, mayHaveUnsentInput: false, openBackgroundTasks: 0))
    }
}
