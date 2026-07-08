import Foundation
import XCTest
@testable import WhisperM8

/// Richtungs-Mapping des Drei-Finger-Swipe-Tab-Wechsels: Finger nach rechts →
/// Tab rechts, Finger nach links → Tab links. AppKit meldet `deltaX > 0` für
/// einen Swipe nach links (Blätter-Konvention) — sollte die QA auf realer
/// Hardware das Gegenteil zeigen, dreht sich das Mapping in
/// `TabSwipeShortcut.direction` und diese Tests mit.
final class TabSwipeShortcutTests: XCTestCase {
    func testSwipeRightSelectsNextTab() {
        // Finger nach rechts = deltaX < 0 → Tab rechts (+1).
        XCTAssertEqual(TabSwipeShortcut.direction(deltaX: -1), 1)
        XCTAssertEqual(TabSwipeShortcut.direction(deltaX: -0.5), 1)
    }

    func testSwipeLeftSelectsPreviousTab() {
        // Finger nach links = deltaX > 0 → Tab links (-1).
        XCTAssertEqual(TabSwipeShortcut.direction(deltaX: 1), -1)
        XCTAssertEqual(TabSwipeShortcut.direction(deltaX: 0.5), -1)
    }

    func testVerticalSwipeDoesNotMatch() {
        // Vertikaler Swipe hat deltaX == 0 → kein Tab-Wechsel.
        XCTAssertNil(TabSwipeShortcut.direction(deltaX: 0))
    }
}
