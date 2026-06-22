import Foundation
import XCTest
@testable import WhisperM8

/// Tests für die reine Tab-Navigations-Mathematik (`adjacentTabID`), die hinter
/// dem ⌘⌥←/→-Tab-Wechsel steckt. Window-frei, daher direkt unit-testbar.
final class TabNavigationTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func testEmptyOrderReturnsNil() {
        XCTAssertNil(adjacentTabID(in: [], current: a, direction: 1))
        XCTAssertNil(adjacentTabID(in: [], current: nil, direction: -1))
    }

    func testSingleTabStaysOnItself() {
        XCTAssertEqual(adjacentTabID(in: [a], current: a, direction: 1), a)
        XCTAssertEqual(adjacentTabID(in: [a], current: a, direction: -1), a)
    }

    func testNextMovesForward() {
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: a, direction: 1), b)
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: b, direction: 1), c)
    }

    func testPreviousMovesBackward() {
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: c, direction: -1), b)
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: b, direction: -1), a)
    }

    func testNextWrapsAroundAtEnd() {
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: c, direction: 1), a)
    }

    func testPreviousWrapsAroundAtStart() {
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: a, direction: -1), c)
    }

    func testNilCurrentFallsBackToFirst() {
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: nil, direction: 1), a)
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: nil, direction: -1), a)
    }

    func testUnknownCurrentFallsBackToFirst() {
        // current nicht (mehr) in der Liste → erster Tab, statt zu crashen.
        XCTAssertEqual(adjacentTabID(in: [a, b, c], current: UUID(), direction: 1), a)
    }
}
