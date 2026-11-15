import Foundation

// Analoge Eingaben des Erkenners: Trigger, linker Stick (Richtungen mit
// Wiederholung), rechter Stick (Scrollen), die Wiederholung des Steuerkreuzes
// und gehaltener Tasten (Viereck); unter R1 blättert der rechte Stick (WM8-116).

extension ControllerGestureRecognizer {
    // MARK: - Trigger

    /// Gedrückt ab `triggerPressThreshold`, wieder frei unter
    /// `triggerReleaseThreshold`. Dazwischen bleibt der letzte Zustand.
    mutating func trigger(_ button: ControllerButton, value: Float, at time: TimeInterval) -> [ControllerGesture] {
        guard button.isTrigger else { return [] }
        let isDown = pressedButtons.contains(button)
        if !isDown, value >= config.triggerPressThreshold {
            return digital(button, pressed: true, at: time)
        }
        if isDown, value < config.triggerReleaseThreshold {
            return digital(button, pressed: false, at: time)
        }
        return []
    }

    // MARK: - Linker Stick

    mutating func leftStick(x: Float, y: Float, at time: TimeInterval) -> [ControllerGesture] {
        leftDeflected = (x * x + y * y).squareRoot() >= config.stickDeadzone
        let direction = Self.stickDirection(x: x, y: y, current: leftDirection, config: config)
        guard direction != leftDirection else { return [] }
        leftDirection = direction
        guard let direction else {
            leftRepeatAt = nil
            leftStickInLayer = false
            return []
        }
        leftRepeatAt = time + config.repeatDelay
        let move = ControllerGesture.move(direction, source: .leftStick, isRepeat: false)
        // Ein Stoß während einer gehaltenen Ebenen-Taste gehört zur Ebene
        // (bei L2 öffnet er die Liste) und macht aus ihr kein Tippen mehr.
        guard var current = layer else {
            leftStickInLayer = false
            return [move]
        }
        current.used = true
        layer = current
        leftStickInLayer = true
        return [.inLayer(current.layer, move)]
    }

    /// Höchstens eine Richtung ist aktiv, und zwar die der dominanten Achse.
    ///
    /// - Unterhalb der radialen Totzone: keine Richtung.
    /// - Eine aktive Richtung bleibt, solange ihr Anteil mindestens
    ///   `stickReleaseThreshold` beträgt. Sie wechselt auf die andere Achse
    ///   nur, wenn diese die Aktivierungsschwelle erreicht und die aktive um
    ///   `stickAxisSwitchMargin` übertrifft (Hysterese an der Diagonale).
    /// - Ohne aktive Richtung: dominante Achse ab `stickActivateThreshold`.
    static func stickDirection(
        x: Float, y: Float, current: ControllerDirection?, config: Config
    ) -> ControllerDirection? {
        guard (x * x + y * y).squareRoot() >= config.stickDeadzone else { return nil }
        if let current {
            let own = component(of: current, x: x, y: y)
            if own >= config.stickReleaseThreshold {
                let isHorizontal = current == .left || current == .right
                let cross = isHorizontal ? y : x
                if abs(cross) >= config.stickActivateThreshold,
                   abs(cross) > own + config.stickAxisSwitchMargin {
                    return isHorizontal ? (cross > 0 ? .up : .down) : (cross > 0 ? .right : .left)
                }
                return current
            }
        }
        if abs(x) >= abs(y) {
            guard abs(x) >= config.stickActivateThreshold else { return nil }
            return x > 0 ? .right : .left
        }
        guard abs(y) >= config.stickActivateThreshold else { return nil }
        return y > 0 ? .up : .down
    }

    /// Ausschlag in Richtung `direction` (negativ, wenn der Stick entgegengesetzt steht).
    static func component(of direction: ControllerDirection, x: Float, y: Float) -> Float {
        switch direction {
        case .up: return y
        case .down: return -y
        case .right: return x
        case .left: return -x
        }
    }

    // MARK: - Wiederholung (Steuerkreuz und linker Stick)

