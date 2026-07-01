import AppKit
import XCTest
@testable import WhisperM8

/// Tab-Wechsel-Erkennung: ⌘⌥←/→ (Chrome) + ⌘⇧←/→ (Safari), robust gegen die
/// `.function`/`.numericPad`-Flags, die macOS auf Pfeiltasten setzt.
final class TabNavShortcutTests: XCTestCase {
    private let left = TerminalShortcut.KeyCode.leftArrow
    private let right = TerminalShortcut.KeyCode.rightArrow

    // macOS liefert Pfeiltasten IMMER mit diesen Zusatz-Flags — der Kern des
    // früheren Bugs. Die Tests hängen sie bewusst an, um die Regression zu decken.
    private let arrowNoise: NSEvent.ModifierFlags = [.function, .numericPad]

    func testCommandOptionLeftIsPrevious() {
        XCTAssertEqual(TabNavShortcut.direction(keyCode: left, modifiers: [.command, .option]), -1)
    }

    func testCommandOptionRightIsNext() {
        XCTAssertEqual(TabNavShortcut.direction(keyCode: right, modifiers: [.command, .option]), 1)
    }

    func testCommandShiftLeftIsPrevious() {
        XCTAssertEqual(TabNavShortcut.direction(keyCode: left, modifiers: [.command, .shift]), -1)
    }

    func testCommandShiftRightIsNext() {
        XCTAssertEqual(TabNavShortcut.direction(keyCode: right, modifiers: [.command, .shift]), 1)
    }

    // Regression: mit den realen Pfeiltasten-Flags muss es weiterhin greifen.
    func testArrowNoiseFlagsDoNotBreakMatch() {
        XCTAssertEqual(TabNavShortcut.direction(keyCode: left, modifiers: [.command, .option, .function, .numericPad]), -1)
        XCTAssertEqual(TabNavShortcut.direction(keyCode: right, modifiers: [.command, .shift, .function, .numericPad]), 1)
    }

    // MARK: - Nicht-Treffer

    func testCommandOnlyDoesNotMatch() {
        XCTAssertNil(TabNavShortcut.direction(keyCode: left, modifiers: [.command]))
    }

    func testCommandOptionShiftDoesNotMatch() {
        XCTAssertNil(TabNavShortcut.direction(keyCode: left, modifiers: [.command, .option, .shift]))
    }

    func testCommandControlDoesNotMatch() {
        XCTAssertNil(TabNavShortcut.direction(keyCode: left, modifiers: [.command, .control]))
    }

    func testNonArrowKeyDoesNotMatch() {
        // 'w' = keyCode 13; mit ⌘⌥ trotzdem kein Tab-Wechsel.
        XCTAssertNil(TabNavShortcut.direction(keyCode: 13, modifiers: [.command, .option]))
    }
}
