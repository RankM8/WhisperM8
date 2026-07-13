import Foundation
import XCTest
@testable import WhisperM8

/// Geometrische Pfeilnavigation (Plan F9, Review-Finding: linear war falsch).
final class GridFocusNavigatorTests: XCTestCase {
    private func allOccupied(_ layout: AgentGridAutoLayout) -> [Bool] {
        Array(repeating: true, count: layout.paneCount)
    }

    func testGrid2x2RightFromRightEdgeIsNil() {
        // Slot 1 (oben rechts) → rechts: KEIN Wrap in die nächste Zeile.
        XCTAssertNil(GridFocusNavigator.target(
            from: 1, direction: .right, layout: .grid2x2, occupied: allOccupied(.grid2x2)
        ))
    }

    func testGrid2x2MovesGeometrically() {
        let occupied = allOccupied(.grid2x2)
        XCTAssertEqual(GridFocusNavigator.target(from: 0, direction: .right, layout: .grid2x2, occupied: occupied), 1)
        XCTAssertEqual(GridFocusNavigator.target(from: 0, direction: .down, layout: .grid2x2, occupied: occupied), 2)
        XCTAssertEqual(GridFocusNavigator.target(from: 3, direction: .up, layout: .grid2x2, occupied: occupied), 1)
        XCTAssertEqual(GridFocusNavigator.target(from: 3, direction: .left, layout: .grid2x2, occupied: occupied), 2)
        XCTAssertNil(GridFocusNavigator.target(from: 0, direction: .up, layout: .grid2x2, occupied: occupied))
    }

    func testTwoPlusOneSpanSlotIsReachableFromBothColumns() {
        let occupied = allOccupied(.twoPlusOne)
        // „Unten" erreicht den spannenden Slot 2 aus BEIDEN Spalten.
        XCTAssertEqual(GridFocusNavigator.target(from: 0, direction: .down, layout: .twoPlusOne, occupied: occupied), 2)
        XCTAssertEqual(GridFocusNavigator.target(from: 1, direction: .down, layout: .twoPlusOne, occupied: occupied), 2)
        // „Oben" vom Span-Slot: Anker ist die linke Kante → Slot 0.
        XCTAssertEqual(GridFocusNavigator.target(from: 2, direction: .up, layout: .twoPlusOne, occupied: occupied), 0)
    }

    func testEmptySlotsAreSkippedInDirection() {
        // 3×3, mittlere Spalte der obersten Zeile leer: rechts von 0 → 2.
        var occupied = allOccupied(.grid3x3)
        occupied[1] = false
        XCTAssertEqual(GridFocusNavigator.target(from: 0, direction: .right, layout: .grid3x3, occupied: occupied), 2)
        // Ganze Richtung leer → nil.
        occupied[2] = false
        XCTAssertNil(GridFocusNavigator.target(from: 0, direction: .right, layout: .grid3x3, occupied: occupied))
    }

    func testGrid3x3ColumnNavigationSkipsEmptyRows() {
        var occupied = allOccupied(.grid3x3)
        occupied[3] = false // Mitte links leer
        XCTAssertEqual(GridFocusNavigator.target(from: 0, direction: .down, layout: .grid3x3, occupied: occupied), 6,
                       "überspringt die leere Zeile in der Spalte")
    }
}
