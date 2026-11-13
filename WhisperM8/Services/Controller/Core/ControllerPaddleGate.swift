import Foundation

/// Ein HID-Bericht des Xbox-Controllers, gebündelt aus allen Werten mit
/// gleichem Zeitstempel (`XboxPaddleHIDSource`).
struct ControllerHIDReport: Equatable, Sendable {
    struct ButtonChange: Equatable, Sendable {
        var button: ControllerButton
        var pressed: Bool
    }

    /// Neue Paddle-Maske, falls der Bericht Consumer 0x0C/0x81 enthielt.
    var paddleMask: UInt32?
    /// Wechsel gewöhnlicher Tasten (Seite 0x09), übersetzt nach `XboxHIDButtons`.
    var buttons: [ButtonChange] = []
    /// Xbox-Knopf (Seite 0x09, Usage 0x0D): kommt nur über HID an und
    /// übernimmt die Rolle des Touchpads (Zwischenablage-Verlauf).
    var homeButton: Bool?
}

/// Weiche gegen die doppelte Taste der Paddles (Plan
/// `controller-xbox-paddles.md`, „Weiche gegen die doppelte Taste“).
///
/// Ein Paddle kommt auf zwei Wegen an: als Bit in HID und, über das Profil im
/// Controller, als gewöhnliche Gesichtstaste bei GameController. Die Weiche
/// macht aus der Maske Paddle-Tasten und verschluckt die mitgeschickte Taste
/// — nach dem Urteil des HID-Berichts, nicht nach einem Zeitfenster allein.
///
/// Zurückgehalten werden nur Tasten, die HID beurteilen kann
/// (`XboxHIDButtons.judgeable`); Steuerkreuz, Trigger und Sticks gehen sofort
/// durch.
///
/// Pure Zustandsmaschine mit Uhr als Parameter, wie der Erkenner. Ohne
/// HID-Paddles und für alle Nicht-Xbox-Geräte ist sie ein reiner Durchgang.
struct ControllerPaddleGate: Sendable {
    /// So lange gilt ein Urteil für die nächste gleichnamige Taste.
    static let verdictLifetime: TimeInterval = 0.1
    /// Spätestens so lange wartet ein Druck von GameController auf sein Urteil.
    static let holdLimit: TimeInterval = 0.04

    struct Stats: Equatable, Sendable {
        /// Letzte Paddle-Maske aus HID.
        var lastMask: UInt32 = 0
        var reports = 0
        var swallowed = 0
        var holds = 0
        /// Zurückgehalten und ohne Urteil nach der Frist durchgelassen.
        var holdsExpired = 0
        var longestHold: TimeInterval = 0
    }

    private struct Verdict: Equatable, Sendable {
        var fromPaddle: Bool
        var at: TimeInterval
    }

    private struct Held: Equatable, Sendable {
        var event: ControllerInputEvent
        var receivedAt: TimeInterval
    }

    private(set) var paddleSourceAvailable = false
    private(set) var stats = Stats()
    private var mask: UInt32 = 0
    private var verdicts: [ControllerButton: Verdict] = [:]
    /// Tasten, deren Druck verschluckt wurde: Ihr Loslassen wird es auch.
    private var ownedByPaddle: Set<ControllerButton> = []
    /// Zurückgehaltene Ereignisse von GameController, in ihrer Reihenfolge.
    private var held: [Held] = []
    /// Gelerntes Profil im Controller: Paddle-Bit → mitgeschickte Taste.
    /// Gelernt aus Berichten mit genau einem neuen Bit und genau einer
    /// gedrückten Taste; ein Profilwechsel am Controller überschreibt es beim
    /// nächsten eindeutigen Bericht.
    private var profileFace: [UInt32: ControllerButton] = [:]

    init() {}

    // MARK: - Eingaben

    /// Paddles über HID lesbar oder nicht. Wird es abgeschaltet, geht alles
    /// Zurückgehaltene sofort durch, und gedrückte Paddles werden losgelassen
    /// (sonst hinge ihr Druck im Erkenner).
    mutating func setPaddleSource(available: Bool) -> [ControllerInputEvent] {
        guard available != paddleSourceAvailable else { return [] }
        paddleSourceAvailable = available
        guard !available else { return [] }
        let pending = held.map(\.event)
        let released = XboxPaddleBits.changes(from: mask, to: 0).map { ControllerInputEvent.button($0.paddle.button, pressed: false) }
        held = []
        verdicts = [:]
        ownedByPaddle = []
        profileFace = [:]
        mask = 0
        stats.lastMask = 0
        return pending + released
    }

    mutating func hid(_ report: ControllerHIDReport, at time: TimeInterval) -> [ControllerInputEvent] {
        purgeVerdicts(at: time)
        stats.reports += 1
        var out: [ControllerInputEvent] = []
        var addedBits: UInt32 = 0
        if let newMask = report.paddleMask {
            addedBits = newMask & ~mask
            for change in XboxPaddleBits.changes(from: mask, to: newMask) {
                out.append(.button(change.paddle.button, pressed: change.pressed))
            }
            mask = newMask
            stats.lastMask = newMask
        }
        // Jeder Tastendruck im Bericht wird zum Urteil für genau diese Taste.
        if paddleSourceAvailable {
            let pressed = report.buttons.filter(\.pressed).map(\.button)
            let fromPaddle = paddleFaces(pressed: pressed, addedBits: addedBits)
            for button in pressed {
                verdicts[button] = Verdict(fromPaddle: fromPaddle.contains(button), at: time)
            }
        }
        if let home = report.homeButton {
            out.append(.button(.touchpad, pressed: home))
        }
        return out + flush(at: time)
    }

