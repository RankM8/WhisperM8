import XCTest
@testable import WhisperM8

final class TranscriptEvidenceExtractorTests: XCTestCase {

    private func timeline(steps: [TranscriptStep]) -> TranscriptTimeline {
        TranscriptTimeline(
            rounds: [TranscriptRound(id: "r1", prompt: nil, steps: steps, answers: [], stats: .init())],
            isLiveSourcePossible: false,
            totalMessageCount: steps.count
        )
    }

    private func bashStep(_ command: String, result: String?, isError: Bool = false) -> TranscriptStep {
        TranscriptStep(id: UUID().uuidString, kind: .tool(TranscriptToolStep(
            name: "Bash", op: .bash, subject: command, detail: nil,
            input: "", result: result, isError: isError
        )), timestamp: nil)
    }

    func testExtractsCommitFromGitOutput() {
        let timeline = timeline(steps: [
            bashStep("git commit -m 'feat: x'", result: "[main 4797eba] feat(agent-cli): Tiefen-Review-Findings\n 8 files changed"),
        ])
        let evidence = TranscriptEvidenceExtractor.extract(from: timeline)
        XCTAssertEqual(evidence.commits, [.init(sha: "4797eba", message: "feat(agent-cli): Tiefen-Review-Findings")])
    }

    func testDeduplicatesCommitsAndCollectsFiles() {
        let write = TranscriptStep(id: "w", kind: .tool(TranscriptToolStep(
            name: "Write", op: .write, subject: "Foo.swift", detail: "Views",
            input: "", result: nil, isError: false
        )), timestamp: nil)
        let timeline = timeline(steps: [
            write, write,
            bashStep("git commit -m x", result: "[main abc1234] eins"),
            bashStep("git commit --amend", result: "[main abc1234] eins"),
        ])
        let evidence = TranscriptEvidenceExtractor.extract(from: timeline)
        XCTAssertEqual(evidence.commits.count, 1)
        XCTAssertEqual(evidence.filesChanged, ["Views/Foo.swift"])
    }

    func testDetectsTestRunsWithPassFail() {
        let timeline = timeline(steps: [
            bashStep("swift test --filter Foo", result: "ok", isError: false),
            bashStep("npm test", result: "fail", isError: true),
            bashStep("ls -la", result: "x", isError: false),
        ])
        let evidence = TranscriptEvidenceExtractor.extract(from: timeline)
        XCTAssertEqual(evidence.tests.map(\.passed), [true, false])
    }
}

extension TranscriptEvidenceExtractorTests {
    /// LR-AK-014: Ohne Ergebnis kein "bestanden".
    func testStartedTestWithoutResultIsNotReportedAsPassed() {
        let evidence = TranscriptEvidenceExtractor.extract(from: timeline2(steps: [
            bashStep2("swift test", result: nil),
        ]))
        XCTAssertTrue(evidence.tests.isEmpty)
    }

    func testQuotedTestCommandIsNotATestRun() {
        let evidence = TranscriptEvidenceExtractor.extract(from: timeline2(steps: [
            bashStep2("echo 'npm test'", result: "npm test"),
        ]))
        XCTAssertTrue(evidence.tests.isEmpty)
    }

    func testChainedAndEnvPrefixedTestCommandsAreRecognized() {
        let evidence = TranscriptEvidenceExtractor.extract(from: timeline2(steps: [
            bashStep2("cd app && CI=1 npm test -- --run", result: "ok"),
        ]))
        XCTAssertEqual(evidence.tests.count, 1)
    }

    private func timeline2(steps: [TranscriptStep]) -> TranscriptTimeline {
        TranscriptTimeline(
            rounds: [TranscriptRound(id: "r1", prompt: nil, steps: steps, answers: [], stats: .init())],
            isLiveSourcePossible: false, totalMessageCount: steps.count)
    }

