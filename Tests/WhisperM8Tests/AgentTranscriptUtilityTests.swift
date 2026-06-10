import Foundation
import XCTest
@testable import WhisperM8

final class AgentTranscriptUtilityTests: XCTestCase {
    // MARK: - Transcript Locator

    func testClaudeCwdEncodingMatchesActualEncoding() {
        // Claude ersetzt jeden Nicht-Alphanumerik-Char durch `-`.
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/Users/foo/repos/heartbeat"),
            "-Users-foo-repos-heartbeat"
        )
        XCTAssertEqual(
            AgentTranscriptLocator.encodeClaudeCwd("/var/lib/data_2"),
            "-var-lib-data-2"
        )
    }

    // MARK: - Terminal drag-drop payload

    func testTerminalDropPayloadEscapesNothingForSimplePath() {
        XCTAssertEqual(
            TerminalDropPayload.build(from: ["/Users/me/repos/whisperm8/file.md"]),
            "/Users/me/repos/whisperm8/file.md"
        )
    }

    func testTerminalDropPayloadEscapesSpacesAndSpecialChars() {
        XCTAssertEqual(
            TerminalDropPayload.shellEscape("/Users/me/Tim AI/2026-05-11 plan.md"),
            "/Users/me/Tim\\ AI/2026-05-11\\ plan.md"
        )
    }

    func testTerminalDropPayloadEscapesUmlauts() {
        // Umlaute sind nicht im "safe"-Set, müssen also escapt werden, damit
        // die Shell sie nicht als Argument-Trennzeichen oder Glob behandelt.
        let escaped = TerminalDropPayload.shellEscape("/Users/me/Übersicht.md")
        XCTAssertTrue(escaped.contains("\\Ü"))
    }

    func testTerminalDropPayloadJoinsMultiplePathsWithSpaces() {
        let result = TerminalDropPayload.build(from: [
            "/tmp/a.md",
            "/tmp/b c.md"
        ])
        XCTAssertEqual(result, "/tmp/a.md /tmp/b\\ c.md")
    }

    func testTerminalDropPayloadEmptyInput() {
        XCTAssertEqual(TerminalDropPayload.build(from: []), "")
    }

    // MARK: - Summary excerpt + parser

    func testBuildExtendedKeepsFirstAndLastMessagesWithMarker() {
        var lines: [String] = []
        for i in 1...30 {
            let role = i.isMultiple(of: 2) ? "assistant" : "user"
            let content = "msg-\(i)"
            if role == "assistant" {
                lines.append(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(content)"}],"stop_reason":"end_turn"}}"#)
            } else {
                lines.append(#"{"type":"user","message":{"role":"user","content":"\#(content)"}}"#)
            }
        }
        let text = lines.joined(separator: "\n")
        let result = AgentTranscriptExcerpt.buildExtended(fromText: text, provider: .claude)

        XCTAssertTrue(result.contains("msg-1"), "Anfangs-Messages müssen erhalten bleiben")
        XCTAssertTrue(result.contains("msg-30"), "Ende-Messages müssen erhalten bleiben")
        XCTAssertTrue(result.contains("trimmed for brevity"), "Truncation-Marker erwartet bei > 24 Messages")
    }

    func testBuildExtendedShortSessionContainsAllMessages() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn"}}"#
        ]
        let result = AgentTranscriptExcerpt.buildExtended(fromText: lines.joined(separator: "\n"), provider: .claude)
        XCTAssertTrue(result.contains("hi"))
        XCTAssertTrue(result.contains("hello"))
        XCTAssertFalse(result.contains("trimmed"))
    }
}
