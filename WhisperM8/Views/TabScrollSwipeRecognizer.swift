import AppKit

/// Erkennt eine horizontale Zwei-Finger-Blätter-Geste (Safari-Stil) aus
/// Trackpad-Scroll-Events — der Tab-Wechsel per Trackpad, der mit den
/// macOS-Default-Einstellungen funktioniert (anders als Drei-Finger-Swipes,
/// die der Window Server standardmäßig für Spaces konsumiert).
///
/// Pure State-Machine über eine Gesten-Lebensdauer (began → changed… →
/// ended → Momentum-Ausläufer). Der Aufrufer füttert Deltas im
/// FINGER-Raum (Natural-Scrolling bereits normalisiert) und setzt das
/// Verdict um:
///
/// - Die Gesten-Achse wird nach `axisLockThreshold` pt Gesamtbewegung
///   festgelegt. Vertikale Gesten laufen komplett unangetastet durch —
///   Terminal-Scrollback bleibt unberührt.
/// - Horizontal gilt nur bei klarer Dominanz (`horizontalDominance`),
///   diagonales Scrollen bleibt vertikal/durchgereicht.
/// - Eine horizontale Geste wird ab Achsen-Entscheid KONSUMIERT (die TUI
///   soll keine horizontalen Scroll-Reste sehen) und löst GENAU EINMAL bei
///   `triggerThreshold` pt akkumuliertem X aus; ihre Momentum-Ausläufer
///   werden ebenfalls geschluckt.
/// - Events ohne Phase (klassische Mausräder) gehen unangetastet durch.
struct TabScrollSwipeRecognizer: Equatable {
    enum Verdict: Equatable {
        /// Event unangetastet weiterreichen (vertikal, Maus, fremdes Momentum).
        case passThrough
        /// Event schlucken (Teil einer horizontalen Geste), kein Wechsel.
        case consume
        /// Schwellwert gerissen → Tab-Wechsel (+1 = rechts, -1 = links).
        case trigger(direction: Int)
    }

    /// Achsen-Entscheid ab dieser Gesamtbewegung (|x| + |y| in pt).
    static let axisLockThreshold: CGFloat = 8
    /// Auslöse-Schwelle für den Tab-Wechsel (akkumuliertes |x| in pt).
    static let triggerThreshold: CGFloat = 60
    /// Horizontal nur, wenn |x| die |y|-Bewegung um diesen Faktor dominiert.
    static let horizontalDominance: CGFloat = 1.5

    private enum Axis { case undecided, horizontal, vertical }
    private var axis: Axis = .undecided
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var didTrigger = false

    /// Verarbeitet ein Scroll-Event. `deltaX`/`deltaY` im Finger-Raum:
    /// positiv = Finger nach rechts/unten.
    mutating func handle(
        phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> Verdict {
        // Momentum-Ausläufer folgen der Achse der gerade beendeten Geste:
        // horizontale Gesten schlucken auch ihr Momentum (sonst trudeln
        // horizontale Scroll-Reste ins Terminal), vertikales Momentum läuft
        // durch (natürliches Ausrollen des Scrollbacks).
        if phase.isEmpty, !momentumPhase.isEmpty {
            let verdict: Verdict = axis == .horizontal ? .consume : .passThrough
            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                reset()
            }
            return verdict
        }

        // Ohne Phase UND ohne Momentum: klassisches Mausrad → nicht unser Fall.
        guard !phase.isEmpty else { return .passThrough }

        if phase.contains(.mayBegin) {
            reset()
            return .passThrough
        }
        if phase.contains(.began) {
            reset()
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            // Achse für evtl. folgendes Momentum behalten; Akkus zurücksetzen.
            let verdict: Verdict = axis == .horizontal ? .consume : .passThrough
            accumulatedX = 0
            accumulatedY = 0
            didTrigger = false
            return verdict
        }

        accumulatedX += deltaX
        accumulatedY += deltaY

        if axis == .undecided,
           abs(accumulatedX) + abs(accumulatedY) >= Self.axisLockThreshold {
            axis = abs(accumulatedX) > abs(accumulatedY) * Self.horizontalDominance
                ? .horizontal
                : .vertical
        }

        switch axis {
        case .undecided, .vertical:
            return .passThrough
        case .horizontal:
            if !didTrigger, abs(accumulatedX) >= Self.triggerThreshold {
                didTrigger = true
                // Finger nach rechts (x > 0) → Tab rechts.
                return .trigger(direction: accumulatedX > 0 ? +1 : -1)
            }
            return .consume
        }
    }

    private mutating func reset() {
        axis = .undecided
        accumulatedX = 0
        accumulatedY = 0
        didTrigger = false
    }
}
