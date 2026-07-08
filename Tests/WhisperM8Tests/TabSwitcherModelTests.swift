import Foundation
import XCTest
@testable import WhisperM8

/// Pure Durchlauf-Maschine des Ctrl+Tab-Switchers: Aktivierung, Wrap-around,
/// Robustheit gegen extern verschwindende Tabs, Commit-Ziel.
final class TabSwitcherModelTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    // MARK: - Aktivierung

    func testBeginNeedsAtLeastTwoTabs() {
        XCTAssertNil(TabSwitcherModel.begin(order: [], current: nil, direction: 1))
        XCTAssertNil(TabSwitcherModel.begin(order: [a], current: a, direction: 1))
    }

    func testBeginHighlightsNextTab() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)
        XCTAssertEqual(model?.highlightedID, b)
    }

    func testBeginBackwardWrapsToLast() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: -1)
        XCTAssertEqual(model?.highlightedID, c)
    }

    func testBeginWithNilCurrentStartsFromFirst() {
        // Keine Selektion → Anker ist der erste Tab, ein Schritt vor = zweiter.
        let model = TabSwitcherModel.begin(order: [a, b, c], current: nil, direction: 1)
        XCTAssertEqual(model?.highlightedID, b)
    }

    // MARK: - Durchlauf

    func testAdvanceMovesForwardWithWrap() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        model.advance(1, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, c)
        model.advance(1, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, a)
    }

    func testAdvanceBackward() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: c, direction: 1)!
        XCTAssertEqual(model.highlightedID, a)
        model.advance(-1, order: [a, b, c])
        XCTAssertEqual(model.highlightedID, c)
    }

    func testAdvanceFallsBackWhenHighlightedTabDisappeared() {
        var model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        XCTAssertEqual(model.highlightedID, b)
        // b wurde extern geschlossen/archiviert → Fallback auf den ersten Tab
        // der frischen Reihenfolge statt hängen/crashen.
        model.advance(1, order: [a, c])
        XCTAssertEqual(model.highlightedID, a)
    }

    func testAdvanceMultiStepBeyondCountWrapsSafely() {
        // ↑/↓ im Karten-Grid springen eine ganze Reihe (= Spaltenzahl). Die
        // Spaltenzahl kann nach externem Tab-Close kurz stale sein und die
        // Tab-Anzahl übersteigen — der Wrap darf dann nie in einen negativen
        // Index laufen (Swifts `%` behält das Vorzeichen).
        var model = TabSwitcherModel.begin(order: [a, b, c], current: b, direction: 1)!
        XCTAssertEqual(model.highlightedID, c)
        model.advance(-4, order: [a, b, c])   // idx 2 → -2 → wrap → b
        XCTAssertEqual(model.highlightedID, b)

        model = TabSwitcherModel.begin(order: [a, b, c], current: c, direction: 1)!
        XCTAssertEqual(model.highlightedID, a)
        model.advance(-4, order: [a, b, c])   // idx 0 → -4 → wrap → c (crashte vorher)
        XCTAssertEqual(model.highlightedID, c)
    }

    // MARK: - Commit

    func testCommitTargetReturnsHighlighted() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        XCTAssertEqual(model.commitTarget(order: [a, b, c]), b)
    }

    func testCommitTargetIsNilWhenHighlightedTabDisappeared() {
        let model = TabSwitcherModel.begin(order: [a, b, c], current: a, direction: 1)!
        // b existiert beim Loslassen nicht mehr → Selektion bleibt, wie sie ist.
        XCTAssertNil(model.commitTarget(order: [a, c]))
    }
}

/// Grid-Layout des Karten-Switchers: Spalten/Reihen/Scroll aus Tab-Anzahl
/// und verfügbarem Platz (pure Mathematik, siehe `TabSwitcherGridLayout`).
final class TabSwitcherGridLayoutTests: XCTestCase {
    private let large = CGSize(width: 1400, height: 900)

    func testGridUsesUpToFourColumnsAndWrapsRows() {
        let metrics = TabSwitcherGridLayout.metrics(count: 10, availableSize: large)
        XCTAssertEqual(metrics.columns, 4)
        XCTAssertEqual(metrics.rows, 3)
        XCTAssertEqual(metrics.visibleRows, 3)
        XCTAssertFalse(metrics.needsScroll)
    }

    func testGridStaysSingleRowForFewTabs() {
        let metrics = TabSwitcherGridLayout.metrics(count: 3, availableSize: large)
        XCTAssertEqual(metrics.columns, 3)
        XCTAssertEqual(metrics.rows, 1)
        XCTAssertFalse(metrics.needsScroll)
    }

    func testGridReducesColumnsInNarrowContentArea() {
        // 620pt Content-Breite: nach Chrome passen nur 2 Karten nebeneinander.
        let metrics = TabSwitcherGridLayout.metrics(count: 8, availableSize: CGSize(width: 620, height: 900))
        XCTAssertEqual(metrics.columns, 2)
        XCTAssertEqual(metrics.rows, 4)
    }

    func testGridScrollsWhenRowsExceedAvailableHeight() {
        // 30 Tabs → 8 Reihen; in 620pt Höhe passen weniger → Scroll.
        let metrics = TabSwitcherGridLayout.metrics(count: 30, availableSize: CGSize(width: 1400, height: 620))
        XCTAssertEqual(metrics.columns, 4)
        XCTAssertEqual(metrics.rows, 8)
        XCTAssertLessThan(metrics.visibleRows, metrics.rows)
        XCTAssertTrue(metrics.needsScroll)
    }

    func testGridWidthAndHeightMatchCardMath() {
        let metrics = TabSwitcherGridLayout.metrics(count: 10, availableSize: large)
        let expectedWidth = 4 * TabSwitcherGridLayout.cardWidth + 3 * TabSwitcherGridLayout.spacing
        let expectedHeight = 3 * TabSwitcherGridLayout.cardHeight + 2 * TabSwitcherGridLayout.spacing
        XCTAssertEqual(metrics.gridWidth, expectedWidth)
        XCTAssertEqual(metrics.gridHeight, expectedHeight)
    }

    func testGridNeverDropsBelowOneColumnAndRow() {
        // Absurd kleiner Platz: Layout bleibt benutzbar statt 0/negativ.
        let metrics = TabSwitcherGridLayout.metrics(count: 5, availableSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(metrics.columns, 1)
        XCTAssertEqual(metrics.rows, 5)
        XCTAssertEqual(metrics.visibleRows, 1)
        XCTAssertTrue(metrics.needsScroll)
    }

    func testGridIsEmptyForZeroTabs() {
        let metrics = TabSwitcherGridLayout.metrics(count: 0, availableSize: large)
        XCTAssertEqual(metrics.columns, 0)
        XCTAssertEqual(metrics.gridWidth, 0)
        XCTAssertEqual(metrics.gridHeight, 0)
    }
}
