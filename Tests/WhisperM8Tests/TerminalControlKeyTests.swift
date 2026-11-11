import AppKit
import XCTest
@testable import WhisperM8

/// Tasten, die die App selbst an eine TUI schickt (Controller-Bedienung):
/// Bytes je Cursor-Modus und die Tastencodes für den Entwurfs-Tracker.
final class TerminalControlKeyTests: XCTestCase {
    func testEnterAndEscapeAreRawBytesInBothModes() {
        for applicationCursor in [false, true] {
            XCTAssertEqual(TerminalControlKey.enter.bytes(applicationCursor: applicationCursor), [0x0D])
            XCTAssertEqual(TerminalControlKey.escape.bytes(applicationCursor: applicationCursor), [0x1B])
        }
    }

    func testArrowsInNormalCursorMode() {
        XCTAssertEqual(TerminalControlKey.up.bytes(applicationCursor: false), Array("\u{1b}[A".utf8))
        XCTAssertEqual(TerminalControlKey.down.bytes(applicationCursor: false), Array("\u{1b}[B".utf8))
        XCTAssertEqual(TerminalControlKey.right.bytes(applicationCursor: false), Array("\u{1b}[C".utf8))
        XCTAssertEqual(TerminalControlKey.left.bytes(applicationCursor: false), Array("\u{1b}[D".utf8))
    }

    func testArrowsInApplicationCursorMode() {
        XCTAssertEqual(TerminalControlKey.up.bytes(applicationCursor: true), Array("\u{1b}OA".utf8))
        XCTAssertEqual(TerminalControlKey.down.bytes(applicationCursor: true), Array("\u{1b}OB".utf8))
        XCTAssertEqual(TerminalControlKey.right.bytes(applicationCursor: true), Array("\u{1b}OC".utf8))
        XCTAssertEqual(TerminalControlKey.left.bytes(applicationCursor: true), Array("\u{1b}OD".utf8))
    }

    func testTabAndBackTab() {
        XCTAssertEqual(TerminalControlKey.tab.bytes(applicationCursor: false), [0x09])
        XCTAssertEqual(TerminalControlKey.backTab.bytes(applicationCursor: false), Array("\u{1b}[Z".utf8))
        // Der Cursor-Modus ändert Tab und Shift+Tab nicht.
        XCTAssertEqual(TerminalControlKey.backTab.bytes(applicationCursor: true), Array("\u{1b}[Z".utf8))
    }

    /// Runde 2: Rücktaste für Viereck — DEL wie die echte Taste, Tastencode 51.
    func testBackspaceIsDelete() {
        for applicationCursor in [false, true] {
            XCTAssertEqual(TerminalControlKey.backspace.bytes(applicationCursor: applicationCursor), [0x7F])
        }
        XCTAssertEqual(TerminalControlKey.backspace.keyCode, 51)
        XCTAssertEqual(TerminalControlKey.backspace.modifiers, [])
    }

    func testWheelSequencesForAlternateBuffer() {
        XCTAssertEqual(TerminalScrollStep.wheelSequence(up: true), "\u{1b}[<64;1;1M")
        XCTAssertEqual(TerminalScrollStep.wheelSequence(up: false), "\u{1b}[<65;1;1M")
    }

    // MARK: - Wirkung auf den Entwurfs-Tracker

    /// Der Tracker bekommt für jede Taste denselben Tastencode wie bei der
    /// Tastatur. Gegengeprüft an seinem beobachtbaren Verhalten.
    private func tracker(after keys: [TerminalControlKey], status: AgentSessionRuntimeStatus? = .idle,
                         startingWithDraft: Bool) -> TerminalComposerDraftTracker {
        var tracker = TerminalComposerDraftTracker()
        if startingWithDraft { tracker.recordTextInserted() }
        for key in keys {
            tracker.recordTerminalKey(
                keyCode: key.keyCode, modifiers: key.modifiers, status: status,
                restoresPromptOnInterrupt: true, now: Date())
        }
        return tracker
    }

    func testEnterCountsAsSubmit() {
        XCTAssertFalse(tracker(after: [.enter], startingWithDraft: true).mayHaveUnsentInput)
    }

