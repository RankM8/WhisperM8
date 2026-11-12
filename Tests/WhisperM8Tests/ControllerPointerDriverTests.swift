import Foundation
import os
import XCTest
@testable import WhisperM8

/// Spion statt echter Mausereignisse.
final class SpyPointerPoster: ControllerPointerPosting, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [ControllerPointerOutput]())

    func post(_ output: ControllerPointerOutput) {
        lock.withLock { $0.append(output) }
    }

    var posted: [ControllerPointerOutput] { lock.withLock { $0 } }
    var moves: Int { posted.filter { if case .move = $0 { return true } else { return false } }.count }
    var buttons: [ControllerPointerOutput] {
        posted.filter { if case .move = $0 { return false } else { return true } }
    }
}

/// Touchpad als Maus auf der Eingabe-Queue: was der Zeiger übernimmt, was an
/// den Erkenner geht, und dass Fingerdaten nie zu Gesten werden.
final class ControllerPointerDriverTests: XCTestCase {
    private var poster = SpyPointerPoster()
    private var driver = ControllerPointerDriver(poster: nil)
    private var clicks = 0

    private static let on = ControllerPointerDriver.Settings(enabled: true, active: true)

    override func setUp() {
        super.setUp()
        poster = SpyPointerPoster()
        driver = ControllerPointerDriver(poster: poster)
        clicks = 0
    }

    private func handle(
        _ event: ControllerInputEvent, at time: TimeInterval, layer: ControllerLayer? = nil
    ) -> ControllerPointerDriver.Disposition {
        driver.handle(event, at: time, activeLayer: layer)
    }

    // MARK: - Schalter aus: alles wie bisher

    func testSwitchOffLeavesTouchpadToTheRecognizer() {
        XCTAssertEqual(handle(.button(.touchpad, pressed: true), at: 0), .recognizer)
        XCTAssertEqual(handle(.button(.touchpad, pressed: false), at: 0.1), .recognizer)
        XCTAssertEqual(handle(.touch(.primary, x: 0.1, y: 0.1), at: 0.2), .handled, "Finger nie in den Erkenner")
        XCTAssertEqual(handle(.touch(.primary, x: 0.2, y: 0.1), at: 0.21), .handled)
        XCTAssertEqual(handle(.button(.cross, pressed: true), at: 0.3), .recognizer)
        XCTAssertEqual(poster.posted, [])
    }

    // MARK: - Schalter an

    func testMovesAndClicks() {
        driver.apply(Self.on)
        driver.onClick = { [weak self] in self?.clicks += 1 }
        XCTAssertEqual(handle(.touch(.primary, x: 0.1, y: 0.1), at: 0), .handled)
        XCTAssertEqual(handle(.touch(.primary, x: 0.15, y: 0.1), at: 0.01), .handled)
        XCTAssertEqual(poster.moves, 1)
        XCTAssertEqual(handle(.button(.touchpad, pressed: true), at: 0.5), .clicked)
        XCTAssertEqual(handle(.button(.touchpad, pressed: false), at: 0.6), .handled)
        XCTAssertEqual(poster.buttons, [.buttonDown(.left, clickCount: 1), .buttonUp(.left, clickCount: 1)])
        XCTAssertEqual(clicks, 1)
    }

    /// L2 gehalten: Der Druck gehört dem Erkenner (Verlauf), kein Klick.
    func testWhereToLayerTakesTheTouchpadPress() {
        driver.apply(Self.on)
        XCTAssertEqual(handle(.button(.touchpad, pressed: true), at: 0, layer: .whereTo), .recognizer)
        XCTAssertEqual(handle(.button(.touchpad, pressed: false), at: 0.1), .recognizer, "auch nach dem Loslassen von L2")
        XCTAssertEqual(poster.buttons, [])
    }

    /// L1 oder R1 gehalten: Der Klick geht raus (die Ebene merkt es sich).
    func testOtherLayersStillClick() {
        driver.apply(Self.on)
        XCTAssertEqual(handle(.button(.touchpad, pressed: true), at: 0, layer: .writing), .clicked)
        XCTAssertEqual(handle(.button(.touchpad, pressed: false), at: 0.1, layer: .writing), .handled)
    }

    /// Pause oder Trockenlauf: weder Zeiger noch Klick noch Verlauf.
    func testInactiveDoesNothing() {
        driver.apply(ControllerPointerDriver.Settings(enabled: true, active: false))
        _ = handle(.touch(.primary, x: 0.1, y: 0.1), at: 0)
        _ = handle(.touch(.primary, x: 0.2, y: 0.1), at: 0.01)
        XCTAssertEqual(handle(.button(.touchpad, pressed: true), at: 0.1), .handled)
        XCTAssertEqual(poster.posted, [])
    }

