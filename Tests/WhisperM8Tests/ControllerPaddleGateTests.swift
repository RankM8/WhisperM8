import XCTest
@testable import WhisperM8

/// Weiche gegen die doppelte Taste der Paddles (Plan
/// `controller-xbox-paddles.md`, „Weiche gegen die doppelte Taste“).
final class ControllerPaddleGateTests: XCTestCase {
    private var gate = ControllerPaddleGate()

    override func setUp() {
        super.setUp()
        gate = ControllerPaddleGate()
        _ = gate.setPaddleSource(available: true)
    }

    private func report(mask: UInt32? = nil, _ buttons: [(ControllerButton, Bool)] = []) -> ControllerHIDReport {
        ControllerHIDReport(paddleMask: mask, buttons: buttons.map { .init(button: $0.0, pressed: $0.1) })
    }

    private func gc(_ button: ControllerButton, _ pressed: Bool, at time: TimeInterval) -> [ControllerInputEvent] {
        gate.gameController(.button(button, pressed: pressed), origin: .xbox, at: time)
    }

    // MARK: - Reihenfolge

    func testHIDFirstSwallowsTheFaceButton() {
        // Paddle P3 (Bit 4) auf A gelegt: HID zuerst, GameController 2 ms danach.
        XCTAssertEqual(gate.hid(report(mask: 0x4, [(.cross, true)]), at: 0), [.button(.paddleUpperLeft, pressed: true)])
        XCTAssertEqual(gc(.cross, true, at: 0.002), [])
        XCTAssertEqual(gate.hid(report(mask: 0, [(.cross, false)]), at: 0.2), [.button(.paddleUpperLeft, pressed: false)])
        XCTAssertEqual(gc(.cross, false, at: 0.202), [], "Loslassen wird ebenfalls verschluckt")
        XCTAssertEqual(gate.stats.swallowed, 1)
    }

    func testGameControllerFirstIsHeldUntilTheVerdict() {
        XCTAssertEqual(gc(.cross, true, at: 0), [])
        XCTAssertEqual(gate.nextDeadline, ControllerPaddleGate.holdLimit)
        XCTAssertEqual(gate.hid(report(mask: 0x4, [(.cross, true)]), at: 0.003),
                       [.button(.paddleUpperLeft, pressed: true)])
        XCTAssertNil(gate.nextDeadline)
        XCTAssertEqual(gc(.cross, false, at: 0.1), [])
    }

    func testDirectVerdictReleasesImmediately() {
        XCTAssertEqual(gc(.cross, true, at: 0), [])
        XCTAssertEqual(gate.hid(report([(.cross, true)]), at: 0.002), [.button(.cross, pressed: true)])
        XCTAssertEqual(gc(.cross, false, at: 0.1), [.button(.cross, pressed: false)])
    }

    func testDirectPressWithVerdictFirstHasNoDelay() {
        XCTAssertEqual(gate.hid(report([(.cross, true)]), at: 0), [])
        XCTAssertEqual(gc(.cross, true, at: 0.001), [.button(.cross, pressed: true)])
        XCTAssertEqual(gate.stats.holds, 0)
    }

    func testMissingVerdictPassesAfterTheDeadline() {
        XCTAssertEqual(gc(.square, true, at: 0), [])
        XCTAssertEqual(gate.tick(at: 0.039), [])
        XCTAssertEqual(gate.tick(at: 0.04), [.button(.square, pressed: true)])
        XCTAssertEqual(gate.stats.holdsExpired, 1)
        XCTAssertEqual(gate.stats.longestHold, 0.04, accuracy: 1e-9)
    }

    func testLaterEventsWaitBehindAHeldPress() {
        XCTAssertEqual(gc(.cross, true, at: 0), [])
        XCTAssertEqual(gate.gameController(.stick(.left, x: 1, y: 0), origin: .xbox, at: 0.001), [])
        XCTAssertEqual(gate.hid(report([(.cross, true)]), at: 0.002),
                       [.button(.cross, pressed: true), .stick(.left, x: 1, y: 0)])
    }

    func testTriggersAndSticksAreNeverHeld() {
        XCTAssertEqual(gate.gameController(.trigger(.r2, value: 1), origin: .xbox, at: 0), [.trigger(.r2, value: 1)])
        XCTAssertEqual(gate.gameController(.stick(.right, x: 0, y: 1), origin: .xbox, at: 0),
                       [.stick(.right, x: 0, y: 1)])
    }

    // MARK: - Mehrere Paddles

    func testTwoPaddlesInOneReport() {
        let out = gate.hid(report(mask: 0x3, [(.circle, true), (.triangle, true)]), at: 0)
        XCTAssertEqual(Set(out.map { "\($0)" }), Set([
            ControllerInputEvent.button(.paddleUpperRight, pressed: true),
            .button(.paddleLowerRight, pressed: true),
        ].map { "\($0)" }))
        XCTAssertEqual(gc(.circle, true, at: 0.001), [])
        XCTAssertEqual(gc(.triangle, true, at: 0.002), [])
    }

    /// Gemessene Folge (probe2.txt): Paddle-Bit 4 los, Bit 2 dazu, A los, Y
    /// gedrückt — alles in einem Bericht.
    func testPaddleToPaddleInOneReport() {
        _ = gate.hid(report(mask: 0x4, [(.cross, true)]), at: 0)
        XCTAssertEqual(gc(.cross, true, at: 0.001), [])
        XCTAssertEqual(gate.hid(report(mask: 0x2, [(.cross, false), (.triangle, true)]), at: 0.3),
                       [.button(.paddleUpperLeft, pressed: false), .button(.paddleLowerRight, pressed: true)])
        XCTAssertEqual(gc(.cross, false, at: 0.301), [])
        XCTAssertEqual(gc(.triangle, true, at: 0.302), [])
        XCTAssertEqual(gate.hid(report(mask: 0, [(.triangle, false)]), at: 0.6),
                       [.button(.paddleLowerRight, pressed: false)])
        XCTAssertEqual(gc(.triangle, false, at: 0.601), [])
    }