    private func bashStep2(_ command: String, result: String?) -> TranscriptStep {
        TranscriptStep(id: UUID().uuidString, kind: .tool(TranscriptToolStep(
            name: "Bash", op: .bash, subject: command, detail: nil,
            input: "", result: result, isError: false)), timestamp: nil)
    }
}

final class AgentSummaryGeneratorTests: XCTestCase {

    func testParsesPlainJSONOutput() {
        let output = AgentSummaryGenerator.parseOutput(#"{"headline":"H","details":"D","status":"abgeschlossen"}"#)
        XCTAssertEqual(output, .init(headline: "H", details: "D", status: "abgeschlossen"))
    }

    func testParsesFencedOutputWithPreamble() {
        let raw = "Hier ist das JSON:\n```json\n{\"headline\":\"H\",\"details\":\"D\"}\n```"
        XCTAssertEqual(AgentSummaryGenerator.parseOutput(raw)?.headline, "H")
    }

    func testRejectsEmptyHeadlineAndGarbage() {
        XCTAssertNil(AgentSummaryGenerator.parseOutput(#"{"headline":"  ","details":"D"}"#))
        XCTAssertNil(AgentSummaryGenerator.parseOutput("kein json"))
    }

    /// LR-AK-001: vertauschte/unvollständige Klammern dürfen nie trappen.
    func testParseOutputWithSwappedOrIncompleteBracesReturnsNil() {
        XCTAssertNil(AgentSummaryGenerator.parseOutput("}{"))
        XCTAssertNil(AgentSummaryGenerator.parseOutput("} text {"))
        XCTAssertNil(AgentSummaryGenerator.parseOutput("{ unvollständig"))
        XCTAssertNil(AgentSummaryGenerator.parseOutput("nur zu }"))
    }

    func testExcerptIsBoundedAndContainsRoles() {
        let messages = [
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.text("Frage")]),
            AgentChatMessage(id: UUID(), role: .assistant, timestamp: nil, blocks: [.text(String(repeating: "x", count: 9000))]),
        ]
        let timeline = TranscriptTimelineBuilder.build(from: .init(messages: messages, isLiveSourcePossible: false))
        let excerpt = AgentSummaryGenerator.excerpt(from: timeline)
        XCTAssertTrue(excerpt.count <= 6000)
        XCTAssertTrue(excerpt.contains("AGENT: "))
    }

    /// LR-AK-003: Der Prompt (Chat-Inhalt) darf nie in argv stehen — nur in stdin.
    func testPromptGoesToStdinNotArgv() async throws {
        for provider in [AgentProvider.claude, .codex] {
            var capturedArgs: [String] = []
            var capturedStdin: Data?
            let generator = AgentSummaryGenerator(
                executableResolver: { _ in "/usr/bin/true" },
                runner: { _, args, _, stdin in
                    capturedArgs = args
                    capturedStdin = stdin
                    return #"{"headline":"H","details":"D"}"#
                }
            )
            _ = try await generator.generate(provider: provider, prompt: "AUSZUG sk-SECRET-123 Ende")
            XCTAssertFalse(capturedArgs.contains { $0.contains("SECRET-123") }, "\(provider): Inhalt in argv")
            XCTAssertEqual(capturedStdin.flatMap { String(data: $0, encoding: .utf8) }, "AUSZUG sk-SECRET-123 Ende")
        }
    }

    /// LR-AK-009: Der Hilfslauf bekommt die Umgebung des Chats (Claude-Profil).
    func testGenerateMergesLaunchContextEnvironmentAndArguments() async throws {
        var capturedEnv: [String: String] = [:]
        var capturedArgs: [String] = []
        let generator = AgentSummaryGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, args, env, _ in
                capturedArgs = args
                capturedEnv = env
                return #"{"headline":"H","details":"D"}"#
            }
        )
        _ = try await generator.generate(
            provider: .claude,
            prompt: "p",
            launch: .init(environment: ["CLAUDE_CONFIG_DIR": "/tmp/ai2"], extraArguments: ["--model", "m"])
        )
        XCTAssertEqual(capturedEnv["CLAUDE_CONFIG_DIR"], "/tmp/ai2")
        XCTAssertEqual(Array(capturedArgs.suffix(2)), ["--model", "m"])
    }

    func testLaunchContextForProfileSessionCarriesConfigDir() {
        var builder = AgentCommandBuilder()
        builder.claudeProfileEnvironmentResolver = { name in
            name == "ai2" ? ["CLAUDE_CONFIG_DIR": "/profiles/ai2"] : [:]
        }
        builder.gptBackendEnabledResolver = { false }
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "T")
        session.claudeProfileName = "ai2"
        let context = AgentSummaryGenerator.launchContext(for: session, transcriptURL: nil, builder: builder)
        XCTAssertEqual(context.environment["CLAUDE_CONFIG_DIR"], "/profiles/ai2")
        XCTAssertTrue(context.extraArguments.isEmpty)

        session.claudeProfileName = nil
        XCTAssertTrue(AgentSummaryGenerator.launchContext(for: session, transcriptURL: nil, builder: builder).environment.isEmpty)
    }

    func testLaunchContextForGPTSessionCarriesRouterHeaderAndModel() {
        var builder = AgentCommandBuilder()
        builder.claudeProfileEnvironmentResolver = { _ in [:] }
        builder.gptBackendEnabledResolver = { true }
        builder.gptProfileHeaderResolver = { _ in "acct2" }
        let token = String(repeating: "a", count: 64)
        builder.gptRouterTokenResolver = { token }
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "T")
        session.claudeBackendModel = "gpt-5.6-terra"
        session.gptProfileName = "acct2"
        let context = AgentSummaryGenerator.launchContext(for: session, transcriptURL: nil, builder: builder)
        XCTAssertNotNil(context.environment["ANTHROPIC_BASE_URL"])
        // Konto und Router-Token, sonst 401 am Router (Review W1).
        XCTAssertEqual(context.environment["ANTHROPIC_CUSTOM_HEADERS"],
                       "\(ClaudeGPTMixRouter.profileHeaderName): acct2\n\(ClaudeGPTRouterToken.headerName): \(token)")
        XCTAssertEqual(context.extraArguments.first, "--model")
    }

    func testLaunchContextForCodexIsEmpty() {
        let session = AgentChatSession(provider: .codex, projectID: UUID(), title: "T")
        XCTAssertEqual(AgentSummaryGenerator.launchContext(for: session, transcriptURL: nil), .init())
    }

    func testHeadlessCLIDeliversStandardInput() async throws {
        let out = try await AgentHeadlessCLI().run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            environment: [:],
            standardInput: Data("hallo stdin".utf8)
        )
        XCTAssertEqual(out, "hallo stdin")
    }

    // P0.4a: Summary-Hilfsläufe erzeugen keine importierbaren Sessions.
    func testSummaryRunsOptOutOfSessionPersistence() async throws {
        var capturedArgs: [[String]] = []
        let generator = AgentSummaryGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, args, _, _ in
                capturedArgs.append(args)
                return #"{"headline":"H","details":"D"}"#
            }
        )
        _ = try await generator.generate(provider: .claude, prompt: "p")
        _ = try await generator.generate(provider: .codex, prompt: "p")
        XCTAssertTrue(capturedArgs[0].contains("--no-session-persistence"))
        XCTAssertTrue(capturedArgs[1].contains("--ephemeral"))
    }
}

