import XCTest
@testable import WhisperM8

final class CodexExecRunnerTests: XCTestCase {
    // MARK: - buildArguments (pure)

    private func makeRequest(resume: String? = nil) -> CodexTurnRequest {
        CodexTurnRequest(
            codexPath: "/fake/codex",
            cwd: "/tmp/project",
            prompt: "do things",
            resumeThreadID: resume,
            outputSchemaPath: "/tmp/schema.json",
            outputLastMessagePath: "/tmp/last.txt"
        )
    }

    func testBuildArgumentsForFirstTurn() {
        let args = CodexExecRunner.buildArguments(for: makeRequest())
        XCTAssertEqual(Array(args.prefix(3)), ["-a", "never", "exec"])
        XCTAssertFalse(args.contains("resume"))
        XCTAssertTrue(args.contains("--json"))
        // Default-Sandbox workspace-write, --cd nur beim ersten Turn.
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")!.advanced(by: 1)], "workspace-write")
        XCTAssertEqual(args[args.firstIndex(of: "--cd")!.advanced(by: 1)], "/tmp/project")
        XCTAssertEqual(args.last, "-")
    }

    func testBuildArgumentsForResumeTurn() {
        let args = CodexExecRunner.buildArguments(for: makeRequest(resume: "thread-123"))
        XCTAssertEqual(Array(args.prefix(4)), ["-a", "never", "exec", "resume"])
        // exec resume kennt --sandbox/--cd nicht — Sandbox via Config-Override.
        XCTAssertFalse(args.contains("--sandbox"))
        XCTAssertFalse(args.contains("--cd"))
        XCTAssertTrue(args.contains(#"sandbox_mode="workspace-write""#))
        // Positional: SESSION_ID direkt vor dem stdin-"-".
        XCTAssertEqual(args.suffix(2), ["thread-123", "-"])
    }

    func testBuildArgumentsWithModelEffortAndNetwork() {
        var request = makeRequest()
        request.model = "gpt-5.2-codex"
        request.effort = "high"
        request.allowNetwork = true
        let args = CodexExecRunner.buildArguments(for: request)
        XCTAssertEqual(args[args.firstIndex(of: "-m")!.advanced(by: 1)], "gpt-5.2-codex")
        XCTAssertTrue(args.contains("model_reasoning_effort=high"))
        XCTAssertTrue(args.contains("sandbox_workspace_write.network_access=true"))
    }

    func testBuildArgumentsWithPlaywrightStorageState() {
        var request = makeRequest()
        request.playwrightStorageStatePath = "/tmp/project/.qa/auth/admin state.json"
        let args = CodexExecRunner.buildArguments(for: request)
        let configValues = args.enumerated()
            .filter { $0.element == "-c" }
            .compactMap { index, _ in args.indices.contains(index + 1) ? args[index + 1] : nil }

        // Self-contained: command + args + Startup-Timeout — darf nicht von
        // einem [mcp_servers.playwright]-Eintrag in der User-Config abhängen.
        XCTAssertTrue(configValues.contains(#"mcp_servers.playwright.command="npx""#))
        XCTAssertTrue(configValues.contains { value in
            value == #"mcp_servers.playwright.args=["-y","@playwright/mcp@"# + CodexExecRunner.playwrightMCPVersion + #"","--browser","chrome","--ignore-https-errors","--isolated","--storage-state","/tmp/project/.qa/auth/admin state.json"]"#
        })
        XCTAssertTrue(configValues.contains("mcp_servers.playwright.startup_timeout_sec=120"))
        XCTAssertTrue(configValues.contains("mcp_servers.playwright.tool_timeout_sec=180"))
        // Headless-Approval für nicht-read-only Browser-Tools (resize, tabs,
        // evaluate, …) — ohne das: "user cancelled MCP tool call".
        XCTAssertTrue(configValues.contains(#"mcp_servers.playwright.default_tools_approval_mode="approve""#))
    }

    func testBuildArgumentsWithoutPlaywrightStorageStateHasNoMCPOverride() {
        let args = CodexExecRunner.buildArguments(for: makeRequest())
        XCTAssertFalse(args.contains { $0.hasPrefix("mcp_servers.playwright") })
    }

    func testBuildArgumentsAddsGitWritableRootForWorkspaceWrite() {
        var request = makeRequest()
        request.gitWritableRootPath = "/tmp/project/.git"
        let args = CodexExecRunner.buildArguments(for: request)
        XCTAssertTrue(args.contains(#"sandbox_workspace_write.writable_roots=["/tmp/project/.git"]"#))
    }

    func testBuildArgumentsAddsGitWritableRootOnResume() {
        var request = makeRequest(resume: "thread-123")
        request.gitWritableRootPath = "/tmp/project/.git"
        let args = CodexExecRunner.buildArguments(for: request)
        // Auch Folge-Turns müssen committen können (Sandbox dort via -c).
        XCTAssertTrue(args.contains(#"sandbox_workspace_write.writable_roots=["/tmp/project/.git"]"#))
    }

    func testBuildArgumentsOmitsGitWritableRootForReadOnly() {
        var request = makeRequest()
        request.sandbox = .readOnly
        request.gitWritableRootPath = "/tmp/project/.git"
        let args = CodexExecRunner.buildArguments(for: request)
        XCTAssertFalse(args.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots") })
    }

    func testBuildArgumentsOmitsGitWritableRootWithoutRepo() {
        let args = CodexExecRunner.buildArguments(for: makeRequest())
        XCTAssertFalse(args.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots") })
    }

    func testBuildArgumentsAppendsConfigOverridesAfterBuiltins() {
        var request = makeRequest()
        request.effort = "high"
        request.configOverrides = ["model_reasoning_effort=low", #"tools.web_search=true"#]
        let args = CodexExecRunner.buildArguments(for: request)

        // Beide Overrides landen als -c-Werte …
        XCTAssertTrue(args.contains("model_reasoning_effort=low"))
        XCTAssertTrue(args.contains("tools.web_search=true"))
        // … und zwar NACH den eingebauten Werten (letzter -c gewinnt),
        // damit der Aufrufer z.B. den Effort-Builtin übersteuern kann.
        let builtin = args.firstIndex(of: "model_reasoning_effort=high")
        let override = args.firstIndex(of: "model_reasoning_effort=low")
        XCTAssertNotNil(builtin)
        XCTAssertNotNil(override)
        XCTAssertLessThan(builtin!, override!)
        // Positional-Kontrakt bleibt: "-" ist das letzte Argument.
        XCTAssertEqual(args.last, "-")
    }

    // MARK: - CodexGitWritableRoot

    func testGitWritableRootResolvesPlainRepo() throws {
        let dir = try makeTempProjectDirectory()
        let gitDir = dir.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        XCTAssertEqual(CodexGitWritableRoot.resolve(repoPath: dir.path), gitDir.path)
    }

    func testGitWritableRootResolvesLinkedWorktreeToMainGit() throws {
        // Haupt-Repo mit .git/worktrees/<n> + Worktree-Checkout, dessen
        // .git-DATEI dorthin zeigt — Commits brauchen das Haupt-.git.
        let dir = try makeTempProjectDirectory()
        let mainGit = dir.appendingPathComponent("main/.git/worktrees/feature", isDirectory: true)
        try FileManager.default.createDirectory(at: mainGit, withIntermediateDirectories: true)
        let checkout = dir.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try "gitdir: \(mainGit.path)\n".write(
            to: checkout.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            CodexGitWritableRoot.resolve(repoPath: checkout.path),
            dir.appendingPathComponent("main/.git").path
        )
    }

    func testGitWritableRootNilWithoutGitRepo() throws {
        let dir = try makeTempProjectDirectory()
        XCTAssertNil(CodexGitWritableRoot.resolve(repoPath: dir.path))
    }

    // MARK: - Integration mit Fake-codex-Skript

    /// Baut ein ausführbares Shellskript, das den Fixture-Stream ausgibt und
    /// die --output-last-message-Datei schreibt (Argument-Parsing im Skript,
    /// weil der Runner den Pfad via argv übergibt).
    private func makeFakeCodex(
        in directory: URL,
        body: String
    ) throws -> URL {
        let script = directory.appendingPathComponent("fake-codex.sh")
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
        return script
    }

    private func writeFixtureStream(in directory: URL) throws -> URL {
        let fixture = directory.appendingPathComponent("fixture.jsonl")
        try CodexExecFixtures.successfulTurnLines.joined(separator: "\n")
            .appending("\n")
            .write(to: fixture, atomically: true, encoding: .utf8)
        return fixture
    }

    func testSuccessfulRunStreamsEventsAndReadsLastMessage() async throws {
        let dir = try makeTempProjectDirectory()
        let fixture = try writeFixtureStream(in: dir)
        let fakeCodex = try makeFakeCodex(in: dir, body: """
        cat "\(fixture.path)"
        printf '{"status":"success","summary":"ok","filesChanged":[],"commits":[],"testsRun":null,"openQuestions":[]}' > "$out"
        exit 0
        """)

        var request = makeRequest()
        request.codexPath = fakeCodex.path
        request.cwd = dir.path
        request.outputLastMessagePath = dir.appendingPathComponent("last.txt").path

        let collector = EventCollector()
        let runner = CodexExecRunner()
        let result = try await runner.run(request: request) { event, _ in
            collector.append(event)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.threadID, "019f2efe-a948-7ad3-8f21-afd79af17271")
        XCTAssertFalse(result.stalled)
        XCTAssertNil(result.turnFailedMessage)
        XCTAssertTrue(result.lastMessage?.contains("\"status\":\"success\"") == true)

        let events = collector.snapshot()
        XCTAssertEqual(events.count, CodexExecFixtures.successfulTurnLines.count)
        XCTAssertEqual(events.first, .threadStarted(threadID: "019f2efe-a948-7ad3-8f21-afd79af17271"))
        guard case .turnCompleted = events.last else {
            return XCTFail("Letztes Event muss turnCompleted sein")
        }
    }

    func testFailingRunCapturesTurnFailedAndExitCode() async throws {
        let dir = try makeTempProjectDirectory()
        let fakeCodex = try makeFakeCodex(in: dir, body: """
        printf '%s\\n' '\(CodexExecFixtures.threadStarted)'
        printf '%s\\n' '\(CodexExecFixtures.turnFailedNested)'
        echo "boom" >&2
        exit 1
        """)

        var request = makeRequest()
        request.codexPath = fakeCodex.path
        request.cwd = dir.path
        request.outputLastMessagePath = dir.appendingPathComponent("last.txt").path

        let runner = CodexExecRunner()
        let result = try await runner.run(request: request) { _, _ in }

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.turnFailedMessage, "stream disconnected")
        XCTAssertNil(result.lastMessage)
        XCTAssertTrue(result.stderrTail.contains("boom"))
    }

    func testIdleWatchdogTerminatesStalledProcess() async throws {
        let dir = try makeTempProjectDirectory()
        let fakeCodex = try makeFakeCodex(in: dir, body: """
        printf '%s\\n' '\(CodexExecFixtures.threadStarted)'
        sleep 30
        exit 0
        """)

        var request = makeRequest()
        request.codexPath = fakeCodex.path
        request.cwd = dir.path
        request.outputLastMessagePath = dir.appendingPathComponent("last.txt").path
        request.idleTimeout = 0.5

        let runner = CodexExecRunner()
        let started = Date()
        let result = try await runner.run(request: request) { _, _ in }

        XCTAssertTrue(result.stalled)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(result.threadID, "019f2efe-a948-7ad3-8f21-afd79af17271")
        // Watchdog muss deutlich vor den 30s Skript-Sleep zuschlagen.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testMissingBinaryThrowsLaunchFailed() async {
        var request = makeRequest()
        request.codexPath = "/nonexistent/codex"
        let runner = CodexExecRunner()
        do {
            _ = try await runner.run(request: request) { _, _ in }
            XCTFail("Erwartet launchFailed")
        } catch {
            XCTAssertTrue(error is CodexExecRunner.RunnerError)
        }
    }
}

/// Thread-sicherer Event-Sammler — onEvent feuert auf einer Hintergrund-Queue.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CodexExecEvent] = []

    func append(_ event: CodexExecEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [CodexExecEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
