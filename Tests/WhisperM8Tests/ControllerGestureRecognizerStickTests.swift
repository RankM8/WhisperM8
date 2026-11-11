import Foundation
import XCTest
@testable import WhisperM8

/// Linker Stick (Richtungen) und rechter Stick (Scrollen) des Erkenners.
final class ControllerGestureRecognizerStickTests: XCTestCase {
    private var recognizer = ControllerGestureRecognizer()

    override func setUp() {
        super.setUp()
        recognizer = ControllerGestureRecognizer()
    }

    private func left(_ x: Float, _ y: Float, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.stick(.left, x: x, y: y), at: time)
    }

    private func right(_ y: Float, x: Float = 0, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.stick(.right, x: x, y: y), at: time)
    }

    private func move(_ direction: ControllerDirection, repeat isRepeat: Bool = false) -> ControllerGesture {
        .move(direction, source: .leftStick, isRepeat: isRepeat)
    }

    // MARK: - Linker Stick

    func testDeadzoneAndActivationThreshold() {
        XCTAssertEqual(left(0.1, 0.1, at: 0), [])
        XCTAssertTrue(recognizer.isIdle, "innerhalb der Totzone gilt der Stick als in Ruhe")
        XCTAssertEqual(left(0.5, 0, at: 0.1), [], "ausgelenkt, aber unter 0,6")
        XCTAssertFalse(recognizer.isIdle)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(left(0.6, 0, at: 0.2), [move(.right)])
    }

    func testDirectionsFollowAxisSigns() {
        XCTAssertEqual(left(0, 0.9, at: 0), [move(.up)], "y positiv heißt oben")
        XCTAssertEqual(left(0, 0, at: 0.1), [])
        XCTAssertEqual(left(0, -0.9, at: 0.2), [move(.down)])
        XCTAssertEqual(left(0, 0, at: 0.3), [])
        XCTAssertEqual(left(-0.9, 0, at: 0.4), [move(.left)])
    }

    func testReleaseHysteresis() {
        XCTAssertEqual(left(0.7, 0, at: 0), [move(.right)])
        XCTAssertEqual(left(0.45, 0, at: 0.1), [], "bleibt aktiv bis unter 0,4")
        XCTAssertEqual(left(0.39, 0, at: 0.2), [], "frei, ohne neue Geste")
        XCTAssertEqual(left(0.55, 0, at: 0.3), [], "unter 0,6 kein neues Auslösen")
        XCTAssertEqual(left(0.6, 0, at: 0.4), [move(.right)])
    }

    func testDiagonalDoesNotFlutter() {
        XCTAssertEqual(left(0.72, 0.7, at: 0), [move(.right)])
        var all: [ControllerGesture] = []
        for step in 1...20 {
            let time = Double(step) * 0.01
            all += step.isMultiple(of: 2) ? left(0.7, 0.72, at: time) : left(0.72, 0.7, at: time)
        }
        XCTAssertEqual(all, [], "an der Diagonale wechselt die Richtung nicht hin und her")
        XCTAssertEqual(left(0.5, 0.8, at: 0.3), [move(.up)], "deutlich dominante andere Achse wechselt")
    }

    func testFlipToOppositeDirection() {
        XCTAssertEqual(left(0.9, 0, at: 0), [move(.right)])
        XCTAssertEqual(left(-0.9, 0, at: 0.05), [move(.left)])
    }

    func testReturnToCenterStopsRepeat() {
        XCTAssertEqual(left(0, 1, at: 0), [move(.up)])
        XCTAssertEqual(recognizer.tick(at: 0.4), [move(.up, repeat: true)])
        XCTAssertEqual(recognizer.tick(at: 0.5), [move(.up, repeat: true)])
        XCTAssertEqual(left(0, 0, at: 0.55), [])
        XCTAssertTrue(recognizer.isIdle)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(recognizer.tick(at: 0.6), [])
    }

    // MARK: - Rechter Stick

    func testRightStickInsideDeadzoneDoesNothing() {
        XCTAssertEqual(right(0.2, at: 0), [])
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.isIdle)
        XCTAssertEqual(right(0, x: 1, at: 0.1), [], "nur die y-Achse zählt")
        XCTAssertNil(recognizer.nextDeadline)
    }

    func testRightStickScrollsWithBoundedRate() {
        XCTAssertEqual(right(-1, at: 0), [], "Scrollen kommt nur über tick")
        var lines = 0
        var ticks = 0
        // Messfenster [0, 1) s; der kleine Abzug fängt Rundungsfehler der Fristen ab.
        while let deadline = recognizer.nextDeadline, deadline < 1.0 - 1e-6, ticks < 1000 {
            for gesture in recognizer.tick(at: deadline) {
                guard case let .scroll(count) = gesture else { return XCTFail("unerwartet: \(gesture)") }
                XCTAssertGreaterThan(count, 0, "Stick nach unten scrollt nach unten")
                lines += count
            }
            ticks += 1
        }
        XCTAssertLessThanOrEqual(lines, 30, "höchstens 30 Zeilen pro Sekunde")
        XCTAssertGreaterThanOrEqual(lines, 28)
    }

    func testRightStickRateGrowsWithDeflection() {
        func linesInOneSecond(_ y: Float) -> Int {
            var recognizer = ControllerGestureRecognizer()
            _ = recognizer.handle(.stick(.right, x: 0, y: y), at: 0)
            var lines = 0
            for step in 0..<100 {
                for case let .scroll(count) in recognizer.tick(at: Double(step) * 0.01) { lines += abs(count) }
            }
            return lines
        }
        let slow = linesInOneSecond(0.4)
        let fast = linesInOneSecond(1.0)
        XCTAssertGreaterThan(slow, 0)
        XCTAssertLessThan(slow, fast)
        XCTAssertLessThanOrEqual(fast, 30)
    }

    func testRightStickUpScrollsUp() {
        _ = right(0.9, at: 0)
        XCTAssertEqual(recognizer.tick(at: 0), [.scroll(lines: -1)])
    }

    func testRightStickLateTickIsCapped() {
        _ = right(-1, at: 0)
        _ = recognizer.tick(at: 0)
        let gestures = recognizer.tick(at: 5)
        guard case let .scroll(count)? = gestures.first else { return XCTFail("kein Scrollen") }
        XCTAssertLessThanOrEqual(count, 8, "ein später Tick holt höchstens 0,25 s nach")
    }

    func testRightStickReturnToCenterStops() {
        _ = right(-1, at: 0)
        XCTAssertNotNil(recognizer.nextDeadline)
        _ = right(0, at: 0.1)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.isIdle)
        XCTAssertEqual(recognizer.tick(at: 0.2), [])
    }
}
