import Foundation
import XCTest
@testable import WhisperM8

final class AgentTranscriptReaderTests: XCTestCase {
    // MARK: - Transcript readers

    func testClaudeTranscriptURLEncodesCWDWithDashes() {
        let url = ClaudeTranscriptReader.transcriptURL(
            forCwd: "/Users/foo/repos/whisperm8",
            sessionID: "abc-123"
        )
        XCTAssertTrue(url.path.hasSuffix("/.claude/projects/-Users-foo-repos-whisperm8/abc-123.jsonl"))
    }

    func testClaudeTranscriptReaderParsesUserAndAssistantEntries() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let lines = [
            #"{"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"role":"user","content":"Hello Claude"}}"#,
            #"{"type":"queue-operation","timestamp":"2026-05-11T10:00:01Z","operation":"x","sessionId":"s"}"#,
            #"{"type":"assistant","timestamp":"2026-05-11T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","timestamp":"2026-05-11T10:00:03Z","message":{"role":"user","content":[{"type":"tool_result","content":"file.txt","is_error":false}]}}"#
        ]
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = ClaudeTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 3)
        XCTAssertEqual(transcript.messages[0].role, .user)
        if case .text(let t) = transcript.messages[0].blocks[0] {
            XCTAssertEqual(t, "Hello Claude")
        } else { XCTFail("Expected text block") }

        XCTAssertEqual(transcript.messages[1].role, .assistant)
        XCTAssertEqual(transcript.messages[1].blocks.count, 2)
        if case .toolUse(let name, let input) = transcript.messages[1].blocks[1] {
            XCTAssertEqual(name, "Bash")
            XCTAssertTrue(input.contains("ls"))
        } else { XCTFail("Expected toolUse block") }

        XCTAssertEqual(transcript.messages[2].role, .user)
        if case .toolResult(let content, let isError) = transcript.messages[2].blocks[0] {
            XCTAssertEqual(content, "file.txt")
            XCTAssertFalse(isError)
        } else { XCTFail("Expected toolResult block") }
    }

    func testClaudeTranscriptReaderSkipsCorruptedLines() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-corrupt-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let content = """
        {"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"role":"user","content":"OK"}}
        not valid json line
        {"type":"assistant","timestamp":"2026-05-11T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Response"}]}}
        """
        try content.write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = ClaudeTranscriptReader.read(fileURL: tempURL)
        // Korrupte Mittelzeile uebersprungen, andere zwei kamen durch.
        XCTAssertEqual(transcript.messages.count, 2)
    }

    func testClaudeTranscriptReaderHandlesImagePayload() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-image-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let line = #"{"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"text","text":"look at this"}]}}"#
        try line.write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = ClaudeTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.messages[0].blocks.count, 2)
        if case .imagePlaceholder(let mediaType, _) = transcript.messages[0].blocks[0] {
            XCTAssertEqual(mediaType, "image/png")
        } else { XCTFail("Expected imagePlaceholder block") }
    }

    func testCodexTranscriptReaderParsesUserAndAgentMessages() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-codex-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let lines = [
            #"{"timestamp":"2026-05-11T10:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"x"}}"#,
            #"{"timestamp":"2026-05-11T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Hi Codex"}}"#,
            #"{"timestamp":"2026-05-11T10:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"ls"}}"#,
            #"{"timestamp":"2026-05-11T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"Hello back"}}"#
        ]
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)

        let transcript = CodexTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].role, .user)
        XCTAssertEqual(transcript.messages[1].role, .assistant)
        if case .text(let t) = transcript.messages[1].blocks[0] {
            XCTAssertEqual(t, "Hello back")
        } else { XCTFail("Expected assistant text block") }
    }

    // MARK: - Retention

    func testAgentSessionRetentionServicePrunesOrphanedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookPaths = ClaudeHookPaths(rootDirectory: root)
        try FileManager.default.createDirectory(at: hookPaths.settingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hookPaths.eventsDirectory, withIntermediateDirectories: true)

        let live = UUID()
        let orphan = UUID()

        try Data().write(to: hookPaths.settingsFileURL(localSessionID: live))
        try Data().write(to: hookPaths.settingsFileURL(localSessionID: orphan))
        try Data().write(to: hookPaths.eventFileURL(localSessionID: live))
        try Data().write(to: hookPaths.eventFileURL(localSessionID: orphan))

        let service = AgentSessionRetentionService(hookPaths: hookPaths)
        let result = service.prune(liveLocalSessionIDs: [live])

        XCTAssertEqual(result.hookSettingsRemoved, 1)
        XCTAssertEqual(result.hookEventsRemoved, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hookPaths.settingsFileURL(localSessionID: live).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hookPaths.settingsFileURL(localSessionID: orphan).path))
    }
}
