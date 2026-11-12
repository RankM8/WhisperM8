import AppKit
import XCTest
@testable import WhisperM8

/// Merker der Controller-Schutzregeln je Chat-Terminal (Review nach Runde 3,
/// Befunde 1 und 5).
final class ControllerTerminalMarksTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Runde 4: Bis Zeilenanfang löschen und Zeilenumbruch (L1-Ebene) sind
    /// Eingaben ins Feld: Sie schließen eine Auswahl und halten Kreuz für die
    /// 30-s-Regel scharf.
    func testLayerWritingKeysCountAsDraftInput() {
        for key in [TerminalControlKey.killLineStart, .newline] {
            var marks = ControllerTerminalMarks()
            marks.choiceListOpened(at: t0)
            marks.recordControllerKey(key, status: .idle, at: at(1))
            XCTAssertFalse(marks.isChoiceListOpen(at: at(2)), "\(key)")
            XCTAssertEqual(marks.lastDraftInputAt, at(1), "\(key)")
        }
    }

    // MARK: - Auswahl offen (Befund 1a)

    /// Feste Höchstdauer ab dem Öffnen: Pfeile und Leerzeichen halten die
    /// Liste offen, verlängern sie aber nicht (Nachreview).
    func testChoiceListHasFixedLifetimeFromOpening() {
        var marks = ControllerTerminalMarks()
        XCTAssertFalse(marks.isChoiceListOpen(at: t0))
        marks.choiceListOpened(at: t0)
        XCTAssertTrue(marks.isChoiceListOpen(at: at(119)))
        XCTAssertFalse(marks.isChoiceListOpen(at: at(120)), "zwei Minuten")

        marks.choiceListOpened(at: t0)
        marks.recordControllerKey(.down, status: .idle, at: at(100))
        marks.recordControllerKey(.space, status: .idle, at: at(110))
        XCTAssertTrue(marks.isChoiceListOpen(at: at(111)), "Pfeil und Leerzeichen schließen nicht")
        XCTAssertFalse(marks.isChoiceListOpen(at: at(121)), "und verlängern nicht")
    }

    /// Nachreview, Lücke 2: „/“ aus dem Menü, dann mit der Rücktaste der
    /// Tastatur gelöscht — das Feld ist leer, der Merker muss weg. Jede
    /// Tastatur-Taste außer Pfeilen und Leerzeichen schließt die Liste.
    func testEveryKeyboardKeyExceptArrowsAndSpaceClosesTheList() {
        for keyCode: UInt16 in [123, 124, 125, 126, 49] {
            var marks = ControllerTerminalMarks()
            marks.choiceListOpened(at: t0)
            marks.recordKeyboard(keyCode: keyCode, modifiers: [], at: at(1))
            XCTAssertTrue(marks.isChoiceListOpen(at: at(1)), "\(keyCode) bewegt nur")
        }
        // Rücktaste, Buchstabe, Tab, Return, Escape, Ctrl+U, Cmd+Pfeil.
        let closing: [(UInt16, NSEvent.ModifierFlags)] = [
            (51, []), (0, []), (48, []), (36, []), (53, []), (32, .control), (123, .command),
        ]
        for (keyCode, modifiers) in closing {
            var marks = ControllerTerminalMarks()
            marks.choiceListOpened(at: t0)
            marks.recordKeyboard(keyCode: keyCode, modifiers: modifiers, at: at(1))
            XCTAssertFalse(marks.isChoiceListOpen(at: at(1)), "\(keyCode) \(modifiers)")
        }
    }

    /// Nachreview, Lücke 1: Bei Claude gilt der Merker nur im Ruhezustand.
    /// Arbeitet oder fragt der Chat, wird er beim Lesen gelöscht und lebt
    /// bei der Rückkehr zu „ruht“ nicht wieder auf. Codex bleibt zeitgebunden.
    func testClaudeChoiceListOnlyCountsWhileIdle() {
        var marks = ControllerTerminalMarks()
        marks.choiceListOpened(at: t0)
        XCTAssertTrue(marks.checkedChoiceListOpen(at: at(1), status: .idle, isClaude: true))
        for status in [AgentSessionRuntimeStatus.working, .awaitingInput] {
            var copy = marks
            XCTAssertFalse(copy.checkedChoiceListOpen(at: at(2), status: status, isClaude: true), "\(status)")
            XCTAssertFalse(copy.checkedChoiceListOpen(at: at(3), status: .idle, isClaude: true), "gelöscht")
        }
        var unknown = marks
        XCTAssertFalse(unknown.checkedChoiceListOpen(at: at(2), status: nil, isClaude: true))

        var codex = ControllerTerminalMarks()
        codex.choiceListOpened(at: t0)
        XCTAssertTrue(codex.checkedChoiceListOpen(at: at(2), status: .working, isClaude: false))
        XCTAssertFalse(codex.checkedChoiceListOpen(at: at(120), status: .idle, isClaude: false))
    }

    /// Ein Pfeil (etwa in einer Rückfrage) öffnet eine verfallene Liste nie wieder.
    func testUseNeverReopensAnExpiredList() {
        var marks = ControllerTerminalMarks()
        marks.choiceListOpened(at: t0)
        marks.recordControllerKey(.up, status: .awaitingInput, at: at(130))
        XCTAssertFalse(marks.isChoiceListOpen(at: at(131)))
        var fresh = ControllerTerminalMarks()
        fresh.recordControllerKey(.up, status: .awaitingInput, at: t0)
        XCTAssertFalse(fresh.isChoiceListOpen(at: t0))
    }

    func testEnterEscapeAndEditingKeysCloseTheList() {
        for key in [TerminalControlKey.enter, .escape, .backspace, .deleteWord, .tab, .backTab, .killLineStart] {
            var marks = ControllerTerminalMarks()
            marks.choiceListOpened(at: t0)
            marks.recordControllerKey(key, status: .idle, at: at(1))
            XCTAssertFalse(marks.isChoiceListOpen(at: at(1)), "\(key)")
        }
    }

    // MARK: - Absenden auf jedem Weg (Befund 5)

    func testLastSubmitCoversControllerKeyboardAndProgrammaticSubmits() {
        var marks = ControllerTerminalMarks()
        XCTAssertNil(marks.lastSubmitAt(programmatic: nil))
        XCTAssertEqual(marks.lastSubmitAt(programmatic: at(5)), at(5), "chats send, Diktat, Menü")
        marks.recordControllerKey(.enter, status: .awaitingInput, at: at(6))
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
        marks.recordControllerKey(.space, status: .awaitingInput, at: t0)
        marks.recordControllerKey(.enter, status: .awaitingInput, at: at(1))
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

    /// Ein Pfeil per Controller zählt als Eingabe, damit Kreuz danach auch bei
    /// „arbeitet“ bestätigen kann (Codex-Freigaben, Claudes Workflow- und
    /// Subagenten-Ansichten).
    func testArrowCountsAsInput() {
        for status in [AgentSessionRuntimeStatus.working, .awaitingInput, .idle] {
            var marks = ControllerTerminalMarks()
            marks.recordControllerKey(.down, status: status, at: t0)
            XCTAssertEqual(marks.lastDraftInputAt, t0, "\(status)")
        }
    }
}
