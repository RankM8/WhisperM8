import Foundation
import XCTest
@testable import WhisperM8

/// Touchpad als Maus, der pure Teil: Aufsetzen ohne Sprung, Beschleunigung,
/// Klick links/rechts, Doppelklick und das Loslassen beim Zurücksetzen.
final class ControllerTouchpadPointerTests: XCTestCase {
    private var pointer = ControllerTouchpadPointer()

    override func setUp() {
        super.setUp()
        pointer = ControllerTouchpadPointer()
    }

    private func touch(
        _ x: Float, _ y: Float, at time: TimeInterval, finger: ControllerTouchFinger = .primary
    ) -> ControllerPointerOutput? {
        pointer.touch(finger, x: x, y: y, at: time)
    }

    private func delta(_ output: ControllerPointerOutput?, file: StaticString = #filePath, line: UInt = #line) -> (dx: Double, dy: Double) {
        guard case let .move(dx, dy)? = output else {
            XCTFail("keine Bewegung: \(String(describing: output))", file: file, line: line)
            return (0, 0)
        }
        return (dx, dy)
    }

    // MARK: - Aufsetzen und Abheben

    /// Die erste Meldung eines Fingers setzt nur den Anker: Der Zeiger springt
    /// nicht dorthin, wo der Finger landet.
    func testLandingOnlyAnchors() {
        XCTAssertNil(touch(0.8, -0.6, at: 0))
        let move = delta(touch(0.82, -0.6, at: 0.01))
        XCTAssertGreaterThan(move.dx, 0)
        XCTAssertEqual(move.dy, 0, accuracy: 1e-9)
    }

    /// (0, 0) heißt „kein Finger“; danach ist der nächste Punkt ein neues Aufsetzen.
    func testZeroMeansLiftedAndNextTouchDoesNotJump() {
        _ = touch(-0.5, 0.2, at: 0)
        _ = touch(-0.45, 0.2, at: 0.01)
        XCTAssertNil(touch(0, 0, at: 0.02))
        XCTAssertNil(pointer.driver)
        XCTAssertNil(touch(-0.44, 0.2, at: 0.03), "neu aufgesetzt, auch ganz in der Nähe")
        XCTAssertNotNil(touch(-0.43, 0.2, at: 0.04))
    }

    /// Meldet das Framework das Abheben nicht: Eine Lücke oder ein großer
    /// Sprung gilt als neues Aufsetzen.
    func testGapOrJumpStartsANewTouch() {
        _ = touch(-0.5, 0.2, at: 0)
        XCTAssertNil(touch(0.6, -0.4, at: 0.01), "Sprung über die halbe Fläche")
        XCTAssertNotNil(touch(0.61, -0.4, at: 0.02))
        XCTAssertNil(touch(0.65, -0.4, at: 0.2), "Lücke länger als 35 ms und weiter als langsames Schieben")
        XCTAssertNotNil(touch(0.66, -0.4, at: 0.21))
    }

    // MARK: - Richtung und Beschleunigung

    func testDirectionsAndVerticalScale() {
        _ = touch(0.1, 0.1, at: 0)
        let right = delta(touch(0.12, 0.1, at: 0.01))
        XCTAssertGreaterThan(right.dx, 0)
        _ = touch(0, 0, at: 0.02)
        _ = touch(0.1, 0.1, at: 0.03)
        let up = delta(touch(0.1, 0.12, at: 0.04))
        XCTAssertLessThan(up.dy, 0, "oben auf dem Touchpad heißt oben auf dem Bildschirm")
        // Die Fläche ist halb so hoch wie breit: gleicher Wert, halber Weg.
        XCTAssertEqual(abs(up.dy), right.dx * 0.5 * (0.5 + 0.55 * 1) / (0.5 + 0.55 * 2), accuracy: 0.01)
    }

    /// Schneller wischen trägt weiter: gleicher Weg in kürzerer Zeit ergibt
    /// mehr Punkte, langsam bleibt es fein.
    func testFasterSwipeGoesFarther() {
        _ = touch(0.1, 0, at: 0)
        let slow = delta(touch(0.11, 0, at: 0.05)).dx      // 0,2 Einheiten/s
        _ = touch(0, 0, at: 0.1)
        _ = touch(0.1, 0, at: 0.2)
        let fast = delta(touch(0.13, 0, at: 0.204)).dx     // 7,5 Einheiten/s
        XCTAssertGreaterThan(fast / 3, slow * 5, "je Weg-Einheit")
        XCTAssertEqual(slow, 0.01 * 280 * (0.5 + 0.55 * 0.2), accuracy: 0.001)
        XCTAssertEqual(fast, 0.03 * 280 * 4, accuracy: 0.001, "gedeckelt")
    }

