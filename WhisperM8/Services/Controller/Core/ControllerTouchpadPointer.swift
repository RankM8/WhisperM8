import Foundation

/// Maustaste, die ein Klick auf das Touchpad drückt.
enum ControllerPointerButton: String, CaseIterable, Sendable {
    case left, right
}

/// Was der Mauszeiger tun soll. Bewegung in Bildschirmpunkten, `dy` positiv
/// heißt nach unten.
enum ControllerPointerOutput: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    /// `clickCount`: 1 einfach, 2 Doppelklick usw. (wie bei einer Maus).
    case buttonDown(ControllerPointerButton, clickCount: Int)
    case buttonUp(ControllerPointerButton, clickCount: Int)
}

/// Touchpad als Maus: macht aus Fingerpositionen relative Bewegungen mit
/// Beschleunigung und entscheidet beim Klick zwischen linker und rechter
/// Taste. Pur, ohne Uhr: Jede Eingabe bringt ihre Zeit mit.
///
/// Das Framework meldet keinen eigenen Zustand „Finger liegt auf“ — nur
/// Positionen, und auch die nur bei einer Änderung. Ob ein Finger neu
/// aufsetzt, wird deshalb dreifach erkannt, damit der Zeiger beim Aufsetzen
/// nie springt:
/// - genau (0, 0) gilt als „kein Finger“ (so meldet das Framework einen
///   abgehobenen Finger, falls es zurücksetzt),
/// - eine Lücke von mehr als `newTouchGap` seit der letzten Meldung,
/// - ein Sprung um mehr als `jumpDistance` zwischen zwei Meldungen.
/// Die erste Meldung eines neuen Fingers setzt nur den Anker.
///
/// Rechtsklick: Liegt beim Drücken ein zweiter Finger auf, der sich in den
/// letzten `secondFingerFreshness` Sekunden gemeldet hat. Die Frist schützt
/// vor einem zweiten Finger, dessen Abheben das Framework nie gemeldet hat.
struct ControllerTouchpadPointer: Sendable {
    struct Config: Equatable, Sendable {
        /// Faktor aus den Einstellungen (Zeigergeschwindigkeit).
        var speed: Double = Self.defaultSpeed
        /// Punkte je Einheit Touchpad-Weg (die Fläche ist zwei Einheiten
        /// breit) bei Faktor 1 und Verstärkung 1.
        var pointsPerUnit: Double = 280
        /// Die Fläche ist etwa halb so hoch wie breit, meldet aber auf beiden
        /// Achsen −1…1. Ohne Ausgleich liefe der Zeiger senkrecht doppelt so schnell.
        var verticalScale: Double = 0.5
        /// Beschleunigung: Verstärkung = `minGain + gainPerSpeed × Tempo`
        /// (Tempo in Einheiten je Sekunde), begrenzt auf `minGain…maxGain`.
        /// Langsam wird fein, eine schnelle Wischbewegung trägt weit.
        var minGain: Double = 0.5
        var maxGain: Double = 4.0
        var gainPerSpeed: Double = 0.55
        /// Glättung des Tempos (Anteil des alten Werts), gegen Zittern.
        var velocitySmoothing: Double = 0.5
        /// Untergrenze für den Abstand zweier Meldungen beim Tempo, gegen
        /// Ausreißer bei fast gleichzeitigen Meldungen.
        var minSampleInterval: TimeInterval = 0.004
        var newTouchGap: TimeInterval = 0.1
        var jumpDistance: Float = 0.5
        /// So lange nach Drücken und Loslassen ruht der Zeiger: Der Finger
        /// verrutscht beim Klicken leicht.
        var clickSettle: TimeInterval = 0.08
        var secondFingerFreshness: TimeInterval = 1.5
        /// Systemwert (`NSEvent.doubleClickInterval`), übergibt die Hardware-Schicht.
        var doubleClickInterval: TimeInterval = 0.5
        /// Weiter darf sich der Zeiger zwischen zwei Klicks eines Doppelklicks
        /// nicht bewegen (Punkte).
        var doubleClickDistance: Double = 6

        static let defaultSpeed: Double = 1.0
        static let speedRange: ClosedRange<Double> = 0.3...3.0
    }

    struct Point: Equatable, Sendable {
        var x: Float
        var y: Float
    }

    struct FingerState: Equatable, Sendable {
        var point: Point
        var at: TimeInterval
    }

    struct Click: Equatable, Sendable {
        var button: ControllerPointerButton
        var at: TimeInterval
        var count: Int
        /// Zeigerweg seit diesem Klick (Punkte).
        var travel: Double = 0
    }

