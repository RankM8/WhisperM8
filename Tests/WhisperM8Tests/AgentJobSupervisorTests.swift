import XCTest
@testable import WhisperM8

final class AgentJobSupervisorTests: XCTestCase {
    private var root: URL!
    private var store: AgentJobStore!

    override func setUpWithError() throws {
        root = try makeTempProjectDirectory()
        store = AgentJobStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// Fake-codex: gibt den Fixture-Stream aus und schreibt die
    /// --output-last-message-Datei (Pfad aus argv geparst).
    private func makeFakeCodex(body: String) throws -> String {
        let script = root.appendingPathComponent("fake-codex-\(UUID().uuidString).sh")
        let content = """
        #!/bin/sh
        out=""
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--output-last-message" ]; then out="$a"; fi
          prev="$a"
        done
        \(body)
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script.path
    }

    private func makeJob(_ shortId: String = "a3f81c2e", state: AgentJobState.State = .spawning) throws {
        let job = AgentJobState(
            shortId: shortId,
            state: state,
            intent: "test",
            cwd: root.path,
            sandbox: .workspaceWrite
        )
        try store.createJob(initial: job)
        try store.writePendingPrompt(shortId: shortId, prompt: "do it")
    }

    private func makeSupervisor(fakeCodexPath: String) -> AgentJobSupervisor {
        AgentJobSupervisor(
            store: store,
            commandResolver: { _ in fakeCodexPath },
            diffStatProvider: { _ in AgentJobState.Metrics(diffChangedFiles: 2, diffAdded: 10, diffDeleted: 3) }
        )
    }

    private var successBody: String {
        """
        cat <<'EOF'
        \(CodexExecFixtures.successfulTurnLines.joined(separator: "\n"))
        EOF
        printf '{"status":"success","summary":"ok","filesChanged":["a.swift"],"commits":[],"testsRun":null,"openQuestions":[]}' > "$out"
        exit 0
        """
    }

    // MARK: - Tests

    func testSuccessfulTurnGoesSpawningRunningDone() async throws {
        try makeJob()
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: successBody))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.ok)
        let final = try XCTUnwrap(store.readState(shortId: "a3f81c2e"))
        XCTAssertEqual(final.state, .done)
        XCTAssertEqual(final.turns, 1)
        XCTAssertEqual(final.codexThreadID, "019f2efe-a948-7ad3-8f21-afd79af17271")
        XCTAssertNil(final.supervisorPid)
        XCTAssertEqual(final.metrics?.diffChangedFiles, 2)
        XCTAssertNotNil(final.metrics?.lastTurnSeconds)

        // Events vollständig persistiert.
        let events = try String(contentsOf: store.eventsURL(for: "a3f81c2e"), encoding: .utf8)
        XCTAssertEqual(events.split(separator: "\n").count, CodexExecFixtures.successfulTurnLines.count)
        // Report liegt als last-message.txt.
        XCTAssertTrue(store.readLastMessage(shortId: "a3f81c2e")?.contains("\"status\":\"success\"") == true)
        // Prompt wurde konsumiert.
        XCTAssertNil(store.consumePendingPrompt(shortId: "a3f81c2e"))
    }

    func testFailingTurnEndsFailedWithReason() async throws {
        try makeJob()
        let body = """
        printf '%s\\n' '\(CodexExecFixtures.threadStarted)'
        printf '%s\\n' '\(CodexExecFixtures.turnFailedNested)'
        exit 1
        """
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: body))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.jobFailed)
        let final = try XCTUnwrap(store.readState(shortId: "a3f81c2e"))
        XCTAssertEqual(final.state, .failed)
        XCTAssertTrue(final.failureReason?.contains("turn.failed") == true)
        // threadID trotzdem persistiert — Job bleibt resumierbar.
        XCTAssertEqual(final.codexThreadID, "019f2efe-a948-7ad3-8f21-afd79af17271")
    }

    /// Fallstrick #2 des Plans: die Thread-ID muss VOR Turn-Ende in
    /// state.json stehen. Das Fake-Skript wartet nach thread.started auf
    /// eine Marker-Datei — wir prüfen state.json mitten im Turn.
    func testThreadIDIsPersistedBeforeTurnEnds() async throws {
        try makeJob()
        let marker = root.appendingPathComponent("continue-marker")
        let body = """
        printf '%s\\n' '\(CodexExecFixtures.threadStarted)'
        while [ ! -f "\(marker.path)" ]; do sleep 0.05; done
        printf '%s\\n' '\(CodexExecFixtures.turnCompleted)'
        printf '{"status":"success","summary":"ok","filesChanged":[],"commits":[],"testsRun":null,"openQuestions":[]}' > "$out"
        exit 0
        """
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: body))

        async let exitCode = supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        // Warten bis die ID auftaucht — währenddessen läuft der Turn noch.
        var midTurnState: AgentJobState?
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let state = store.readState(shortId: "a3f81c2e"), state.codexThreadID != nil {
                midTurnState = state
                break
            }
        }
        XCTAssertEqual(midTurnState?.state, .running, "Thread-ID muss ankommen, WÄHREND der Turn läuft")
        XCTAssertEqual(midTurnState?.codexThreadID, "019f2efe-a948-7ad3-8f21-afd79af17271")

        // Turn freigeben und Ende abwarten.
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let exit = await exitCode
        XCTAssertEqual(exit, AgentCLIExit.ok)
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.state, .done)
    }

    func testRequestStopEndsAsStopped() async throws {
        try makeJob()
        let body = """
        printf '%s\\n' '\(CodexExecFixtures.threadStarted)'
        sleep 30
        exit 0
        """
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: body))

        async let exitCode = supervisor.superviseCurrentTurn(shortId: "a3f81c2e")
        // Kurz warten bis der Turn läuft, dann stoppen.
        try await Task.sleep(nanoseconds: 500_000_000)
        supervisor.requestStop()

        let exit = await exitCode
        XCTAssertEqual(exit, AgentCLIExit.ok)
        let final = try XCTUnwrap(store.readState(shortId: "a3f81c2e"))
        XCTAssertEqual(final.state, .stopped)
        XCTAssertNil(final.failureReason)
    }

    func testMissingPendingPromptFails() async throws {
        try makeJob()
        _ = store.consumePendingPrompt(shortId: "a3f81c2e") // weg damit
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: successBody))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.jobFailed)
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.state, .failed)
        XCTAssertTrue(store.readState(shortId: "a3f81c2e")?.failureReason?.contains("pending-prompt") == true)
    }

    func testTakenOverJobRefusesTurn() async throws {
        try makeJob(state: .spawning)
        // spawning → running → takenOver simulieren (Übernahme mitten drin).
        try store.transition(shortId: "a3f81c2e", to: .running)
        try store.transition(shortId: "a3f81c2e", to: .takenOver)
        try store.writePendingPrompt(shortId: "a3f81c2e", prompt: "late prompt")
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: successBody))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.stateConflict)
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.state, .takenOver)
    }

    func testConfigOverridesAndGitRootReachCodexArgv() async throws {
        // Job mit persistierten Overrides in einem ECHTEN Repo — der
        // Supervisor muss Overrides und den .git-Writable-Root in die
        // codex-argv geben (der Root kommt aus `git rev-parse`).
        try makeJob()
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["-C", root.path, "init", "-q"]
        gitInit.standardError = FileHandle.nullDevice
        try gitInit.run()
        gitInit.waitUntilExit()
        let expectedGitRoot = try XCTUnwrap(CodexGitWritableRoot.resolve(repoPath: root.path))

        try store.mutateState(shortId: "a3f81c2e") {
            $0.configOverrides = ["tools.web_search=true"]
        }

        let argvFile = root.appendingPathComponent("seen-argv.txt")
        let body = """
        printf '%s\\n' "$@" > "\(argvFile.path)"
        printf '%s\\n' '\(CodexExecFixtures.turnCompleted)'
        printf '{"status":"success","summary":"ok","filesChanged":[],"commits":[],"testsRun":null,"openQuestions":[]}' > "$out"
        exit 0
        """
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: body))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.ok)
        let argv = try String(contentsOf: argvFile, encoding: .utf8)
        XCTAssertTrue(argv.contains("tools.web_search=true"))
        XCTAssertTrue(argv.contains(
            #"sandbox_workspace_write.writable_roots=["\#(expectedGitRoot)"]"#
        ))
    }

    func testResumeTurnAppliesStoredConfigOverrides() async throws {
        // Folge-Turn (send): die beim run persistierten Overrides müssen auch
        // bei `codex exec resume` ankommen.
        try makeJob()
        try store.mutateState(shortId: "a3f81c2e") {
            $0.codexThreadID = "prev-thread-42"
            $0.configOverrides = ["model_reasoning_effort=low"]
        }
        try store.transition(shortId: "a3f81c2e", to: .running)
        try store.transition(shortId: "a3f81c2e", to: .done)

        let argvFile = root.appendingPathComponent("seen-argv.txt")
        let body = """
        printf '%s\\n' "$@" > "\(argvFile.path)"
        printf '%s\\n' '\(CodexExecFixtures.turnCompleted)'
        printf '{"status":"success","summary":"ok","filesChanged":[],"commits":[],"testsRun":null,"openQuestions":[]}' > "$out"
        exit 0
        """
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: body))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.ok)
        let argv = try String(contentsOf: argvFile, encoding: .utf8)
        XCTAssertTrue(argv.contains("resume"))
        XCTAssertTrue(argv.contains("model_reasoning_effort=low"))
    }

    func testResumeTurnPassesThreadIDToCodex() async throws {
        // Job mit vorhandener Thread-ID (zweiter Turn) — das Fake-Skript
        // schreibt seine argv in eine Datei, damit wir resume prüfen können.
        try makeJob()
        try store.mutateState(shortId: "a3f81c2e") { $0.codexThreadID = "prev-thread-42" }
        try store.transition(shortId: "a3f81c2e", to: .running)
        try store.transition(shortId: "a3f81c2e", to: .done)

        let argvFile = root.appendingPathComponent("seen-argv.txt")
        let body = """
        printf '%s\\n' "$@" > "\(argvFile.path)"
        printf '%s\\n' '\(CodexExecFixtures.turnCompleted)'
        printf '{"status":"success","summary":"ok","filesChanged":[],"commits":[],"testsRun":null,"openQuestions":[]}' > "$out"
        exit 0
        """
        let supervisor = makeSupervisor(fakeCodexPath: try makeFakeCodex(body: body))

        let exit = await supervisor.superviseCurrentTurn(shortId: "a3f81c2e")

        XCTAssertEqual(exit, AgentCLIExit.ok)
        let argv = try String(contentsOf: argvFile, encoding: .utf8)
        XCTAssertTrue(argv.contains("resume"))
        XCTAssertTrue(argv.contains("prev-thread-42"))
        XCTAssertEqual(store.readState(shortId: "a3f81c2e")?.turns, 1)
    }
}
