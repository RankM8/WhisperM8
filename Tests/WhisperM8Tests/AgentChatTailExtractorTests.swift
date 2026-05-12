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
}
