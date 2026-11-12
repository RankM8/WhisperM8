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
/// - **Tippen oder Halten**: Kreis (0,4 s), Viereck (0,6 s), R3 (0,6 s). Viereck wiederholt danach wie eine gehaltene Taste
///   (`.holdRepeat` alle 60 ms, nach 1 s `.holdRepeatLong` alle 150 ms — im
///   Chat erst Zeichen, dann Wörter, wie beim iPhone); im
///   Zwischenablage-Verlauf löscht nur `.holdBegan` einen Eintrag. Bewegt
///   sich der rechte Stick, während R3 noch nicht als gehalten gilt, verfällt
///   der Druck ohne `.tap` (R3 wird beim Scrollen leicht mitgedrückt).
/// - **Ebenen-Tasten L1, R1, L2** (Runde 4): `.tap` beim Loslassen, wenn sie
///   kürzer als 0,3 s gehalten wurden und keine andere Taste (auch kein
///   Stoß von Stick oder Steuerkreuz) dazwischen kam. Gehalten werden sie zur
///   Ebene: `.layerBegan` nach 0,3 s (die Insel erscheint), andere Tasten
///   kommen solange als `.inLayer` und wirken sofort beim Drücken, das
///   Loslassen meldet `.layerEnded`. Es gilt immer nur eine Ebene; eine
///   zweite Ebenen-Taste ist darin eine gewöhnliche Taste. Ausnahme: L1 und
///   R1 zusammen sind der Pause-Akkord, egal in welchem Abstand — die Ebene
///   endet dann still (`.layerCancelled`), es gibt weder Tippen noch
///   Ebenen-Aktion.
/// - **Steuerkreuz und linker Stick**: `.move` mit Wiederholung.
/// - **Trigger**: Analogwert mit Hysterese, danach wie digitale Tasten.
/// - **Rechter Stick**: `.scroll` im Takt von `tick`.
struct ControllerGestureRecognizer: Sendable {
    struct Config: Equatable, Sendable {
        /// Ab hier gilt eine Ebenen-Taste (L1, R1, L2) als gehalten, und die
        /// Insel erscheint. Kombinationen wirken schon vorher.
        var layerHoldThreshold: TimeInterval = 0.3
        /// Viereck in der Ebene „Schreiben“: erst nach dieser Zeit wiederholen,
        /// dann im Takt von `layerRepeatInterval` (Zeile für Zeile löschen).
        var layerRepeatDelay: TimeInterval = 0.4
        var layerRepeatInterval: TimeInterval = 0.15
        /// Tasten, die innerhalb einer Ebene beim Halten wiederholen.
        var layerRepeatButtons: [ControllerLayer: Set<ControllerButton>] = [.writing: [.square]]
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

    /// Gehaltene Ebenen-Taste.
    struct LayerState: Equatable, Sendable {
        var layer: ControllerLayer
        var pressedAt: TimeInterval
        /// `.layerBegan` ist gemeldet (Halte-Schwelle erreicht).
        var began = false
        /// Eine andere Taste kam dazwischen: kein Tippen mehr.
        var used = false
    }

