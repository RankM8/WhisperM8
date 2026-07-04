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
        XCTAssertEqual(args.first, "exec")
        XCTAssertFalse(args.contains("resume"))
        XCTAssertTrue(args.contains("--json"))
        // Default-Sandbox workspace-write, --cd nur beim ersten Turn.
        XCTAssertEqual(args[args.firstIndex(of: "--sandbox")!.advanced(by: 1)], "workspace-write")
        XCTAssertEqual(args[args.firstIndex(of: "--cd")!.advanced(by: 1)], "/tmp/project")
        XCTAssertEqual(args.last, "-")
    }

    func testBuildArgumentsForResumeTurn() {
        let args = CodexExecRunner.buildArguments(for: makeRequest(resume: "thread-123"))
        XCTAssertEqual(Array(args.prefix(2)), ["exec", "resume"])
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
