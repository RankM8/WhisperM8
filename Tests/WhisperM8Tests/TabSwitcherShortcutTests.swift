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

    func testNonTabKeyDoesNotMatch() {
        // Escape (53) mit Control → kein Switcher-Schritt.
        XCTAssertNil(TabSwitcherShortcut.direction(
            keyCode: TabSwitcherShortcut.KeyCode.escape, modifiers: [.control]
        ))
    }
}
