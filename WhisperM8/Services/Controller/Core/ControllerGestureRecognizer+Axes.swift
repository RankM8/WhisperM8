import Foundation

// Analoge Eingaben des Erkenners: Trigger, linker Stick (Richtungen mit
// Wiederholung), rechter Stick (Scrollen) und die Wiederholung des Steuerkreuzes.

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
            return []
        }
        leftRepeatAt = time + config.repeatDelay
        return [.move(direction, source: .leftStick, isRepeat: false)]
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
            gestures.append(.move(state.direction, source: .dpad, isRepeat: true))
            state.nextAt = nextRepeat(after: state.nextAt, now: time)
            dpadRepeat = state
        }
        if let direction = leftDirection, let nextAt = leftRepeatAt, Self.isDue(nextAt, at: time) {
            gestures.append(.move(direction, source: .leftStick, isRepeat: true))
            leftRepeatAt = nextRepeat(after: nextAt, now: time)
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
    /// Die erste Zeile kommt beim nächsten Tick sofort.
    mutating func rightStick(y: Float, at time: TimeInterval) {
        let magnitude = abs(y)
        guard magnitude >= config.stickDeadzone else {
            scroll = nil
            return
        }
        let normalized = min(1, max(0, Double((magnitude - config.stickDeadzone) / (1 - config.stickDeadzone))))
        let speed = config.scrollMinLinesPerSecond
            + (config.scrollMaxLinesPerSecond - config.scrollMinLinesPerSecond) * normalized * normalized
        // Stick nach oben heißt nach oben scrollen, also negative Zeilen.
        let rate = y > 0 ? -speed : speed
        if var state = scroll, (state.linesPerSecond < 0) == (rate < 0) {
            accumulate(&state, to: time)
            state.linesPerSecond = rate
            scroll = state
        } else {
            scroll = ScrollState(linesPerSecond: rate, accumulator: 1, lastUpdate: time)
        }
    }

    mutating func scrollLines(at time: TimeInterval) -> [ControllerGesture] {
        guard var state = scroll else { return [] }
        accumulate(&state, to: time)
        let lines = Int((state.accumulator + Self.epsilon).rounded(.down))
        state.accumulator = max(0, state.accumulator - Double(lines))
        scroll = state
        guard lines > 0 else { return [] }
        return [.scroll(lines: state.linesPerSecond < 0 ? -lines : lines)]
    }

    private func accumulate(_ state: inout ScrollState, to time: TimeInterval) {
        let elapsed = min(max(0, time - state.lastUpdate), config.scrollMaxCatchUp)
        state.accumulator += abs(state.linesPerSecond) * elapsed
        state.lastUpdate = time
    }

    var scrollDeadline: TimeInterval? {
        guard let state = scroll else { return nil }
        let missing = 1 - state.accumulator
        guard missing > Self.epsilon else { return state.lastUpdate }
        return state.lastUpdate + missing / abs(state.linesPerSecond)
    }
}
