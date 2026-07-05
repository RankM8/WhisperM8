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
        // Seit der Timeline-Erweiterung liefert der Reader auch den
        // function_call als toolUse-Message (Position 1, chronologisch).
        XCTAssertEqual(transcript.messages.count, 3)
        XCTAssertEqual(transcript.messages[0].role, .user)
        if case .toolUse(let name, let input) = transcript.messages[1].blocks[0] {
            XCTAssertEqual(name, "shell")
            XCTAssertEqual(input, "ls")
        } else { XCTFail("Expected toolUse block") }
        XCTAssertEqual(transcript.messages[2].role, .assistant)
        if case .text(let t) = transcript.messages[2].blocks[0] {
            XCTAssertEqual(t, "Hello back")
        } else { XCTFail("Expected assistant text block") }
    }

    // MARK: - Codex response_item (echte Rollout-Fixtures, codex 0.142.5)

    private func writeCodexFixture(_ lines: [String]) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-codex-rollout-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    func testCodexReaderParsesFullRealTurn() throws {
        let tempURL = try writeCodexFixture(CodexRolloutFixtures.fullTurnLines)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transcript = CodexTranscriptReader.read(fileURL: tempURL)
        // Erwartet: user_message, agent_message (commentary), function_call,
        // function_call_output, agent_message (final). Duplikate
        // (response_item/message) + Skip-Typen (session_meta, task_*,
        // token_count, reasoning ohne Summary) erzeugen NICHTS.
        XCTAssertEqual(transcript.messages.count, 5)
        XCTAssertEqual(transcript.messages[0].role, .user)
        if case .text(let commentary) = transcript.messages[1].blocks[0] {
            XCTAssertTrue(commentary.hasPrefix("Ich lese gezielt"))
        } else { XCTFail("Commentary-Text erwartet") }
        if case .toolUse(let name, let input) = transcript.messages[2].blocks[0] {
            XCTAssertEqual(name, "exec_command")
            XCTAssertTrue(input.contains("AgentCLICommand.swift"))
        } else { XCTFail("toolUse erwartet") }
        if case .toolResult(let content, let isError) = transcript.messages[3].blocks[0] {
            XCTAssertTrue(content.contains("Process exited with code 0"))
            XCTAssertFalse(isError)
        } else { XCTFail("toolResult erwartet") }
        XCTAssertEqual(transcript.messages[3].role, .user)
        if case .text(let final) = transcript.messages[4].blocks[0] {
            XCTAssertTrue(final.contains("\"status\":\"success\""))
        } else { XCTFail("Finale Antwort erwartet") }
    }

    func testCodexReaderMarksNonZeroExitAsError() throws {
        let tempURL = try writeCodexFixture([CodexRolloutFixtures.functionCallOutputFailed])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transcript = CodexTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 1)
        if case .toolResult(_, let isError) = transcript.messages[0].blocks[0] {
            XCTAssertTrue(isError)
        } else { XCTFail("toolResult erwartet") }
    }

    func testCodexReaderMapsToolSearchCallAndSkipsEncryptedReasoning() throws {
        let tempURL = try writeCodexFixture([
            CodexRolloutFixtures.reasoningEncrypted,
            CodexRolloutFixtures.toolSearchCall,
        ])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transcript = CodexTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 1)
        if case .toolUse(let name, let input) = transcript.messages[0].blocks[0] {
            XCTAssertEqual(name, "tool_search")
            XCTAssertTrue(input.contains("computer-use"))
        } else { XCTFail("tool_search als toolUse erwartet") }
    }

    // MARK: - Tail-first (Freeze-Schutz bei großen Transcripts)

    func testReadTailSetsTruncatedHeadFlag() throws {
        let tempURL = try writeCodexFixture(CodexRolloutFixtures.fullTurnLines)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Winziges Fenster → Kopf abgeschnitten.
        let truncated = CodexTranscriptReader.readTail(fileURL: tempURL, tailBytes: 600)
        XCTAssertTrue(truncated.hasTruncatedHead)

        // Fenster größer als die Datei → alles gelesen, kein Rest davor.
        let full = CodexTranscriptReader.readTail(fileURL: tempURL, tailBytes: 10_000_000)
        XCTAssertFalse(full.hasTruncatedHead)
        XCTAssertEqual(full.messages.count, 5)
    }

    // MARK: - Stabile Message-IDs

    func testCodexReaderAssignsStableIDsAcrossReloads() throws {
        let tempURL = try writeCodexFixture(CodexRolloutFixtures.fullTurnLines)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let first = CodexTranscriptReader.read(fileURL: tempURL)
        let second = CodexTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(first.messages.map(\.id), second.messages.map(\.id))
    }

    func testStableIDsSurviveTailWindowShift() throws {
        // Wachsende Datei: Nachzügler-Append darf die IDs der bestehenden
        // Messages nicht ändern (Kern-Garantie gegen Scroll-Springen).
        let tempURL = try writeCodexFixture(CodexRolloutFixtures.fullTurnLines)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let before = CodexTranscriptReader.readTail(fileURL: tempURL)
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + CodexRolloutFixtures.agentMessageCommentary).utf8))
        try handle.close()
        let after = CodexTranscriptReader.readTail(fileURL: tempURL)

        XCTAssertEqual(after.messages.count, before.messages.count + 1)
        XCTAssertEqual(Array(after.messages.dropLast()).map(\.id), before.messages.map(\.id))
    }

    func testStableIDsDisambiguateIdenticalMessages() {
        var generator = TranscriptStableIDGenerator()
        let message = AgentChatMessage(id: UUID(), role: .assistant, timestamp: nil, blocks: [.text("ok")])
        let first = generator.assign(message)
        let second = generator.assign(message)
        XCTAssertNotEqual(first.id, second.id)

        // Neuer Lauf → gleiche Sequenz → gleiche IDs.
        var freshGenerator = TranscriptStableIDGenerator()
        XCTAssertEqual(freshGenerator.assign(message).id, first.id)
        XCTAssertEqual(freshGenerator.assign(message).id, second.id)
    }

    func testClaudeReaderAssignsStableIDsAcrossReloads() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-stable-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let lines = [
            #"{"type":"user","timestamp":"2026-05-11T10:00:00Z","message":{"content":"Hallo"}}"#,
            #"{"type":"assistant","timestamp":"2026-05-11T10:00:05Z","message":{"content":[{"type":"text","text":"Hi!"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tempURL, atomically: true, encoding: .utf8)

        let first = ClaudeTranscriptReader.read(fileURL: tempURL)
        let second = ClaudeTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(first.messages.map(\.id), second.messages.map(\.id))
        XCTAssertEqual(first.messages.count, 2)
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
