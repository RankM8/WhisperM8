import AppKit
import XCTest
@testable import WhisperM8

/// Erkennung des Ctrl+Tab-Switchers: Ctrl+Tab (vorwärts) / Ctrl+Shift+Tab
/// (rückwärts), robust gegen Zusatz-Flags, die macOS an Events hängt.
final class TabSwitcherShortcutTests: XCTestCase {
    private let tab = TabSwitcherShortcut.KeyCode.tab

    func testControlTabIsForward() {
        XCTAssertEqual(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.control]), 1)
    }

    func testControlShiftTabIsBackward() {
        XCTAssertEqual(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.control, .shift]), -1)
    }

    // Zusatz-Flags außerhalb der Maske (CapsLock aktiv, Function-Flag) dürfen
    // den Match nicht brechen — gleiche Lektion wie beim TabNavShortcut.
    func testNoiseFlagsDoNotBreakMatch() {
        XCTAssertEqual(
            TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.control, .capsLock]), 1
        )
        XCTAssertEqual(
            TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.control, .shift, .function]), -1
        )
    }

    // MARK: - Nicht-Treffer

    func testPlainTabDoesNotMatch() {
        // Tab ohne Control = Completion/Fokus-Navigation — gehört der TUI.
        XCTAssertNil(TabSwitcherShortcut.direction(keyCode: tab, modifiers: []))
        XCTAssertNil(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.shift]))
    }

    func testCommandTabDoesNotMatch() {
        // ⌘Tab ist der System-App-Switcher.
        XCTAssertNil(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.command]))
        XCTAssertNil(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.command, .control]))
    }

    func testControlOptionTabDoesNotMatch() {
        XCTAssertNil(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.control, .option]))
    }

    // MARK: - ⌃⌥Tab (nächster wartender Chat) — getrennt vom Switcher

    func testControlOptionTabIsNextWaitingChat() {
        XCTAssertTrue(TabSwitcherShortcut.isNextWaitingChat(keyCode: tab, modifiers: [.control, .option]))
        // Zusatz-Flags brechen den Match nicht.
        XCTAssertTrue(TabSwitcherShortcut.isNextWaitingChat(
            keyCode: tab, modifiers: [.control, .option, .capsLock, .function]
        ))
    }

    func testOtherCombosAreNotNextWaitingChat() {
        for modifiers: NSEvent.ModifierFlags in [
            [.control], [.control, .shift], [.option], [.command, .option],
            [.control, .option, .shift], [.control, .option, .command], [],
        ] {
            XCTAssertFalse(
                TabSwitcherShortcut.isNextWaitingChat(keyCode: tab, modifiers: modifiers),
                "\(modifiers)"
            )
        }
        XCTAssertFalse(TabSwitcherShortcut.isNextWaitingChat(
            keyCode: TabSwitcherShortcut.KeyCode.escape, modifiers: [.control, .option]
        ))
    }

    func testSwitcherAndNextWaitingChatNeverOverlap() {
        // ⌃⌥Tab löst den Switcher nicht aus, ⌃Tab/⌃⇧Tab nicht den Sprung.
        XCTAssertNil(TabSwitcherShortcut.direction(keyCode: tab, modifiers: [.control, .option]))
        XCTAssertFalse(TabSwitcherShortcut.isNextWaitingChat(keyCode: tab, modifiers: [.control]))
        XCTAssertFalse(TabSwitcherShortcut.isNextWaitingChat(keyCode: tab, modifiers: [.control, .shift]))
    }

    func testNonTabKeyDoesNotMatch() {
        // Escape (53) mit Control → kein Switcher-Schritt.
        XCTAssertNil(TabSwitcherShortcut.direction(
            keyCode: TabSwitcherShortcut.KeyCode.escape, modifiers: [.control]
        ))
    }
}
