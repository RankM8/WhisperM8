import XCTest
@testable import WhisperM8

/// Prueft das Trennerziehen mit der Dehn-Technik.
///
/// Die Kernfrage ist nicht „bewegt sich der Trenner", sondern **„bleiben alle
/// anderen Flaechen in Ruhe"**. Wandert beim Ziehen eines Trenners das halbe
/// Layout mit, muessen auch dort die Terminals ihre Groesse aendern — und genau
/// das soll die Technik verhindern.
final class LayoutDividerDragTests: XCTestCase {
    private let cellA = UUID(), cellB = UUID()

    private var divider: LayoutDividerDrag.Divider {
        .init(leadingCellID: cellA, trailingCellID: cellB, axis: .horizontal)
    }

    // MARK: - Zustand

    func testDragTracksOffsetOnly() {
        var drag = LayoutDividerDrag()
        drag.begin(divider, at: 500)
        drag.move(to: 560, limits: -400...400)
        XCTAssertEqual(drag.offset, 60)
        XCTAssertTrue(drag.isActive)
    }

    func testOffsetIsClampedToLimits() {
        var drag = LayoutDividerDrag()
        drag.begin(divider, at: 500)
        drag.move(to: 9999, limits: -100...100)
        XCTAssertEqual(drag.offset, 100, "Ohne Begrenzung rutschte eine Flaeche ins Negative")

        drag.move(to: -9999, limits: -100...100)
        XCTAssertEqual(drag.offset, -100)
    }

    func testMoveWithoutBeginDoesNothing() {
        var drag = LayoutDividerDrag()
        drag.move(to: 500, limits: -100...100)
        XCTAssertFalse(drag.isActive)
        XCTAssertNil(drag.end())
    }

    /// Ein Zug ohne Bewegung darf nichts anwenden — sonst schriebe jeder
    /// versehentliche Klick auf den Trenner das Layout neu.
    func testEndWithoutMovementAppliesNothing() {
        var drag = LayoutDividerDrag()
        drag.begin(divider, at: 500)
        XCTAssertNil(drag.end())
    }

    func testEndReturnsOffsetAndResets() {
        var drag = LayoutDividerDrag()
        drag.begin(divider, at: 500)
        drag.move(to: 560, limits: -400...400)

        let ergebnis = drag.end()
        XCTAssertEqual(ergebnis?.offset, 60)
        XCTAssertFalse(drag.isActive)
        XCTAssertNil(drag.end(), "Zweimal beenden darf nicht zweimal anwenden")
    }

    func testCancelDiscards() {
        var drag = LayoutDividerDrag()
        drag.begin(divider, at: 500)
        drag.move(to: 560, limits: -400...400)
        drag.cancel()
        XCTAssertNil(drag.end())
    }

    // MARK: - Aufloesung in Anteile

    func testOffsetBecomesFractionShift() {
        let result = LayoutDividerDrag.resolvedFractions(
            fractions: [0.5, 0.5], index: 0, offset: 100, available: 1000
        )
        XCTAssertEqual(result[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.4, accuracy: 0.001)
    }

    /// Der wichtigste Test: Nur die beiden Nachbarn aendern sich.
    func testOnlyNeighboursOfTheDividerChange() {
        let result = LayoutDividerDrag.resolvedFractions(
            fractions: [0.25, 0.25, 0.5], index: 0, offset: 100, available: 1000
        )
        XCTAssertEqual(result[0], 0.35, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.15, accuracy: 0.001)
        XCTAssertEqual(result[2], 0.5, accuracy: 0.001,
                       "Die dritte Flaeche darf sich nicht bewegen")
    }

    /// Keine Flaeche darf verschwinden, egal wie weit gezogen wird.
    func testMinimumFractionIsKept() {
        let result = LayoutDividerDrag.resolvedFractions(
            fractions: [0.5, 0.5], index: 0, offset: 10_000, available: 1000
        )
        XCTAssertGreaterThanOrEqual(result[1], 0.07, "Die rechte Flaeche waere verschwunden")
        XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 0.001)
    }

    func testSumStaysOne() {
        for offset in stride(from: -900.0, through: 900.0, by: 150.0) {
            let result = LayoutDividerDrag.resolvedFractions(
                fractions: [0.3, 0.3, 0.4], index: 1, offset: CGFloat(offset), available: 1000
            )
            XCTAssertEqual(result.reduce(0, +), 1.0, accuracy: 0.001, "Versatz \(offset)")
            XCTAssertTrue(result.allSatisfy { $0 > 0 }, "Versatz \(offset) erzeugt Flaeche 0")
        }
    }

    // MARK: - Randfaelle

    func testInvalidIndexLeavesFractionsUntouched() {
        let vorher = [0.5, 0.5]
        XCTAssertEqual(
            LayoutDividerDrag.resolvedFractions(fractions: vorher, index: 1, offset: 100, available: 1000),
            vorher, "Der letzte Index hat keinen rechten Nachbarn"
        )
        XCTAssertEqual(
            LayoutDividerDrag.resolvedFractions(fractions: vorher, index: -1, offset: 100, available: 1000),
            vorher
        )
    }

    func testZeroAvailableLeavesFractionsUntouched() {
        let vorher = [0.5, 0.5]
        XCTAssertEqual(
            LayoutDividerDrag.resolvedFractions(fractions: vorher, index: 0, offset: 100, available: 0),
            vorher
        )
    }
}