    /// Wiederholung einer Taste innerhalb einer Ebene (Viereck beim Schreiben).
    struct LayerRepeat: Equatable, Sendable {
        var button: ControllerButton
        var nextAt: TimeInterval
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
    var layer: LayerState?
    /// In einer Ebene gedrückte Tasten: Ihr Loslassen bleibt still, auch wenn
    /// die Ebene inzwischen vorbei ist.
    var layerButtons: Set<ControllerButton> = []
    var layerRepeat: LayerRepeat?
    /// Die laufende Wiederholung des Steuerkreuzes bzw. die Richtung des
    /// linken Sticks begann in der Ebene.
    var dpadInLayer = false
    var leftStickInLayer = false
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
            // Scrollen während einer gehaltenen Ebenen-Taste ist eine zweite
            // Eingabe: kein Tippen mehr (das Scrollen selbst läuft weiter).
            if scroll != nil, var current = layer {
                current.used = true
                layer = current
            }
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
        if let layer, !layer.began {
            deadlines.append(layer.pressedAt + config.layerHoldThreshold)
        }
        if let layerRepeat { deadlines.append(layerRepeat.nextAt) }
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
        pressedButtons.isEmpty && holds.isEmpty && layer == nil && layerButtons.isEmpty && chord == nil
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
        if let layer { gestures.append(.layerCancelled(layer.layer)) }
        if let chord, !chord.completed {
            gestures.append(.chordCancelled)
        }
        pressedButtons = []
        holds = [:]
        layer = nil
        layerButtons = []
        layerRepeat = nil
        dpadInLayer = false
        leftStickInLayer = false
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
        if var current = layer, !current.began,
           Self.isDue(current.pressedAt + config.layerHoldThreshold, at: time) {
            current.began = true
            layer = current
            gestures.append(.layerBegan(current.layer))
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
            if let kind = ControllerLayer(key: button), let gestures = layerKeyDown(kind, at: time) {
                return gestures
            }
            if layer != nil { return layerButtonDown(button, at: time) }
            if let direction = button.dpadDirection {
                dpadRepeat = RepeatState(direction: direction, nextAt: time + config.repeatDelay)
                return [.move(direction, source: .dpad, isRepeat: false)]
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
        if layerButtons.remove(button) != nil {
            // In der Ebene gedrückt: still, auch nach dem Ende der Ebene.
            if layerRepeat?.button == button { layerRepeat = nil }
            if let direction = button.dpadDirection, dpadRepeat?.direction == direction {
                dpadRepeat = nil
                dpadInLayer = false
            }
            return button.isBumper ? bumperReleased() : []
        }
        if let direction = button.dpadDirection {
            if dpadRepeat?.direction == direction { dpadRepeat = nil }
            return []
        }
        if let current = layer, current.layer.key == button {
            layer = nil
            endLayerRepeats()
            return current.began || current.used ? [.layerEnded(current.layer)] : [.tap(button)]
        }
        if button.isBumper {
            return bumperReleased()
        }
        if ControllerLayer(key: button) != nil { return [] }
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

    // MARK: - Ebenen und der Pause-Akkord

    /// Ebenen-Taste gedrückt. `nil` heißt: Sie ist hier eine gewöhnliche Taste
    /// in der schon laufenden Ebene (`layerButtonDown`).
    mutating func layerKeyDown(_ kind: ControllerLayer, at time: TimeInterval) -> [ControllerGesture]? {
        let button = kind.key
        if button.isBumper {
            // Nach einem Akkord lösen L1 und R1 nichts aus, bis beide los sind.
            if bumpersSuppressed || chord != nil { return [] }
            if let current = layer, current.layer.key.isBumper {
                // L1 und R1 zusammen: Pause-Akkord, die Ebene endet still.
                layer = nil
                endLayerRepeats()
                chord = ChordState(startedAt: time)
                return [.layerCancelled(current.layer), .chordPending(duration: config.chordHoldDuration)]
            }
        }
        guard layer == nil else { return nil }
        layer = LayerState(layer: kind, pressedAt: time)
        // Für den Tasten-Test der Einstellungen; die Belegung zeigt keinen Ring.
        return [.holdPending(button, duration: config.layerHoldThreshold)]
    }

    /// Andere Taste, während eine Ebenen-Taste gehalten wird: wirkt sofort,
    /// ihr Loslassen bleibt still. Viereck wiederholt beim Schreiben.
    mutating func layerButtonDown(_ button: ControllerButton, at time: TimeInterval) -> [ControllerGesture] {
        guard var current = layer else { return [] }
        current.used = true
        layer = current
        layerButtons.insert(button)
        if let direction = button.dpadDirection {
            dpadRepeat = RepeatState(direction: direction, nextAt: time + config.repeatDelay)
            dpadInLayer = true
            return [.inLayer(current.layer, .move(direction, source: .dpad, isRepeat: false))]
        }
        if config.layerRepeatButtons[current.layer]?.contains(button) == true {
            layerRepeat = LayerRepeat(button: button, nextAt: time + config.layerRepeatDelay)
        }
        return [.inLayer(current.layer, .press(button))]
    }

    /// Wiederholungen, die in der Ebene begannen, enden mit ihr: Die Taste
    /// bekäme sonst nach dem Loslassen der Ebenen-Taste ihre gewöhnliche
    /// Bedeutung.
    mutating func endLayerRepeats() {
        layerRepeat = nil
        if dpadInLayer {
            dpadRepeat = nil
            dpadInLayer = false
        }
        if leftStickInLayer { leftRepeatAt = nil }
    }

    /// L1 oder R1 losgelassen (ohne eigene Ebene): beendet einen Akkord.
    mutating func bumperReleased() -> [ControllerGesture] {
        var gestures: [ControllerGesture] = []
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
