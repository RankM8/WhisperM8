import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Die Tab-Leiste im echten Rahmen (WM8-80, Auflage Uli): Der gemessene
/// Bereich darf nie breiter werden als das, was das Fenster ihm gibt, und
/// der Streifen nie breiter als sein Platz — sonst wächst die Leiste mit
/// jedem Durchlauf über den Fensterrand. Gegenprobe 15.11.2026: Mit dem
/// alten Rahmen (`maxWidth` ohne `minWidth: 0`, Abzug 5 pt) wuchs der Bereich
/// bei 560 pt Fenster in 13-pt-Schritten von 488 auf 3.778 pt (255 Messungen);
/// dieser Test schlug dabei an allen drei Breiten fehl.
@MainActor
final class TabStripAreaLayoutTests: XCTestCase {
    private func render(width: CGFloat, probe: TabStripProbe) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: TabStripHarness.sample(probe: probe).frame(width: width, height: 34))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 34)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        window.contentView = nil
        window.close()
        return host
    }

    func testAreaStaysAtWhatTheWindowGivesInANarrowWindowWithManyTabs() {
        for width in [CGFloat(560), 760, 1_100] {
            let probe = TabStripProbe()
            _ = render(width: width, probe: probe)
            // Fenster − Ränder (8 + 6) − zwei feste Knöpfe (24 + 24) − zwei Abstände (5 + 5).
            let expected = width - 14 - 48 - 10
            XCTAssertFalse(probe.areaWidths.isEmpty, "Breite \(width): keine Messung")
            XCTAssertEqual(probe.areaWidths.last ?? 0, expected, accuracy: 0.5, "Breite \(width)")
            XCTAssertTrue(probe.areaWidths.allSatisfy { $0 <= expected + 0.5 },
                          "Breite \(width): Bereich wuchs über das Fenster: \(probe.areaWidths)")
            XCTAssertLessThanOrEqual(probe.areaWidths.count, 2,
                                     "Breite \(width): Messung kommt nicht zur Ruhe: \(probe.areaWidths)")
            XCTAssertGreaterThan(probe.chipMeasurements, 0, "Breite \(width): Chips nicht gemessen")
            let viewport = AgentTabWidthResolver.stripViewportWidth(areaWidth: expected, trailingWidth: 49)
            XCTAssertLessThanOrEqual(probe.stripWidths.last ?? 0, viewport + 0.5,
                                     "Breite \(width): Streifen breiter als sein Platz")
        }
    }
}
