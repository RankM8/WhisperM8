import AppKit
import SwiftTerm
import XCTest
@testable import WhisperM8

/// Finger-Bedienung des Chat-Terminals am Touch-Display (WM8-136).
final class TerminalTouchScrollingTests: XCTestCase {
    // MARK: - Absicht: scrollen oder markieren

    func testImmediateMoveScrolls() {
        XCTAssertEqual(TerminalTouchIntent.decide(restBeforeMove: 0), .scroll)
        XCTAssertEqual(TerminalTouchIntent.decide(restBeforeMove: 0.12), .scroll)
        XCTAssertEqual(TerminalTouchIntent.decide(restBeforeMove: TerminalTouchIntent.holdThreshold - 0.01), .scroll)
    }

    func testHoldThenMoveSelects() {
        XCTAssertEqual(TerminalTouchIntent.decide(restBeforeMove: TerminalTouchIntent.holdThreshold), .select)
        XCTAssertEqual(TerminalTouchIntent.decide(restBeforeMove: 1.2), .select)
    }

    // MARK: - Ziel des Scrolls (wie beim Trackpad)

    func testRouteNormalBufferUsesScrollback() {
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: false, mouseReportingActive: false, processRunning: true),
            .scrollback)
        // Beendeter Chat: Verlauf bleibt mit dem Finger lesbar.
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: false, mouseReportingActive: false, processRunning: false),
            .scrollback)
    }

    func testRouteAlternateBufferGoesToTUI() {
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: true, mouseReportingActive: false, processRunning: true),
            .wheelToAlternateScreen)
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: true, mouseReportingActive: true, processRunning: true),
            .wheelToAlternateScreen)
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: true, mouseReportingActive: false, processRunning: false),
            .ignore)
    }

    func testRouteMouseReportingInNormalBufferGoesToTUI() {
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: false, mouseReportingActive: true, processRunning: true),
            .wheelToMouseReporting)
        XCTAssertEqual(
            TerminalTouchScrollRoute.decide(isAlternateBuffer: false, mouseReportingActive: true, processRunning: false),
            .scrollback)
    }

    // MARK: - Fingerweg in Zeilen

    func testAccumulatorKeepsRemainderAcrossSmallSteps() {
        var accumulator = TerminalTouchLineAccumulator()
        XCTAssertEqual(accumulator.lines(forFingerTravel: 7, cellHeight: 16), 0)
        XCTAssertEqual(accumulator.lines(forFingerTravel: 7, cellHeight: 16), 0)
        XCTAssertEqual(accumulator.lines(forFingerTravel: 7, cellHeight: 16), 1)
        XCTAssertEqual(accumulator.remainder, 5, accuracy: 0.0001)
    }

    func testAccumulatorFastTravelSkipsNoLines() {
        var accumulator = TerminalTouchLineAccumulator()
        XCTAssertEqual(accumulator.lines(forFingerTravel: 160, cellHeight: 16), 10)
        XCTAssertEqual(accumulator.lines(forFingerTravel: -40, cellHeight: 16), -2)
        XCTAssertEqual(accumulator.remainder, -8, accuracy: 0.0001)
    }

    func testAccumulatorDirectionChangeCancelsRemainder() {
        var accumulator = TerminalTouchLineAccumulator()
        XCTAssertEqual(accumulator.lines(forFingerTravel: 10, cellHeight: 16), 0)
        XCTAssertEqual(accumulator.lines(forFingerTravel: -10, cellHeight: 16), 0)
        XCTAssertEqual(accumulator.remainder, 0, accuracy: 0.0001)
    }

    func testAccumulatorIgnoresInvalidInput() {
        var accumulator = TerminalTouchLineAccumulator()
        XCTAssertEqual(accumulator.lines(forFingerTravel: 100, cellHeight: 0), 0)
        XCTAssertEqual(accumulator.lines(forFingerTravel: .nan, cellHeight: 16), 0)
        XCTAssertEqual(accumulator.remainder, 0)
    }

    // MARK: - Schwung

    func testSlowReleaseHasNoMomentum() {
        XCTAssertNil(TerminalTouchMomentum(releaseVelocity: 0))
        XCTAssertNil(TerminalTouchMomentum(releaseVelocity: TerminalTouchMomentum.minimumStartVelocity - 1))
        XCTAssertNil(TerminalTouchMomentum(releaseVelocity: .infinity))
    }

    func testMomentumIsClampedAndKeepsDirection() throws {
        let up = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 50_000))
        XCTAssertEqual(up.velocity, TerminalTouchMomentum.maximumVelocity)
        let down = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: -1_000))
        XCTAssertEqual(down.velocity, -1_000)
    }

    func testMomentumDeceleratesAndEnds() throws {
        var momentum = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 2_000))
        var total: CGFloat = 0
        var previousStep = CGFloat.greatestFiniteMagnitude
        var frames = 0
        while !momentum.isFinished && frames < 2_000 {
            let step = momentum.advance(by: 1.0 / 120.0)
            XCTAssertGreaterThan(step, 0)
            XCTAssertLessThanOrEqual(step, previousStep)
            previousStep = step
            total += step
            frames += 1
        }
        XCTAssertTrue(momentum.isFinished)
        // Ausrollweg v0 / -ln(0,998^1000) ≈ 2000 / 2 ≈ 1000 Punkte, Ende nach
        // gut zwei Sekunden (wie die normale Abbremsung bei Apple).
        XCTAssertEqual(total, 990, accuracy: 30)
        XCTAssertLessThan(frames, 400)
        XCTAssertEqual(momentum.advance(by: 1.0 / 120.0), 0)
    }

    func testMomentumIndependentOfFrameRate() throws {
        var at60 = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 3_000))
        var at120 = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 3_000))
        var travel60: CGFloat = 0
        var travel120: CGFloat = 0
        for _ in 0..<30 { travel60 += at60.advance(by: 1.0 / 60.0) }
        for _ in 0..<60 { travel120 += at120.advance(by: 1.0 / 120.0) }
        XCTAssertEqual(travel60, travel120, accuracy: 0.5)
        XCTAssertEqual(at60.velocity, at120.velocity, accuracy: 0.5)
    }

    func testMomentumCapsLongPauses() throws {
        var momentum = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 3_000))
        var reference = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 3_000))
        XCTAssertEqual(
            momentum.advance(by: 5), reference.advance(by: TerminalTouchMomentum.maximumStep), accuracy: 0.001)
    }

    func testMomentumStop() throws {
        var momentum = try XCTUnwrap(TerminalTouchMomentum(releaseVelocity: 3_000))
        momentum.stop()
        XCTAssertTrue(momentum.isFinished)
    }

    // MARK: - Tippen wie Klicken

    func testTapCounterCountsQuickTapsAtSamePlace() {
        var counter = TerminalTapCounter()
        XCTAssertEqual(counter.register(at: CGPoint(x: 100, y: 100), time: 10.0, interval: 0.5), 1)
        XCTAssertEqual(counter.register(at: CGPoint(x: 104, y: 98), time: 10.3, interval: 0.5), 2)
        XCTAssertEqual(counter.register(at: CGPoint(x: 101, y: 101), time: 10.6, interval: 0.5), 3)
        // Nach dem Dreifachtipper beginnt die Zählung neu.
        XCTAssertEqual(counter.register(at: CGPoint(x: 101, y: 101), time: 10.9, interval: 0.5), 1)
    }

    func testTapCounterResetsWhenSlowOrFarAway() {
        var counter = TerminalTapCounter()
        XCTAssertEqual(counter.register(at: CGPoint(x: 100, y: 100), time: 10.0, interval: 0.5), 1)
        XCTAssertEqual(counter.register(at: CGPoint(x: 100, y: 100), time: 10.8, interval: 0.5), 1)
        XCTAssertEqual(counter.register(at: CGPoint(x: 200, y: 100), time: 11.0, interval: 0.5), 1)
    }

    // MARK: - Maus und Trackpad bleiben unberührt

    /// Die Erkenner dürfen nur direkte Touches sehen: `buttonMask = 0` schließt
    /// Maus und Trackpad aus, und keiner verzögert Mausereignisse. So laufen
    /// Klick, Ziehen und Scrollrad weiter unverändert über SwiftTerm.
    @MainActor
    func testRecognizersSeeOnlyDirectTouches() throws {
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let gestures = TerminalTouchGestures(attachedTo: terminal) { _, _ in true }
        let recognizers = terminal.gestureRecognizers
        XCTAssertEqual(recognizers.count, 3)
        for recognizer in recognizers {
            XCTAssertEqual(recognizer.allowedTouchTypes, [.direct], "\(type(of: recognizer))")
            XCTAssertFalse(recognizer.delaysPrimaryMouseButtonEvents, "\(type(of: recognizer))")
            XCTAssertFalse(recognizer.delaysSecondaryMouseButtonEvents, "\(type(of: recognizer))")
            XCTAssertFalse(recognizer.delaysKeyEvents, "\(type(of: recognizer))")
            XCTAssertFalse(recognizer.delaysMagnificationEvents, "\(type(of: recognizer))")
        }
        let pan = try XCTUnwrap(recognizers.compactMap { $0 as? NSPanGestureRecognizer }.first)
        XCTAssertEqual(pan.buttonMask, 0)
        let tap = try XCTUnwrap(recognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
        XCTAssertEqual(tap.buttonMask, 0)
        let press = try XCTUnwrap(recognizers.compactMap { $0 as? NSPressGestureRecognizer }.first)
        XCTAssertEqual(press.buttonMask, 0)
        XCTAssertEqual(press.minimumPressDuration, TerminalTouchIntent.holdThreshold)

        gestures.detach()
        XCTAssertTrue(terminal.gestureRecognizers.isEmpty)
    }

    /// Auf der Scrollleiste bildet die Erkennung keinen Klick nach (sonst
    /// hinge die App in der Tracking-Schleife des Scrollers).
    @MainActor
    func testScrollerIsLeftToTheSystem() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let terminal = TerminalView(frame: container.bounds)
        container.addSubview(terminal)
        let gestures = TerminalTouchGestures(attachedTo: terminal) { _, _ in true }
        let scroller = try XCTUnwrap(terminal.subviews.compactMap { $0 as? NSScroller }.first)
        XCTAssertFalse(scroller.isHidden)
        let onScroller = NSPoint(x: scroller.frame.midX, y: scroller.frame.midY)
        XCTAssertFalse(gestures.handlesTouch(at: onScroller))
        XCTAssertTrue(gestures.handlesTouch(at: NSPoint(x: 20, y: 150)))
        XCTAssertFalse(gestures.handlesTouch(at: NSPoint(x: -5, y: 150)))
    }
}