    /// Je Quelle höchstens eine Wiederholung pro Tick. Kommt der Tick spät,
    /// wird nicht nachgeholt, sondern im Takt ab jetzt weitergemacht.
    mutating func repeats(at time: TimeInterval) -> [ControllerGesture] {
        var gestures: [ControllerGesture] = []
        if var state = dpadRepeat, Self.isDue(state.nextAt, at: time) {
            gestures.append(inLayerIf(dpadInLayer, .move(state.direction, source: .dpad, isRepeat: true)))
            state.nextAt = nextRepeat(after: state.nextAt, now: time)
            dpadRepeat = state
        }
        if let direction = leftDirection, let nextAt = leftRepeatAt, Self.isDue(nextAt, at: time) {
            gestures.append(inLayerIf(leftStickInLayer, .move(direction, source: .leftStick, isRepeat: true)))
            leftRepeatAt = nextRepeat(after: nextAt, now: time)
        }
        if var state = layerRepeat, let current = layer, Self.isDue(state.nextAt, at: time) {
            gestures.append(.inLayer(current.layer, .holdRepeat(state.button)))
            let next = state.nextAt + config.layerRepeatInterval
            state.nextAt = Self.isDue(next, at: time) ? time + config.layerRepeatInterval : next
            layerRepeat = state
        }
        gestures += holdRepeats(at: time)
        gestures += pageRepeats(at: time)
        return gestures
    }

    /// Wiederholung einer Bewegung, die in der Ebene begann, bleibt in ihr.
    /// (Endet die Ebene, hält `endLayerRepeats` die Wiederholung an.)
    private func inLayerIf(_ inLayer: Bool, _ gesture: ControllerGesture) -> ControllerGesture {
        guard inLayer, let layer else { return gesture }
        return .inLayer(layer.layer, gesture)
    }

    /// Gehaltene Tasten mit Wiederholung (Viereck): erst `.holdRepeat` im
    /// normalen Takt, nach `holdRepeatLongAfter` `.holdRepeatLong` im
    /// langsameren. Wie oben höchstens eine
    /// Wiederholung je Tick und Taste, kein Nachholen.
    mutating func holdRepeats(at time: TimeInterval) -> [ControllerGesture] {
        var gestures: [ControllerGesture] = []
        for button in ControllerButton.allCases {
            guard var hold = holds[button], hold.began, let nextAt = hold.nextRepeatAt,
                  Self.isDue(nextAt, at: time), let threshold = config.holdThreshold(for: button) else { continue }
            let heldFor = time - (hold.pressedAt + threshold)
            let isLong = heldFor + Self.epsilon >= config.holdRepeatLongAfter
            gestures.append(isLong ? .holdRepeatLong(button) : .holdRepeat(button))
            let interval = isLong ? config.holdRepeatLongInterval : config.holdRepeatInterval
            let next = nextAt + interval
            hold.nextRepeatAt = Self.isDue(next, at: time) ? time + interval : next
            holds[button] = hold
        }
        return gestures
    }

    private func nextRepeat(after deadline: TimeInterval, now: TimeInterval) -> TimeInterval {
        let next = deadline + config.repeatInterval
        return Self.isDue(next, at: now) ? now + config.repeatInterval : next
    }

    // MARK: - Rechter Stick

