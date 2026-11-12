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
/// aufsetzt, wird deshalb mehrfach erkannt, damit der Zeiger beim Aufsetzen
/// nie springt, auch wenn das Framework beim Abheben die letzte Position
/// stehen lässt (Nachgreifen):
/// - genau (0, 0) gilt als „kein Finger“ (falls das Framework zurücksetzt),
/// - eine Lücke von mehr als `newTouchGap` (35 ms) seit der letzten Meldung,
///   außer der Finger ist kaum weitergekommen (`slowMoveDistance` innerhalb
///   `slowMoveGap`): so bleibt sehr langsames Schieben eine Bewegung,
/// - ein Sprung um mehr als `jumpDistance` zwischen zwei Meldungen.
/// Die erste Meldung eines neuen Fingers setzt nur den Anker.
///
/// Es führt der Finger, der sich zuletzt gemeldet hat, solange der andere
/// seit mehr als `newTouchGap` schweigt (ein liegen gelassener Finger
/// blockiert nichts); melden sich beide, führt der erste.
///
/// Rechtsklick: Liegt beim Drücken ein zweiter Finger auf, der sich nach dem
/// letzten Drücken oder Loslassen und nach dem Aufsetzen des führenden
/// Fingers gemeldet hat — und höchstens `secondFingerFreshness` her. Ein
/// zweiter Finger, dessen Abheben das Framework nie gemeldet hat, zählt so
/// nach dem nächsten Klick nicht mehr.
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
        var newTouchGap: TimeInterval = 0.035
        /// Längere Lücke, die noch als Bewegung gilt, wenn der Finger dabei
        /// höchstens `slowMoveDistance` weitergekommen ist (sehr langsames
        /// Schieben meldet nur selten eine neue Position).
        var slowMoveGap: TimeInterval = 0.25
        var slowMoveDistance: Float = 0.02
        /// Ein Viertel der Breite (die Fläche misst −1…1).
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
        /// Erste Meldung dieser Berührung.
        var landedAt: TimeInterval
    }

    /// Wechsel an einem Finger, für ein Log am Gerät (je Abheben bzw.
    /// Aufsetzen einmal, nie je Meldung).
    enum Transition: Equatable, Sendable {
        enum Reason: String, Sendable {
            /// Erste Meldung nach (0, 0) oder überhaupt.
            case first
            /// Lücke seit der letzten Meldung.
            case gap
            /// Sprung zwischen zwei Meldungen.
            case jump
        }

        /// Das Framework meldet (0, 0).
        case lifted(ControllerTouchFinger)
        case landed(ControllerTouchFinger, Reason)
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
    /// Letztes Drücken oder Loslassen.
    private var lastButtonEventAt: TimeInterval = -.infinity
    /// Wechsel der letzten `touch`-Meldung, sonst `nil`.
    private(set) var lastTransition: Transition?

    init(config: Config = .init()) {
        self.config = config
    }

    /// Finger, der den Zeiger führt: der zuletzt gemeldete, wenn der andere
    /// seit mehr als `newTouchGap` schweigt; sonst der erste.
    var driver: ControllerTouchFinger? {
        switch (fingers[.primary], fingers[.secondary]) {
        case (nil, nil): return nil
        case (.some, nil): return .primary
        case (nil, .some): return .secondary
        case let (primary?, secondary?):
            return secondary.at - primary.at > config.newTouchGap ? .secondary : .primary
        }
    }

    /// Eine Fingerposition. Liefert eine Bewegung oder `nil`.
    mutating func touch(_ finger: ControllerTouchFinger, x: Float, y: Float, at time: TimeInterval) -> ControllerPointerOutput? {
        lastTransition = nil
        guard x != 0 || y != 0 else {
            if fingers.removeValue(forKey: finger) != nil { lastTransition = .lifted(finger) }
            velocity = 0
            return nil
        }
        let point = Point(x: x, y: y)
        let previous = fingers[finger]
        let reason = previous.flatMap { newTouchReason(from: $0, to: point, at: time) }
        guard let previous, reason == nil else {
            // Neu aufgesetzt: nur den Anker setzen.
            fingers[finger] = FingerState(point: point, at: time, landedAt: time)
            lastTransition = .landed(finger, reason ?? .first)
            if driver == finger { velocity = 0 }
            return nil
        }
        fingers[finger] = FingerState(point: point, at: time, landedAt: previous.landedAt)
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
        lastButtonEventAt = time
        return .buttonDown(button, clickCount: count)
    }

    /// Touchpad losgelassen. `nil`, wenn kein Klick lief.
    mutating func release(at time: TimeInterval) -> ControllerPointerOutput? {
        guard let click = pressed else { return nil }
        pressed = nil
        settleUntil = time + config.clickSettle
        lastButtonEventAt = time
        return .buttonUp(click.button, clickCount: click.count)
    }

    /// Alles vergessen (Pause, Trennung, Ausschalten). Eine noch gedrückte
    /// Taste wird losgelassen, sonst bliebe sie im System hängen.
    mutating func reset() -> ControllerPointerOutput? {
        fingers = [:]
        velocity = 0
        settleUntil = -.infinity
        lastButtonEventAt = -.infinity
        lastTransition = nil
        lastClick = nil
        guard let click = pressed else { return nil }
        pressed = nil
        return .buttonUp(click.button, clickCount: click.count)
    }

    /// Liegt neben dem führenden Finger ein zweiter auf, der sich nach dem
    /// letzten Drücken oder Loslassen und nach dem Aufsetzen des führenden
    /// gemeldet hat (mit kleiner Toleranz für gleichzeitiges Aufsetzen)?
    func secondFingerDown(at time: TimeInterval) -> Bool {
        guard let driver, let driving = fingers[driver] else { return false }
        let other: ControllerTouchFinger = driver == .primary ? .secondary : .primary
        guard let state = fingers[other] else { return false }
        return state.at > lastButtonEventAt
            && state.at >= driving.landedAt - config.newTouchGap
            && time - state.at <= config.secondFingerFreshness
    }

    /// Warum `point` keine Fortsetzung von `previous` ist; `nil` heißt Bewegung.
    private func newTouchReason(from previous: FingerState, to point: Point, at time: TimeInterval) -> Transition.Reason? {
        let dx = point.x - previous.point.x
        let dy = point.y - previous.point.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > config.jumpDistance { return .jump }
        let gap = time - previous.at
        if gap <= config.newTouchGap { return nil }
        if gap <= config.slowMoveGap, distance <= config.slowMoveDistance { return nil }
        return .gap
    }
}
