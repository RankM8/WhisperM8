import Foundation
import XCTest
@testable import WhisperM8

final class AgentAutoNamingRegressionTests: XCTestCase {
    private func builder(enabled: Bool = true, fast: Bool = false) -> AgentCommandBuilder {
        var builder = AgentCommandBuilder()
        builder.claudeProfileEnvironmentResolver = { name in
            name.map { ["CLAUDE_CONFIG_DIR": "/profiles/\($0)"] } ?? [:]
        }
        builder.gptBackendEnabledResolver = { enabled }
        builder.gptFastModeEnabledResolver = { fast }
        builder.gptRouterPortResolver = { 18766 }
        builder.gptDefaultModelResolver = { "gpt-5.6-sol" }
        builder.gptPickerModelResolver = { "" }
        builder.gptSubagentModelResolver = { "gpt-5.6-sol" }
        builder.gptContextWindowResolver = { 272_000 }
        return builder
    }

    func testProfileAndGPTRoutingAreAppliedAfterEnvironmentCleanup() async throws {
        var capturedArgs: [String] = []
        var capturedEnvironment: [String: String] = [:]
        var generator = AgentTitleGenerator(
            executableResolver: { _ in "/unused" },
            runner: { _, args, env in
                capturedArgs = args
                capturedEnvironment = env
                return "Chat Benennung: Automatik reparieren"
            }
        )
        generator.commandBuilder = builder(fast: true)
        let login = LoginShellEnvironment(pathLoader: { "/usr/bin:/bin" })
        generator.environmentProvider = {
            login.processEnvironment(base: [
                "CLAUDE_CONFIG_DIR": "/profiles/WRONG",
                "CLAUDECODE": "1",
                "CLAUDE_CODE_SESSION_ID": "parent",
                "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "999",
                "ANTHROPIC_BASE_URL": "http://wrong.invalid",
            ])
        }
        let session = AgentChatSession(
            provider: .claude, projectID: UUID(), title: "Claude Chat",
            claudeProfileName: "PowerUser", claudeBackendModel: "gpt-5.6-sol"
        )
        _ = try await generator.generate(session: session, excerpt: "User: Benennung reparieren")
        XCTAssertEqual(capturedEnvironment["CLAUDE_CONFIG_DIR"], "/profiles/PowerUser")
        XCTAssertNil(capturedEnvironment["CLAUDECODE"])
        XCTAssertNil(capturedEnvironment["CLAUDE_CODE_SESSION_ID"])
        XCTAssertEqual(capturedEnvironment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:18766")
        XCTAssertEqual(capturedEnvironment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "272000")
        XCTAssertEqual(capturedEnvironment["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], "1000000")
        XCTAssertEqual(capturedArgs.suffix(2), ["--model", "gpt-5.6-sol-fast"])
        XCTAssertTrue(capturedArgs.contains("--no-session-persistence"))
        XCTAssertFalse(capturedArgs.contains("--resume"))
    }

    func testNativeProfilesDoNotInheritForeignAccountAndCodexUsesExplicitModel() async throws {
        var args: [String] = []
        var environment: [String: String] = [:]
        var generator = AgentTitleGenerator(executableResolver: { _ in "/unused" }, runner: { _, a, e in
            args = a
            environment = e
            return "Chat Benennung"
        })
        generator.commandBuilder = builder(enabled: false)
        let login = LoginShellEnvironment(pathLoader: { "/usr/bin:/bin" })
        generator.environmentProvider = { login.processEnvironment(base: ["CLAUDE_CONFIG_DIR": "/wrong"]) }
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Claude Chat")
        _ = try await generator.generate(session: session, excerpt: "excerpt")
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertFalse(args.contains("--model"), "Native Modellwahl bleibt beim korrekten Profil")
        session.claudeProfileName = "Work"
        _ = try await generator.generate(session: session, excerpt: "excerpt")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/profiles/Work")
        session.provider = .codex
        session.model = "gpt-5.6-sol"
        _ = try await generator.generate(session: session, excerpt: "excerpt")
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(args.suffix(3).first, "--model")
        XCTAssertEqual(args.suffix(2).first, "gpt-5.6-sol")
        XCTAssertTrue(args.contains("--ephemeral"))
    }

    func testDisabledOrUnknownGPTModelNeverFallsBackToNativeCall() async throws {
        for (enabled, model) in [(false, "gpt-5.6-sol"), (true, "gpt-invalid-model")] {
            var generator = AgentTitleGenerator(executableResolver: { _ in "/unused" }, runner: { _, _, _ in
                XCTFail("Kein Request an das falsche Backend")
                return "Chat Benennung"
            })
            generator.commandBuilder = builder(enabled: enabled)
            generator.environmentProvider = { [:] }
            let session = AgentChatSession(provider: .claude, projectID: UUID(), title: "Claude Chat", claudeBackendModel: model)
            do {
                _ = try await generator.generate(session: session, excerpt: "excerpt")
                XCTFail("Expected unavailable model")
            } catch AgentTitleGeneratorError.unavailableBackendModel { }
        }
    }

    func testNonZeroExitRetainsBoundedStdoutAndStderrWithoutLoggingContents() async throws {
        do {
            _ = try await AgentHeadlessCLI(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'authentication_error secret-token\\n'; yes x | head -c 9000; printf 'stderr secret-token' >&2; exit 1"],
                environment: ["PATH": "/usr/bin:/bin"]
            )
            XCTFail("Expected failure")
        } catch let error as AgentHeadlessCLIError {
            guard case .nonZeroExit(let code, let stderr, let stdout) = error else {
                return XCTFail("Wrong error")
            }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(stdout.contains("authentication_error"))
            XCTAssertEqual(stdout.utf8.count, AgentHeadlessCLIError.diagnosticByteLimit)
            XCTAssertTrue(stderr.contains("stderr"))
            XCTAssertFalse(error.localizedDescription.contains("secret-token"))
        }
    }

    func testTitleRunnerRetainsStdoutOnlyFailureAndSafeDescription() async throws {
        do {
            _ = try await AgentTitleGenerator.defaultRunner(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'authentication_error secret-token'; exit 1"], environment: [:]
            )
            XCTFail("Expected failure")
        } catch let error as AgentTitleGeneratorError {
            guard case .nonZeroExit(let code, let stderr, let stdout) = error else {
                return XCTFail("Wrong error")
            }
            XCTAssertEqual(code, 1)
            XCTAssertEqual(stderr, "")
            XCTAssertEqual(stdout, "authentication_error secret-token")
            XCTAssertFalse(error.localizedDescription.contains("secret-token"))
        }
    }

    func testPromptRequiresTwoTopicWordsAndShortTask() {
        let prompt = AgentTitleGenerator.titlePrompt(for: "EXCERPT")
        XCTAssertTrue(prompt.contains("exactly two clearly understandable topic words"))
        XCTAssertTrue(prompt.contains("never more than 5"))
        XCTAssertTrue(prompt.contains("Apify Review: Fehler prüfen und beheben"))
        XCTAssertTrue(prompt.contains("Chat Benennung: Automatik reparieren"))
        XCTAssertTrue(prompt.hasSuffix("EXCERPT"))
        XCTAssertEqual(AgentTitleGenerator.cleanTitle("Apify Review: Fehler prüfen und beheben"),
                       "Apify Review: Fehler prüfen und beheben")
        XCTAssertNil(AgentTitleGenerator.retryArgumentsAfterUnknownOption(
            arguments: ["--ephemeral"], stderr: "authentication failed while using --ephemeral"
        ))
    }

    @MainActor
    func testAutomaticFailuresBackOffAndManualRetryBypassesDelay() async throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        var session = try store.createSession(provider: .claude, projectPath: NSTemporaryDirectory(), title: "Claude Chat")
        session.externalSessionID = UUID().uuidString
        session.lastTurnAt = Date()
        session.claudeProfileName = "Work"
        session.claudeBackendModel = "gpt-5.6-sol"
        _ = try store.upsertSession(session)
        var clock = Date(timeIntervalSince1970: 1000)
        var calls = 0
        var generator = AgentTitleGenerator(executableResolver: { _ in "/unused" }, runner: { _, args, env in
            calls += 1
            XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/profiles/Work")
            XCTAssertEqual(args.suffix(2), ["--model", "gpt-5.6-sol"])
            throw AgentTitleGeneratorError.nonZeroExit(1)
        })
        generator.commandBuilder = builder()
        generator.environmentProvider = { [:] }
        let namer = AgentSessionAutoNamer(store: store, titleGenerator: generator, now: { clock },
                                         isEnabled: { true }, excerptLoader: { _, _ in "excerpt" })
        func attempt(force: Bool = false) async {
            await withCheckedContinuation { continuation in
                let done: (Result<String, Error>) -> Void = { result in
                    if case .success = result { XCTFail("Expected failure") }
                    continuation.resume()
                }
                if force { namer.forceGenerateTitle(session: session, cwd: "/unused", onCompletion: done) }
                else { namer.generateTitleIfNeeded(session: session, cwd: "/unused", onCompletion: done) }
            }
        }
        await attempt()
        for _ in 0..<9 { namer.generateTitleIfNeeded(session: session, cwd: "/unused") }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(namer.inFlight.isEmpty)
        clock = clock.addingTimeInterval(60)
        await attempt()
        XCTAssertEqual(calls, 2)
        clock = clock.addingTimeInterval(119)
        namer.generateTitleIfNeeded(session: session, cwd: "/unused")
        XCTAssertTrue(namer.inFlight.isEmpty, "Zweiter Fehler verdoppelt die Wartezeit")
        await attempt(force: true)
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testMissingTranscriptIsDistinctAndRetryDoesNotInvokeModelUntilReady() async throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        var session = try store.createSession(provider: .claude, projectPath: NSTemporaryDirectory(), title: "Claude Chat")
        // Kein Lookup in echten Account-Roots für den Missing-Transcript-Test.
        do {
            _ = try await AgentSessionAutoNamer.loadExcerpt(session: session, cwd: "/unused")
            XCTFail("Expected missing transcript")
        } catch AgentTitleGeneratorError.missingTranscript { }
        session.externalSessionID = UUID().uuidString
        _ = try store.upsertSession(session)
        var ready = false
        var calls = 0
        var clock = Date(timeIntervalSince1970: 1000)
        let generator = AgentTitleGenerator(executableResolver: { _ in "/unused" }, runner: { _, _, _ in
            calls += 1
            return "Chat Benennung"
        })
        let namer = AgentSessionAutoNamer(store: store, titleGenerator: generator, now: { clock },
                                         isEnabled: { true }, excerptLoader: { _, _ in
            if !ready { throw AgentTitleGeneratorError.missingTranscript }
            return "excerpt"
        })
        await withCheckedContinuation { continuation in
            namer.generateTitleIfNeeded(session: session, cwd: "/unused") { result in
                guard case .failure(AgentTitleGeneratorError.missingTranscript) = result else {
                    XCTFail("Missing darf nicht emptyOutput sein")
                    continuation.resume()
                    return
                }
                continuation.resume()
            }
        }
        XCTAssertEqual(calls, 0)
        ready = true
        namer.generateTitleIfNeeded(session: session, cwd: "/unused")
        XCTAssertTrue(namer.inFlight.isEmpty)
        clock = clock.addingTimeInterval(15)
        await withCheckedContinuation { continuation in
            namer.generateTitleIfNeeded(session: session, cwd: "/unused") { result in
                if case .failure = result { XCTFail("Expected title") }
                continuation.resume()
            }
        }
        XCTAssertEqual(calls, 1)
        namer.generateTitleIfNeeded(session: session, cwd: "/unused")
        XCTAssertTrue(namer.inFlight.isEmpty, "Erfolgreiche automatische Benennung nicht wiederholen")
    }

    @MainActor
    func testQueueLimitsParallelismDeduplicatesAndDrainsAfterFailure() async throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentSessionStore(fileURL: url)
        var sessions: [AgentChatSession] = []
        for _ in 0..<4 {
            var session = try store.createSession(provider: .claude, projectPath: NSTemporaryDirectory(), title: "Claude Chat")
            session.externalSessionID = UUID().uuidString
            _ = try store.upsertSession(session)
            sessions.append(session)
        }
        let firstTwo = expectation(description: "first two start")
        firstTwo.expectedFulfillmentCount = 2
        let third = expectation(description: "third starts after failure")
        let fourth = expectation(description: "fourth starts after success")
        let gate = NamingRunnerGate { index in
            switch index {
            case 1, 2: firstTwo.fulfill()
            case 3: third.fulfill()
            case 4: fourth.fulfill()
            default: XCTFail("Unexpected duplicate")
            }
        }
        let generator = AgentTitleGenerator(executableResolver: { _ in "/unused" }, runner: { _, _, _ in
            try await gate.run()
        })
        let namer = AgentSessionAutoNamer(store: store, titleGenerator: generator, isEnabled: { true },
                                         excerptLoader: { _, _ in "excerpt" })
        let completed = expectation(description: "all complete")
        completed.expectedFulfillmentCount = 4
        for session in sessions {
            namer.generateTitleIfNeeded(session: session, cwd: "/unused") { _ in completed.fulfill() }
            namer.forceGenerateTitle(session: session, cwd: "/unused") { _ in XCTFail("Duplicate callback") }
        }
        await fulfillment(of: [firstTwo], timeout: 3)
        XCTAssertEqual(namer.inFlight.count, 4)
        namer.resetAttemptTracking()
        namer.forceGenerateTitle(session: sessions[0], cwd: "/unused") { _ in XCTFail("Reset permitted duplicate") }
        await gate.finishOne(fail: true)
        await fulfillment(of: [third], timeout: 3)
        await gate.finishOne()
        await fulfillment(of: [fourth], timeout: 3)
        await gate.finishOne()
        await gate.finishOne()
        await fulfillment(of: [completed], timeout: 3)
        let peak = await gate.peak
        XCTAssertEqual(peak, 2)
        XCTAssertTrue(namer.inFlight.isEmpty)
    }
}

private actor NamingRunnerGate {
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var started = 0
    private(set) var peak = 0
    private let onStart: (Int) -> Void

    init(onStart: @escaping (Int) -> Void) { self.onStart = onStart }

    func run() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            peak = max(peak, waiters.count)
            started += 1
            onStart(started)
        }
    }

    func finishOne(fail: Bool = false) {
        guard !waiters.isEmpty else { return }
        let continuation = waiters.removeFirst()
        if fail { continuation.resume(throwing: AgentTitleGeneratorError.nonZeroExit(1)) }
        else { continuation.resume(returning: "Chat Benennung") }
    }
}