    /// Nur die y-Achse zählt (axiale Totzone, damit ein seitlicher Ausschlag
    /// nicht langsam mitscrollt). Die Rate wächst quadratisch mit dem
    /// Ausschlag von `scrollMinLinesPerSecond` bis `scrollMaxLinesPerSecond`.
    /// Am Anschlag gehalten steigt sie nach `scrollBoostDelay` gleichmäßig bis
    /// zum `scrollBoostMaxFactor`-fachen (WM8-116); Loslassen, Richtungswechsel
    /// oder ein Ausschlag unter `scrollBoostExitDeflection` setzen das zurück.
    /// Die erste Zeile kommt beim nächsten Tick sofort.
    ///
    /// In einer Ebene aus `stickPagingLayers` (R1) blättert der Stick statt zu
    /// scrollen (`pageStick`). Ein Scrollen, das vor der Ebene begann, läuft
    /// weiter, bis der Stick in die Mitte zurückkehrt.
    mutating func rightStick(y: Float, at time: TimeInterval) -> [ControllerGesture] {
        let magnitude = abs(y)
        guard magnitude >= config.stickDeadzone else {
            scroll = nil
            page = nil
            return []
        }
        if page != nil || (scroll == nil && layer.map { config.stickPagingLayers.contains($0.layer) } == true) {
            return pageStick(y: y, at: time)
        }
        let normalized = min(1, max(0, Double((magnitude - config.stickDeadzone) / (1 - config.stickDeadzone))))
        let speed = config.scrollMinLinesPerSecond
            + (config.scrollMaxLinesPerSecond - config.scrollMinLinesPerSecond) * normalized * normalized
        // Stick nach oben heißt nach oben scrollen, also negative Zeilen.
        let rate = y > 0 ? -speed : speed
        let atStop = magnitude >= config.scrollBoostEnterDeflection
        if var state = scroll, (state.linesPerSecond < 0) == (rate < 0) {
            // Erst bis jetzt mit dem alten Tempo aufsummieren, dann umstellen.
            accumulate(&state, to: time)
            state.linesPerSecond = rate
            if state.boostSince == nil, atStop {
                state.boostSince = time
            } else if state.boostSince != nil, magnitude < config.scrollBoostExitDeflection {
                state.boostSince = nil
            }
            scroll = state
        } else {
            scroll = ScrollState(linesPerSecond: rate, accumulator: 1, lastUpdate: time,
                                 boostSince: atStop ? time : nil)
        }
        return []
    }

    /// Blättern unter R1: ein Stoß hoch oder runter (ab
    /// `stickActivateThreshold`, frei unter `stickReleaseThreshold`) gibt
    /// sofort einen Bildschirm, gehalten nach `pageRepeatDelay` alle
    /// `pageRepeatInterval` den nächsten. Jede Auslenkung über der Totzone
    /// zählt als zweite Eingabe der Ebene: R1 löst beim Loslassen dann kein
    /// Tippen (Chatwechsel) mehr aus.
    mutating func pageStick(y: Float, at time: TimeInterval) -> [ControllerGesture] {
        guard var state = page ?? layer.map({ PageState(layer: $0.layer) }) else { return [] }
        defer { page = state }
        guard !state.ended else { return [] }
        if var current = layer {
            current.used = true
            layer = current
        }
        let direction = Self.pageDirection(y: y, current: state.direction, config: config)
        guard direction != state.direction else { return [] }
        state.direction = direction
        guard let direction else {
            state.nextAt = nil
            return []
        }
        state.nextAt = time + config.pageRepeatDelay
        return [.inLayer(state.layer, .scrollPage(step: direction == .up ? -1 : 1))]
    }

    /// Richtung beim Blättern, nur die y-Achse, mit Hysterese wie der linke Stick.
    static func pageDirection(y: Float, current: ControllerDirection?, config: Config) -> ControllerDirection? {
        if let current, component(of: current, x: 0, y: y) >= config.stickReleaseThreshold { return current }
        guard abs(y) >= config.stickActivateThreshold else { return nil }
        return y > 0 ? .up : .down
    }

    /// Wiederholung beim Blättern: höchstens eine je Tick, kein Nachholen.
    mutating func pageRepeats(at time: TimeInterval) -> [ControllerGesture] {
        guard var state = page, !state.ended, let direction = state.direction, let nextAt = state.nextAt,
              Self.isDue(nextAt, at: time) else { return [] }
        let next = nextAt + config.pageRepeatInterval
        state.nextAt = Self.isDue(next, at: time) ? time + config.pageRepeatInterval : next
        page = state
        return [.inLayer(state.layer, .scrollPage(step: direction == .up ? -1 : 1))]
    }

