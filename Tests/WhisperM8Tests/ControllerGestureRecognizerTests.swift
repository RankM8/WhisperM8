import Foundation
import XCTest
@testable import WhisperM8

/// Tasten, Trigger und Akkord des Erkenners (Plan Etappe 3, Punkt 2).
final class ControllerGestureRecognizerTests: XCTestCase {
    private var recognizer = ControllerGestureRecognizer()

    override func setUp() {
        super.setUp()
        recognizer = ControllerGestureRecognizer()
    }

    private func down(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.button(button, pressed: true), at: time)
    }

    private func up(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.button(button, pressed: false), at: time)
    }

    private func trigger(_ button: ControllerButton, _ value: Float, at time: TimeInterval) -> [ControllerGesture] {
        recognizer.handle(.trigger(button, value: value), at: time)
    }

    // MARK: - Sofort-Tasten

    func testImmediateButtonsFireOnPressOnly() {
        for button in [ControllerButton.cross, .triangle, .l3, .r3, .create, .options, .touchpad] {
            XCTAssertEqual(down(button, at: 1), [.press(button)], "\(button)")
            XCTAssertEqual(up(button, at: 1.1), [], "\(button)")
        }
        XCTAssertTrue(recognizer.isIdle)
        XCTAssertNil(recognizer.nextDeadline)
    }

    func testRepeatedPressWithoutReleaseIsIgnored() {
        XCTAssertEqual(down(.cross, at: 0), [.press(.cross)])
        XCTAssertEqual(down(.cross, at: 0.05), [])
        XCTAssertEqual(up(.cross, at: 0.1), [])
        XCTAssertEqual(up(.cross, at: 0.2), [])
    }

    // MARK: - Tippen oder Halten

    func testL2TapBeforeThreshold() {
        XCTAssertEqual(down(.l2Digital, at: 0), [])  // digitale Trigger-Ereignisse zählen nicht
        XCTAssertEqual(trigger(.l2, 1, at: 0), [.holdPending(.l2, duration: 0.3)])
        XCTAssertEqual(recognizer.nextDeadline ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(trigger(.l2, 0, at: 0.2), [.holdCancelled(.l2), .tap(.l2)])
        XCTAssertTrue(recognizer.isIdle)
    }

    func testL2HoldViaTick() {
        _ = trigger(.l2, 1, at: 0)
        XCTAssertEqual(recognizer.tick(at: 0.29), [])
        XCTAssertEqual(recognizer.tick(at: 0.3), [.holdBegan(.l2)])
        XCTAssertEqual(recognizer.tick(at: 0.5), [], "nur einmal")
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(trigger(.l2, 0, at: 2), [.holdEnded(.l2)])
    }

    func testCircleTapAndHold() {
        XCTAssertEqual(down(.circle, at: 10), [.holdPending(.circle, duration: 0.4)])
        XCTAssertEqual(up(.circle, at: 10.1), [.holdCancelled(.circle), .tap(.circle)])

        XCTAssertEqual(down(.circle, at: 20), [.holdPending(.circle, duration: 0.4)])
        XCTAssertEqual(recognizer.tick(at: 20.4), [.holdBegan(.circle)])
        XCTAssertEqual(up(.circle, at: 21), [.holdEnded(.circle)])
    }

    /// 0,35 s liegt hinter der L2-Schwelle, aber vor der Kreis-Schwelle.
    func testReleaseBetweenTheTwoThresholds() {
        _ = down(.circle, at: 0)
        XCTAssertEqual(up(.circle, at: 0.35), [.holdCancelled(.circle), .tap(.circle)])

        _ = trigger(.l2, 1, at: 1)
        XCTAssertEqual(trigger(.l2, 0, at: 1.35), [.holdBegan(.l2), .holdEnded(.l2)])
    }

    func testReleaseExactlyAtThresholdCountsAsHold() {
        _ = down(.circle, at: 0.1)
        XCTAssertEqual(up(.circle, at: 0.5), [.holdBegan(.circle), .holdEnded(.circle)])
    }

    /// Der Zeitgeber feuert gar nicht oder 5 s zu spät: die Zeitstempel entscheiden.
    func testLateTimerKeepsDecisionCorrect() {
        _ = down(.circle, at: 0)
        XCTAssertEqual(up(.circle, at: 5), [.holdBegan(.circle), .holdEnded(.circle)])

        _ = down(.circle, at: 10)
        XCTAssertEqual(recognizer.tick(at: 15), [.holdBegan(.circle)])
        XCTAssertEqual(up(.circle, at: 15.1), [.holdEnded(.circle)])

        // Kurzes Tippen bleibt ein Tippen, auch wenn der Tick erst später kommt.
        _ = down(.circle, at: 20)
        XCTAssertEqual(up(.circle, at: 20.1), [.holdCancelled(.circle), .tap(.circle)])
        XCTAssertEqual(recognizer.tick(at: 25), [])
    }

    func testOtherEventCatchesUpOverdueHold() {
        _ = trigger(.l2, 1, at: 0)
        // Kein Tick; das nächste Ereignis holt die fällige Entscheidung nach.
        XCTAssertEqual(down(.cross, at: 1), [.holdBegan(.l2), .press(.cross)])
    }

    func testSquareIsTapOrHold() {
        XCTAssertEqual(down(.square, at: 0), [.holdPending(.square, duration: 0.6)])
        XCTAssertEqual(up(.square, at: 0.2), [.holdCancelled(.square), .tap(.square)])
        _ = down(.square, at: 1)
        XCTAssertEqual(recognizer.tick(at: 1.6), [.holdBegan(.square)])
    }

    // MARK: - Trigger

    func testTriggerHysteresis() {
        XCTAssertEqual(trigger(.r2, 0.02, at: 0), [], "0,02 löst nie aus")
        XCTAssertEqual(trigger(.r2, 0.49, at: 0.1), [])
        XCTAssertEqual(trigger(.r2, 0.5, at: 0.2), [.press(.r2)])
        XCTAssertEqual(trigger(.r2, 0.35, at: 0.3), [], "hält zwischen den Schwellen")
        XCTAssertEqual(trigger(.r2, 0.6, at: 0.4), [], "kein zweites Auslösen")
        XCTAssertFalse(recognizer.isIdle)
        XCTAssertEqual(trigger(.r2, 0.25, at: 0.5), [], "frei, R2 meldet beim Loslassen nichts")
        XCTAssertTrue(recognizer.isIdle)
        XCTAssertEqual(trigger(.r2, 0.5, at: 0.6), [.press(.r2)])
    }

    func testDigitalTriggerEventsAreIgnored() {
        XCTAssertEqual(down(.r2, at: 0), [])
        XCTAssertEqual(down(.l2, at: 0), [])
        XCTAssertTrue(recognizer.isIdle)
    }

    func testTriggerValueOnNonTriggerIsIgnored() {
        XCTAssertEqual(trigger(.cross, 1, at: 0), [])
        XCTAssertTrue(recognizer.isIdle)
    }

    // MARK: - Steuerkreuz

    func testDpadRepeatsWhileHeld() {
        XCTAssertEqual(down(.dpadDown, at: 0), [.move(.down, source: .dpad, isRepeat: false)])
        XCTAssertEqual(recognizer.nextDeadline ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(recognizer.tick(at: 0.39), [])
        XCTAssertEqual(recognizer.tick(at: 0.4), [.move(.down, source: .dpad, isRepeat: true)])
        XCTAssertEqual(recognizer.nextDeadline ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(recognizer.tick(at: 0.5), [.move(.down, source: .dpad, isRepeat: true)])
        XCTAssertEqual(recognizer.tick(at: 0.6), [.move(.down, source: .dpad, isRepeat: true)])
        XCTAssertEqual(up(.dpadDown, at: 0.65), [])
        XCTAssertEqual(recognizer.tick(at: 0.7), [])
        XCTAssertNil(recognizer.nextDeadline)
    }

    func testDpadLateTickRepeatsOnlyOnce() {
        _ = down(.dpadUp, at: 0)
        XCTAssertEqual(recognizer.tick(at: 5), [.move(.up, source: .dpad, isRepeat: true)])
        XCTAssertEqual(recognizer.nextDeadline ?? -1, 5.1, accuracy: 1e-9)
    }

    func testNewDpadDirectionTakesOverRepeat() {
        _ = down(.dpadUp, at: 0)
        XCTAssertEqual(down(.dpadRight, at: 0.2), [.move(.right, source: .dpad, isRepeat: false)])
        XCTAssertEqual(recognizer.tick(at: 0.6), [.move(.right, source: .dpad, isRepeat: true)])
        XCTAssertEqual(up(.dpadUp, at: 0.65), [])
        XCTAssertEqual(recognizer.tick(at: 0.7), [.move(.right, source: .dpad, isRepeat: true)])
    }

    // MARK: - L1 / R1 und Akkord

    func testSingleL1FiresAfterChordWindow() {
        XCTAssertEqual(down(.l1, at: 0), [])
        XCTAssertEqual(recognizer.nextDeadline ?? -1, 0.15, accuracy: 1e-9)
        XCTAssertEqual(recognizer.tick(at: 0.15), [.press(.l1)])
        XCTAssertEqual(recognizer.tick(at: 0.3), [])
        XCTAssertEqual(up(.l1, at: 1), [], "genau einmal")
    }

    func testSingleL1FiresOnEarlyRelease() {
        XCTAssertEqual(down(.r1, at: 0), [])
        XCTAssertEqual(up(.r1, at: 0.05), [.press(.r1)])
        XCTAssertEqual(recognizer.tick(at: 0.2), [])
        XCTAssertNil(recognizer.nextDeadline)
    }

    func testSingleL1ReleasedLateWithoutTickFiresOnce() {
        _ = down(.l1, at: 0)
        XCTAssertEqual(up(.l1, at: 3), [.press(.l1)])
    }

    func testChordWithinWindowCompletes() {
        XCTAssertEqual(down(.l1, at: 0), [])
        XCTAssertEqual(down(.r1, at: 0.1), [.chordPending(duration: 1.0)])
        XCTAssertEqual(recognizer.nextDeadline ?? -1, 1.1, accuracy: 1e-9)
        XCTAssertEqual(recognizer.tick(at: 0.15), [], "kein .press für L1")
        XCTAssertEqual(recognizer.tick(at: 1.1), [.chordCompleted])
        XCTAssertEqual(recognizer.tick(at: 2), [], "nur einmal")
        XCTAssertEqual(up(.l1, at: 2.1), [])
        // Bis beide los sind, löst keine der beiden etwas aus.
        XCTAssertEqual(down(.l1, at: 2.2), [])
        XCTAssertEqual(recognizer.tick(at: 2.5), [])
        XCTAssertEqual(up(.l1, at: 2.6), [])
        XCTAssertEqual(up(.r1, at: 2.7), [])
        XCTAssertTrue(recognizer.isIdle)
        // Danach wieder normal.
        _ = down(.r1, at: 3)
        XCTAssertEqual(up(.r1, at: 3.05), [.press(.r1)])
    }

    func testChordOutsideWindowGivesTwoPresses() {
        _ = down(.l1, at: 0)
        XCTAssertEqual(down(.r1, at: 0.2), [.press(.l1), .press(.r1)])
        XCTAssertEqual(recognizer.tick(at: 2), [], "kein Akkord")
    }

    func testChordReleasedEarlyCancelsAndSuppresses() {
        _ = down(.r1, at: 0)
        XCTAssertEqual(down(.l1, at: 0.05), [.chordPending(duration: 1.0)])
        XCTAssertEqual(up(.r1, at: 0.5), [.chordCancelled])
        XCTAssertEqual(recognizer.tick(at: 2), [])
        XCTAssertEqual(up(.l1, at: 2.1), [], "nach dem Akkord kein .press")
        XCTAssertTrue(recognizer.isIdle)
    }

    func testChordCompletesOnReleaseWithoutTick() {
        _ = down(.l1, at: 0)
        _ = down(.r1, at: 0.1)
        XCTAssertEqual(up(.l1, at: 3), [.chordCompleted])
    }

    // MARK: - Zurücksetzen

    func testResetReleasesEverything() {
        _ = trigger(.l2, 1, at: 0)
        _ = recognizer.tick(at: 0.3)          // L2 hält
        _ = down(.circle, at: 0.4)            // Kreis wartet noch
        _ = down(.l1, at: 0.5)
        _ = down(.r1, at: 0.55)               // Akkord läuft
        _ = down(.dpadLeft, at: 0.6)
        _ = recognizer.handle(.stick(.left, x: 0, y: 1), at: 0.6)
        _ = recognizer.handle(.stick(.right, x: 0, y: -1), at: 0.6)
        XCTAssertFalse(recognizer.isIdle)

        let gestures = recognizer.reset(at: 0.7)
        XCTAssertEqual(gestures, [.holdCancelled(.circle), .holdCancelled(.l2), .chordCancelled])
        XCTAssertTrue(recognizer.isIdle)
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertEqual(recognizer.tick(at: 5), [])
        // Loslassen nach dem Zurücksetzen bleibt ohne Wirkung.
        XCTAssertEqual(trigger(.l2, 0, at: 5.1), [])
        XCTAssertEqual(up(.circle, at: 5.1), [])
    }

    func testResetDoesNotCatchUpOverdueDecisions() {
        _ = trigger(.l2, 1, at: 0)
        _ = down(.l1, at: 0)
        XCTAssertEqual(recognizer.reset(at: 5), [.holdCancelled(.l2)], "kein .holdBegan, kein .press(.l1)")
    }

    func testNextDeadlineIsNilWhenNothingIsActive() {
        XCTAssertNil(recognizer.nextDeadline)
        XCTAssertTrue(recognizer.isIdle)
        _ = down(.cross, at: 0)
        XCTAssertNil(recognizer.nextDeadline, "Sofort-Tasten brauchen keinen Zeitgeber")
        XCTAssertFalse(recognizer.isIdle)
        _ = up(.cross, at: 0.1)
        XCTAssertTrue(recognizer.isIdle)
    }
}

private extension ControllerButton {
    /// Lesbarer Alias im Test: digitales L2-Ereignis, das ignoriert werden muss.
    static let l2Digital = ControllerButton.l2
}
