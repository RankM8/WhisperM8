import AppKit
import SwiftUI
import XCTest
@testable import WhisperM8

/// Der Tracker hält `isMovable` im Titelband aktuell. Verfolgt er das falsche
/// Rechteck (unten statt oben, ganzes Fenster), stimmt der Zustand beim Klick
/// nicht — und Knöpfe im Titelband ziehen wieder das Fenster.
@MainActor
final class TitleBandPointerTrackerTests: XCTestCase {
    private func findTracker(in view: NSView) -> TitleBandPointerTracker.TrackerView? {
        if let tracker = view as? TitleBandPointerTracker.TrackerView { return tracker }
        for subview in view.subviews {
            if let found = findTracker(in: subview) { return found }
        }
        return nil
    }

    func testTracksOnlyTheTopBandOfTheWindow() throws {
        var moved: [CGPoint] = []
        var exits = 0
        let root = Color.clear
            .frame(width: 400, height: 300)
            .background(TitleBandPointerTracker(
                bandHeight: 34,
                onPointerMoved: { moved.append($0) },
                onPointerExited: { exits += 1 }
            ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let host = NSHostingView(rootView: root)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let tracker = try XCTUnwrap(findTracker(in: host))
        tracker.updateTrackingAreas()
        let area = try XCTUnwrap(tracker.trackingAreas.first)
        XCTAssertEqual(tracker.trackingAreas.count, 1)

        // In Fensterkoordinaten (Ursprung unten links): die obersten 34 pt.
        let inWindow = tracker.convert(area.rect, to: nil)
        XCTAssertEqual(inWindow.minY, 266, accuracy: 0.5)
        XCTAssertEqual(inWindow.maxY, 300, accuracy: 0.5)
        XCTAssertEqual(inWindow.width, 400, accuracy: 0.5)
        XCTAssertTrue(area.options.contains(.mouseMoved))
        XCTAssertTrue(area.options.contains(.activeAlways))

        // Der Tracker nimmt nie einen Klick an.
        XCTAssertNil(tracker.hitTest(NSPoint(x: 10, y: 290)))

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 120, y: 290), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ))
        tracker.mouseMoved(with: event)
        tracker.mouseExited(with: event)
        XCTAssertEqual(moved, [CGPoint(x: 120, y: 290)])
        XCTAssertEqual(exits, 1)
    }
}