    /// Gibt die aufgelaufenen Zeilen als eine Geste aus, höchstens alle
    /// `scrollMinInterval` (Bündelung bei hohem Tempo).
    mutating func scrollLines(at time: TimeInterval) -> [ControllerGesture] {
        guard var state = scroll else { return [] }
        if let lastEmit = state.lastEmit, !Self.isDue(lastEmit + config.scrollMinInterval, at: time) { return [] }
        accumulate(&state, to: time)
        let lines = Int((state.accumulator + Self.epsilon).rounded(.down))
        state.accumulator = max(0, state.accumulator - Double(lines))
        if lines > 0 { state.lastEmit = time }
        scroll = state
        guard lines > 0 else { return [] }
        return [.scroll(lines: state.linesPerSecond < 0 ? -lines : lines)]
    }

    /// Summiert die Zeilen seit `lastUpdate` auf, mit dem Anstieg am Anschlag.
    /// Kommt der Zeitgeber spät, zählen höchstens `scrollMaxCatchUp` Sekunden.
    private func accumulate(_ state: inout ScrollState, to time: TimeInterval) {
        let end = max(state.lastUpdate, time)
        let start = max(state.lastUpdate, end - config.scrollMaxCatchUp)
        let effective: TimeInterval
        if let since = state.boostSince {
            effective = Self.boostIntegral(upTo: end - since, config: config)
                - Self.boostIntegral(upTo: start - since, config: config)
        } else {
            effective = end - start
        }
        state.accumulator += abs(state.linesPerSecond) * effective
        state.lastUpdate = end
    }

    /// Tempo-Faktor nach `held` Sekunden am Anschlag: bis `scrollBoostDelay`
    /// 1, dann gleichmäßig steigend bis `scrollBoostMaxFactor` nach weiteren
    /// `scrollBoostRampDuration`.
    static func boostFactor(after held: TimeInterval, config: Config) -> Double {
        let ramp = held - config.scrollBoostDelay
        guard ramp > 0 else { return 1 }
        guard config.scrollBoostRampDuration > 0 else { return config.scrollBoostMaxFactor }
        let progress = min(1, ramp / config.scrollBoostRampDuration)
        return 1 + (config.scrollBoostMaxFactor - 1) * progress
    }

    /// Fläche unter `boostFactor` von 0 bis `held` (in „Sekunden Grundtempo“):
    /// Zeilen zwischen a und b = Grundtempo × (F(b) − F(a)). Exakt statt
    /// abgetastet, damit das Tempo nicht vom Takt des Zeitgebers abhängt.
    static func boostIntegral(upTo held: TimeInterval, config: Config) -> Double {
        let time = max(0, held)
        let delay = config.scrollBoostDelay
        guard time > delay else { return time }
        let rampDuration = config.scrollBoostRampDuration
        let maxFactor = config.scrollBoostMaxFactor
        guard rampDuration > 0 else { return delay + maxFactor * (time - delay) }
        let ramp = min(time - delay, rampDuration)
        var area = delay + ramp + (maxFactor - 1) * ramp * ramp / (2 * rampDuration)
        if time > delay + rampDuration { area += maxFactor * (time - delay - rampDuration) }
        return area
    }

    /// Wann die nächste Zeile fällig ist, frühestens `scrollMinInterval` nach
    /// der letzten Geste. Gerechnet mit dem Tempo von jetzt; da es am Anschlag
    /// nur steigt, ist die Zeile zur Frist sicher voll.
    var scrollDeadline: TimeInterval? {
        guard let state = scroll else { return nil }
        let missing = 1 - state.accumulator
        var due = state.lastUpdate
        if missing > Self.epsilon {
            let factor = state.boostSince.map { Self.boostFactor(after: state.lastUpdate - $0, config: config) } ?? 1
            due += missing / (abs(state.linesPerSecond) * factor)
        }
        guard let lastEmit = state.lastEmit else { return due }
        return max(due, lastEmit + config.scrollMinInterval)
    }
}