    func testSpeedSettingScales() {
        pointer.config.speed = 2
        _ = touch(0.1, 0, at: 0)
        let doubled = delta(touch(0.11, 0, at: 0.05)).dx
        XCTAssertEqual(doubled, 2 * 0.01 * 280 * (0.5 + 0.55 * 0.2), accuracy: 0.001)
    }

    // MARK: - Klicken

    func testClickLeftWithOneFinger() {
        _ = touch(0.1, 0, at: 0)
        XCTAssertEqual(pointer.press(at: 0.5), .buttonDown(.left, clickCount: 1))
        XCTAssertEqual(pointer.release(at: 0.6), .buttonUp(.left, clickCount: 1))
        XCTAssertNil(pointer.release(at: 0.7), "kein zweites Loslassen")
    }

    func testClickRightWithTwoFingers() {
        _ = touch(-0.3, 0, at: 0)
        _ = touch(0.3, 0, at: 0.01, finger: .secondary)
        XCTAssertEqual(pointer.press(at: 0.4), .buttonDown(.right, clickCount: 1))
        XCTAssertEqual(pointer.release(at: 0.5), .buttonUp(.right, clickCount: 1))
    }

    /// Ein zweiter Finger, der sich lange nicht gemeldet hat, zählt nicht:
    /// Sein Abheben könnte nie angekommen sein.
    func testStaleSecondFingerClicksLeft() {
        _ = touch(0.3, 0, at: 0, finger: .secondary)
        _ = touch(-0.3, 0, at: 0.5)
        XCTAssertEqual(pointer.press(at: 2.0), .buttonDown(.left, clickCount: 1))
    }

    /// Hebt der erste Finger ab, führt der zweite weiter (und klickt links).
    func testSecondFingerDrivesWhenFirstLifts() {
        _ = touch(-0.3, 0, at: 0)
        _ = touch(0.3, 0, at: 0.01, finger: .secondary)
        XCTAssertNil(touch(0.32, 0, at: 0.02, finger: .secondary), "führt noch nicht")
        _ = touch(0, 0, at: 0.03)
        XCTAssertEqual(pointer.driver, .secondary)
        XCTAssertNotNil(touch(0.34, 0, at: 0.04, finger: .secondary))
        XCTAssertEqual(pointer.press(at: 0.05), .buttonDown(.left, clickCount: 1))
    }

    /// Beim Drücken verrutscht der Finger leicht: kurz keine Bewegung. Danach
    /// zieht der Finger mit gedrückter Taste (Ziehen und Ablegen).
    func testClickSettlesThenDrags() {
        _ = touch(0.1, 0, at: 0)
        XCTAssertNotNil(touch(0.105, 0, at: 0.02))
        _ = pointer.press(at: 0.03)
        XCTAssertNil(touch(0.11, 0, at: 0.05), "Verrutschen beim Drücken")
        XCTAssertNil(touch(0.115, 0, at: 0.07))
        XCTAssertNotNil(touch(0.13, 0, at: 0.13), "Ziehen mit gedrückter Taste")
        XCTAssertNotNil(touch(0.135, 0, at: 0.15))
        _ = pointer.release(at: 0.16)
        XCTAssertNil(touch(0.14, 0, at: 0.18), "Verrutschen beim Loslassen")
    }

    func testDoubleClickCountsWhenQuickAndStill() {
        _ = touch(0.1, 0, at: 0)
        XCTAssertEqual(pointer.press(at: 0.1), .buttonDown(.left, clickCount: 1))
        _ = pointer.release(at: 0.15)
        XCTAssertEqual(pointer.press(at: 0.4), .buttonDown(.left, clickCount: 2))
        XCTAssertEqual(pointer.release(at: 0.45), .buttonUp(.left, clickCount: 2))
        XCTAssertEqual(pointer.press(at: 1.5), .buttonDown(.left, clickCount: 1), "zu spät")
    }

