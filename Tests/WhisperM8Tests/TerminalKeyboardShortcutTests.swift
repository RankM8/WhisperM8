import Foundation
import XCTest
@testable import WhisperM8

final class TerminalKeyboardShortcutTests: XCTestCase {
    // MARK: - Terminal Keyboard Shortcuts (Claude Code / Codex / Readline)

    func testTerminalShortcutOptionBackspaceMapsToCtrlW() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.option],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x17])
    }

    func testTerminalShortcutCommandBackspaceMapsToCtrlU() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.command],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x15])
    }

    func testTerminalShortcutCommandZMapsToReadlineUndo() {
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.command],
            characters: "z"
        )
        XCTAssertEqual(bytes, [0x1f])
    }

    func testTerminalShortcutCommandShiftZIsNotIntercepted() {
        // Cmd+Shift+Z (Redo) → durchreichen, Readline kennt kein Redo.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.command, .shift],
            characters: "Z"
        )
        XCTAssertNil(bytes)
    }

    func testTerminalShortcutOptionArrowsMapToWordMovement() {
        let leftBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.leftArrow,
            modifiers: [.option],
            characters: nil
        )
        let rightBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.rightArrow,
            modifiers: [.option],
            characters: nil
        )
        XCTAssertEqual(leftBytes, [0x1b, 0x62])   // Esc+B
        XCTAssertEqual(rightBytes, [0x1b, 0x66])  // Esc+F
    }

    func testTerminalShortcutCommandArrowsMapToLineMovement() {
        let leftBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.leftArrow,
            modifiers: [.command],
            characters: nil
        )
        let rightBytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.rightArrow,
            modifiers: [.command],
            characters: nil
        )
        XCTAssertEqual(leftBytes, [0x01])  // Ctrl+A
        XCTAssertEqual(rightBytes, [0x05]) // Ctrl+E
    }

    func testTerminalShortcutPlainBackspaceIsNotIntercepted() {
        // Ohne Modifier soll SwiftTerms Default greifen (sendet 0x7f).
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [],
            characters: nil
        )
        XCTAssertNil(bytes)
    }

    func testTerminalShortcutShiftEnterChatProfileBackslashContinuation() {
        // Im normalen Claude-Code-/Codex-Chat soll Shift+Enter als
        // Backslash-Continuation (`\<CR>`) gesendet werden.
        let bytesClaude = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .claudeCodeChat
        )
        let bytesCodex = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .codexChat
        )
        XCTAssertEqual(bytesClaude, [0x5c, 0x0d])
        XCTAssertEqual(bytesCodex, [0x5c, 0x0d])
    }

    func testTerminalShortcutShiftEnterAgentsViewProfileSendsCsiU() {
        // `claude agents` hat keine Backslash-Continuation — Shift+Enter
        // muss als kitty/CSI-u-Sequenz `ESC [ 13 ; 2 u` gesendet werden,
        // damit das Input-Field einen Soft-Newline einfuegt.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil,
            profile: .claudeAgentsView
        )
        XCTAssertEqual(bytes, [0x1b, 0x5b, 0x31, 0x33, 0x3b, 0x32, 0x75])
    }

    func testTerminalShortcutPlainEnterIsNotIntercepted() {
        // Ohne Shift soll Enter durchgereicht werden — sonst killt unser
        // Mapping den normalen Submit.
        for profile in [TerminalKeyboardProfile.claudeCodeChat,
                        .codexChat,
                        .claudeAgentsView] {
            let bytes = TerminalShortcut.bytes(
                keyCode: TerminalShortcut.KeyCode.returnKey,
                modifiers: [],
                characters: nil,
                profile: profile
            )
            XCTAssertNil(bytes, "Enter ohne Modifier muss in \(profile) durchgereicht werden")
        }
    }

    func testTerminalShortcutDefaultProfileIsClaudeCodeChat() {
        // Bestandstests rufen `bytes(...)` ohne profile-Argument auf — das
        // Default muss daher das Chat-Mapping liefern, sonst brechen die
        // alten Aufrufer.
        let bytes = TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.returnKey,
            modifiers: [.shift],
            characters: nil
        )
        XCTAssertEqual(bytes, [0x5c, 0x0d])
    }

    func testTerminalShortcutControlCombosAreNotIntercepted() {
        // Wenn der User Control hält, soll SwiftTerm seine Standard-Control-
        // Sequences durchgeben (Ctrl+W = 0x17, Ctrl+U = 0x15 etc.) — wir
        // konkurrieren nicht damit.
        XCTAssertNil(TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.delete,
            modifiers: [.control, .option],
            characters: nil
        ))
        XCTAssertNil(TerminalShortcut.bytes(
            keyCode: TerminalShortcut.KeyCode.z,
            modifiers: [.control, .command],
            characters: "z"
        ))
    }
}
