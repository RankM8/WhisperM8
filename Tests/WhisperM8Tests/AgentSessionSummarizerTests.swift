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

    // P0.4a: Summary-Hilfsläufe erzeugen keine importierbaren Sessions.
    func testSummaryRunsOptOutOfSessionPersistence() async throws {
        var capturedArgs: [[String]] = []
        let generator = AgentSummaryGenerator(
            executableResolver: { _ in "/usr/bin/true" },
            runner: { _, args, _ in
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
}
