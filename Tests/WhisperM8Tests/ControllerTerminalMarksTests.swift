import AppKit
import XCTest
@testable import WhisperM8

/// Merker der Controller-Schutzregeln je Chat-Terminal (Review nach Runde 3,
/// Befunde 1 und 5).
final class ControllerTerminalMarksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Auswahl offen (Befund 1a)

    func testChoiceListStaysOpenWhileUsedAndExpiresAfterTwoMinutesOfRest() {
        var marks = ControllerTerminalMarks()
        XCTAssertFalse(marks.isChoiceListOpen(at: t0))
        marks.choiceListOpened(at: t0)
        XCTAssertTrue(marks.isChoiceListOpen(at: at(119)))
        XCTAssertFalse(marks.isChoiceListOpen(at: at(120)), "zwei Minuten Ruhe")

        marks.choiceListOpened(at: t0)
        marks.recordControllerKey(.down, status: .idle, isCodex: false, at: at(100))
        XCTAssertTrue(marks.isChoiceListOpen(at: at(200)), "Bewegung verlängert")
        marks.recordControllerKey(.space, status: .idle, isCodex: false, at: at(210))
        XCTAssertTrue(marks.isChoiceListOpen(at: at(320)), "Leerzeichen (/config) verlängert")
    }

    /// Ein Pfeil (etwa in einer Rückfrage) öffnet eine verfallene Liste nie wieder.
    func testUseNeverReopensAnExpiredList() {
        var marks = ControllerTerminalMarks()
        marks.choiceListOpened(at: t0)
        marks.recordControllerKey(.up, status: .awaitingInput, isCodex: false, at: at(130))
        XCTAssertFalse(marks.isChoiceListOpen(at: at(131)))
        var fresh = ControllerTerminalMarks()
        fresh.recordControllerKey(.up, status: .awaitingInput, isCodex: false, at: t0)
        XCTAssertFalse(fresh.isChoiceListOpen(at: t0))
    }

    func testEnterEscapeAndEditingKeysCloseTheList() {
        for key in [TerminalControlKey.enter, .escape, .backspace, .deleteWord, .tab, .backTab, .killLineStart] {
            var marks = ControllerTerminalMarks()
            marks.choiceListOpened(at: t0)
            marks.recordControllerKey(key, status: .idle, isCodex: false, at: at(1))
            XCTAssertFalse(marks.isChoiceListOpen(at: at(1)), "\(key)")
        }
    }

    func testKeyboardEnterAndEscapeCloseTheList() {
        var marks = ControllerTerminalMarks()
        marks.choiceListOpened(at: t0)
        marks.recordKeyboard(keyCode: 125, modifiers: [], at: at(1))
        XCTAssertTrue(marks.isChoiceListOpen(at: at(1)), "Pfeil der Tastatur bewegt nur")
        marks.recordKeyboard(keyCode: 53, modifiers: [], at: at(2))
        XCTAssertFalse(marks.isChoiceListOpen(at: at(2)))

        marks.choiceListOpened(at: at(3))
        marks.recordKeyboard(keyCode: 36, modifiers: [], at: at(4))
        XCTAssertFalse(marks.isChoiceListOpen(at: at(4)))
    }

    // MARK: - Absenden auf jedem Weg (Befund 5)

    func testLastSubmitCoversControllerKeyboardAndProgrammaticSubmits() {
        var marks = ControllerTerminalMarks()
        XCTAssertNil(marks.lastSubmitAt(programmatic: nil))
        XCTAssertEqual(marks.lastSubmitAt(programmatic: at(5)), at(5), "chats send, Diktat, Menü")
        marks.recordControllerKey(.enter, status: .awaitingInput, isCodex: false, at: at(6))
        XCTAssertEqual(marks.lastSubmitAt(programmatic: at(5)), at(6), "Kreuz auch in einer Rückfrage")
        marks.recordKeyboard(keyCode: 36, modifiers: [], at: at(7))
        XCTAssertEqual(marks.lastSubmitAt(programmatic: at(5)), at(7), "Enter der Tastatur")
        marks.recordKeyboard(keyCode: 36, modifiers: .shift, at: at(8))
        marks.recordKeyboard(keyCode: 76, modifiers: .option, at: at(9))
        XCTAssertEqual(marks.lastSubmitAt(programmatic: nil), at(7), "Shift/Option+Enter ist ein Zeilenumbruch")
    }

    /// Der Fall aus dem Review: In einer Rückfrage „Other“ tippen und mit
    /// Kreuz bestätigen. Danach darf die Eingabe Kreuz nicht 30 s lang für
    /// einen neuen Freigabe-Dialog scharf halten.
    func testEnterInsideQuestionEndsTheFreshDraftInput() {
        var marks = ControllerTerminalMarks()
        marks.recordControllerKey(.space, status: .awaitingInput, isCodex: false, at: t0)
        marks.recordControllerKey(.enter, status: .awaitingInput, isCodex: false, at: at(1))
        XCTAssertNotNil(marks.lastDraftInputAt, "die Rückfrage leert das Eingabefeld nicht")
        XCTAssertFalse(ControllerTerminalMarks.hasFreshDraftInput(
            draftAt: marks.lastDraftInputAt, lastSubmitAt: marks.lastSubmitAt(programmatic: nil),
            window: 30, now: at(2)))
    }

    func testFreshDraftInputNeedsToBeNewerThanTheLastSubmit() {
        func fresh(_ draft: Date?, _ submit: Date?, now: Date) -> Bool {
            ControllerTerminalMarks.hasFreshDraftInput(draftAt: draft, lastSubmitAt: submit, window: 30, now: now)
        }
        XCTAssertFalse(fresh(nil, nil, now: t0))
        XCTAssertTrue(fresh(t0, nil, now: at(29)))
        XCTAssertFalse(fresh(t0, nil, now: at(30)), "30 s")
        XCTAssertTrue(fresh(at(2), at(1), now: at(3)), "Eingabe nach dem Absenden")
        XCTAssertFalse(fresh(at(1), at(2), now: at(3)), "Absenden danach (chats send, Tastatur …)")
        XCTAssertFalse(fresh(at(1), at(1), now: at(3)))
    }

    /// Codex: Ein Pfeil per Controller zählt als Eingabe, damit Kreuz eine
    /// Freigabe bestätigen kann, die Codex nie als Rückfrage meldet.
    func testCodexArrowCountsAsInputClaudeArrowDoesNot() {
        var codex = ControllerTerminalMarks()
        codex.recordControllerKey(.down, status: .working, isCodex: true, at: t0)
        XCTAssertEqual(codex.lastDraftInputAt, t0)
        var claude = ControllerTerminalMarks()
        claude.recordControllerKey(.down, status: .awaitingInput, isCodex: false, at: t0)
        XCTAssertNil(claude.lastDraftInputAt)
    }
}
