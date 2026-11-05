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
            #"{"type":"assistant","timestamp":"2026-05-11T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","timestamp":"2026-05-11T10:00:03Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file.txt","is_error":false}]}}"#
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
        if case .toolUse(let name, let input, let callID) = transcript.messages[1].blocks[1] {
            XCTAssertEqual(callID, "toolu_1") // LR-AK-013
            XCTAssertEqual(name, "Bash")
            XCTAssertTrue(input.contains("ls"))
        } else { XCTFail("Expected toolUse block") }

        XCTAssertEqual(transcript.messages[2].role, .user)
        if case .toolResult(let content, let isError, let useID) = transcript.messages[2].blocks[0] {
            XCTAssertEqual(useID, "toolu_1")
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

    /// `<synthetic>` (lokal erzeugte Fehlermeldung) ist kein Modell — der
    /// Scan liefert die letzte echte Antwort davor.
    func testLastAssistantModelSkipsSyntheticEntries() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-synthetic-model-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let lines = [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#,
            "",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: tempURL)

        XCTAssertEqual(ClaudeTranscriptReader.lastAssistantModel(fileURL: tempURL), "claude-opus-5-5")
    }

    func testLastAssistantModelReverseScanSkipsTwentyMegabyteTrailingLineWithoutMaterializingIt() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-claude-reverse-model-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Data().write(to: tempURL)
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.write(contentsOf: Data(
            (#"{"type":"assistant","message":{"model":"gpt-5.6-terra[1m]","content":[]}}"# + "\n").utf8
        ))
        try handle.write(contentsOf: Data(#"{"type":"user","message":{"content":""#.utf8))
        let oneMegabyte = Data(repeating: Character("x").asciiValue!, count: 1_024 * 1_024)
        for _ in 0..<20 {
            try handle.write(contentsOf: oneMegabyte)
        }
        try handle.write(contentsOf: Data(#""}}"#.utf8))
        try handle.close()

        var statistics = ClaudeTranscriptReader.LastAssistantModelScanStatistics()
        let model = ClaudeTranscriptReader.lastAssistantModel(
            fileURL: tempURL,
            statistics: &statistics
        )
        let fileSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.intValue
        )

        XCTAssertEqual(model, "gpt-5.6-terra[1m]")
        XCTAssertEqual(
            model.map { ClaudeGPTModelAlias.effectiveModel($0, fastEnabled: false) },
            "gpt-5.6-terra"
        )
        XCTAssertGreaterThan(fileSize, 20 * 1_024 * 1_024)
        XCTAssertGreaterThan(statistics.boundaryBytesRead, 16 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(statistics.boundaryBytesRead, fileSize)
        XCTAssertEqual(statistics.longLinesInspected, 1)
        XCTAssertLessThanOrEqual(statistics.maximumLinePayloadBytesRead, 64 * 1_024)
        XCTAssertGreaterThanOrEqual(statistics.fullLinesParsed, 1)
    }

    /// LR-AK-004: skalare Tool-Payloads (`input: 1/true/null`) lösen in
    /// `JSONSerialization.data` eine NSException aus, die `try?` nicht fängt.
    func testClaudeParseEntryHandlesScalarToolInputsWithoutCrashing() throws {
        let inputs: [(Any, String)] = [(1, "1"), (true, "true"), (NSNull(), ""), ("x", "x")]
        for (value, expected) in inputs {
            let entry: [String: Any] = [
                "type": "assistant",
                "message": ["content": [["type": "tool_use", "name": "T", "input": value]]]
            ]
            let message = try XCTUnwrap(ClaudeTranscriptReader.parseEntry(entry))
            guard case let .toolUse(_, input, _)? = message.blocks.first else { return XCTFail("kein toolUse") }
            XCTAssertEqual(input, expected)
        }
        let array: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "name": "T", "input": [1, 2]]]]
        ]
        XCTAssertNotNil(ClaudeTranscriptReader.parseEntry(array))
    }

    func testCodexToolSearchCallWithScalarArgumentsDoesNotCrash() throws {
        for value in [1, true] as [Any] {
            let entry: [String: Any] = [
                "type": "response_item",
                "payload": ["type": "tool_search_call", "arguments": value]
            ]
            let message = try XCTUnwrap(CodexTranscriptReader.parseEntry(entry))
            guard case .toolUse? = message.blocks.first else { return XCTFail("kein toolUse") }
        }
        let nullEntry: [String: Any] = [
            "type": "response_item",
            "payload": ["type": "tool_search_call", "arguments": NSNull()]
        ]
        XCTAssertNotNil(CodexTranscriptReader.parseEntry(nullEntry))
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
        if case .toolUse(let name, let input, _) = transcript.messages[1].blocks[0] {
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
        if case .toolUse(let name, let input, _) = transcript.messages[2].blocks[0] {
            XCTAssertEqual(name, "exec_command")
            XCTAssertTrue(input.contains("AgentCLICommand.swift"))
        } else { XCTFail("toolUse erwartet") }
        if case .toolResult(let content, let isError, _) = transcript.messages[3].blocks[0] {
            XCTAssertTrue(content.contains("Process exited with code 0"))
            XCTAssertFalse(isError)
        } else { XCTFail("toolResult erwartet") }
        XCTAssertEqual(transcript.messages[3].role, .user)
        if case .text(let final) = transcript.messages[4].blocks[0] {
            XCTAssertTrue(final.contains("\"status\":\"success\""))
        } else { XCTFail("Finale Antwort erwartet") }
    }

    /// LR-AK-007: Endet die Datei mit einer Zeile > Tail-Fenster, bleibt der Tail leer
    /// (hasTruncatedHead) — der Container muss dann den Nachlade-Button anbieten.
    func testHugeLastLineLeavesEmptyTruncatedTailAndContainerOffersHistory() throws {
        let small = (0..<5).map { #"{"type":"user","message":{"content":"frage \#($0)"}}"# }
        let huge = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: 4_000) + #""}}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8HugeLast-\(UUID().uuidString).jsonl")
        try (small + [huge]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = ClaudeTranscriptReader.readTail(fileURL: url, tailBytes: 1_000)

        XCTAssertTrue(transcript.messages.isEmpty)
        XCTAssertTrue(transcript.hasTruncatedHead)
        XCTAssertTrue(AgentTranscriptContainerView.offersEarlierHistoryWhenEmpty(transcript: transcript, canLoad: true))
        XCTAssertFalse(AgentTranscriptContainerView.offersEarlierHistoryWhenEmpty(transcript: transcript, canLoad: false))
        XCTAssertFalse(AgentTranscriptContainerView.offersEarlierHistoryWhenEmpty(transcript: .empty, canLoad: true))
    }

    func testCodexReaderMarksNonZeroExitAsError() throws {
        let tempURL = try writeCodexFixture([CodexRolloutFixtures.functionCallOutputFailed])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let transcript = CodexTranscriptReader.read(fileURL: tempURL)
        XCTAssertEqual(transcript.messages.count, 1)
        if case .toolResult(_, let isError, _) = transcript.messages[0].blocks[0] {
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
        if case .toolUse(let name, let input, _) = transcript.messages[0].blocks[0] {
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

    /// Hook-Analyse 05.11.2026, Stufe 0: alte Event-Dateien von Chats im
    /// Workspace räumen, Hintergrund-Agenten und frische Dateien behalten.
    func testAgentSessionRetentionServicePrunesStaleEventFiles() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanUp() }
        let staleChat = UUID(), freshChat = UUID(), backgroundAgent = UUID()
        for id in [staleChat, freshChat, backgroundAgent] {
            try fixture.writeEvent(id, contents: "{}\n")
            try fixture.writeSettings(id)
        }
        try fixture.age(staleChat, by: 15)
        try fixture.age(backgroundAgent, by: 15)

        let result = fixture.service().prune(
            liveLocalSessionIDs: [staleChat, freshChat, backgroundAgent],
            protectedLocalSessionIDs: [backgroundAgent],
            now: fixture.now)

        XCTAssertEqual(result.hookEventsRemoved, 0)
        XCTAssertEqual(result.staleHookEventsRemoved, 1)
        XCTAssertEqual(result.staleHookEventBytesRemoved, 3)
        XCTAssertFalse(fixture.eventExists(staleChat))
        XCTAssertTrue(fixture.eventExists(freshChat))
        XCTAssertTrue(fixture.eventExists(backgroundAgent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.settingsFileURL(localSessionID: staleChat).path),
                      "Settings-Dateien bleiben")
    }

    /// Grenze: genau 14 Tage alt bleibt, eine Sekunde älter wird gelöscht.
    func testAgentSessionRetentionServiceStaleAgeBoundary() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanUp() }
        let atCutoff = UUID(), pastCutoff = UUID()
        try fixture.writeEvent(atCutoff)
        try fixture.writeEvent(pastCutoff)
        try fixture.setModified(atCutoff, to: fixture.now.addingTimeInterval(-AgentSessionRetentionService.staleEventAge))
        try fixture.setModified(pastCutoff, to: fixture.now.addingTimeInterval(-AgentSessionRetentionService.staleEventAge - 1))

        let result = fixture.service().prune(liveLocalSessionIDs: [atCutoff, pastCutoff], now: fixture.now)

        XCTAssertEqual(result.staleHookEventsRemoved, 1)
        XCTAssertTrue(fixture.eventExists(atCutoff))
        XCTAssertFalse(fixture.eventExists(pastCutoff))
    }

    /// Fremde Dateien im Ordner (kein UUID-Name, andere Endung) bleiben liegen.
    func testAgentSessionRetentionServiceIgnoresForeignFiles() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let foreign = [
            fixture.paths.eventsDirectory.appendingPathComponent("notes.jsonl"),
            fixture.paths.eventsDirectory.appendingPathComponent("\(id.uuidString).log"),
            fixture.paths.eventsDirectory.appendingPathComponent("\(id.uuidString).jsonl.bak"),
        ]
        for url in foreign {
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: fixture.now.addingTimeInterval(-30 * 24 * 60 * 60)], ofItemAtPath: url.path)
        }

        let result = fixture.service().prune(liveLocalSessionIDs: [], now: fixture.now)

        XCTAssertEqual(result, RetentionResult())
        for url in foreign {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
    }

    /// Review Stufe 0, Befund 1: Ein wiederhergestellter Chat legt seine
    /// Event-Datei neu an, nachdem das Aufräumen den Ordner gelesen hat. Das
    /// frisch gelesene Änderungsdatum muss die Löschung verhindern.
    func testAgentSessionRetentionServiceRechecksDateBeforeRemoving() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanUp() }
        let restored = UUID()
        try fixture.writeEvent(restored, contents: "alt\n")
        try fixture.age(restored, by: 30)

        let service = fixture.service(beforeRemoval: { url in
            // Launch genau zwischen Auflisten und Löschen: Datei frisch angelegt.
            try? FileManager.default.removeItem(at: url)
            try? Data().write(to: url, options: .atomic)
        })
        let result = service.prune(liveLocalSessionIDs: [restored], now: fixture.now)

        XCTAssertEqual(result.staleHookEventsRemoved, 0)
        XCTAssertTrue(fixture.eventExists(restored))
    }

    /// Befund 1: Hat die App den Chat schon gestartet (Dateien beansprucht),
    /// bleiben seine Dateien, auch wenn das Datum noch alt aussieht und der
    /// Chat im Workspace-Snapshot noch fehlt.
    @MainActor
    func testAgentSessionRetentionServiceSkipsFilesClaimedByLaunch() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanUp() }
        let restored = UUID(), newChat = UUID()
        let bridge = ClaudeHookBridge(paths: fixture.paths)
        for id in [restored, newChat] {
            XCTAssertNotNil(bridge.prepareSettingsFile(localSessionID: id))
            try fixture.age(id, by: 30)
        }
        XCTAssertTrue(ClaudeHookFileClaims.shared.isClaimed(restored))

        let result = fixture.service(claims: .shared).prune(
            liveLocalSessionIDs: [restored], now: fixture.now)

        XCTAssertEqual(result, RetentionResult())
        for id in [restored, newChat] {
            XCTAssertTrue(fixture.eventExists(id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.settingsFileURL(localSessionID: id).path))
        }
    }

    /// Verdrahtung beim App-Start: Workspace-Chats gelten als lebendig,
    /// Hintergrund-Agenten als geschützt, alles andere ist verwaist.
    func testAgentSessionRetentionServicePruneAtLaunchProtectsBackgroundChats() throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanUp() }
        let projectID = UUID()
        let chat = AgentChatSession(provider: .claude, projectID: projectID, title: "Chat")
        let background = AgentChatSession(provider: .claude, projectID: projectID, title: "BG", kind: .backgroundChat)
        let orphan = UUID()
        for id in [chat.id, background.id, orphan] {
            try fixture.writeEvent(id)
            try fixture.age(id, by: 20)
        }

        let result = fixture.service().pruneAtLaunch(
            workspace: AgentWorkspace(projects: [], sessions: [chat, background]), now: fixture.now)

        XCTAssertEqual(result.hookEventsRemoved, 1)
        XCTAssertEqual(result.staleHookEventsRemoved, 1)
        XCTAssertFalse(fixture.eventExists(orphan))
        XCTAssertFalse(fixture.eventExists(chat.id))
        XCTAssertTrue(fixture.eventExists(background.id))
    }
}

