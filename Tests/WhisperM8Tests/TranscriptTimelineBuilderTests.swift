import XCTest
@testable import WhisperM8

final class TranscriptTimelineBuilderTests: XCTestCase {

    // MARK: - Helper

    private func message(
        _ role: AgentChatMessage.Role,
        at seconds: TimeInterval? = nil,
        blocks: [AgentChatBlock]
    ) -> AgentChatMessage {
        AgentChatMessage(
            id: UUID(),
            role: role,
            timestamp: seconds.map { Date(timeIntervalSince1970: $0) },
            blocks: blocks
        )
    }

    private func build(_ messages: [AgentChatMessage], live: Bool = false) -> TranscriptTimeline {
        TranscriptTimelineBuilder.build(from: AgentChatTranscript(messages: messages, isLiveSourcePossible: live))
    }

    // MARK: - Rundensegmentierung

    func testSplitsIntoRoundsAtUserTextMessages() {
        let timeline = build([
            message(.user, blocks: [.text("Erste Frage")]),
            message(.assistant, blocks: [.text("Erste Antwort")]),
            message(.user, blocks: [.text("Zweite Frage")]),
            message(.assistant, blocks: [.text("Zweite Antwort")]),
        ])
        XCTAssertEqual(timeline.rounds.count, 2)
        XCTAssertEqual(timeline.rounds[0].prompt?.text, "Erste Frage")
        XCTAssertEqual(timeline.rounds[0].answers.map(\.text), ["Erste Antwort"])
        XCTAssertEqual(timeline.rounds[1].prompt?.text, "Zweite Frage")
        XCTAssertEqual(timeline.totalMessageCount, 4)
    }

