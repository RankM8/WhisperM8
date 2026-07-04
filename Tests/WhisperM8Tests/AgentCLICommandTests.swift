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

    /// Ein reservierter (spawning) Job prallt einen zweiten parallelen send ab.
    func testSendOnSpawningJobIsRejectedWithConflict() async throws {
        try makeJob(state: .spawning, pid: 4711)
        let exit = await AgentSendCLI.run(["a3f81c2e", "next"])
        XCTAssertEqual(exit, AgentCLIExit.stateConflict)
        XCTAssertNil(store.consumePendingPrompt(shortId: "a3f81c2e"))
    }

    // MARK: - send: Claim (TOCTOU-Schutz, ohne Supervisor-Launch)

    func testSendClaimReservesRestingJobAndStoresPrompt() throws {
        try makeJob(state: .done, threadID: "thread-1")
        let options = try AgentCLIParser.parseSend(["a3f81c2e", "next turn"])
        let result = AgentSendCLI.claim(store: store, options: options)
        guard case .success = result else { return XCTFail("claim sollte erfolgreich sein") }
        // Reserviert: ruhend → spawning, danach sieht ein zweiter send isActive.
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.state, .spawning)
        let prompt = try XCTUnwrap(store.consumePendingPrompt(shortId: "a3f81c2e"))
        XCTAssertTrue(prompt.contains("next turn"))
    }

    func testSendClaimOnActiveJobFailsWithoutReserving() throws {
        try makeJob(state: .running, pid: 4711)
        let options = try AgentCLIParser.parseSend(["a3f81c2e", "next"])
        let result = AgentSendCLI.claim(store: store, options: options)
        guard case .failure(let error) = result else { return XCTFail("Konflikt erwartet") }
        XCTAssertEqual(error.exit, AgentCLIExit.stateConflict)
        XCTAssertNil(store.consumePendingPrompt(shortId: "a3f81c2e"))
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

    /// done + Report-Status `failure` muss Exit 2 liefern — konsistent mit dem
    /// `--wait`-Lauf, der den Job beendet hat (Exit-Code-Vertrag).
    func testStatusOfDoneJobWithFailureReportExitsJobFailed() throws {
        try makeJob(state: .done)
        store.writeLastMessage(shortId: "a3f81c2e", text: """
        {"status": "failure", "summary": "kaputt", "filesChanged": [], "commits": [], "testsRun": null, "openQuestions": []}
        """)
        XCTAssertEqual(AgentStatusCLI.run(["a3f81c2e", "--json"]), AgentCLIExit.jobFailed)
    }

    func testStatusOfDoneJobWithSuccessReportExitsOK() throws {
        try makeJob(state: .done)
        store.writeLastMessage(shortId: "a3f81c2e", text: """
        {"status": "success", "summary": "fertig", "filesChanged": [], "commits": [], "testsRun": null, "openQuestions": []}
        """)
        XCTAssertEqual(AgentStatusCLI.run(["a3f81c2e", "--json"]), AgentCLIExit.ok)
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
