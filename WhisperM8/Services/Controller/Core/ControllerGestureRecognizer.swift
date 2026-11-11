import Foundation

/// Macht aus rohen Controller-Eingaben diskrete Gesten (Plan Abschnitt 3.1).
///
/// Zustandsmaschine ohne Uhr und ohne App-Zustand: Jede Eingabe bringt ihre
/// Zeit mit, der Zeitgeber der Hardware-Schicht ruft `tick(at:)` zu
/// `nextDeadline`. Ob eine Taste getippt oder gehalten wurde, entscheiden die
/// Zeitstempel, nicht ob der Zeitgeber rechtzeitig gefeuert hat: Jede Eingabe
/// holt zuerst fällige Entscheidungen nach.
///
/// Verhalten je Taste (fest, ohne Kontext):
/// - **sofort** (`.press` beim Drücken): Kreuz, Dreieck, L3, Create,
///   Options, Touchpad, R2.
/// - **Tippen oder Halten**: L2 (0,3 s), Kreis (0,4 s), Viereck (0,6 s),
///   R3 (0,6 s). Viereck wiederholt danach wie eine gehaltene Taste
///   (`.holdRepeat` alle 60 ms, nach 1 s `.holdRepeatLong` alle 150 ms — im
///   Chat erst Zeichen, dann Wörter, wie beim iPhone); im
///   Zwischenablage-Verlauf löscht nur `.holdBegan` einen Eintrag. Bewegt
///   sich der rechte Stick, während R3 noch nicht als gehalten gilt, verfällt
///   der Druck ohne `.tap` (R3 wird beim Scrollen leicht mitgedrückt).
/// - **L1/R1**: einzeln `.press`, aber erst nach dem Akkord-Fenster oder beim
///   früheren Loslassen. Beide zusammen ergeben den Pause-Akkord.
/// - **Steuerkreuz und linker Stick**: `.move` mit Wiederholung.
/// - **Trigger**: Analogwert mit Hysterese, danach wie digitale Tasten.
/// - **Rechter Stick**: `.scroll` im Takt von `tick`.
struct ControllerGestureRecognizer: Sendable {
    struct Config: Equatable, Sendable {
        var l2HoldThreshold: TimeInterval = 0.3
        var circleHoldThreshold: TimeInterval = 0.4
        var squareHoldThreshold: TimeInterval = 0.6
        var r3HoldThreshold: TimeInterval = 0.6
        /// Tasten, die nach Beginn des Haltens wiederholen (`.holdRepeat`).
        var holdRepeatButtons: Set<ControllerButton> = [.square]
        var holdRepeatInterval: TimeInterval = 0.06
        /// So lange nach Beginn des Haltens kommt `.holdRepeatLong` statt
        /// `.holdRepeat`, im langsameren Takt.
        var holdRepeatLongAfter: TimeInterval = 1.0
        var holdRepeatLongInterval: TimeInterval = 0.15
        /// Tasten, deren Druck verfällt, sobald der rechte Stick scrollt.
        var scrollCancelsHold: Set<ControllerButton> = [.r3]
        /// So knapp nacheinander müssen L1 und R1 kommen, damit es ein Akkord ist.
        var chordWindow: TimeInterval = 0.15
        /// So lange müssen beide gemeinsam gehalten werden.
        var chordHoldDuration: TimeInterval = 1.0
        /// Entspricht `NSEvent.keyRepeatDelay` / `keyRepeatInterval`; die
        /// Hardware-Schicht übergibt die Systemwerte.
        var repeatDelay: TimeInterval = 0.4
        var repeatInterval: TimeInterval = 0.1
        var triggerPressThreshold: Float = 0.5
        var triggerReleaseThreshold: Float = 0.3
        var stickDeadzone: Float = 0.25
        var stickActivateThreshold: Float = 0.6
        var stickReleaseThreshold: Float = 0.4
        /// Um so viel muss die andere Achse die aktive übertreffen, damit die
        /// Richtung wechselt. Verhindert Flattern an der Diagonale.
        var stickAxisSwitchMargin: Float = 0.15
        var scrollMinLinesPerSecond: Double = 2
        var scrollMaxLinesPerSecond: Double = 30
        /// Kommt der Zeitgeber spät, wird höchstens so viel Zeit nachgeholt,
        /// damit kein Sprung über viele Zeilen entsteht.
        var scrollMaxCatchUp: TimeInterval = 0.25

        func holdThreshold(for button: ControllerButton) -> TimeInterval? {
            switch button {
            case .l2: return l2HoldThreshold
            case .circle: return circleHoldThreshold
            case .square: return squareHoldThreshold
            case .r3: return r3HoldThreshold
            default: return nil
            }
        }
    }

    struct HoldState: Equatable, Sendable {
        var pressedAt: TimeInterval
        var began = false
        /// Nächste Wiederholung, nur bei Tasten mit Wiederholung und erst ab
        /// Beginn des Haltens.
        var nextRepeatAt: TimeInterval?
    }

