import XCTest
@testable import WhisperM8

final class TeammateMessageParserTests: XCTestCase {

    /// Realistische Injektion (Struktur aus einer echten Claude-Code-Session).
    private let realPayload = """
    Another Claude session sent a message:
    <teammate-message teammate_id="akq93" color="pink">
    {"type":"idle_notification","from":"akq93","timestamp":"2026-07-04T20:24:42.828Z",\
    "idleReason":"available","summary":"[to main] AKQ-93 Abschlussbericht: nicht prüfbar wegen 502"}
    </teammate-message>

    This came from another Claude session — not typed by your user.
    """

    func testParsesRealTeammateMessage() throws {
        let parsed = try XCTUnwrap(TeammateMessageParser.parse(realPayload))
        XCTAssertEqual(parsed.teammateID, "akq93")
        XCTAssertEqual(parsed.kind, "idle_notification")
        XCTAssertEqual(parsed.summary, "[to main] AKQ-93 Abschlussbericht: nicht prüfbar wegen 502")
        XCTAssertEqual(parsed.raw, realPayload)
        XCTAssertTrue(parsed.gist.contains("akq93"))
        XCTAssertTrue(parsed.gist.contains("idle_notification"))
    }

    func testNormalPromptIsNotTeammate() {
        XCTAssertNil(TeammateMessageParser.parse("Bitte committe alles und mach make dev."))
    }

    func testMissingFieldsFallBackToFirstLine() throws {
        let parsed = try XCTUnwrap(TeammateMessageParser.parse("<teammate-message>\nnackter block ohne felder"))
        XCTAssertNil(parsed.teammateID)
        XCTAssertNil(parsed.summary)
        XCTAssertEqual(parsed.gist, "<teammate-message>")
    }

    func testSummaryUnescapesQuotesAndNewlines() throws {
        let text = #"<teammate-message teammate_id="x">{"summary":"Zeile1\nmit \"Zitat\""}"#
        let parsed = try XCTUnwrap(TeammateMessageParser.parse(text))
        XCTAssertEqual(parsed.summary, "Zeile1 mit \"Zitat\"")
    }

    func testBuilderMarksTeammatePrompt() {
        let message = AgentChatMessage(id: UUID(), role: .user, timestamp: nil, blocks: [.text(realPayload)])
        let timeline = TranscriptTimelineBuilder.build(
            from: AgentChatTranscript(messages: [message], isLiveSourcePossible: false)
        )
        XCTAssertNotNil(timeline.rounds.first?.prompt?.teammate)
        XCTAssertEqual(timeline.rounds.first?.prompt?.teammate?.teammateID, "akq93")
    }
}
