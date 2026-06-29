import Foundation
import XCTest
@testable import WhisperM8

/// Multi-Tab-Drag: Gruppe als Block vor das Ziel sortieren, Relativ-Reihenfolge
/// erhalten. Reine Logik.
final class TabGroupReorderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private var order: [UUID] { [a, b, c, d, e] }

    func testMovesGroupBeforeTarget() {
        XCTAssertEqual(
            TabGroupReorder.newOrder(order, moving: [b, d], before: c),
            [a, b, d, c, e]
        )
    }

    func testMovesGroupToEndWhenBeforeNil() {
        XCTAssertEqual(
            TabGroupReorder.newOrder(order, moving: [a, b], before: nil),
            [c, d, e, a, b]
        )
    }

    func testPreservesGroupRelativeOrder() {
        // Set-Reihenfolge egal — Ergebnis folgt der Anzeige-Reihenfolge (b vor d).
        XCTAssertEqual(
            TabGroupReorder.newOrder(order, moving: [d, b], before: e),
            [a, c, b, d, e]
        )
    }

    func testDropOnOwnGroupMemberIsNoOp() {
        XCTAssertEqual(
            TabGroupReorder.newOrder(order, moving: [b, c], before: b),
            order
        )
    }

    func testSingleElementGroupReturnsUnchanged() {
        // Einzel-Auswahl: Caller nutzt moveTab, nicht diese Funktion.
        XCTAssertEqual(
            TabGroupReorder.newOrder(order, moving: [c], before: a),
            order
        )
    }
}
