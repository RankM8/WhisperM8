import Foundation
import XCTest
@testable import WhisperM8

/// Ebenen-Tasten L1, R1 und L2 im Erkenner (Runde 4, Controller-Insel):
/// Tippen nur kurz und ohne zweite Taste, Kombinationen sofort, die Insel
/// erst nach 0,3 s.
final class ControllerGestureRecognizerLayerTests: XCTestCase {
    private var recognizer = ControllerGestureRecognizer()

    override func setUp() {
        super.setUp()
        recognizer = ControllerGestureRecognizer()
    }

    private func down(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        if button.isTrigger { return recognizer.handle(.trigger(button, value: 1), at: time) }
        return recognizer.handle(.button(button, pressed: true), at: time)
    }

    private func up(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        if button.isTrigger { return recognizer.handle(.trigger(button, value: 0), at: time) }
        return recognizer.handle(.button(button, pressed: false), at: time)
    }

    func testEachLayerKeyTapsWhenShort() {
        for (key, layer) in [(ControllerButton.l1, ControllerLayer.writing), (.r1, .quickDraw), (.l2, .whereTo)] {
            XCTAssertEqual(ControllerLayer(key: key), layer)
            XCTAssertEqual(down(key, at: 0), [.holdPending(key, duration: 0.3)], "\(key)")
            XCTAssertEqual(up(key, at: 0.29), [.tap(key)], "\(key)")
            XCTAssertTrue(recognizer.isIdle)
        }
    }

    /// Kombination wirkt sofort beim Druck der zweiten Taste; danach gibt es
    /// kein Tippen mehr, die Insel erscheint trotzdem nach 0,3 s.
    func testCombinationFiresImmediatelyAndCancelsTheTap() {
        _ = down(.l1, at: 0)
        XCTAssertEqual(down(.triangle, at: 0.05), [.inLayer(.writing, .press(.triangle))])
        XCTAssertEqual(up(.triangle, at: 0.1), [], "Loslassen in der Ebene ist still")
        XCTAssertEqual(recognizer.tick(at: 0.3), [.layerBegan(.writing)])
        XCTAssertEqual(up(.l1, at: 0.35), [.layerEnded(.writing)])
        XCTAssertTrue(recognizer.isIdle)
    }

    func testShortReleaseAfterCombinationIsNoTap() {
        _ = down(.r1, at: 0)
        _ = down(.cross, at: 0.05)
        XCTAssertEqual(up(.r1, at: 0.1), [.layerEnded(.quickDraw)])
    }

    /// Hold-Tasten (Kreis, Viereck) wirken in einer Ebene beim Drücken, ohne
    /// eigenes Halten.
    func testHoldButtonsActOnPressInsideALayer() {
        _ = down(.r1, at: 0)
        XCTAssertEqual(down(.circle, at: 0.1), [.inLayer(.quickDraw, .press(.circle))])
        XCTAssertEqual(recognizer.tick(at: 1), [.layerBegan(.quickDraw)], "kein .holdBegan(.circle)")
        XCTAssertEqual(up(.circle, at: 1.1), [])
    }

    /// Viereck beim Schreiben: sofort, nach 0,4 s alle 150 ms, nur solange L1
    /// gehalten wird. Danach bleibt Viereck still (keine Rücktaste).
    func testSquareRepeatsLineByLineInTheWritingLayer() {
        _ = down(.l1, at: 0)
        XCTAssertEqual(down(.square, at: 1), [.layerBegan(.writing), .inLayer(.writing, .press(.square))])
        XCTAssertEqual(recognizer.tick(at: 1.39), [])
        XCTAssertEqual(recognizer.tick(at: 1.4), [.inLayer(.writing, .holdRepeat(.square))])
        XCTAssertEqual(recognizer.tick(at: 1.55), [.inLayer(.writing, .holdRepeat(.square))])
        XCTAssertEqual(up(.l1, at: 1.6), [.layerEnded(.writing)])
        XCTAssertEqual(recognizer.tick(at: 1.8), [], "Wiederholung endet mit der Ebene")
        XCTAssertEqual(up(.square, at: 2), [], "kein Tippen, keine Rücktaste")
        XCTAssertTrue(recognizer.isIdle)
    }

    func testSquareDoesNotRepeatInOtherLayers() {
        _ = down(.r1, at: 0)
        _ = down(.square, at: 0.1)
        XCTAssertEqual(recognizer.tick(at: 0.3), [.layerBegan(.quickDraw)])
        XCTAssertEqual(recognizer.tick(at: 1), [])
    }

