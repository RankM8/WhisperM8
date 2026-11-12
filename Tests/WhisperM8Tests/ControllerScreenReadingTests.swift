import XCTest
@testable import WhisperM8

/// Runde 5, R2: offene Claude-Ansichten und das Eingabefeld am unteren Rand.
/// Die Hinweistexte stammen aus Claude Code 2.1.322.
final class ControllerScreenReadingTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)

    private func screen(_ lines: [String], cursor: (row: Int, col: Int)? = nil) -> ControllerScreenSnapshot {
        ControllerScreenReading.read(lines: lines, cursor: cursor, detectViews: true)
    }

    // MARK: - Ansichten

    func testTranscriptView() {
        let lines = ["⏺ Bash(ls)", "  ⎿ README.md", "",
                     "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll · v to open in editor"]
        XCTAssertEqual(screen(lines).openView, .transcript)
    }

    func testWorkflowsInBothStyles() {
        XCTAssertEqual(screen(["Dynamic workflows", "  ❯ review-pr",
                               "↑/↓ to select · Enter to view · x to stop · s to save · Esc to close"]).openView,
                       .workflows)
        XCTAssertEqual(screen(["Dynamic workflows", "↑↓ select · enter view · x stop · s save · esc close"]).openView,
                       .workflows)
    }

    func testTasksDialog() {
        XCTAssertEqual(screen(["Background", "  ❯ npm test (running)",
                               "↑/↓ to select · Enter to view · x to stop · Esc to close"]).openView, .tasks)
        XCTAssertEqual(screen(["npm test", "output …", "x to stop · Esc to go back"]).openView, .tasks)
        XCTAssertEqual(screen(["Background", "↑↓ select · enter view · x stop · esc close"]).openView, .tasks)
    }

    func testRewindNeedsTitleAndCancel() {
        XCTAssertEqual(screen(["Rewind", "  ❯ Fix the tests", "Enter to continue · Esc to cancel"]).openView, .rewind)
        XCTAssertEqual(screen(["Confirm you want to restore", "Enter to continue · Esc to cancel"]).openView, .rewind)
        // „Esc to cancel“ allein ist zu allgemein.
        XCTAssertNil(screen(["Some dialog", "Enter to continue · Esc to cancel"]).openView)
    }

    func testFooterSelectionKeepsThePromptBox() {
        let lines = [rule, "❯ ", rule, "  ⏵⏵ accept edits on",
                     "  ❯ 2 agents · Enter to view · x to stop · Esc to collapse · ctrl+x ctrl+k to stop all agents"]
        let snapshot = screen(lines, cursor: (1, 2))
        XCTAssertEqual(snapshot.openView, .footerSelection)
        XCTAssertNotNil(snapshot.promptField)
    }

    /// Chat-Text über dem Eingabefeld darf keine Ansicht vortäuschen.
    func testHintQuotedInChatAboveThePromptIsIgnored() {
        let lines = ["⏺ Die Fußzeile zeigt „Showing detailed transcript“ und „s to save“.",
                     "  Rewind … Esc to cancel · x to stop · Esc to close",
                     rule, "❯ weiter", rule, "  ? for shortcuts"]
        XCTAssertNil(screen(lines, cursor: (3, 9)).openView)
    }

    func testNoViewsForCodex() {
        let lines = ["Showing detailed transcript"]
        XCTAssertNil(ControllerScreenReading.read(lines: lines, cursor: nil, detectViews: false).openView)
    }

    // MARK: - Eingabefeld

    func testEmptyPromptIsVisiblyEmpty() {
        let field = screen(["⏺ Fertig.", rule, "❯ ", rule, "  ? for shortcuts"], cursor: (2, 2)).promptField
        XCTAssertEqual(field?.rows, 1)
        XCTAssertEqual(field?.isEmpty, true)
        XCTAssertEqual(field?.hasText, false)
    }

    func testTextWithCursorAtEndCountsAsText() {
        let field = screen([rule, "❯ bitte die Tests", rule], cursor: (1, 17)).promptField
        XCTAssertEqual(field?.isEmpty, false)
        XCTAssertEqual(field?.hasText, true)
    }

    /// Ein nicht abgeblendeter Platzhalter steht im leeren Feld mit dem Cursor
    /// am Anfang: kein sicherer Text, aber auch nicht sichtbar leer.
    func testPlaceholderWithCursorAtStartIsAmbiguous() {
        let field = screen([rule, "❯ Try \"refactor the parser\"", rule], cursor: (1, 2)).promptField
        XCTAssertEqual(field?.isEmpty, false)
        XCTAssertEqual(field?.hasText, false)
    }

    func testMultiLineDraftWithCursorRow() {
        let lines = [rule, "❯ erste Zeile", "  zweite Zeile", "  dritte Zeile", rule, "  footer"]
        let field = screen(lines, cursor: (2, 8)).promptField
        XCTAssertEqual(field?.rows, 3)
        XCTAssertEqual(field?.cursorRow, 1)
        XCTAssertEqual(field?.hasText, true)
    }

    func testCursorOutsideTheFieldIsUnknown() {
        let field = screen([rule, "❯ text", rule, "footer"], cursor: (3, 0)).promptField
        XCTAssertNil(field?.cursorRow)
        XCTAssertEqual(field?.hasText, false, "ohne Cursor im Feld kein sicherer Text")
    }

    func testOldBoxedPrompt() {
        let lines = ["╭" + rule + "╮", "│ > hallo  │", "╰" + rule + "╯"]
        let field = screen(lines, cursor: (1, 9)).promptField
        XCTAssertEqual(field?.rows, 1)
        XCTAssertEqual(field?.isEmpty, false)
    }

    func testNoPromptBoxWithoutPromptCharacter() {
        XCTAssertNil(screen([rule, "  some table row", rule]).promptField)
    }

    // MARK: - ← im Feld

    func testLeftArrowRule() {
        let empty = ControllerScreenSnapshot(promptField: .init(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: true))
        let text = ControllerScreenSnapshot(promptField: .init(rows: 1, cursorRow: 0, cursorAtStart: false, isEmpty: false))
        let ambiguous = ControllerScreenSnapshot(promptField: .init(rows: 1, cursorRow: 0, cursorAtStart: true, isEmpty: false))
        // Sichtbar leer sperrt, auch wenn der Tracker Text vermutet.
        XCTAssertFalse(ControllerScreenReading.fieldMayHaveText(screen: empty, tracker: true))
        XCTAssertTrue(ControllerScreenReading.fieldMayHaveText(screen: text, tracker: false))
        XCTAssertFalse(ControllerScreenReading.fieldMayHaveText(screen: ambiguous, tracker: false))
        XCTAssertTrue(ControllerScreenReading.fieldMayHaveText(screen: ambiguous, tracker: true))
        XCTAssertFalse(ControllerScreenReading.fieldMayHaveText(screen: nil, tracker: false))
        XCTAssertTrue(ControllerScreenReading.fieldMayHaveText(
            screen: ControllerScreenSnapshot(openView: .tasks), tracker: false))
    }
}
