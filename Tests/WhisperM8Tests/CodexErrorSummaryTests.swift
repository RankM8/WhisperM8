import Foundation
import XCTest
@testable import WhisperM8

/// Phase-3 Test-Seam: deckt die aus `CodexPostProcessor` extrahierte
/// Fehler-Verdichtung ab (Priorisierung der Meldungen, ohne Subprozess).
final class CodexErrorSummaryTests: XCTestCase {
    func testVersionErrorTakesPriority() {
        let output = "irgendwas\nrequires a newer version of Codex\nletzte zeile"
        XCTAssertEqual(
            CodexErrorSummary.concise(from: output),
            "Codex CLI needs an update before post-processing can run."
        )
    }

    func testNotLoggedInIsCaseInsensitive() {
        XCTAssertEqual(
            CodexErrorSummary.concise(from: "Error: not logged in"),
            "Codex is not signed in with ChatGPT."
        )
        XCTAssertEqual(
            CodexErrorSummary.concise(from: "FATAL: NOT LOGGED IN"),
            "Codex is not signed in with ChatGPT."
        )
    }

    func testVersionBeatsLoginWhenBothPresent() {
        let output = "not logged in\nrequires a newer version of Codex"
        XCTAssertEqual(
            CodexErrorSummary.concise(from: output),
            "Codex CLI needs an update before post-processing can run."
        )
    }

    func testFallsBackToLastNonEmptyLine() {
        let output = "first line\nthe real error\n   \n\n"
        XCTAssertEqual(CodexErrorSummary.concise(from: output), "the real error")
    }

    func testEmptyOutputUsesGenericFallback() {
        XCTAssertEqual(CodexErrorSummary.concise(from: ""), "Codex post-processing failed.")
        XCTAssertEqual(CodexErrorSummary.concise(from: "   \n  \n"), "Codex post-processing failed.")
    }
}
