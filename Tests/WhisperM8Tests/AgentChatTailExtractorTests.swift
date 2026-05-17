import Foundation
import XCTest
@testable import WhisperM8

final class AgentChatTailExtractorTests: XCTestCase {

    // MARK: - plainText

    func testPlainTextJoinsTextBlocksAndIgnoresToolUse() {
        let message = AgentChatMessage(
            id: UUID(),
            role: .user,
            timestamp: nil,
            blocks: [
                .text("Hello"),
                .toolUse(name: "Read", input: "{}"),
                .text("world")
            ]
        )
        XCTAssertEqual(AgentChatTailExtractor.plainText(from: message), "Hello world")
    }

    func testPlainTextReturnsNilWhenOnlyToolBlocks() {
        let message = AgentChatMessage(
            id: UUID(),
            role: .assistant,
            timestamp: nil,
            blocks: [.toolUse(name: "Read", input: "{}"), .thinking("...")]
        )
        XCTAssertNil(AgentChatTailExtractor.plainText(from: message))
    }

    func testPlainTextTrimsWhitespace() {
        let message = AgentChatMessage(
            id: UUID(),
            role: .user,
            timestamp: nil,
            blocks: [.text("  spaced  "), .text("\n\nokay")]
        )
        XCTAssertEqual(AgentChatTailExtractor.plainText(from: message), "spaced okay")
    }

    // MARK: - summarize

    func testSummarizeIncludesLastUserAndLastAssistant() {
        let messages: [AgentChatMessage] = [
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.text("old user")]),
            AgentChatMessage(id: UUID(), role: .assistant, timestamp: nil, blocks: [.text("old answer")]),
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.text("latest question")]),
            AgentChatMessage(id: UUID(), role: .assistant, timestamp: nil, blocks: [.text("latest answer")])
        ]
        let summary = AgentChatTailExtractor.summarize(messages: messages, maxCharacters: 500)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("[user] latest question"))
        XCTAssertTrue(summary!.contains("[assistant] latest answer"))
        XCTAssertFalse(summary!.contains("old user"))
        XCTAssertFalse(summary!.contains("old answer"))
    }

    func testSummarizeReturnsNilWhenNoTextContent() {
        let messages: [AgentChatMessage] = [
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.toolUse(name: "Read", input: "{}")])
        ]
        XCTAssertNil(AgentChatTailExtractor.summarize(messages: messages))
    }

    func testSummarizeWorksWithOnlyUserMessage() {
        let messages: [AgentChatMessage] = [
            AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.text("just a question")])
        ]
        let summary = AgentChatTailExtractor.summarize(messages: messages)
        XCTAssertEqual(summary, "[user] just a question")
    }

    // MARK: - truncate

    func testTruncateLeavesShortStringsAsIs() {
        XCTAssertEqual(AgentChatTailExtractor.truncate("hello", maxCharacters: 100), "hello")
    }

    func testTruncateAddsEllipsisOnOverflow() {
        let raw = String(repeating: "a", count: 100)
        let truncated = AgentChatTailExtractor.truncate(raw, maxCharacters: 10)
        XCTAssertEqual(truncated.count, 10)
        XCTAssertTrue(truncated.hasSuffix("…"))
    }

    // MARK: - extract from ref (smoke)

    func testExtractReturnsNilWhenExternalSessionIDMissing() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "repo",
            projectPath: "/tmp/repo",
            title: "Test",
            externalSessionID: nil
        )
        XCTAssertNil(AgentChatTailExtractor.extract(for: ref))
    }

    func testExtractReturnsNilWhenExternalSessionIDEmpty() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "repo",
            projectPath: "/tmp/repo",
            title: "Test",
            externalSessionID: ""
        )
        XCTAssertNil(AgentChatTailExtractor.extract(for: ref))
    }

    func testExtractReturnsNilForAgentViewWhenNoActiveSupervisorJob() {
        // Agent View ohne laufende Background-Jobs → Fallback findet
        // nichts, gibt nil. Wir zeigen auf ein leeres Temp-Directory.
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "repo",
            projectPath: "/tmp/repo",
            title: "Agents",
            externalSessionID: nil,
            kind: .agentView
        )
        XCTAssertNil(
            AgentChatTailExtractor.extractFromAgentView(
                ref: ref,
                maxCharacters: 600,
                jobsDirectory: emptyDir
            )
        )
    }

    func testExtractReturnsNilForAgentViewWhenAllJobsStale() {
        // Agent View mit Jobs, aber alle aelter als Recency-Window →
        // nichts liefern. Test schreibt ein state.json mit altem updatedAt
        // und ohne linkScanPath (greift erst in mostRecentlyActive nach
        // recencyWindow). Recency-Filter muss greifen.
        let jobsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-stale-\(UUID().uuidString)", isDirectory: true)
        let jobDir = jobsDir.appendingPathComponent("ab12cd34", isDirectory: true)
        try? FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: jobsDir) }
        let stateJSON = """
        {"daemonShort":"ab12cd34","cwd":"/tmp","updatedAt":"2020-01-01T00:00:00Z"}
        """
        try? stateJSON.write(
            to: jobDir.appendingPathComponent("state.json"),
            atomically: true,
            encoding: .utf8
        )

        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "repo",
            projectPath: "/tmp/repo",
            title: "Agents",
            externalSessionID: nil,
            kind: .agentView
        )
        XCTAssertNil(
            AgentChatTailExtractor.extractFromAgentView(
                ref: ref,
                maxCharacters: 600,
                jobsDirectory: jobsDir,
                recencyWindow: 60,
                now: Date()
            )
        )
    }

    func testExtractReturnsNilForAgentViewWhenProviderNotClaude() {
        // Agent View ist Claude-only — fuer Codex-Refs muss der Fallback
        // sofort nil liefern und gar nicht erst Supervisor-Files lesen.
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .codex,
            projectName: "repo",
            projectPath: "/tmp/repo",
            title: "Agents",
            externalSessionID: nil,
            kind: .agentView
        )
        XCTAssertNil(AgentChatTailExtractor.extract(for: ref))
    }

    func testExtractReturnsNilForBackgroundChatWithoutShortID() {
        // Background-Chats brauchen die Supervisor-Short-ID — ohne die
        // gibt es keinen Weg vom Roster zum JSONL.
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "repo",
            projectPath: "/tmp/repo",
            title: "BG",
            externalSessionID: "doesnt-matter",
            kind: .backgroundChat,
            backgroundShortID: nil
        )
        XCTAssertNil(AgentChatTailExtractor.extract(for: ref))
    }
}
