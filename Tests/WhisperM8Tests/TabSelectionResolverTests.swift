import Foundation
import XCTest
@testable import WhisperM8

/// Multi-Select-Semantik der Tab-Leiste: Click / Cmd-Click (Toggle) /
/// Shift-Click (Range). Reine Logik, ohne SwiftUI.
final class TabSelectionResolverTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private var order: [UUID] { [a, b, c, d] }

    func testClickSelectsSingleAndClearsGroup() {
        let r = TabSelectionResolver.click(a)
        XCTAssertEqual(r.active, a)
        XCTAssertTrue(r.selection.isEmpty)
    }

    func testCommandClickFromSingleFormsPairSeededWithActive() {
        let r = TabSelectionResolver.commandClick(b, active: a, selection: [])
        XCTAssertEqual(r.active, b)
        XCTAssertEqual(r.selection, [a, b])
    }

    func testCommandClickAddsThird() {
        let r = TabSelectionResolver.commandClick(c, active: b, selection: [a, b])
        XCTAssertEqual(r.active, c)
        XCTAssertEqual(r.selection, [a, b, c])
    }

    func testCommandClickRemovesAndCollapsesToSingle() {
        // Aus {a,b} b wieder rausnehmen → nur noch a → Auswahl kollabiert auf leer.
        let r = TabSelectionResolver.commandClick(b, active: b, selection: [a, b])
        XCTAssertEqual(r.active, a)
        XCTAssertTrue(r.selection.isEmpty)
    }

    func testCommandClickOnLoneActiveStaysSingle() {
        let r = TabSelectionResolver.commandClick(a, active: a, selection: [])
        XCTAssertEqual(r.active, a)
        XCTAssertTrue(r.selection.isEmpty)
    }

    func testShiftClickSelectsForwardRange() {
        let r = TabSelectionResolver.shiftClick(c, anchor: a, order: order)
        XCTAssertEqual(r.active, c)
        XCTAssertEqual(r.selection, [a, b, c])
    }

    func testShiftClickSelectsBackwardRange() {
        let r = TabSelectionResolver.shiftClick(a, anchor: c, order: order)
        XCTAssertEqual(r.active, a)
        XCTAssertEqual(r.selection, [a, b, c])
    }

    func testShiftClickOnAnchorItselfStaysSingle() {
        let r = TabSelectionResolver.shiftClick(a, anchor: a, order: order)
        XCTAssertEqual(r.active, a)
        XCTAssertTrue(r.selection.isEmpty)
    }

    func testShiftClickWithoutAnchorFallsBackToSingle() {
        let r = TabSelectionResolver.shiftClick(c, anchor: nil, order: order)
        XCTAssertEqual(r.active, c)
        XCTAssertTrue(r.selection.isEmpty)
    }
}