    func testToolResultOnlyUserMessageStaysInCurrentRound() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [.toolUse(name: "Read", input: #"{"file_path":"/repo/a.swift"}"#)]),
            message(.user, blocks: [.toolResult(content: "inhalt", isError: false)]),
            message(.assistant, blocks: [.text("Fertig")]),
        ])
        XCTAssertEqual(timeline.rounds.count, 1)
        let round = timeline.rounds[0]
        XCTAssertEqual(round.steps.count, 1)
        guard case .tool(let tool) = round.steps[0].kind else { return XCTFail("Tool-Step erwartet") }
        XCTAssertEqual(tool.result, "inhalt")
        XCTAssertEqual(round.answers.map(\.text), ["Fertig"])
    }

    /// Claude hängt Tool-Results der Vorrunde manchmal an die nächste
    /// Prompt-Message — sie gehören zur VORHERIGEN Runde.
    func testToolResultsOnPromptMessageAttachToPreviousRound() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt 1")]),
            message(.assistant, blocks: [.toolUse(name: "Bash", input: #"{"command":"ls"}"#)]),
            message(.user, blocks: [
                .toolResult(content: "datei.txt", isError: false),
                .text("Prompt 2"),
            ]),
        ])
        XCTAssertEqual(timeline.rounds.count, 2)
        guard case .tool(let tool) = timeline.rounds[0].steps[0].kind else { return XCTFail() }
        XCTAssertEqual(tool.result, "datei.txt")
        XCTAssertEqual(timeline.rounds[1].prompt?.text, "Prompt 2")
        XCTAssertTrue(timeline.rounds[1].steps.isEmpty)
    }

    func testLeadingActivityWithoutPromptBecomesIncompleteRound() {
        let timeline = build([
            message(.assistant, blocks: [.text("Antwort aus angeschnittener Runde")]),
            message(.user, blocks: [.text("Neuer Prompt")]),
            message(.assistant, blocks: [.text("Antwort")]),
        ])
        XCTAssertEqual(timeline.rounds.count, 2)
        XCTAssertTrue(timeline.rounds[0].isIncomplete)
        XCTAssertNil(timeline.rounds[0].prompt)
        XCTAssertEqual(timeline.rounds[0].answers.map(\.text), ["Antwort aus angeschnittener Runde"])
        XCTAssertFalse(timeline.rounds[1].isIncomplete)
    }

    func testOrphanToolResultOnFirstPromptGetsOwnRound() {
        let timeline = build([
            message(.user, blocks: [
                .toolResult(content: "übrig aus Fenster-Schnitt", isError: false),
                .text("Prompt"),
            ]),
        ])
        XCTAssertEqual(timeline.rounds.count, 2)
        XCTAssertTrue(timeline.rounds[0].isIncomplete)
        guard case .tool(let tool) = timeline.rounds[0].steps[0].kind else { return XCTFail() }
        XCTAssertEqual(tool.result, "übrig aus Fenster-Schnitt")
        XCTAssertEqual(timeline.rounds[1].prompt?.text, "Prompt")
    }

    // MARK: - Antwort vs. Zwischenbericht

    func testIntermediateAssistantTextBecomesNoteStep() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [.text("Ich prüfe erst die Datei …")]),
            message(.assistant, blocks: [.toolUse(name: "Read", input: #"{"file_path":"/repo/a.swift"}"#)]),
            message(.user, blocks: [.toolResult(content: "code", isError: false)]),
            message(.assistant, blocks: [.text("Finale Antwort")]),
        ])
        let round = timeline.rounds[0]
        XCTAssertEqual(round.answers.map(\.text), ["Finale Antwort"])
        let notes = round.steps.compactMap { step -> String? in
            if case .note(let text) = step.kind { return text }
            return nil
        }
        XCTAssertEqual(notes, ["Ich prüfe erst die Datei …"])
        // Reihenfolge: Note VOR dem Tool-Step.
        if case .note = round.steps[0].kind {} else { XCTFail("Note muss vor dem Tool-Step stehen") }
    }

    func testMultipleTrailingTextsAllBecomeAnswers() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [.text("Teil 1"), .text("Teil 2")]),
        ])
        XCTAssertEqual(timeline.rounds[0].answers.map(\.text), ["Teil 1", "Teil 2"])
    }

    func testThinkingDemotesEarlierTextToNote() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [.text("Moment"), .thinking("überlege"), .text("Antwort")]),
        ])
        let round = timeline.rounds[0]
        XCTAssertEqual(round.answers.map(\.text), ["Antwort"])
        XCTAssertEqual(round.stats.thinkingCount, 1)
        XCTAssertEqual(round.stats.noteCount, 1)
    }

    // MARK: - Tool-Pairing

    func testPairsToolResultsFIFO() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [
                .toolUse(name: "Read", input: #"{"file_path":"/a.swift"}"#),
                .toolUse(name: "Read", input: #"{"file_path":"/b.swift"}"#),
            ]),
            message(.user, blocks: [
                .toolResult(content: "inhalt-a", isError: false),
                .toolResult(content: "inhalt-b", isError: true),
            ]),
        ])
        let round = timeline.rounds[0]
        guard case .tool(let first) = round.steps[0].kind,
              case .tool(let second) = round.steps[1].kind else { return XCTFail() }
        XCTAssertEqual(first.result, "inhalt-a")
        XCTAssertFalse(first.isError)
        XCTAssertEqual(second.result, "inhalt-b")
        XCTAssertTrue(second.isError)
        XCTAssertEqual(round.stats.errorCount, 1)
    }

    // MARK: - Stats

    func testStatsCountDistinctFilesAndDuration() {
        let timeline = build([
            message(.user, at: 0, blocks: [.text("Prompt")]),
            message(.assistant, at: 10, blocks: [
                .toolUse(name: "Read", input: #"{"file_path":"/repo/a.swift"}"#),
                .toolUse(name: "Edit", input: #"{"file_path":"/repo/a.swift"}"#),
                .toolUse(name: "Write", input: #"{"file_path":"/repo/b.swift"}"#),
                .toolUse(name: "Bash", input: #"{"command":"swift test"}"#),
            ]),
            message(.assistant, at: 130, blocks: [.text("Fertig")]),
        ])
        let stats = timeline.rounds[0].stats
        XCTAssertEqual(stats.toolCallCount, 4)
        XCTAssertEqual(stats.fileCount, 2) // a.swift dedupliziert, Bash zählt nicht
        XCTAssertEqual(stats.duration, 130)
    }

    func testMissingTimestampsYieldNilDuration() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [.text("Antwort")]),
        ])
        XCTAssertNil(timeline.rounds[0].stats.duration)
    }

    // MARK: - Verlustfreiheit

    func testImageAttachmentsLandOnPrompt() {
        let timeline = build([
            message(.user, blocks: [
                .text("Schau dir das an"),
                .imagePlaceholder(mediaType: "image/png", byteSize: 412_000),
            ]),
        ])
        XCTAssertEqual(timeline.rounds[0].prompt?.attachments, [TranscriptAttachment(mediaType: "image/png", byteSize: 412_000)])
    }

    func testSystemMessageBecomesSystemStep() {
        let timeline = build([
            message(.user, blocks: [.text("Prompt")]),
            message(.system, blocks: [.text("Kontext komprimiert")]),
        ])
        guard case .system(let text) = timeline.rounds[0].steps[0].kind else { return XCTFail() }
        XCTAssertEqual(text, "Kontext komprimiert")
    }

    func testEmptyTranscriptYieldsEmptyTimeline() {
        let timeline = build([])
        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.totalMessageCount, 0)
    }

    func testStableRoundAndStepIDsAcrossRebuilds() {
        let messages = [
            message(.user, blocks: [.text("Prompt")]),
            message(.assistant, blocks: [.toolUse(name: "Read", input: #"{"file_path":"/a"}"#), .text("Antwort")]),
        ]
        let first = build(messages)
        let second = build(messages)
        XCTAssertEqual(first.rounds.map(\.id), second.rounds.map(\.id))
        XCTAssertEqual(first.rounds[0].steps.map(\.id), second.rounds[0].steps.map(\.id))
        XCTAssertEqual(first.rounds[0].answers.map(\.id), second.rounds[0].answers.map(\.id))
    }
}

// MARK: - ToolCallClassifier

final class ToolCallClassifierTests: XCTestCase {

    func testClassifiesClaudeCoreTools() {
        XCTAssertEqual(
            ToolCallClassifier.classify(name: "Read", input: #"{"file_path":"/repo/src/Foo.swift"}"#),
            ToolCallClassifier.Classification(op: .read, subject: "Foo.swift", detail: "src")
        )
        XCTAssertEqual(
            ToolCallClassifier.classify(name: "MultiEdit", input: #"{"file_path":"/repo/Bar.swift"}"#).op,
            .edit
        )
        XCTAssertEqual(
            ToolCallClassifier.classify(name: "Write", input: #"{"file_path":"/repo/Neu.swift"}"#).op,
            .write
        )
    }

    func testBashSubjectIsFirstCommandLineTruncated() {
        let long = String(repeating: "x", count: 200)
        let result = ToolCallClassifier.classify(name: "Bash", input: "{\"command\":\"\(long)\\nzweite zeile\"}")
        XCTAssertEqual(result.op, .bash)
        XCTAssertEqual(result.subject.count, 91) // 90 + Ellipse
        XCTAssertTrue(result.subject.hasSuffix("…"))
    }

    func testClassifiesCodexExecCommand() {
        let result = ToolCallClassifier.classify(
            name: "exec_command",
            input: #"{"cmd":"sed -n '1,260p' Datei.swift","workdir":"/Users/x/repos/whisperm8"}"#
        )
        XCTAssertEqual(result.op, .bash)
        XCTAssertEqual(result.subject, "sed -n '1,260p' Datei.swift")
        XCTAssertEqual(result.detail, "whisperm8")
    }

    func testClassifiesMCPTools() {
        let result = ToolCallClassifier.classify(name: "mcp__chrome__navigate", input: #"{"url":"https://x.test"}"#)
        XCTAssertEqual(result.op, .mcp)
        XCTAssertEqual(result.subject, "chrome · navigate")
        XCTAssertEqual(result.detail, "https://x.test")
    }

    func testGrepUsesPatternAndPath() {
        let result = ToolCallClassifier.classify(name: "Grep", input: ##"{"pattern":"#22c55e","path":"/repo/src/admin"}"##)
        XCTAssertEqual(result.op, .search)
        XCTAssertEqual(result.subject, "#22c55e")
        XCTAssertEqual(result.detail, "admin")
    }

    func testUnknownToolFallsBackToPrimaryArgumentOrName() {
        XCTAssertEqual(
            ToolCallClassifier.classify(name: "TodoWrite", input: "{}").subject,
            "TodoWrite"
        )
        XCTAssertEqual(
            ToolCallClassifier.classify(name: "Custom", input: #"{"description":"etwas tun"}"#).subject,
            "etwas tun"
        )
    }

    func testNonJSONInputFallsBackToName() {
        let result = ToolCallClassifier.classify(name: "Read", input: "kein json")
        XCTAssertEqual(result.op, .read)
        XCTAssertEqual(result.subject, "Read")
    }
}