    /// Ereignis von GameController; `origin` ist die Familie des Geräts.
    mutating func gameController(
        _ event: ControllerInputEvent, origin: ControllerFamily, at time: TimeInterval
    ) -> [ControllerInputEvent] {
        guard paddleSourceAvailable, origin == .xbox else { return [event] }
        purgeVerdicts(at: time)
        // Hinter Zurückgehaltenem anstellen: Ein Stick-Ausschlag überholt nie
        // einen Tastendruck.
        guard held.isEmpty else {
            held.append(Held(event: event, receivedAt: time))
            return flush(at: time)
        }
        if let out = decide(event, receivedAt: time, at: time, mayHold: true) { return out }
        held.append(Held(event: event, receivedAt: time))
        stats.holds += 1
        return []
    }

    mutating func tick(at time: TimeInterval) -> [ControllerInputEvent] {
        purgeVerdicts(at: time)
        return flush(at: time)
    }

    /// Trennung, Ruhezustand, Pause des Systems, Ausschalten. Die Maske
    /// bleibt: Ein Paddle kann noch gedrückt sein, und ein neuer Bericht soll
    /// nur Wechsel melden, keinen Phantom-Druck. Nach einer Trennung meldet
    /// der neue Bericht die Maske ohnehin vollständig (der Bündler beginnt
    /// leer) und lässt Hängengebliebenes los.
    mutating func reset() {
        verdicts = [:]
        ownedByPaddle = []
        held = []
    }

    /// Wann `tick` fällig ist: Frist des ersten zurückgehaltenen Drucks.
    var nextDeadline: TimeInterval? {
        held.first.map { $0.receivedAt + Self.holdLimit }
    }

    var isHolding: Bool { !held.isEmpty }

    // MARK: - Entscheidung

    /// `nil` heißt: zurückhalten (nur bei `mayHold`).
    private mutating func decide(
        _ event: ControllerInputEvent, receivedAt: TimeInterval, at time: TimeInterval, mayHold: Bool
    ) -> [ControllerInputEvent]? {
        // Nur Tasten, die HID beurteilt, warten auf ein Urteil; für alle
        // anderen (Steuerkreuz, Trigger, Paddles) käme nie eines.
        guard case let .button(button, pressed) = event, XboxHIDButtons.judgeable.contains(button) else {
            return [event]
        }
        if !pressed {
            return ownedByPaddle.remove(button) != nil ? [] : [event]
        }
        if let verdict = verdicts.removeValue(forKey: button) {
            noteHold(since: receivedAt, at: time)
            if verdict.fromPaddle {
                ownedByPaddle.insert(button)
                stats.swallowed += 1
                return []
            }
            return [event]
        }
        if mayHold, time - receivedAt + ControllerGestureRecognizer.epsilon < Self.holdLimit { return nil }
        // Frist abgelaufen: durchlassen wie heute.
        stats.holdsExpired += 1
        noteHold(since: receivedAt, at: time)
        return [event]
    }

    /// Gibt frei, was jetzt entschieden werden kann, in der Reihenfolge des
    /// Eingangs. Freigegebenes trägt die Zeit des Durchlassens (der Pumpe).
    private mutating func flush(at time: TimeInterval) -> [ControllerInputEvent] {
        var out: [ControllerInputEvent] = []
        while let head = held.first {
            guard let events = decide(head.event, receivedAt: head.receivedAt, at: time, mayHold: true) else { break }
            held.removeFirst()
            out += events
        }
        return out
    }

    /// Welche gedrückten Tasten eines Berichts das Paddle mitgeschickt hat.
    /// Höchstens so viele Tasten wie neue Bits gehören zum Paddle; sind es
    /// mehr, entscheidet das gelernte Profil. Ist es für ein neues Bit noch
    /// unbekannt, zählen alle als „vom Paddle“ (Grenze in `controller.md`).
    private mutating func paddleFaces(pressed: [ControllerButton], addedBits: UInt32) -> Set<ControllerButton> {
        let bits = XboxPaddleBits.table.map(\.bit).filter { addedBits & $0 != 0 }
        guard !bits.isEmpty, !pressed.isEmpty else { return [] }
        if bits.count == 1, pressed.count == 1 { profileFace[bits[0]] = pressed[0] }
        guard pressed.count > bits.count else { return Set(pressed) }
        let learned = bits.compactMap { profileFace[$0] }
        guard learned.count == bits.count else { return Set(pressed) }
        return Set(learned).intersection(pressed)
    }

    private mutating func purgeVerdicts(at time: TimeInterval) {
        verdicts = verdicts.filter { time - $0.value.at <= Self.verdictLifetime }
    }

    private mutating func noteHold(since receivedAt: TimeInterval, at time: TimeInterval) {
        stats.longestHold = max(stats.longestHold, time - receivedAt)
    }
}
