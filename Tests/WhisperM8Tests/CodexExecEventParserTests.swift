import XCTest
@testable import WhisperM8

final class CodexExecEventParserTests: XCTestCase {
    // MARK: - Kern-Events (echte Fixture-Zeilen)

    func testParsesThreadStarted() {
        let event = CodexExecEventParser.parse(line: CodexExecFixtures.threadStarted)
        XCTAssertEqual(event, .threadStarted(threadID: "019f2efe-a948-7ad3-8f21-afd79af17271"))
    }

    func testParsesTurnStarted() {
        XCTAssertEqual(CodexExecEventParser.parse(line: CodexExecFixtures.turnStarted), .turnStarted)
    }

    func testParsesAgentMessageItem() {
        guard case .itemCompleted(let item)? = CodexExecEventParser.parse(line: CodexExecFixtures.itemAgentMessage) else {
            return XCTFail("Erwartet itemCompleted")
        }
        XCTAssertEqual(item.type, "agent_message")
        XCTAssertEqual(item.id, "item_1")
        XCTAssertTrue(item.text?.hasPrefix("Ich lese kurz") == true)
    }

    func testParsesCommandExecutionInProgress() {
        guard case .itemStarted(let item)? = CodexExecEventParser.parse(line: CodexExecFixtures.itemCommandStarted) else {
            return XCTFail("Erwartet itemStarted")
        }
        XCTAssertEqual(item.type, "command_execution")
        XCTAssertEqual(item.status, "in_progress")
        // exit_code ist im Fixture JSON-null → nil, kein 0.
        XCTAssertNil(item.exitCode)
        XCTAssertTrue(item.command?.contains("ls -la readme.txt") == true)
    }

    func testParsesCommandExecutionFailedWithExitCode() {
        guard case .itemCompleted(let item)? = CodexExecEventParser.parse(line: CodexExecFixtures.itemCommandFailed) else {
            return XCTFail("Erwartet itemCompleted")
        }
        XCTAssertEqual(item.exitCode, 127)
        XCTAssertEqual(item.status, "failed")
        XCTAssertTrue(item.aggregatedOutput?.contains("command not found") == true)
    }

    func testParsesTurnCompletedWithUsage() {
        guard case .turnCompleted(let usage)? = CodexExecEventParser.parse(line: CodexExecFixtures.turnCompleted) else {
            return XCTFail("Erwartet turnCompleted")
        }
        XCTAssertEqual(usage?.inputTokens, 52453)
        XCTAssertEqual(usage?.cachedInputTokens, 39040)
        XCTAssertEqual(usage?.outputTokens, 319)
        XCTAssertEqual(usage?.reasoningOutputTokens, 0)
    }

    /// Items vom Typ "error" tragen ihre Meldung in `message` (nicht `text`)
    /// — der Parser mappt beides auf `text`.
    func testErrorItemMessageLandsInText() {
        guard case .itemCompleted(let item)? = CodexExecEventParser.parse(line: CodexExecFixtures.itemErrorNote) else {
            return XCTFail("Erwartet itemCompleted")
        }
        XCTAssertEqual(item.type, "error")
        XCTAssertTrue(item.text?.contains("skills context budget") == true)
    }

    // MARK: - Fehler-Events (synthetische Form)

    func testParsesTurnFailedWithNestedMessage() {
        XCTAssertEqual(
            CodexExecEventParser.parse(line: CodexExecFixtures.turnFailedNested),
            .turnFailed(message: "stream disconnected")
        )
    }

    func testParsesTopLevelError() {
        XCTAssertEqual(
            CodexExecEventParser.parse(line: CodexExecFixtures.topLevelError),
            .error(message: "unexpected server error")
        )
    }

    // MARK: - Toleranz

    func testUnknownEventTypeYieldsUnknown() {
        let event = CodexExecEventParser.parse(line: #"{"type":"thread.renamed","name":"x"}"#)
        XCTAssertEqual(event, .unknown(type: "thread.renamed"))
    }

    func testThreadStartedWithoutIDYieldsUnknown() {
        let event = CodexExecEventParser.parse(line: #"{"type":"thread.started"}"#)
        XCTAssertEqual(event, .unknown(type: "thread.started"))
    }

    func testJSONWithoutTypeYieldsUnknownEmpty() {
        XCTAssertEqual(CodexExecEventParser.parse(line: #"{"foo":1}"#), .unknown(type: ""))
    }

    func testGarbageLineYieldsNil() {
        XCTAssertNil(CodexExecEventParser.parse(line: "not json at all"))
    }

    func testEmptyLineYieldsNil() {
        XCTAssertNil(CodexExecEventParser.parse(line: "   "))
    }

    /// Der komplette Fixture-Turn parst ohne nil-Zeilen und endet mit
    /// turnCompleted — Rauchtest gegen das echte Stream-Format.
    func testFullSuccessfulTurnParsesInOrder() {
        let events = CodexExecFixtures.successfulTurnLines.compactMap(CodexExecEventParser.parse(line:))
        XCTAssertEqual(events.count, CodexExecFixtures.successfulTurnLines.count)
        XCTAssertEqual(events.first, .threadStarted(threadID: "019f2efe-a948-7ad3-8f21-afd79af17271"))
        guard case .turnCompleted = events.last else {
            return XCTFail("Letztes Event muss turnCompleted sein")
        }
    }
}
