import CoreGraphics
import XCTest
@testable import WhisperM8

/// LR-AU-008: zustandslose Entscheidung statt hängender Hover-Flags.
final class WindowMovabilityTests: XCTestCase {
    private let height: CGFloat = 800
    private let strip = CGRect(x: 100, y: 0, width: 600, height: 34)

    func testNotMovableOverTabStrip() {
        let p = CGPoint(x: 300, y: height - 10) // AppKit: oben = hohes y
        XCTAssertFalse(WindowMovability.isMovable(pointInWindow: p, contentViewHeight: height, stripFrame: strip, resizeHandleRanges: []))
    }

    /// Kernfall des Befunds: kein Hover-Flag, Zeiger auf freiem Titelband → verschiebbar.
    func testMovableOnFreeTitleBand() {
        let p = CGPoint(x: 750, y: height - 10)
        XCTAssertTrue(WindowMovability.isMovable(pointInWindow: p, contentViewHeight: height, stripFrame: strip, resizeHandleRanges: []))
    }

    func testNotMovableOverSidebarResizeEdge() {
        let ranges = WindowMovability.resizeHandleRanges(sidebarWidth: 260, inspectorWidth: nil, windowWidth: 1200)
        XCTAssertFalse(WindowMovability.isMovable(pointInWindow: CGPoint(x: 262, y: height - 10), contentViewHeight: height, stripFrame: .zero, resizeHandleRanges: ranges))
        XCTAssertTrue(WindowMovability.isMovable(pointInWindow: CGPoint(x: 270, y: height - 10), contentViewHeight: height, stripFrame: .zero, resizeHandleRanges: ranges))
    }

    /// Sidebar per Kürzel ausgeblendet → keine Zone mehr → Fenster wieder verschiebbar.
    func testHiddenSidebarLeavesNoStickyZone() {
        let ranges = WindowMovability.resizeHandleRanges(sidebarWidth: nil, inspectorWidth: nil, windowWidth: 1200)
        XCTAssertTrue(ranges.isEmpty)
        XCTAssertTrue(WindowMovability.isMovable(pointInWindow: CGPoint(x: 260, y: height - 10), contentViewHeight: height, stripFrame: .zero, resizeHandleRanges: ranges))
    }

    func testInspectorEdgeRange() {
        let ranges = WindowMovability.resizeHandleRanges(sidebarWidth: nil, inspectorWidth: 300, windowWidth: 1200)
        XCTAssertTrue(ranges.first?.contains(900) ?? false)
        XCTAssertFalse(ranges.first?.contains(920) ?? true)
    }

    // MARK: - Griffflächen (Befund 10.11.2026)

    /// Sidebar-Kopf (bis 28 pt Tiefe) und der freie Rest der Tab-Zeile.
    private let areas = [
        WindowDragArea(xRange: 0...120, depth: 28),
        WindowDragArea(xRange: 900...1100, depth: 34),
    ]

    private func movable(x: CGFloat, depth: CGFloat, areas: [WindowDragArea]) -> Bool {
        WindowMovability.isMovable(
            pointInWindow: CGPoint(x: x, y: height - depth),
            contentViewHeight: height,
            stripFrame: strip,
            resizeHandleRanges: [],
            dragAreas: areas
        )
    }

    /// Kernfall: ein Knopf im Titelband (hier bei x = 80, zwischen Griff und
    /// Tab-Strip) liegt auf keiner Grifffläche — der Klick zieht nicht mehr das
    /// Fenster.
    func testControlInTitleBandIsNotMovable() {
        XCTAssertFalse(movable(x: 80, depth: 10, areas: [WindowDragArea(xRange: 0...60, depth: 28)]))
        XCTAssertFalse(movable(x: 750, depth: 10, areas: areas))
    }

    func testDragAreaInTitleBandIsMovable() {
        XCTAssertTrue(movable(x: 60, depth: 10, areas: areas))
        XCTAssertTrue(movable(x: 1000, depth: 30, areas: areas))
    }

    /// Unter der Sidebar-Kopfzeile beginnt „Neuer Chat": gleiche X-Spanne, aber
    /// tiefer als die Grifffläche reicht.
    func testBelowDragAreaDepthIsNotMovable() {
        XCTAssertFalse(movable(x: 60, depth: 31, areas: areas))
    }

    /// Der Tab-Strip gewinnt immer, auch wenn eine Grifffläche ihn überlappt.
    func testTabStripBeatsDragArea() {
        XCTAssertFalse(movable(x: 300, depth: 10, areas: [WindowDragArea(xRange: 0...1200, depth: 34)]))
    }

    /// Ohne Messung (vor dem ersten Layout) bleibt das alte Verhalten — ein
    /// Messfehler darf das Fenster nie unverschiebbar machen.
    func testWithoutMeasuredAreasFallsBackToFreeBand() {
        XCTAssertTrue(movable(x: 750, depth: 10, areas: []))
    }

    /// Unterhalb des Titelbands zieht macOS ohnehin nicht; dort bleibt es bei
    /// „verschiebbar", damit nichts gesperrt zurückbleibt.
    func testBelowTitleBandStaysMovable() {
        XCTAssertTrue(movable(x: 750, depth: 200, areas: areas))
    }

    func testIsOverDragAreaUsesDepthFromTop() {
        XCTAssertTrue(WindowMovability.isOverDragArea(
            pointInWindow: CGPoint(x: 100, y: height - 28), contentViewHeight: height, dragAreas: areas))
        XCTAssertFalse(WindowMovability.isOverDragArea(
            pointInWindow: CGPoint(x: 100, y: height - 29), contentViewHeight: height, dragAreas: areas))
        XCTAssertFalse(WindowMovability.isOverDragArea(
            pointInWindow: CGPoint(x: 500, y: height - 10), contentViewHeight: height, dragAreas: areas))
    }
}
