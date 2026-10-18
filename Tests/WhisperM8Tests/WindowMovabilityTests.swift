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
}
