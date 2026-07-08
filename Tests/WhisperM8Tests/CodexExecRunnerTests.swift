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

        // Overrides müssen ECHTE -c-Werte sein (Paar-Kontrakt), nicht bloß
        // irgendwo im argv stehen: ein loser Wert würde von codex als
        // Positional/Prompt gelesen.
        let configValues = Self.configValues(in: args)
        XCTAssertTrue(configValues.contains("model_reasoning_effort=low"))
        XCTAssertTrue(configValues.contains("tools.web_search=true"))
        // … und zwar NACH den eingebauten Werten (letzter -c gewinnt),
        // damit der Aufrufer z.B. den Effort-Builtin übersteuern kann.
        let builtin = configValues.firstIndex(of: "model_reasoning_effort=high")
        let override = configValues.firstIndex(of: "model_reasoning_effort=low")
        XCTAssertNotNil(builtin)
        XCTAssertNotNil(override)
        XCTAssertLessThan(builtin!, override!)
        // Positional-Kontrakt bleibt: "-" ist das letzte Argument.
        XCTAssertEqual(args.last, "-")
    }

    func testGitWritableRootIsPassedAsConfigPair() {
        var request = makeRequest()
        request.gitWritableRootPath = "/tmp/project/.git"
        let values = Self.configValues(in: CodexExecRunner.buildArguments(for: request))
        XCTAssertTrue(values.contains(#"sandbox_workspace_write.writable_roots=["/tmp/project/.git"]"#))
    }

    /// Werte, die unmittelbar auf ein `-c` folgen — genau das, was codex als
    /// Config-Override akzeptiert. Ein Substring-Match über das ganze argv
    /// würde ein kaputtes Layout (loser Wert ohne `-c`) grün durchlassen.
    private static func configValues(in args: [String]) -> [String] {
        args.enumerated().compactMap { index, element in
            guard element == "-c", args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
    }

    // MARK: - CodexGitWritableRoot (echte Repos — die Fälle, die eine
    // Pfad-Heuristik reihenweise verfehlt hat)

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Repo mit einem Commit (worktree add braucht HEAD).
    private func makeRepo(at dir: URL) throws {
        try git(["-C", dir.path, "init", "-q"])
        try Data("x".utf8).write(to: dir.appendingPathComponent("README.md"))
        try git(["-C", dir.path, "add", "."])
        try git(["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"])
    }

    func testGitWritableRootResolvesPlainRepo() throws {
        let dir = try makeTempProjectDirectory()
        try makeRepo(at: dir)
        let expected = try git(["-C", dir.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        XCTAssertEqual(CodexGitWritableRoot.resolve(repoPath: dir.path), expected)
    }

    /// Regression: cwd im UNTERverzeichnis (z.B. `--cd /repo/Sources`) — der
    /// alte Resolver fand dort kein `.git` und lieferte nil, wodurch Commits
    /// weiterhin an `.git/index.lock` scheiterten.
    func testGitWritableRootResolvesFromSubdirectory() throws {
        let dir = try makeTempProjectDirectory()
        try makeRepo(at: dir)
        let sub = dir.appendingPathComponent("Sources/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let resolved = try XCTUnwrap(CodexGitWritableRoot.resolve(repoPath: sub.path))
        XCTAssertEqual(resolved, try git(["-C", dir.path, "rev-parse", "--path-format=absolute", "--git-common-dir"]))
        XCTAssertTrue(resolved.hasSuffix("/.git"))
    }

    /// Linked Worktree: Commits schreiben ins gemeinsame Haupt-.git.
    func testGitWritableRootResolvesLinkedWorktreeToCommonDir() throws {
        let dir = try makeTempProjectDirectory()
        let main = dir.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try makeRepo(at: main)
        let worktree = dir.appendingPathComponent("wt", isDirectory: true)
        try git(["-C", main.path, "worktree", "add", "-q", worktree.path, "-b", "feature"])

        let resolved = try XCTUnwrap(CodexGitWritableRoot.resolve(repoPath: worktree.path))
        // Das gemeinsame Verzeichnis ist main/.git, NICHT .git/worktrees/wt.
        XCTAssertEqual(
            resolved,
            try git(["-C", main.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        )
        XCTAssertFalse(resolved.contains("worktrees"))
    }

    /// Regression: Worktree eines BARE-Repos — gitdir hat keine `.git`-
    /// Pfadkomponente (`/repos/main.git/worktrees/feature`).
    func testGitWritableRootResolvesWorktreeOfBareRepo() throws {
        let dir = try makeTempProjectDirectory()
        let bare = dir.appendingPathComponent("main.git", isDirectory: true)
        try git(["init", "-q", "--bare", bare.path])
        let clone = dir.appendingPathComponent("work", isDirectory: true)
        try git(["clone", "-q", bare.path, clone.path])
        try Data("x".utf8).write(to: clone.appendingPathComponent("README.md"))
        try git(["-C", clone.path, "add", "."])
        try git(["-C", clone.path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"])
        let worktree = dir.appendingPathComponent("wt", isDirectory: true)
        try git(["-C", clone.path, "worktree", "add", "-q", worktree.path, "-b", "feature"])

        let resolved = try XCTUnwrap(CodexGitWritableRoot.resolve(repoPath: worktree.path))
        XCTAssertEqual(
            resolved,
            try git(["-C", clone.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        )
    }

    func testGitWritableRootNilWithoutGitRepo() throws {
        // Temp-Verzeichnis liegt unter /var/folders — kein Git-Repo darüber.
        let dir = try makeTempProjectDirectory()
        XCTAssertNil(CodexGitWritableRoot.resolve(repoPath: dir.path))
    }

    func testGitWritableRootNilOnGitFailureOrRelativeOutput() {
        let original = CodexGitWritableRoot.gitRunner
        defer { CodexGitWritableRoot.gitRunner = original }

        CodexGitWritableRoot.gitRunner = { _ in .init(exitCode: 128, stdout: "") }
        XCTAssertNil(CodexGitWritableRoot.resolve(repoPath: "/tmp/x"))

        // Relativer Output (fehlendes --path-format) darf nie durchrutschen —
        // ein relativer writable_root wäre in der Sandbox wirkungslos.
        CodexGitWritableRoot.gitRunner = { _ in .init(exitCode: 0, stdout: ".git\n") }
        XCTAssertNil(CodexGitWritableRoot.resolve(repoPath: "/tmp/x"))

        CodexGitWritableRoot.gitRunner = { _ in .init(exitCode: 0, stdout: "  /abs/repo/.git  \n") }
        XCTAssertEqual(CodexGitWritableRoot.resolve(repoPath: "/tmp/x"), "/abs/repo/.git")
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

    /// Regression: der Idle-Watchdog darf einen bereits abgeschlossenen Run
    /// nicht nachträglich als stalled markieren — `mapOutcome` prüft `stalled`
    /// VOR dem Exit-Code, ein erfolgreicher Turn würde sonst als failed enden.
    /// Direkt am Guard getestet: der Timer-Handler feuert im echten Lauf
    /// zeitabhängig, ein Integrationstest wäre flaky.
    func testStalledFlagIsIgnoredAfterRunFinished() {
        let runner = CodexExecRunner()
        runner.markRunFinished()   // group.notify: stdout+stderr+Termination da
        runner.markStalled()       // spät feuernder Watchdog-Handler
        XCTAssertFalse(runner.isStalled, "Fertiger Run darf nicht nachträglich stalled werden")
    }

    func testStalledFlagIsSetWhileRunIsActive() {
        let runner = CodexExecRunner()
        runner.markStalled()       // Watchdog feuert, während der Prozess hängt
        XCTAssertTrue(runner.isStalled)
    }

    /// Ein zügig endender Run mit großzügigem Idle-Timeout ist nie stalled.
    func testFastRunIsNeverStalled() async throws {
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
        request.idleTimeout = 5

        let runner = CodexExecRunner()
        let result = try await runner.run(request: request) { _, _ in }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.stalled)
    }

    func testStderrTailSurvivesSplitMultibyteCharacter() async throws {
        let dir = try makeTempProjectDirectory()
        // stderr > 4096 Bytes, gefüllt mit Mehrbyte-Zeichen → der Tail-Schnitt
        // trifft garantiert mitten in ein 'ä'. Mit String(data:encoding:) wäre
        // der komplette Tail nil → Diagnose weg.
        let fakeCodex = try makeFakeCodex(in: dir, body: """
        for i in $(seq 1 400); do printf 'ääääääääää' >&2; done
        printf 'ENDMARKER' >&2
        exit 1
        """)

        var request = makeRequest()
        request.codexPath = fakeCodex.path
        request.cwd = dir.path
        request.outputLastMessagePath = dir.appendingPathComponent("last.txt").path

        let runner = CodexExecRunner()
        let result = try await runner.run(request: request) { _, _ in }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.stderrTail.isEmpty, "stderr-Tail darf nicht komplett verloren gehen")
        XCTAssertTrue(result.stderrTail.hasSuffix("ENDMARKER"))
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
