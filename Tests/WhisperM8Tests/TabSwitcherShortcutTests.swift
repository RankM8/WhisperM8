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

    // MARK: - Tasten bei aktivem Switcher

    private typealias Action = TabSwitcherShortcut.ActiveKeyAction
    private let escape = TabSwitcherShortcut.KeyCode.escape
    private let returnKey = TabSwitcherShortcut.KeyCode.returnKey

    private func active(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Action {
        TabSwitcherShortcut.activeKeyAction(keyCode: keyCode, modifiers: modifiers)
    }

    func testActiveStepsWithControlTab() {
        XCTAssertEqual(active(tab, [.control]), .step(1))
        XCTAssertEqual(active(tab, [.control, .shift]), .step(-1))
    }

    func testActiveArrowsWithControlNavigate() {
        // Pfeile tragen .function/.numericPad — der Match darf daran nicht scheitern.
        XCTAssertEqual(active(123, [.control, .function, .numericPad]), .arrow(.left))
        XCTAssertEqual(active(124, [.control]), .arrow(.right))
        XCTAssertEqual(active(125, [.control, .shift]), .arrow(.down))
        XCTAssertEqual(active(126, [.control, .function]), .arrow(.up))
    }

    func testActiveEscapeAndReturnWithOrWithoutControl() {
        XCTAssertEqual(active(escape, []), .cancel)
        XCTAssertEqual(active(escape, [.control]), .cancel)
        XCTAssertEqual(active(returnKey, []), .commit)
        XCTAssertEqual(active(returnKey, [.control]), .commit)
    }

    func testActiveOtherKeyWithControlIsSwallowed() {
        // Ctrl+C (keyCode 8) darf nie die TUI erreichen.
        XCTAssertEqual(active(8, [.control]), .cancel)
        // ⌃⌥Tab mitten im Durchlauf: Abbruch, kein Sprung.
        XCTAssertEqual(active(tab, [.control, .option]), .cancel)
    }

    func testActiveKeyWithoutControlCancelsAndPassesThrough() {
        // Ctrl-Loslassen verpasst (Menü-Tracking): die nächste Taste gehört
        // wieder dem Terminal.
        XCTAssertEqual(active(0, []), .cancelAndPassThrough) // „a"
        XCTAssertEqual(active(tab, []), .cancelAndPassThrough)
        XCTAssertEqual(active(tab, [.shift]), .cancelAndPassThrough)
        XCTAssertEqual(active(123, [.function, .numericPad]), .cancelAndPassThrough)
        XCTAssertEqual(active(8, [.command]), .cancelAndPassThrough)
    }

    // MARK: - Modifier-Änderung bei aktivem Switcher

    private func flags(_ previous: NSEvent.ModifierFlags, _ current: NSEvent.ModifierFlags) -> TabSwitcherShortcut.FlagsChangeAction {
        TabSwitcherShortcut.flagsChangeAction(previous: previous, current: current)
    }

    func testControlReleaseCommits() {
        XCTAssertEqual(flags([.control], []), .commit)
        // Shift bleibt gehalten, Ctrl geht → Commit (Ctrl+Shift+Tab-Durchlauf).
        XCTAssertEqual(flags([.control, .shift], [.shift]), .commit)
        // CapsLock aktiv bleibt aktiv.
        XCTAssertEqual(flags([.control, .capsLock], [.capsLock]), .commit)
        // Pfeil-keyDown hinterließ .function — kein Grund für einen Abbruch.
        XCTAssertEqual(flags([.control, .function, .numericPad], []), .commit)
    }

    func testControlStillHeldDoesNothing() {
        XCTAssertEqual(flags([.control], [.control, .shift]), .none)
        XCTAssertEqual(flags([.control, .shift], [.control]), .none)
        XCTAssertEqual(flags([.control], [.control, .option]), .none)
    }

    func testMissedControlReleaseCancels() {
        // Ctrl im Kontextmenü losgelassen, dann Shift gedrückt: Ctrl war
        // zuletzt gesehen gehalten, aber dieses Event hat Shift geändert.
        XCTAssertEqual(flags([.control], [.shift]), .cancel)
        // Shift (seit dem Durchlauf gehalten) losgelassen, Ctrl längst weg.
        XCTAssertEqual(flags([.control, .shift], []), .cancel)
        // CapsLock-Toggle nach verpasstem Ctrl-Loslassen.
        XCTAssertEqual(flags([.control], [.capsLock]), .cancel)
        // Ctrl war schon vorher nicht gehalten.
        XCTAssertEqual(flags([], [.shift]), .cancel)
    }
}