    func testArrowsTabAndEscapeKeepADraft() {
        for key in [TerminalControlKey.up, .down, .left, .right, .tab, .backTab, .escape, .backspace] {
            XCTAssertTrue(
                tracker(after: [key], startingWithDraft: true).mayHaveUnsentInput,
                "\(key) darf einen Entwurf nicht als gesendet melden")
            XCTAssertFalse(
                tracker(after: [key], startingWithDraft: false).mayHaveUnsentInput,
                "\(key) ist kein Text")
        }
    }

    /// In einer Rückfrage bestätigt Enter die Auswahl; ein Entwurf im
    /// Eingabefeld bleibt stehen.
    func testEnterInsideQuestionKeepsDraft() {
        XCTAssertTrue(
            tracker(after: [.enter], status: .awaitingInput, startingWithDraft: true).mayHaveUnsentInput)
    }

    // MARK: - Schreibtasten (Runde 3)

    /// Dreieck: Leerzeichen, Tastencode 49 — der Tracker wertet es als Text.
    func testSpaceIsTypedText() {
        XCTAssertEqual(TerminalControlKey.space.bytes(applicationCursor: false), [0x20])
        XCTAssertEqual(TerminalControlKey.space.keyCode, 49)
        XCTAssertEqual(TerminalControlKey.space.modifiers, [])
        XCTAssertTrue(tracker(after: [.space], startingWithDraft: false).mayHaveUnsentInput)
    }

    /// Wort löschen und Leeren: Ctrl+W, Ctrl+U, Ctrl+E — nie ein ESC-Präfix
    /// (ein einzelnes ESC bricht einen arbeitenden Chat ab).
    func testDeleteWordAndClearKeysAreControlBytesWithoutEscape() {
        XCTAssertEqual(TerminalControlKey.deleteWord.bytes(applicationCursor: false), [0x17])
        XCTAssertEqual(TerminalControlKey.killLineStart.bytes(applicationCursor: true), [0x15])
        XCTAssertEqual(TerminalControlKey.lineEnd.bytes(applicationCursor: false), [0x05])
        for key in [TerminalControlKey.deleteWord, .killLineStart, .lineEnd] {
            XCTAssertEqual(key.modifiers, .control)
            XCTAssertTrue(tracker(after: [key], startingWithDraft: true).mayHaveUnsentInput, "kein Absenden")
            XCTAssertFalse(tracker(after: [key], startingWithDraft: false).mayHaveUnsentInput, "kein Text")
        }
        let all = TerminalControlKey.clearInputBursts.flatMap { $0 }.flatMap { $0.bytes(applicationCursor: false) }
        XCTAssertFalse(all.contains(0x1B))
        XCTAssertFalse(all.contains(0x03), "nie Ctrl+C")
    }

    /// Leeren: zuerst ans Zeilenende, dann genug Ctrl+U für 64 Zeilen, in Stößen.
    func testClearInputBursts() {
        let bursts = TerminalControlKey.clearInputBursts
        XCTAssertEqual(bursts.first?.first, .lineEnd)
        XCTAssertEqual(bursts.flatMap { $0 }.filter { $0 == .killLineStart }.count, 128)
        XCTAssertTrue(bursts.allSatisfy { $0.count <= 17 })
    }

    /// Absicherung: Leeren nie in einer Rückfrage; Leerzeichen und Wort löschen überall.
    func testControllerGuardForWritingKeys() {
        XCTAssertFalse(TerminalControlKey.controllerAllows(.killLineStart, status: .awaitingInput))
        XCTAssertTrue(TerminalControlKey.controllerAllows(.killLineStart, status: .working))
        XCTAssertTrue(TerminalControlKey.controllerAllows(.space, status: .awaitingInput))
        XCTAssertTrue(TerminalControlKey.controllerAllows(.deleteWord, status: nil))
    }

    func testEscapeWhileWorkingMarksRestoredPrompt() {
        XCTAssertTrue(
            tracker(after: [.escape], status: .working, startingWithDraft: false).mayHoldRestoredPrompt)
    }
}
