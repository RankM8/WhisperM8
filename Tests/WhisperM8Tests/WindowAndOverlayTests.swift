import AppKit
import XCTest
@testable import WhisperM8

@MainActor
final class WindowAndOverlayTests: XCTestCase {
    func testWindowRequestCenterStoresLatestRequest() {
        let center = WindowRequestCenter.shared

        center.request(.settings)
        XCTAssertEqual(center.latestRequest, .settings)

        center.request(.onboarding)
        XCTAssertEqual(center.latestRequest, .onboarding)

        center.request(.outputDashboard)
        XCTAssertEqual(center.latestRequest, .outputDashboard)
    }

    func testOverlayClampKeepsPanelInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 100, y: 100, width: 800, height: 600)
        let panelSize = NSSize(width: 300, height: 100)

        let clamped = OverlayPositionStore.clamp(
            origin: NSPoint(x: 950, y: 50),
            size: panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(clamped.x, 600)
        XCTAssertEqual(clamped.y, 100)
    }
}