/// Temporärer Hook-Ordner für die Retention-Tests.
private struct RetentionFixture {
    let root: URL
    let paths: ClaudeHookPaths
    let now = Date()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Retention-\(UUID().uuidString)", isDirectory: true)
        paths = ClaudeHookPaths(rootDirectory: root)
        try FileManager.default.createDirectory(at: paths.settingsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.eventsDirectory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Eigene Claims-Menge, damit parallele Tests sich nicht beeinflussen.
    func service(
        claims: ClaudeHookFileClaims = ClaudeHookFileClaims(),
        beforeRemoval: @escaping (URL) -> Void = { _ in }
    ) -> AgentSessionRetentionService {
        AgentSessionRetentionService(hookPaths: paths, claims: claims, beforeRemoval: beforeRemoval)
    }

    func writeEvent(_ id: UUID, contents: String = "") throws {
        try Data(contents.utf8).write(to: paths.eventFileURL(localSessionID: id))
    }

    func writeSettings(_ id: UUID) throws {
        try Data().write(to: paths.settingsFileURL(localSessionID: id))
    }

    func age(_ id: UUID, by days: Double) throws {
        try setModified(id, to: now.addingTimeInterval(-days * 24 * 60 * 60))
    }

    func setModified(_ id: UUID, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: paths.eventFileURL(localSessionID: id).path)
    }

    func eventExists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: paths.eventFileURL(localSessionID: id).path)
    }
}