    var config: Config

    /// Finger, die gerade aufliegen.
    private(set) var fingers: [ControllerTouchFinger: FingerState] = [:]
    private(set) var pressed: Click?
    private var lastClick: Click?
    private var velocity: Double = 0
    private var settleUntil: TimeInterval = -.infinity

    init(config: Config = .init()) {
        self.config = config
    }

    /// Finger, der den Zeiger führt: der erste, sonst der zweite (hebt der
    /// erste ab, führt der verbliebene weiter).
    var driver: ControllerTouchFinger? {
        if fingers[.primary] != nil { return .primary }
        if fingers[.secondary] != nil { return .secondary }
        return nil
    }

    /// Eine Fingerposition. Liefert eine Bewegung oder `nil`.
    mutating func touch(_ finger: ControllerTouchFinger, x: Float, y: Float, at time: TimeInterval) -> ControllerPointerOutput? {
        guard x != 0 || y != 0 else {
            fingers[finger] = nil
            velocity = 0
            return nil
        }
        let point = Point(x: x, y: y)
        let previous = fingers[finger]
        fingers[finger] = FingerState(point: point, at: time)
        guard let previous, continues(from: previous, to: point, at: time) else {
            // Neu aufgesetzt: nur den Anker setzen.
            if driver == finger { velocity = 0 }
            return nil
        }
        guard driver == finger, time >= settleUntil else { return nil }

        let dx = Double(point.x - previous.point.x)
        let dy = Double(point.y - previous.point.y) * config.verticalScale
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0 else { return nil }
        let interval = max(time - previous.at, config.minSampleInterval)
        let instant = distance / interval
        velocity = velocity == 0 ? instant : velocity * config.velocitySmoothing + instant * (1 - config.velocitySmoothing)
        let gain = min(max(config.minGain + config.gainPerSpeed * velocity, config.minGain), config.maxGain)
        let scale = config.pointsPerUnit * config.speed * gain
        let output = (dx: dx * scale, dy: -dy * scale)
        lastClick?.travel += (output.dx * output.dx + output.dy * output.dy).squareRoot()
        return .move(dx: output.dx, dy: output.dy)
    }

    /// Touchpad gedrückt: linke Taste, mit zweitem Finger die rechte.
    mutating func press(at time: TimeInterval) -> ControllerPointerOutput {
        if let pressed { return .buttonDown(pressed.button, clickCount: pressed.count) }
        let button: ControllerPointerButton = secondFingerDown(at: time) ? .right : .left
        var count = 1
        if let last = lastClick, last.button == button, time - last.at <= config.doubleClickInterval,
           last.travel <= config.doubleClickDistance {
            count = last.count + 1
        }
        let click = Click(button: button, at: time, count: count)
        lastClick = click
        pressed = click
        settleUntil = time + config.clickSettle
        return .buttonDown(button, clickCount: count)
    }

    /// Touchpad losgelassen. `nil`, wenn kein Klick lief.
    mutating func release(at time: TimeInterval) -> ControllerPointerOutput? {
        guard let click = pressed else { return nil }
        pressed = nil
        settleUntil = time + config.clickSettle
        return .buttonUp(click.button, clickCount: click.count)
    }

    /// Alles vergessen (Pause, Trennung, Ausschalten). Eine noch gedrückte
    /// Taste wird losgelassen, sonst bliebe sie im System hängen.
    mutating func reset() -> ControllerPointerOutput? {
        fingers = [:]
        velocity = 0
        settleUntil = -.infinity
        lastClick = nil
        guard let click = pressed else { return nil }
        pressed = nil
        return .buttonUp(click.button, clickCount: click.count)
    }

    /// Liegt neben dem führenden Finger ein zweiter auf, der sich zuletzt
    /// rechtzeitig gemeldet hat?
    func secondFingerDown(at time: TimeInterval) -> Bool {
        guard let driver else { return false }
        let other: ControllerTouchFinger = driver == .primary ? .secondary : .primary
        guard let state = fingers[other] else { return false }
        return time - state.at <= config.secondFingerFreshness
    }

    private func continues(from previous: FingerState, to point: Point, at time: TimeInterval) -> Bool {
        guard time - previous.at <= config.newTouchGap else { return false }
        let dx = point.x - previous.point.x
        let dy = point.y - previous.point.y
        return (dx * dx + dy * dy).squareRoot() <= config.jumpDistance
    }
}