    struct PendingBumper: Equatable, Sendable {
        var button: ControllerButton
        var pressedAt: TimeInterval
    }

    struct ChordState: Equatable, Sendable {
        var startedAt: TimeInterval
        var completed = false
    }

    struct RepeatState: Equatable, Sendable {
        var direction: ControllerDirection
        var nextAt: TimeInterval
    }

    struct ScrollState: Equatable, Sendable {
        /// Vorzeichenbehaftet, positiv heißt nach unten.
        var linesPerSecond: Double
        /// Noch nicht ausgegebene Zeilen (ohne Vorzeichen).
        var accumulator: Double
        var lastUpdate: TimeInterval
    }

    /// Kleine Toleranz gegen Rundungsfehler bei Zeitvergleichen: Ein Tick
    /// genau zur Frist soll sicher feuern.
    static let epsilon: TimeInterval = 1e-9

    let config: Config

    // Zustand. `internal`, weil die Achsen-Logik in einer eigenen Datei liegt.
    var pressedButtons: Set<ControllerButton> = []
    var holds: [ControllerButton: HoldState] = [:]
    var pendingBumper: PendingBumper?
    var chord: ChordState?
    /// Nach einem Akkord lösen L1 und R1 nichts mehr aus, bis beide los sind.
    var bumpersSuppressed = false
    var dpadRepeat: RepeatState?
    var leftDirection: ControllerDirection?
    var leftRepeatAt: TimeInterval?
    var leftDeflected = false
    var scroll: ScrollState?

    init(config: Config = .init()) {
        self.config = config
    }

    // MARK: - Öffentliche Schnittstelle

    mutating func handle(_ event: ControllerInputEvent, at time: TimeInterval) -> [ControllerGesture] {
        var gestures = advance(to: time, includeTimers: false)
        switch event {
        case let .button(button, pressed):
            // Trigger zählen nur über ihren Analogwert, sonst kämen sie doppelt.
            guard !button.isTrigger else { return gestures }
            gestures += digital(button, pressed: pressed, at: time)
        case let .trigger(button, value):
            gestures += trigger(button, value: value, at: time)
        case let .stick(.left, x, y):
            gestures += leftStick(x: x, y: y, at: time)
        case let .stick(.right, _, y):
            rightStick(y: y, at: time)
            gestures += cancelHoldsWhileScrolling()
        }
        return gestures
    }

    mutating func tick(at time: TimeInterval) -> [ControllerGesture] {
        advance(to: time, includeTimers: true)
    }

