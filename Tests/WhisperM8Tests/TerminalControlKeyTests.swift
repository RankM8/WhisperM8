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

    /// Runde 4: Zeilenumbruch per Ctrl+J (LF). Der Entwurfs-Tracker sieht
    /// Shift+Return — ein Umbruch im Entwurf, kein Absenden.
    func testNewlineIsLineFeedAndKeepsTheDraft() {
        for applicationCursor in [false, true] {
            XCTAssertEqual(TerminalControlKey.newline.bytes(applicationCursor: applicationCursor), [0x0A])
        }
        XCTAssertEqual(TerminalControlKey.killLineStart.bytes(applicationCursor: false), [0x15])
        XCTAssertTrue(tracker(after: [.newline], startingWithDraft: false).mayHaveUnsentInput)
        XCTAssertTrue(tracker(after: [.newline], startingWithDraft: true).mayHaveUnsentInput)
    }

    /// Zeilenumbruch und Löschen bis Zeilenanfang nur bei Claude und Codex,
    /// nicht in einer Rückfrage.
    func testNewlineAndKillLineOnlyInAgentInputs() {
        for key in [TerminalControlKey.newline, .killLineStart] {
            XCTAssertTrue(TerminalControlKey.controllerAllows(key, status: .idle, profile: .claudeCodeChat, choiceListOpen: false))
            XCTAssertTrue(TerminalControlKey.controllerAllows(key, status: .working, profile: .codexChat, choiceListOpen: false))
            XCTAssertFalse(TerminalControlKey.controllerAllows(key, status: .idle, profile: .plainShell, choiceListOpen: false))
            XCTAssertFalse(TerminalControlKey.controllerAllows(key, status: .awaitingInput, profile: .claudeCodeChat, choiceListOpen: false))
        }
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

    /// Absicherung: Leeren nie in einer Rückfrage; Leerzeichen und Wort löschen
    /// in jedem Zustand — aber nur bei Claude und Codex (Befund 4 nach Runde 3).
    func testControllerGuardForWritingKeys() {
        func allows(_ key: TerminalControlKey, _ status: AgentSessionRuntimeStatus?,
                    _ profile: TerminalKeyboardProfile = .claudeCodeChat) -> Bool {
            TerminalControlKey.controllerAllows(key, status: status, profile: profile, choiceListOpen: false)
        }
        XCTAssertFalse(allows(.killLineStart, .awaitingInput))
        XCTAssertTrue(allows(.killLineStart, .working))
        XCTAssertTrue(allows(.space, .awaitingInput))
        XCTAssertTrue(allows(.deleteWord, nil))
        for profile in [TerminalKeyboardProfile.claudeCodeChat, .codexChat] {
            for key in [TerminalControlKey.space, .deleteWord, .killLineStart, .lineEnd] {
                XCTAssertTrue(allows(key, .idle, profile), "\(key) \(profile)")
            }
        }
        for profile in [TerminalKeyboardProfile.plainShell, .claudeAgentsView] {
            for key in [TerminalControlKey.space, .deleteWord, .killLineStart, .lineEnd] {
                XCTAssertFalse(allows(key, .idle, profile), "\(key) \(profile)")
            }
            XCTAssertTrue(allows(.backspace, .idle, profile), "Rücktaste bleibt in \(profile)")
            XCTAssertTrue(allows(.enter, .idle, profile))
        }
    }

    func testEscapeWhileWorkingMarksRestoredPrompt() {
        XCTAssertTrue(
            tracker(after: [.escape], status: .working, startingWithDraft: false).mayHoldRestoredPrompt)
    }

    /// R3 leeren: Shell nur im normalen Puffer, Agent-Chats wie Ctrl+U.
    func testControllerMayClearInput() {
        func may(_ profile: TerminalKeyboardProfile, _ status: AgentSessionRuntimeStatus?, alternate: Bool) -> Bool {
            TerminalControlKey.controllerMayClearInput(
                status: status, profile: profile, alternateBuffer: alternate, choiceListOpen: false)
        }
        XCTAssertTrue(may(.plainShell, nil, alternate: false))
        XCTAssertFalse(may(.plainShell, nil, alternate: true), "nano, vim, less")
        XCTAssertTrue(may(.claudeCodeChat, .idle, alternate: true))
        XCTAssertFalse(may(.claudeCodeChat, .awaitingInput, alternate: true))
        XCTAssertFalse(may(.claudeAgentsView, .idle, alternate: false))
    }
}
