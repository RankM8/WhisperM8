import XCTest
@testable import WhisperM8

/// LR-CLI-001: Ein eingebettetes Paste-Ende (ESC[201~) beendete den
/// Bracketed-Paste-Modus vorzeitig, der Rest kam als getippte Tasten an.
final class TerminalPasteSanitizerTests: XCTestCase {
    func testEmbeddedPasteEndAndControlBytesAreRemoved() {
        let hostile = "harmlos\u{1B}[201~\n/exit\n\u{1B}[200~weiter\u{9B}31m\u{07}\u{7F}"
        let clean = TerminalPasteSanitizer.sanitize(hostile)
        XCTAssertFalse(clean.contains("\u{1B}"))
        XCTAssertFalse(clean.contains("\u{9B}"))
        XCTAssertFalse(clean.contains("\u{07}"))
        XCTAssertFalse(clean.contains("\u{7F}"))
        XCTAssertEqual(clean, "harmlos\n/exit\nweiter")
    }

    func testTabsNewlinesAndUnicodeStay() {
        XCTAssertEqual(TerminalPasteSanitizer.sanitize("a\tb\nc äöü 🚀"), "a\tb\nc äöü 🚀")
        XCTAssertEqual(TerminalPasteSanitizer.sanitize("a\r\nb\rc"), "a\nb\nc")
    }

    func testPayloadHasExactlyOneBracketPair() {
        let payload = TerminalPasteSanitizer.bracketedPastePayload("x\u{1B}[201~y\u{1B}[200~z")
        XCTAssertEqual(payload.components(separatedBy: "\u{1B}[200~").count - 1, 1)
        XCTAssertEqual(payload.components(separatedBy: "\u{1B}[201~").count - 1, 1)
        XCTAssertTrue(payload.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(payload.hasSuffix("\u{1B}[201~"))
    }
}