    /// Wann der Zeitgeber das nächste Mal feuern soll; `nil`, wenn nichts läuft.
    var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        for (button, hold) in holds {
            if !hold.began, let threshold = config.holdThreshold(for: button) {
                deadlines.append(hold.pressedAt + threshold)
            }
            if let nextRepeatAt = hold.nextRepeatAt { deadlines.append(nextRepeatAt) }
        }
        if let pendingBumper {
            deadlines.append(pendingBumper.pressedAt + config.chordWindow)
        }
        if let chord, !chord.completed {
            deadlines.append(chord.startedAt + config.chordHoldDuration)
        }
        if let dpadRepeat { deadlines.append(dpadRepeat.nextAt) }
        if let leftRepeatAt { deadlines.append(leftRepeatAt) }
        if let scrollDeadline { deadlines.append(scrollDeadline) }
        return deadlines.min()
    }

    /// Nichts gedrückt, kein Stick ausgelenkt.
    var isIdle: Bool {
        pressedButtons.isEmpty && holds.isEmpty && pendingBumper == nil && chord == nil
            && !leftDeflected && leftDirection == nil && scroll == nil
    }

    /// Löst alles Gehaltene, etwa bei Trennung oder Ruhezustand.
    ///
    /// Gehaltene Tippen-oder-Halten-Tasten melden `.holdCancelled` (ohne
    /// `.tap`), auch wenn das Halten schon begonnen hatte: Ein Zurücksetzen
    /// soll nichts auslösen, eine offene Chat-Auswahl schließt ohne Wechsel
    /// (Plan, Sonderfälle). Fällige, aber noch nicht gemeldete Entscheidungen
    /// werden bewusst nicht nachgeholt.
    mutating func reset(at time: TimeInterval) -> [ControllerGesture] {
        var gestures: [ControllerGesture] = []
        for button in ControllerButton.allCases where holds[button] != nil {
            gestures.append(.holdCancelled(button))
        }
        if let chord, !chord.completed {
            gestures.append(.chordCancelled)
        }
        pressedButtons = []
        holds = [:]
        pendingBumper = nil
        chord = nil
        bumpersSuppressed = false
        dpadRepeat = nil
        leftDirection = nil
        leftRepeatAt = nil
        leftDeflected = false
        scroll = nil
        return gestures
    }

    // MARK: - Fristen nachholen

    /// Holt alle bis `time` fälligen Entscheidungen nach. Wiederholungen und
    /// Scrollen laufen nur über `tick`, damit ein spätes Ereignis keinen
    /// Schwall nachgeholter Wiederholungen auslöst.
    mutating func advance(to time: TimeInterval, includeTimers: Bool) -> [ControllerGesture] {
        var gestures: [ControllerGesture] = []
        for button in ControllerButton.allCases {
            guard var hold = holds[button], !hold.began,
                  let threshold = config.holdThreshold(for: button),
                  Self.isDue(hold.pressedAt + threshold, at: time) else { continue }
            hold.began = true
            if config.holdRepeatButtons.contains(button) {
                hold.nextRepeatAt = hold.pressedAt + threshold + config.holdRepeatInterval
            }
            holds[button] = hold
            gestures.append(.holdBegan(button))
        }
        if let pending = pendingBumper, Self.isDue(pending.pressedAt + config.chordWindow, at: time) {
            pendingBumper = nil
            gestures.append(.press(pending.button))
        }
        if var current = chord, !current.completed,
           Self.isDue(current.startedAt + config.chordHoldDuration, at: time) {
            current.completed = true
            chord = current
            gestures.append(.chordCompleted)
        }
        if includeTimers {
            gestures += repeats(at: time)
            gestures += scrollLines(at: time)
        }
        return gestures
    }

    static func isDue(_ deadline: TimeInterval, at time: TimeInterval) -> Bool {
        time + epsilon >= deadline
    }

    // MARK: - Digitale Tasten

    mutating func digital(_ button: ControllerButton, pressed: Bool, at time: TimeInterval) -> [ControllerGesture] {
        if pressed {
            guard pressedButtons.insert(button).inserted else { return [] }
            if let direction = button.dpadDirection {
                dpadRepeat = RepeatState(direction: direction, nextAt: time + config.repeatDelay)
                return [.move(direction, source: .dpad, isRepeat: false)]
            }
            if button.isBumper {
                return bumperDown(button, at: time)
            }
            if let threshold = config.holdThreshold(for: button) {
                // Wer gerade scrollt, drückt R3 eher aus Versehen.
                if config.scrollCancelsHold.contains(button), scroll != nil { return [] }
                holds[button] = HoldState(pressedAt: time)
                return [.holdPending(button, duration: threshold)]
            }
            return [.press(button)]
        }

        guard pressedButtons.remove(button) != nil else { return [] }
        if let direction = button.dpadDirection {
            if dpadRepeat?.direction == direction { dpadRepeat = nil }
            return []
        }
        if button.isBumper {
            return bumperUp(button)
        }
        if let hold = holds.removeValue(forKey: button) {
            // `advance` hat eine fällige Schwelle schon in `.holdBegan` verwandelt.
            return hold.began ? [.holdEnded(button)] : [.holdCancelled(button), .tap(button)]
        }
        return []
    }

    /// Scrollt der rechte Stick, verfallen Drücke auf R3, die noch nicht als
    /// gehalten gelten: kein Halten, beim Loslassen auch kein Tippen.
    mutating func cancelHoldsWhileScrolling() -> [ControllerGesture] {
        guard scroll != nil else { return [] }
        var gestures: [ControllerGesture] = []
        for button in config.scrollCancelsHold.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let hold = holds[button], !hold.began else { continue }
            holds[button] = nil
            gestures.append(.holdCancelled(button))
        }
        return gestures
    }

    // MARK: - L1 / R1 und der Pause-Akkord

    mutating func bumperDown(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        guard !bumpersSuppressed, chord == nil else { return [] }
        let other: ControllerButton = button == .l1 ? .r1 : .l1
        if let pending = pendingBumper, pending.button == other {
            // Innerhalb des Fensters (sonst hätte `advance` schon `.press` gemeldet).
            pendingBumper = nil
            chord = ChordState(startedAt: time)
            return [.chordPending(duration: config.chordHoldDuration)]
        }
        if pressedButtons.contains(other) {
            // Die andere Taste ist schon länger unten: kein Akkord mehr möglich.
            return [.press(button)]
        }
        pendingBumper = PendingBumper(button: button, pressedAt: time)
        return []
    }

    mutating func bumperUp(_ button: ControllerButton) -> [ControllerGesture] {
        var gestures: [ControllerGesture] = []
        if pendingBumper?.button == button {
            pendingBumper = nil
            gestures.append(.press(button))
        }
        if let current = chord {
            if !current.completed { gestures.append(.chordCancelled) }
            chord = nil
            bumpersSuppressed = true
        }
        if !pressedButtons.contains(.l1), !pressedButtons.contains(.r1) {
            bumpersSuppressed = false
        }
        return gestures
    }
}
