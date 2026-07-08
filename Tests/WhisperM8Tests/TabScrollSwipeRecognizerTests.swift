import AppKit
import XCTest
@testable import WhisperM8

/// Zwei-Finger-Swipe-Erkennung (Tab links/rechts, Safari-Stil): Achsen-
/// Entscheid, Einmal-Trigger, Momentum-Schlucken, Durchreichen vertikaler
/// Gesten. Deltas im Finger-Raum: positiv = Finger nach rechts/unten.
final class TabScrollSwipeRecognizerTests: XCTestCase {
    private var recognizer = TabScrollSwipeRecognizer()

    private func changed(_ dx: CGFloat, _ dy: CGFloat = 0) -> TabScrollSwipeRecognizer.Verdict {
        recognizer.handle(phase: .changed, momentumPhase: [], deltaX: dx, deltaY: dy)
    }

    // MARK: - Horizontale Geste

    func testSwipeRightTriggersNextTabExactlyOnce() {
        XCTAssertEqual(recognizer.handle(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        // Achsen-Entscheid nach 8pt: ab jetzt konsumieren.
        XCTAssertEqual(changed(10), .consume)
        XCTAssertEqual(changed(20), .consume)
        // 60pt akkumuliert → genau ein Trigger, Finger rechts = Tab rechts.
        XCTAssertEqual(changed(30), .trigger(direction: 1))
        // Weitere Bewegung derselben Geste löst nicht erneut aus.
        XCTAssertEqual(changed(50), .consume)
        XCTAssertEqual(recognizer.handle(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0), .consume)
    }

    func testSwipeLeftTriggersPreviousTab() {
        XCTAssertEqual(changed(-40), .consume)
        XCTAssertEqual(changed(-40), .trigger(direction: -1))
    }

    func testHorizontalMomentumIsConsumed() {
        XCTAssertEqual(changed(80), .trigger(direction: 1))
        XCTAssertEqual(recognizer.handle(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0), .consume)
        // Momentum-Ausläufer der horizontalen Geste erreichen die TUI nie.
        XCTAssertEqual(recognizer.handle(phase: [], momentumPhase: .changed, deltaX: 12, deltaY: 0), .consume)
        XCTAssertEqual(recognizer.handle(phase: [], momentumPhase: .ended, deltaX: 0, deltaY: 0), .consume)
        // Danach ist der Zustand frisch: neue Geste kann wieder auslösen.
        XCTAssertEqual(changed(80), .trigger(direction: 1))
    }

    // MARK: - Vertikale / diagonale Gesten

    func testVerticalScrollPassesThroughEntirely() {
        XCTAssertEqual(recognizer.handle(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        XCTAssertEqual(changed(0, 20), .passThrough)
        XCTAssertEqual(changed(0, 200), .passThrough)
        XCTAssertEqual(recognizer.handle(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        // Vertikales Momentum (Scrollback-Ausrollen) läuft ebenfalls durch.
        XCTAssertEqual(recognizer.handle(phase: [], momentumPhase: .changed, deltaX: 0, deltaY: 30), .passThrough)
    }

    func testDiagonalWithoutHorizontalDominanceStaysVertical() {
        // |x| muss |y| um Faktor 1.5 dominieren — 12 vs. 10 reicht nicht.
        XCTAssertEqual(changed(12, 10), .passThrough)
        XCTAssertEqual(changed(100, 0), .passThrough)
    }

    func testNewGestureAfterVerticalCanBeHorizontal() {
        XCTAssertEqual(changed(0, 50), .passThrough)
        XCTAssertEqual(recognizer.handle(phase: .ended, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        // .began setzt zurück → neue Geste entscheidet ihre Achse frisch.
        XCTAssertEqual(recognizer.handle(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        XCTAssertEqual(changed(80), .trigger(direction: 1))
    }

    // MARK: - Randfälle

    func testMouseWheelWithoutPhasePassesThrough() {
        XCTAssertEqual(
            recognizer.handle(phase: [], momentumPhase: [], deltaX: 40, deltaY: 0),
            .passThrough
        )
    }

    func testMayBeginResetsAndPassesThrough() {
        XCTAssertEqual(changed(40), .consume)
        XCTAssertEqual(recognizer.handle(phase: .mayBegin, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        // Akkumulation von vorher ist weg — 40pt reichen nicht mehr zum Trigger.
        XCTAssertEqual(changed(40), .consume)
    }

    func testCancelledGestureKeepsAxisForMomentumButResetsAccumulation() {
        XCTAssertEqual(changed(40), .consume)
        XCTAssertEqual(recognizer.handle(phase: .cancelled, momentumPhase: [], deltaX: 0, deltaY: 0), .consume)
        // Nächste echte Geste startet frisch.
        XCTAssertEqual(recognizer.handle(phase: .began, momentumPhase: [], deltaX: 0, deltaY: 0), .passThrough)
        XCTAssertEqual(changed(0, 50), .passThrough)
    }
}