    /// Stick und Steuerkreuz gehören zur Ebene (bei L2 öffnet der erste Stoß
    /// die Liste) und wiederholen dort; das Ende der Ebene hält das an.
    func testMovesAreWrappedAndRepeatInsideTheLayer() {
        _ = down(.l2, at: 0)
        XCTAssertEqual(recognizer.handle(.stick(.left, x: 0, y: -1), at: 0.1),
                       [.inLayer(.whereTo, .move(.down, source: .leftStick, isRepeat: false))])
        XCTAssertEqual(recognizer.tick(at: 0.3), [.layerBegan(.whereTo)])
        XCTAssertEqual(recognizer.tick(at: 0.5),
                       [.inLayer(.whereTo, .move(.down, source: .leftStick, isRepeat: true))])
        XCTAssertEqual(up(.l2, at: 0.55), [.layerEnded(.whereTo)], "nach einem Stoß kein Tippen")
        XCTAssertEqual(recognizer.tick(at: 0.7), [], "keine Wiederholung mehr")

        _ = recognizer.handle(.stick(.left, x: 0, y: 0), at: 1)
        _ = down(.l2, at: 2)
        XCTAssertEqual(down(.dpadRight, at: 2.1), [.inLayer(.whereTo, .move(.right, source: .dpad, isRepeat: false))])
        XCTAssertEqual(recognizer.tick(at: 2.5),
                       [.layerBegan(.whereTo), .inLayer(.whereTo, .move(.right, source: .dpad, isRepeat: true))])
        XCTAssertEqual(up(.l2, at: 2.55), [.layerEnded(.whereTo)])
        XCTAssertEqual(recognizer.tick(at: 2.7), [])
        XCTAssertEqual(up(.dpadRight, at: 2.8), [])
        XCTAssertTrue(recognizer.isIdle)
    }

    /// Rechter Stick scrollt weiter und macht aus einem Tippen nichts anderes.
    func testScrollingIsNotPartOfALayer() {
        _ = down(.l1, at: 0)
        _ = recognizer.handle(.stick(.right, x: 0, y: -1), at: 0.05)
        let scrolled = recognizer.tick(at: 0.06).contains { gesture in
            if case .scroll = gesture { return true }
            return false
        }
        XCTAssertTrue(scrolled)
        _ = recognizer.handle(.stick(.right, x: 0, y: 0), at: 0.1)
        XCTAssertEqual(up(.l1, at: 0.2), [.tap(.l1)])
    }

    /// Nur eine Ebene zugleich: Unter L2 sind L1 und R1 gewöhnliche Tasten
    /// (kein Pause-Akkord, wie bisher in der Chat-Auswahl).
    func testOtherLayerKeysArePlainButtonsInsideALayer() {
        _ = down(.l2, at: 0)
        XCTAssertEqual(down(.l1, at: 0.1), [.inLayer(.whereTo, .press(.l1))])
        XCTAssertEqual(down(.r1, at: 0.12), [.inLayer(.whereTo, .press(.r1))])
        XCTAssertEqual(recognizer.tick(at: 1.2), [.layerBegan(.whereTo)], "kein Akkord")
        XCTAssertEqual(up(.l1, at: 1.3), [])
        XCTAssertEqual(up(.r1, at: 1.3), [])
        XCTAssertEqual(up(.l2, at: 1.4), [.layerEnded(.whereTo)])

        _ = down(.l1, at: 2)
        XCTAssertEqual(down(.l2, at: 2.05), [.inLayer(.writing, .press(.l2))])
        XCTAssertEqual(up(.l1, at: 2.1), [.layerEnded(.writing)])
        XCTAssertEqual(up(.l2, at: 2.2), [])
    }

    /// R2 diktiert auf jeder Ebene; als Trigger kommt er über den Analogwert.
    func testR2InsideALayer() {
        _ = down(.r1, at: 0)
        XCTAssertEqual(down(.r2, at: 0.1), [.inLayer(.quickDraw, .press(.r2))])
        XCTAssertEqual(up(.r2, at: 0.2), [])
        XCTAssertEqual(up(.r1, at: 0.25), [.layerEnded(.quickDraw)])
    }

    /// Eine vor der Ebene gedrückte Taste behält ihre gewöhnliche Bedeutung.
    func testButtonHeldBeforeTheLayerKeepsItsMeaning() {
        XCTAssertEqual(down(.square, at: 0), [.holdPending(.square, duration: 0.6)])
        _ = down(.l1, at: 0.1)
        XCTAssertEqual(up(.square, at: 0.2), [.holdCancelled(.square), .tap(.square)])
        XCTAssertEqual(up(.l1, at: 0.25), [.tap(.l1)], "ein Loslassen ist keine zweite Taste")
    }
}
