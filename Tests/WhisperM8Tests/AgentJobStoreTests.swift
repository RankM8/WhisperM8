import XCTest
@testable import WhisperM8

final class AgentJobStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTempProjectDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(
        alive: @escaping (Int32) -> Bool = { _ in true },
        now: @escaping () -> Date = Date.init
    ) -> AgentJobStore {
        AgentJobStore(rootDirectory: root, livenessProbe: alive, now: now)
    }

    private func makeJob(_ shortId: String = "a3f81c2e", state: AgentJobState.State = .spawning) -> AgentJobState {
        AgentJobState(
            shortId: shortId,
            state: state,
            intent: "test intent",
            cwd: "/tmp/project",
            sandbox: .workspaceWrite
        )
    }

    // MARK: - Layout & Atomarität

    func testCreateJobWritesLayout() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.stateURL(for: "a3f81c2e").path))
        let read = try XCTUnwrap(store.readState(shortId: "a3f81c2e"))
        XCTAssertEqual(read.state, .spawning)
        XCTAssertEqual(read.intent, "test intent")
    }

    func testCreateJobTwiceThrows() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        XCTAssertThrowsError(try store.createJob(initial: makeJob())) { error in
            XCTAssertEqual(error as? AgentJobStore.StoreError, .jobAlreadyExists("a3f81c2e"))
        }
    }

    func testWriteStateLeavesNoTempFiles() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        try store.mutateState(shortId: "a3f81c2e") { $0.turns = 3 }
        let contents = try FileManager.default.contentsOfDirectory(atPath: store.jobDirectory(for: "a3f81c2e").path)
        XCTAssertFalse(contents.contains { $0.contains(".tmp-") }, "rename() muss die Temp-Datei wegräumen: \(contents)")
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.turns, 3)
    }

    func testCorruptStateJSONIsSkippedInReadAll() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob("good0001"))
        let badDir = root.appendingPathComponent("bad00001", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: badDir.appendingPathComponent("state.json"))

        let all = store.readAllCorrected()
        XCTAssertEqual(all.map(\.shortId), ["good0001"])
    }

    // MARK: - Transitions

    func testTransitionGuardRejectsInvalid() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob(state: .spawning))
        XCTAssertThrowsError(try store.transition(shortId: "a3f81c2e", to: .done)) { error in
            XCTAssertEqual(
                error as? AgentJobStore.StoreError,
                .invalidTransition(from: .spawning, to: .done)
            )
        }
        // spawning → running → done ist der legale Weg.
        try store.transition(shortId: "a3f81c2e", to: .running)
        try store.transition(shortId: "a3f81c2e", to: .done)
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.state, .done)
    }

    func testReserveToSpawningFromRestingStatesSucceeds() throws {
        // send reserviert einen ruhenden Job auf spawning, bevor der Supervisor
        // startet — der Guard muss das aus done/failed/stopped erlauben.
        for resting in [AgentJobState.State.done, .failed, .stopped] {
            let store = makeStore()
            let id = "rest\(resting.rawValue.prefix(4))"
            try store.createJob(initial: makeJob(id, state: .running))
            try store.transition(shortId: id, to: resting)
            try store.transition(shortId: id, to: .spawning)
            XCTAssertEqual(store.readState(shortId: id)?.state, .spawning)
        }
    }

    func testReserveToSpawningFromActiveIsRejected() throws {
        // Ein bereits reservierter/laufender Job darf nicht erneut reserviert
        // werden — genau das prallt einen zweiten parallelen send ab.
        let store = makeStore()
        try store.createJob(initial: makeJob(state: .spawning))
        XCTAssertThrowsError(try store.transition(shortId: "a3f81c2e", to: .spawning))
        try store.transition(shortId: "a3f81c2e", to: .running)
        XCTAssertThrowsError(try store.transition(shortId: "a3f81c2e", to: .spawning))
    }

    func testExclusiveLockRunsBodyAndReturnsValue() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        let value = try store.withExclusiveLock(shortId: "a3f81c2e") { 42 }
        XCTAssertEqual(value, 42)
        // Reentrant-frei genutzt: ein zweiter Lock nach Freigabe klappt wieder.
        let again = try store.withExclusiveLock(shortId: "a3f81c2e") { "ok" }
        XCTAssertEqual(again, "ok")
    }

    // MARK: - Orphan-Korrektur

    func testOrphanedRunningJobIsCorrectedToFailed() throws {
        let store = makeStore(alive: { _ in false })
        try store.createJob(initial: makeJob(state: .spawning))
        try store.transition(shortId: "a3f81c2e", to: .running) { $0.supervisorPid = 99999 }

        let corrected = store.readAllCorrected()
        XCTAssertEqual(corrected.first?.state, .failed)
        XCTAssertTrue(corrected.first?.failureReason?.contains("supervisor died") == true)
        // Korrektur ist persistiert, nicht nur im Rückgabewert.
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.state, .failed)
    }

    func testAliveRunningJobStaysRunning() throws {
        let store = makeStore(alive: { _ in true })
        try store.createJob(initial: makeJob(state: .spawning))
        try store.transition(shortId: "a3f81c2e", to: .running) { $0.supervisorPid = 99999 }
        XCTAssertEqual(store.readAllCorrected().first?.state, .running)
    }

    func testDoneJobWithDeadPidStaysDone() throws {
        let store = makeStore(alive: { _ in false })
        try store.createJob(initial: makeJob(state: .spawning))
        try store.transition(shortId: "a3f81c2e", to: .running) { $0.supervisorPid = 99999 }
        // Manuell auf done (Supervisor hat sauber beendet, PID danach tot — normal).
        var job = try XCTUnwrap(store.readState(shortId: "a3f81c2e"))
        job.state = .done
        try store.writeState(job)
        XCTAssertEqual(store.readAllCorrected().first?.state, .done)
    }

    func testStaleSpawningWithoutPidTimesOut() throws {
        let past = Date(timeIntervalSinceNow: -120)
        var currentNow = past
        let store = makeStore(alive: { _ in true }, now: { currentNow })
        try store.createJob(initial: makeJob(state: .spawning))
        // Jetzt springen wir 120s in die Zukunft — spawning ohne PID ist stale.
        currentNow = Date()
        let corrected = store.readAllCorrected()
        XCTAssertEqual(corrected.first?.state, .failed)
        XCTAssertTrue(corrected.first?.failureReason?.contains("spawn timed out") == true)
    }

    func testFreshSpawningWithoutPidIsLeftAlone() throws {
        let store = makeStore(alive: { _ in true })
        try store.createJob(initial: makeJob(state: .spawning))
        XCTAssertEqual(store.readAllCorrected().first?.state, .spawning)
    }

    // MARK: - ShortID, Events, Prompt-Handoff

    func testGenerateShortIDAvoidsCollision() throws {
        let store = makeStore()
        let id = store.generateShortID()
        XCTAssertEqual(id.count, 8)
        try store.createJob(initial: makeJob(id))
        let second = store.generateShortID()
        XCTAssertNotEqual(second, id)
    }

    func testAppendEventAccumulatesLines() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        store.appendEvent(shortId: "a3f81c2e", rawLine: CodexExecFixtures.threadStarted)
        store.appendEvent(shortId: "a3f81c2e", rawLine: CodexExecFixtures.turnStarted)
        let content = try String(contentsOf: store.eventsURL(for: "a3f81c2e"), encoding: .utf8)
        XCTAssertEqual(content.split(separator: "\n").count, 2)
    }

    func testPendingPromptCycle() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        try store.writePendingPrompt(shortId: "a3f81c2e", prompt: "next turn")
        XCTAssertEqual(store.consumePendingPrompt(shortId: "a3f81c2e"), "next turn")
        // Zweiter Consume: weg.
        XCTAssertNil(store.consumePendingPrompt(shortId: "a3f81c2e"))
    }

    func testRemoveJobDeletesDirectory() throws {
        let store = makeStore()
        try store.createJob(initial: makeJob())
        try store.removeJob(shortId: "a3f81c2e")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.jobDirectory(for: "a3f81c2e").path))
        XCTAssertThrowsError(try store.removeJob(shortId: "a3f81c2e"))
    }
}