    func testDoubleClickBreaksAfterMovement() {
        _ = touch(0.1, 0, at: 0)
        _ = pointer.press(at: 0.1)
        _ = pointer.release(at: 0.15)
        _ = touch(0.1, 0, at: 0.3)
        _ = touch(0.2, 0, at: 0.31)
        XCTAssertEqual(pointer.press(at: 0.4), .buttonDown(.left, clickCount: 1))
    }

    // MARK: - Framework ohne (0, 0) beim Abheben (Review-Befund 1)

    /// Nachgreifen: Abheben und weiter links wieder aufsetzen, ohne dass das
    /// Framework (0, 0) meldet. Der Zeiger darf nicht rückwärts springen.
    func testRegripWithoutZeroDoesNotJumpBack() {
        _ = touch(0.3, 0, at: 0)
        _ = touch(0.4, 0, at: 0.01)
        _ = touch(0.5, 0, at: 0.02)
        XCTAssertNil(touch(0.2, 0, at: 0.07), "nach 50 ms an anderer Stelle: neu aufgesetzt")
        XCTAssertEqual(pointer.lastTransition, .landed(.primary, .gap))
        XCTAssertGreaterThan(delta(touch(0.25, 0, at: 0.08)).dx, 0, "weiter nach rechts")
    }

    /// Sehr langsames Schieben meldet selten eine neue Position und bleibt
    /// trotzdem eine Bewegung.
    func testVerySlowSlideStillMoves() {
        _ = touch(0.1, 0, at: 0)
        XCTAssertGreaterThan(delta(touch(0.101, 0, at: 0.2)).dx, 0)
        XCTAssertNil(pointer.lastTransition)
    }

    /// Ein liegen gelassener erster Finger, dessen Abheben nie kam, blockiert
    /// nichts: Es führt der Finger, der sich meldet.
    func testSilentFirstFingerDoesNotBlockTheSecond() {
        _ = touch(-0.6, 0, at: 0)
        _ = touch(0.5, 0, at: 0.5, finger: .secondary)
        XCTAssertEqual(pointer.driver, .secondary)
        XCTAssertGreaterThan(delta(touch(0.52, 0, at: 0.51, finger: .secondary)).dx, 0)
        XCTAssertEqual(pointer.press(at: 0.6), .buttonDown(.left, clickCount: 1),
                       "der erste hat sich vor dem Aufsetzen des zweiten zuletzt gemeldet")
    }

    /// Nach einem Rechtsklick ist der nächste Einfingerklick links, auch wenn
    /// das Framework den zweiten Finger nie als abgehoben meldet.
    func testRightClickDoesNotStickToTheNextClick() {
        _ = touch(-0.3, 0, at: 0)
        _ = touch(0.3, 0, at: 0.01, finger: .secondary)
        XCTAssertEqual(pointer.press(at: 0.1), .buttonDown(.right, clickCount: 1))
        _ = pointer.release(at: 0.2)
        _ = touch(-0.29, 0, at: 0.21)
        XCTAssertEqual(pointer.press(at: 0.4), .buttonDown(.left, clickCount: 1))
    }

    /// Wechsel kommen einmal je Abheben bzw. Aufsetzen (für das Log am Gerät).
    func testTransitionsAreReportedOncePerChange() {
        _ = touch(0.1, 0, at: 0)
        XCTAssertEqual(pointer.lastTransition, .landed(.primary, .first))
        _ = touch(0.11, 0, at: 0.01)
        XCTAssertNil(pointer.lastTransition)
        _ = touch(0.9, 0, at: 0.02)
        XCTAssertEqual(pointer.lastTransition, .landed(.primary, .jump))
        _ = touch(0, 0, at: 0.03)
        XCTAssertEqual(pointer.lastTransition, .lifted(.primary))
        _ = touch(0, 0, at: 0.04)
        XCTAssertNil(pointer.lastTransition, "kein zweites Abheben")
    }

    /// Zurücksetzen (Pause, Trennung) lässt eine gedrückte Taste los, sonst
    /// hinge sie im System.
    func testResetReleasesHeldButton() {
        _ = touch(0.1, 0, at: 0)
        _ = pointer.press(at: 0.1)
        XCTAssertEqual(pointer.reset(), .buttonUp(.left, clickCount: 1))
        XCTAssertNil(pointer.reset())
        XCTAssertNil(pointer.driver)
    }
}
