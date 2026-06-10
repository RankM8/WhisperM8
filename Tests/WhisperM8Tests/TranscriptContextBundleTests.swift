import Foundation
import XCTest
@testable import WhisperM8

final class TranscriptContextBundleTests: XCTestCase {
    // MARK: - Auto-Chat-Context

    func testTranscriptContextBundleIsNotEmptyWhenAgentChatPresent() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: nil
        )
        let bundle = TranscriptContextBundle(agentChat: ref)
        XCTAssertFalse(bundle.isEmpty)
    }

    func testTranscriptContextBundleDisplaySummaryShowsChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .codex,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Codex Chat",
            externalSessionID: nil
        )
        let bundle = TranscriptContextBundle(agentChat: ref)
        XCTAssertEqual(bundle.displaySummary, "Chat")
    }

    func testTranscriptContextBundleDisplaySummaryCombinesChatWithText() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: nil
        )
        let selected = SelectedContext(
            text: "hello",
            sourceAppName: "Cursor",
            sourceBundleIdentifier: "com.cursor.app"
        )
        let bundle = TranscriptContextBundle(selectedText: selected, agentChat: ref)
        XCTAssertEqual(bundle.displaySummary, "Chat + Text")
    }

    func testTranscriptContextBundleCompactSummaryPrefersChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "x",
            projectPath: "/tmp/x",
            title: "Chat",
            externalSessionID: nil
        )
        // Selbst wenn Screenshots da sind, gewinnt Chat im Compact-Slot.
        let shot = ContextAttachment(
            kind: .screenshot,
            fileURL: URL(fileURLWithPath: "/tmp/shot.png")
        )
        let bundle = TranscriptContextBundle(agentChat: ref, screenshots: [shot])
        XCTAssertEqual(bundle.compactSummary, "Chat")
    }

    func testTranscriptContextBundleFromHelperPropagatesAgentChat() {
        let ref = AgentChatContextRef(
            sessionID: UUID(),
            provider: .claude,
            projectName: "heartbeat",
            projectPath: "/tmp/heartbeat",
            title: "Claude Chat",
            externalSessionID: "ext-id"
        )
        let bundle = TranscriptContextBundle.from(
            selectedContext: .empty,
            sourceApp: nil,
            agentChat: ref
        )
        XCTAssertEqual(bundle.agentChat, ref)
        XCTAssertEqual(bundle.displaySummary, "Chat")
    }

    func testTranscriptContextBundleNoChatStillReportsNoContext() {
        let bundle = TranscriptContextBundle()
        XCTAssertTrue(bundle.isEmpty)
        XCTAssertEqual(bundle.displaySummary, "No Context")
    }
}
