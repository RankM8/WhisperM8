import AppKit
import XCTest
@testable import WhisperM8

final class ClipboardSettingsAndKeysTests: XCTestCase {
    // MARK: Einstellungen

    func testDefaultsAreOffAndSafe() {
        let settings = ClipboardSettings.read { _ in nil }
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.paused)
        XCTAssertEqual(settings.maxItems, 200)
        XCTAssertTrue(settings.autoPaste)
        XCTAssertTrue(settings.agentAccess)
        XCTAssertTrue(settings.maskSecrets)
        XCTAssertFalse(settings.clearOnQuit)
        XCTAssertEqual(settings.windowPosition, .cursor)
        XCTAssertTrue(settings.excludedApps.contains("com.1password.1password"))
        XCTAssertTrue(settings.excludedApps.contains("com.bitwarden.desktop"))
        XCTAssertTrue(settings.excludedApps.contains("com.apple.keychainaccess"))
        XCTAssertTrue(settings.excludedApps.contains("com.apple.Passwords"))
        XCTAssertTrue(settings.excludedApps.contains("org.keepassxc.keepassxc"))
    }

    func testReadsStoredValuesAndClampsMaxItems() {
        let values: [String: Any] = [
            ClipboardPreferenceKeys.enabled: true,
            ClipboardPreferenceKeys.maxItems: 5,
            ClipboardPreferenceKeys.windowPosition: "center",
            ClipboardPreferenceKeys.agentAccess: false,
            ClipboardPreferenceKeys.excludedApps: ClipboardSettings.encodeApps(["a.b.c"]),
        ]
        let settings = ClipboardSettings.read { values[$0] }
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.maxItems, ClipboardSettings.maxItemsRange.lowerBound)
        XCTAssertEqual(settings.windowPosition, .center)
        XCTAssertFalse(settings.agentAccess)
        XCTAssertEqual(settings.excludedApps, ["a.b.c"])
    }

    func testBrokenExcludedAppsFallBackToDefaults() {
        XCTAssertEqual(ClipboardSettings.decodeApps("kaputt"), ClipboardSettings.defaultExcludedApps)
        XCTAssertEqual(ClipboardSettings.decodeApps(ClipboardSettings.encodeApps([])), [])
    }

    // MARK: Tasten

    private func resolve(_ keyCode: UInt16, _ chars: String? = nil, _ flags: NSEvent.ModifierFlags = []) -> ClipboardKeyCommand? {
        ClipboardKeyCommand.resolve(keyCode: keyCode, characters: chars, modifiers: flags)
    }

    func testNavigationAndPasteKeys() {
        XCTAssertEqual(resolve(126), .moveUp)
        XCTAssertEqual(resolve(125), .moveDown)
        XCTAssertEqual(resolve(36), .paste)
        XCTAssertEqual(resolve(76), .paste)
        XCTAssertEqual(resolve(36, nil, .option), .pastePlain)
        XCTAssertEqual(resolve(53), .close)
    }

    func testCommandShortcuts() {
        XCTAssertEqual(resolve(18, "1", .command), .quickSelect(1))
        XCTAssertEqual(resolve(25, "9", .command), .quickSelect(9))
        XCTAssertNil(resolve(29, "0", .command))
        XCTAssertEqual(resolve(35, "p", .command), .togglePin)
        XCTAssertEqual(resolve(51, nil, .command), .delete)
    }

    func testTypingStaysWithTheSearchField() {
        XCTAssertNil(resolve(0, "a"))
        XCTAssertNil(resolve(51))                     // Rückschritt im Suchfeld
        XCTAssertNil(resolve(126, nil, .shift))       // Shift+Pfeil: Textauswahl
        XCTAssertNil(resolve(18, "1"))                // Ziffer ohne ⌘ ist Text
        XCTAssertNil(resolve(35, "p", [.command, .shift]))
        XCTAssertNil(resolve(36, nil, .command))
    }

    // MARK: Fensterposition

    func testPlacementCenterAndCursorClampToScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 760, height: 460)
        let center = ClipboardPanelPlacement.origin(size: size, position: .center, mouse: CGPoint(x: 10, y: 10), screens: [screen])
        XCTAssertEqual(center.x, 340, accuracy: 0.5)
        XCTAssertTrue(screen.contains(CGRect(origin: center, size: size)))

        let nearEdge = ClipboardPanelPlacement.origin(size: size, position: .cursor, mouse: CGPoint(x: 1430, y: 20), screens: [screen])
        XCTAssertTrue(screen.contains(CGRect(origin: nearEdge, size: size)))

        let inside = ClipboardPanelPlacement.origin(size: size, position: .cursor, mouse: CGPoint(x: 500, y: 700), screens: [screen])
        XCTAssertEqual(inside.x, 476, accuracy: 0.5)
        XCTAssertEqual(inside.y, 700 - 460 + 24, accuracy: 0.5)
    }

    func testPlacementPicksScreenUnderMouse() {
        let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let right = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 760, height: 460)
        let origin = ClipboardPanelPlacement.origin(size: size, position: .center, mouse: CGPoint(x: 1500, y: 400), screens: [left, right])
        XCTAssertTrue(right.contains(CGRect(origin: origin, size: size)))
    }

    // MARK: Hotkey

    func testHotkeyDefaultIsShiftCommandC() {
        let shortcut = KeyboardShortcutsDefaultProbe.defaultShortcut
        XCTAssertEqual(shortcut?.modifiers, [.command, .shift])
    }
}

import KeyboardShortcuts

private enum KeyboardShortcutsDefaultProbe {
    static var defaultShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.Name.clipboardHistory.defaultShortcut
    }
}
