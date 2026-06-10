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
}
