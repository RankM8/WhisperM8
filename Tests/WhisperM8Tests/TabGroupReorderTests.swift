import Foundation
import XCTest
@testable import WhisperM8

/// Block-Reorder der Tab-Leiste: die bewegten IDs landen zusammenhängend vor
/// dem Ziel, die Relativ-Reihenfolge bleibt erhalten. Eingabe ist immer die
/// SICHTBARE (gruppierte) Reihenfolge — deren Ergebnis wird zur neuen
/// manuellen Reihenfolge. Reine Logik.
final class TabGroupReorderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private var order: [UUID] { [a, b, c, d, e] }

    func testMovesGroupBeforeTarget() {
        XCTAssertEqual(
            TabOrderReorder.newOrder(order, moving: [b, d], before: c),
            [a, b, d, c, e]
        )
    }

    func testMovesGroupToEndWhenBeforeNil() {
        XCTAssertEqual(
            TabOrderReorder.newOrder(order, moving: [a, b], before: nil),
            [c, d, e, a, b]
        )
    }

    func testPreservesGroupRelativeOrder() {
        // Set-Reihenfolge egal — Ergebnis folgt der Anzeige-Reihenfolge (b vor d).
        XCTAssertEqual(
            TabOrderReorder.newOrder(order, moving: [d, b], before: e),
            [a, c, b, d, e]
        )
    }

    func testDropOnOwnMemberIsNoOp() {
        XCTAssertEqual(
            TabOrderReorder.newOrder(order, moving: [b, c], before: b),
            order
        )
    }

    func testUnknownMovingIDsLeaveOrderUntouched() {
        XCTAssertEqual(
            TabOrderReorder.newOrder(order, moving: [UUID()], before: a),
            order
        )
    }

    func testReordersSingleAgainstVisualOrder() {
        XCTAssertEqual(
            TabOrderReorder.newOrder([a, c, b], moving: [b], before: a),
            [b, a, c]
        )
    }

    func testReordersSelectionAsVisualBlock() {
        XCTAssertEqual(
            TabOrderReorder.newOrder([a, c, b, d], moving: [c, d], before: a),
            [c, d, a, b]
        )
    }
}
