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

    // MARK: - Mehrspurige Achsen (Kapazitäten 6/9, Plan F10)

    func testTrackSizesFillTotalExactly() {
        let sizes = GridSplitResolver.trackSizes(total: 1202, fractions: [0.25, 0.25, 0.5])
        XCTAssertEqual(sizes.count, 3)
        // usable = 1202 - 2×1px Divider = 1200
        XCTAssertEqual(sizes[0], 300)
        XCTAssertEqual(sizes[1], 300)
        XCTAssertEqual(sizes[2], 600, "letzte Spur nimmt den Rest — Summe exakt")
        XCTAssertEqual(sizes.reduce(0, +), 1200)
    }

    func testFractionsDuringDragMovesOnlyNeighborPair() {
        // usable = 1200; Spur 0: 300pt +48pt = 348pt → 0.29; Spur 1 gibt ab.
        let base = [0.25, 0.25, 0.5]
        let next = GridSplitResolver.fractionsDuringDrag(
            base: base, dividerIndex: 0, translation: 48, total: 1202
        )
        XCTAssertEqual(next[0], 0.29, accuracy: 0.001)
        XCTAssertEqual(next[1], 0.21, accuracy: 0.001)
        XCTAssertEqual(next[2], 0.5, accuracy: 0.0001, "übrige Spuren bleiben exakt")
        XCTAssertEqual(next.reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testFractionsDuringDragClampsToMinPanePerSide() {
        let base = [0.5, 0.5]
        let total: CGFloat = 1201 // usable 1200
        let far = GridSplitResolver.fractionsDuringDrag(
            base: base, dividerIndex: 0, translation: 5000, total: total
        )
        // Rechte Spur klemmt bei minPane (240/1200 = 0.2).
        XCTAssertEqual(far[1], 0.2, accuracy: 0.001)
        let tiny = GridSplitResolver.fractionsDuringDrag(
            base: base, dividerIndex: 0, translation: -5000, total: total
        )
        XCTAssertEqual(tiny[0], 0.2, accuracy: 0.001)
    }

    func testFractionsDuringDragKeepsBaseWhenPairTooSmall() {
        // Nachbar-Paar (0.55 × 798 ≈ 439pt) < 2×minPane (480pt) → Basis bleibt.
        let base = [0.45, 0.1, 0.45]
        let next = GridSplitResolver.fractionsDuringDrag(
            base: base, dividerIndex: 1, translation: 50, total: 800
        )
        XCTAssertEqual(next, base)
    }

    func testFractionsDuringDragRejectsInvalidDividerIndex() {
        let base = [0.5, 0.5]
        XCTAssertEqual(
            GridSplitResolver.fractionsDuringDrag(base: base, dividerIndex: 1, translation: 10, total: 1000),
            base
        )
    }

    func testTrackSizesClampEachTrackToMinPane() {
        // Gespeichertes 0,1-Gewicht + verkleinertes Fenster: die Spur darf
        // nicht unter 240 pt fallen (Review-Finding: erster Drag-Tick sprang
        // sonst zur Clamp-Grenze).
        let sizes = GridSplitResolver.trackSizes(total: 1001, fractions: [0.1, 0.9])
        XCTAssertEqual(sizes[0], 240)
        XCTAssertEqual(sizes[1], 760)
        // Zu kleine Fläche für alle Mindest-Panes → gleichmäßig quetschen.
        let squeezed = GridSplitResolver.trackSizes(total: 401, fractions: [0.1, 0.9])
        XCTAssertEqual(squeezed[0], 200)
        XCTAssertEqual(squeezed[1], 200)
    }
}