final class SummaryStartupPlannerTests: XCTestCase {

    private func session(
        id: UUID = UUID(),
        externalID: String? = "ext",
        lastActivity: Date = Date(),
        kind: AgentSessionKind? = nil,
        status: AgentChatStatus = .closed
    ) -> AgentChatSession {
        var session = AgentChatSession(provider: .claude, projectID: UUID(), title: "T")
        session.id = id
        session.externalSessionID = externalID
        session.lastActivityAt = lastActivity
        session.kind = kind
        session.status = status
        return session
    }

    func testPlansOnlyOpenStaleRecentChats() {
        let fresh = session()
        let stale = session()
        let old = session(lastActivity: Date(timeIntervalSinceNow: -30 * 24 * 3600))
        let notOpen = session()
        let ids = SummaryStartupPlanner.plan(
            openTabIDs: [fresh.id, stale.id, old.id],
            sessions: [fresh, stale, old, notOpen],
            now: Date(),
            isStale: { $0.id != fresh.id }
        )
        XCTAssertEqual(ids, [stale.id])
    }

    func testExcludesSpecialKindsArchivedAndUnbound() {
        let subagent = session(kind: .subagentJob)
        let archived = session(status: .archived)
        let unbound = session(externalID: nil)
        let ids = SummaryStartupPlanner.plan(
            openTabIDs: [subagent.id, archived.id, unbound.id],
            sessions: [subagent, archived, unbound],
            now: Date(),
            isStale: { _ in true }
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testCapsAndSortsByRecency() {
        let sessions = (0..<10).map { index in
            session(lastActivity: Date(timeIntervalSinceNow: -Double(index) * 60))
        }
        let ids = SummaryStartupPlanner.plan(
            openTabIDs: sessions.map { $0.id }.shuffled(),
            sessions: sessions,
            now: Date(),
            isStale: { _ in true }
        )
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(ids.first, sessions[0].id)
    }

    // R4-AS-11: doppelte persistierte Session-IDs duerfen den Planer nie
    // trappen (vorher: `Dictionary(uniqueKeysWithValues:)`-Precondition).
    func testDuplicateSessionIDsDoNotTrapAndPlanOnce() {
        let sharedID = UUID()
        let first = session(id: sharedID)
        var duplicate = session(id: sharedID)
        duplicate.title = "Duplikat"

        let ids = SummaryStartupPlanner.plan(
            openTabIDs: [sharedID],
            sessions: [first, duplicate],
            now: Date(),
            isStale: { _ in true }
        )
        XCTAssertEqual(ids, [sharedID], "eine Planung pro ID, kein Crash")
    }
}

/// Analyse 11.10.2026: Fehlschläge wiederholten sich bei jedem Start.
@MainActor
final class SummaryBackoffTests: XCTestCase {
    func testFailurePausesAllAutomaticRunsThenOnlyThatSession() {
        let summarizer = AgentSessionSummarizer()
        var clock = Date()
        summarizer.now = { clock }
        let failed = UUID(), other = UUID()
        XCTAssertTrue(summarizer.automaticRunAllowed(sessionID: failed))

        summarizer.recordAutomaticFailure(sessionID: failed)
        XCTAssertFalse(summarizer.automaticRunAllowed(sessionID: other), "globale Pause (meist das Konto)")

        clock = clock.addingTimeInterval(AgentSessionSummarizer.failureBackoff + 1)
        XCTAssertTrue(summarizer.automaticRunAllowed(sessionID: other))
        XCTAssertFalse(summarizer.automaticRunAllowed(sessionID: failed), "längere Pause je Session")

        clock = clock.addingTimeInterval(AgentSessionSummarizer.sessionFailureBackoff)
        XCTAssertTrue(summarizer.automaticRunAllowed(sessionID: failed))
    }

    func testSuccessClearsThePause() {
        let summarizer = AgentSessionSummarizer()
        let id = UUID()
        summarizer.recordAutomaticFailure(sessionID: id)
        summarizer.recordSuccess(sessionID: id)
        XCTAssertTrue(summarizer.automaticRunAllowed(sessionID: id))
    }

    func testStartupReconciliationIsOffByDefault() throws {
        let suite = "summary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppPreferences(defaults: defaults).isStartupSummaryReconciliationEnabled)
    }
}