    /// Pause mitten im Ziehen: Die Taste wird losgelassen.
    func testPauseWhileHeldReleasesTheButton() {
        driver.apply(Self.on)
        _ = handle(.touch(.primary, x: 0.1, y: 0.1), at: 0)
        _ = handle(.button(.touchpad, pressed: true), at: 0.1)
        driver.apply(ControllerPointerDriver.Settings(enabled: true, active: false))
        XCTAssertEqual(poster.buttons, [.buttonDown(.left, clickCount: 1), .buttonUp(.left, clickCount: 1)])
        XCTAssertEqual(handle(.button(.touchpad, pressed: false), at: 0.3), .handled)
        XCTAssertEqual(poster.buttons.count, 2, "kein zweites Loslassen")
    }

    func testSpeedIsClamped() {
        driver.apply(ControllerPointerDriver.Settings(enabled: true, active: true, speed: 50))
        _ = handle(.touch(.primary, x: 0.1, y: 0), at: 0)
        _ = handle(.touch(.primary, x: 0.11, y: 0), at: 0.05)
        guard case let .move(dx, _)? = poster.posted.first else { return XCTFail("keine Bewegung") }
        XCTAssertEqual(dx, 3 * 0.01 * 280 * (0.5 + 0.55 * 0.2), accuracy: 0.001)
    }
}

/// Die Pumpe mit Zeiger: Fingerdaten und Klicks erzeugen keine Gesten, L2 +
/// Touchpad wird zur Ebenen-Geste, ein Klick unter L1 nimmt L1 das Tippen.
final class ControllerGesturePumpPointerTests: XCTestCase {
    private var poster = SpyPointerPoster()
    private var pump = ControllerGesturePump()
    private let received = OSAllocatedUnfairLock(initialState: [ControllerGesture]())
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    override func setUp() {
        super.setUp()
        poster = SpyPointerPoster()
        pump = ControllerGesturePump(pointerPoster: poster)
        let received = received, calls = calls
        pump.onGestures = { gestures, _ in
            received.withLock { $0 += gestures }
            calls.withLock { $0 += 1 }
        }
    }

    private func send(_ events: [ControllerInputEvent]) {
        events.forEach(pump.ingest)
        pump.queue.sync {}
    }

    private var gestures: [ControllerGesture] { received.withLock { $0 } }

    func testTouchesNeverReachTheGestureChannel() {
        pump.setPointer(.init(enabled: true, active: true))
        send([
            .touch(.primary, x: 0.1, y: 0.1), .touch(.primary, x: 0.2, y: 0.1),
            .touch(.secondary, x: -0.3, y: 0), .touch(.primary, x: 0, y: 0),
        ])
        XCTAssertEqual(calls.withLock { $0 }, 0, "kein Paket, auch kein „ruhig“")
        XCTAssertEqual(poster.moves, 1)
    }

    func testClickProducesNoGesture() {
        pump.setPointer(.init(enabled: true, active: true))
        send([.button(.touchpad, pressed: true), .button(.touchpad, pressed: false)])
        XCTAssertEqual(gestures, [])
        XCTAssertEqual(poster.buttons, [.buttonDown(.left, clickCount: 1), .buttonUp(.left, clickCount: 1)])
    }

    func testSwitchOffKeepsTodaysTouchpadPress() {
        send([.button(.touchpad, pressed: true), .button(.touchpad, pressed: false)])
        XCTAssertEqual(gestures, [.press(.touchpad)])
        XCTAssertEqual(poster.posted, [])
    }

    func testL2PlusTouchpadIsALayerGesture() {
        pump.setPointer(.init(enabled: true, active: true))
        send([
            .trigger(.l2, value: 1), .button(.touchpad, pressed: true),
            .button(.touchpad, pressed: false), .trigger(.l2, value: 0),
        ])
        XCTAssertEqual(gestures, [
            .holdPending(.l2, duration: 0.3), .inLayer(.whereTo, .press(.touchpad)), .layerEnded(.whereTo),
        ])
        XCTAssertEqual(poster.posted, [])
    }

    func testClickUnderL1CancelsTheTap() {
        pump.setPointer(.init(enabled: true, active: true))
        send([
            .button(.l1, pressed: true), .button(.touchpad, pressed: true),
            .button(.touchpad, pressed: false), .button(.l1, pressed: false),
        ])
        XCTAssertEqual(gestures, [.holdPending(.l1, duration: 0.3), .layerEnded(.writing)])
        XCTAssertEqual(poster.buttons.count, 2)
    }

    func testResetReleasesAHeldClick() {
        pump.setPointer(.init(enabled: true, active: true))
        send([.button(.touchpad, pressed: true)])
        pump.reset()
        pump.queue.sync {}
        XCTAssertEqual(poster.buttons, [.buttonDown(.left, clickCount: 1), .buttonUp(.left, clickCount: 1)])
    }
}
