import XCTest
@testable import WhisperM8

/// Tests der Verwaltungs-Commands gegen einen Temp-Store (via
/// AgentJobCLIShared.storeFactory-Seam). Der eigentliche Turn-Lauf ist in
/// AgentJobSupervisorTests abgedeckt — hier geht es um Guards + Exit-Codes.
final class AgentCLICommandTests: XCTestCase {
    private var root: URL!
    private var store: AgentJobStore!
    private var previousFactory: (() -> AgentJobStore)!
    private var previousKill: ((Int32, Int32) -> Int32)!

    override func setUpWithError() throws {
        root = try makeTempProjectDirectory()
        store = AgentJobStore(rootDirectory: root, livenessProbe: { _ in true })
        previousFactory = AgentJobCLIShared.storeFactory
        previousKill = AgentStopCLI.killProcess
        let testStore = store!
        AgentJobCLIShared.storeFactory = { testStore }
    }

    override func tearDownWithError() throws {
        AgentJobCLIShared.storeFactory = previousFactory
        AgentStopCLI.killProcess = previousKill
        try? FileManager.default.removeItem(at: root)
    }

    private func makeJob(
        _ shortId: String = "a3f81c2e",
        state: AgentJobState.State,
        threadID: String? = "thread-1",
        pid: Int32? = nil
    ) throws {
        var job = AgentJobState(
            shortId: shortId,
            state: .spawning,
            intent: "test",
            cwd: root.path,
            sandbox: .workspaceWrite
        )
        job.state = state
        job.codexThreadID = threadID
        job.supervisorPid = pid
        try store.createJob(initial: job)
    }

    // MARK: - send: Zustands-Guards

    func testSendOnRunningJobIsRejectedWithConflict() async throws {
        try makeJob(state: .running, pid: 4711)
        let exit = await AgentSendCLI.run(["a3f81c2e", "next"])
        XCTAssertEqual(exit, AgentCLIExit.stateConflict)
        // Kein Prompt hinterlegt.
        XCTAssertNil(store.consumePendingPrompt(shortId: "a3f81c2e"))
    }

    func testSendOnTakenOverJobIsRejected() async throws {
        try makeJob(state: .takenOver)
        let exit = await AgentSendCLI.run(["a3f81c2e", "next"])
        XCTAssertEqual(exit, AgentCLIExit.stateConflict)
    }

    func testSendWithoutThreadIDIsRejected() async throws {
        try makeJob(state: .failed, threadID: nil)
        let exit = await AgentSendCLI.run(["a3f81c2e", "next"])
        XCTAssertEqual(exit, AgentCLIExit.stateConflict)
    }

    func testSendOnUnknownJobIsEnvironmentError() async {
        let exit = await AgentSendCLI.run(["deadbeef", "next"])
        XCTAssertEqual(exit, AgentCLIExit.environment)
    }

    // MARK: - stop

    func testStopSendsSigtermToSupervisorPid() throws {
        try makeJob(state: .running, pid: 4711)
        var killed: [(Int32, Int32)] = []
        AgentStopCLI.killProcess = { pid, sig in
            killed.append((pid, sig))
            // Simulieren: Supervisor reagiert und schreibt stopped.
            _ = try? self.store.transition(shortId: "a3f81c2e", to: .stopped)
            return 0
        }
        let exit = AgentStopCLI.run(["a3f81c2e"])
        XCTAssertEqual(exit, AgentCLIExit.ok)
        XCTAssertEqual(killed.count, 1)
        XCTAssertEqual(killed.first?.0, 4711)
        XCTAssertEqual(killed.first?.1, SIGTERM)
    }

    func testStopOnIdleJobIsConflict() throws {
        try makeJob(state: .done)
        AgentStopCLI.killProcess = { _, _ in XCTFail("darf nicht killen"); return -1 }
        XCTAssertEqual(AgentStopCLI.run(["a3f81c2e"]), AgentCLIExit.stateConflict)
    }

    // MARK: - rm

    func testRemoveActiveJobIsConflict() throws {
        try makeJob(state: .running, pid: 4711)
        XCTAssertEqual(AgentRemoveCLI.run(["a3f81c2e"]), AgentCLIExit.stateConflict)
        XCTAssertNotNil(store.readState(shortId: "a3f81c2e"))
    }

    func testRemoveIdleJobDeletesDirectory() throws {
        try makeJob(state: .done)
        XCTAssertEqual(AgentRemoveCLI.run(["a3f81c2e"]), AgentCLIExit.ok)
        XCTAssertNil(store.readState(shortId: "a3f81c2e"))
    }

    // MARK: - list/status Exit-Semantik

    func testStatusOfFailedJobExitsJobFailed() throws {
        try makeJob(state: .failed)
        XCTAssertEqual(AgentStatusCLI.run(["a3f81c2e", "--json"]), AgentCLIExit.jobFailed)
    }

    func testStatusOfUnknownJobIsEnvironmentError() {
        XCTAssertEqual(AgentStatusCLI.run(["deadbeef"]), AgentCLIExit.environment)
    }

    func testListRunsCleanOnEmptyStore() {
        XCTAssertEqual(AgentListCLI.run([]), AgentCLIExit.ok)
    }

    // MARK: - Parser-Ergänzungen

    func testParseSend() throws {
        let options = try AgentCLIParser.parseSend(["a3f81c2e", "--wait", "--json", "next turn"])
        XCTAssertEqual(options.shortId, "a3f81c2e")
        XCTAssertEqual(options.prompt, "next turn")
        XCTAssertTrue(options.wait)
        XCTAssertTrue(options.json)
    }

    func testParseSendMissingPromptThrows() {
        XCTAssertThrowsError(try AgentCLIParser.parseSend(["a3f81c2e"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .missingPrompt)
        }
    }

    func testParseLogsTail() throws {
        let parsed = try AgentCLIParser.parseLogs(["a3f81c2e", "--tail", "10"])
        XCTAssertEqual(parsed.shortId, "a3f81c2e")
        XCTAssertEqual(parsed.tail, 10)
    }

    func testParseIDCommandRejectsExtra() {
        XCTAssertThrowsError(try AgentCLIParser.parseIDCommand(["a", "b"])) { error in
            XCTAssertEqual(error as? AgentCLIParser.ParseError, .tooManyPositionals)
        }
    }
}
