import Foundation
import XCTest
@testable import WhisperM8

final class GridSplitResolverTests: XCTestCase {
    func testClampedFractionRespectsMinPaneOnBothSides() {
        let total: CGFloat = 1001 // usable = 1000 → minFraction = 0.24
        XCTAssertEqual(GridSplitResolver.clampedFraction(0.1, total: total), 0.24, accuracy: 0.001)
        XCTAssertEqual(GridSplitResolver.clampedFraction(0.95, total: total), 0.76, accuracy: 0.001)
        XCTAssertEqual(GridSplitResolver.clampedFraction(0.6, total: total), 0.6, accuracy: 0.001,
                       "Werte innerhalb der Grenzen bleiben unangetastet")
    }

    func testTooSmallTotalFallsBackToHalf() {
        // Fläche < 2 × minPane: beide Panes quetschen sich gleichmäßig.
        XCTAssertEqual(GridSplitResolver.clampedFraction(0.8, total: 400), 0.5)
        XCTAssertEqual(GridSplitResolver.clampedFraction(0.2, total: 0), 0.5)
    }

    func testFirstSizeAppliesClampedFraction() {
        let total: CGFloat = 1001 // usable = 1000
        XCTAssertEqual(GridSplitResolver.firstSize(total: total, fraction: 0.6), 600)
        XCTAssertEqual(GridSplitResolver.firstSize(total: total, fraction: 0.05), 240,
                       "geclampte Untergrenze = minPane")
        XCTAssertEqual(GridSplitResolver.firstSize(total: 0, fraction: 0.6), 0,
                       "leere Fläche → 0, kein negativer Frame")
    }

    func testFractionDuringDragAddsTranslationAndClamps() {
        let total: CGFloat = 1001 // usable = 1000
        // Start bei 500, 100 nach rechts → 0.6.
        XCTAssertEqual(
            GridSplitResolver.fractionDuringDrag(startFirstSize: 500, translation: 100, total: total),
            0.6, accuracy: 0.001
        )
        // Weit über die Grenze ziehen → klebt am Maximum.
        XCTAssertEqual(
            GridSplitResolver.fractionDuringDrag(startFirstSize: 500, translation: 5000, total: total),
            0.76, accuracy: 0.001
        )
        XCTAssertEqual(
            GridSplitResolver.fractionDuringDrag(startFirstSize: 500, translation: -5000, total: total),
            0.24, accuracy: 0.001
        )
    }

    func testDefaultFractionIsHalf() {
        XCTAssertEqual(GridSplitResolver.defaultFraction, 0.5)
    }
}