    /// A von Hand gehalten, dann das A-Paddle: GameController meldet nichts,
    /// das spätere Loslassen von A geht normal durch.
    func testHandHeldButtonPlusItsPaddle() {
        _ = gate.hid(report([(.cross, true)]), at: 0)
        XCTAssertEqual(gc(.cross, true, at: 0.001), [.button(.cross, pressed: true)])
        XCTAssertEqual(gate.hid(report(mask: 0x4), at: 0.5), [.button(.paddleUpperLeft, pressed: true)])
        XCTAssertEqual(gate.hid(report(mask: 0), at: 0.7), [.button(.paddleUpperLeft, pressed: false)])
        XCTAssertEqual(gc(.cross, false, at: 0.9), [.button(.cross, pressed: false)])
    }

    // MARK: - Durchgang, Reset, Verfall

    func testOtherFamiliesPassStraightThrough() {
        XCTAssertEqual(gate.gameController(.button(.cross, pressed: true), origin: .playStation, at: 0),
                       [.button(.cross, pressed: true)])
        XCTAssertNil(gate.nextDeadline)
    }

    func testWithoutHIDPaddlesTheGateIsAPassage() {
        var plain = ControllerPaddleGate()
        XCTAssertEqual(plain.gameController(.button(.cross, pressed: true), origin: .xbox, at: 0),
                       [.button(.cross, pressed: true)])
        XCTAssertNil(plain.nextDeadline)
    }

    func testSwitchingTheSourceOffReleasesHeldEvents() {
        XCTAssertEqual(gc(.cross, true, at: 0), [])
        XCTAssertEqual(gate.setPaddleSource(available: false), [.button(.cross, pressed: true)])
        XCTAssertNil(gate.nextDeadline)
    }

    func testResetWhileHolding() {
        XCTAssertEqual(gc(.cross, true, at: 0), [])
        gate.reset()
        XCTAssertNil(gate.nextDeadline)
        XCTAssertEqual(gate.tick(at: 1), [])
        // Nach dem Reset beginnt die Maske bei null.
        XCTAssertEqual(gate.hid(report(mask: 0x1), at: 2), [.button(.paddleUpperRight, pressed: true)])
    }

    func testVerdictsExpire() {
        _ = gate.hid(report(mask: 0x4, [(.cross, true)]), at: 0)
        _ = gate.hid(report(mask: 0), at: 0.05)
        // Über 100 ms später: kein Urteil mehr, zurückhalten bis zur Frist.
        XCTAssertEqual(gc(.cross, true, at: 0.2), [])
        XCTAssertEqual(gate.tick(at: 0.24), [.button(.cross, pressed: true)])
    }

    func testHomeButtonActsAsTouchpad() {
        XCTAssertEqual(gate.hid(ControllerHIDReport(homeButton: true), at: 0), [.button(.touchpad, pressed: true)])
        XCTAssertEqual(gate.hid(ControllerHIDReport(homeButton: false), at: 0.1), [.button(.touchpad, pressed: false)])
    }

    // MARK: - Mit Erkenner

    func testGestureChainProducesOnlyThePaddle() {
        var recognizer = ControllerGestureRecognizer()
        var gestures: [ControllerGesture] = []
        for event in gate.hid(report(mask: 0x4, [(.cross, true)]), at: 0) { gestures += recognizer.handle(event, at: 0) }
        for event in gc(.cross, true, at: 0.002) { gestures += recognizer.handle(event, at: 0.002) }
        XCTAssertEqual(gestures, [.press(.paddleUpperLeft)])
    }
}

/// Die Pumpe schaltet die Weiche vor den Erkenner und stellt ihre Frist.
final class ControllerGesturePumpGateTests: XCTestCase {
    func testPumpRoutesHIDAndHoldsUntilTheDeadline() {
        let pump = ControllerGesturePump()
        let lock = NSLock()
        var seen: [ControllerGesture] = []
        let done = expectation(description: "Gesten")
        done.expectedFulfillmentCount = 2
        pump.onGestures = { gestures, _ in
            guard !gestures.isEmpty else { return }
            lock.lock(); seen += gestures; lock.unlock()
            done.fulfill()
        }
        pump.setPaddleSourceAvailable(true)
        // Paddle über HID, die mitgeschickte Taste wird verschluckt.
        pump.ingestHID(ControllerHIDReport(paddleMask: 0x4, buttons: [.init(button: .cross, pressed: true)]))
        pump.ingest(.button(.cross, pressed: true), origin: .xbox)
        // Druck ohne Urteil: geht nach der Frist (Zeitgeber der Pumpe) durch.
        pump.ingest(.button(.triangle, pressed: true), origin: .xbox)
        wait(for: [done], timeout: 2)
        lock.lock(); let gestures = seen; lock.unlock()
        XCTAssertEqual(gestures, [.press(.paddleUpperLeft), .press(.triangle)])
        XCTAssertEqual(pump.paddleGateStats.swallowed, 1)
        XCTAssertEqual(pump.paddleGateStats.holdsExpired, 1)
    }
}
