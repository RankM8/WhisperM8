import Foundation

// ==============================================================================
// Entscheidet, ob ein tauber Listener neu gebaut wird.
//
// Bewusst als eigener, reiner Typ: `VoiceGateCoordinator` ist ein Singleton mit
// privatem Init und damit im Test kaum greifbar. Die Entscheidung
// herauszuziehen ist billiger, als den Coordinator testbar zu machen — und sie
// ist der Teil, bei dem Fehler weh tun (Neustart-Schleife).
//
// Der Wachhund heilt ursachenunabhaengig: Er fragt nicht, WARUM keine Puffer
// mehr kommen, sondern nur DASS keine kommen. Damit faengt er auch die stillen
// Tode, die wir nicht gefunden haben.
// ==============================================================================

struct VoiceGateWatchdogPolicy: Equatable {
    enum Action: Equatable {
        case none
        /// Listener verwerfen und neu aufbauen.
        case restart
        /// Mehrfach erfolglos — aufgeben und den Zustand sichtbar machen,
        /// statt weiter „scharf" zu behaupten.
        case giveUp
    }

    /// Mindestabstand zwischen zwei Neustarts.
    var minRestartInterval: TimeInterval = 30
    /// Nach so vielen erfolglosen Neustarts in Folge wird aufgegeben.
    var maxConsecutiveRestarts = 3

    private var lastRestartAt: Date?
    private var consecutiveRestarts = 0
    private var gaveUp = false

    init(minRestartInterval: TimeInterval = 30, maxConsecutiveRestarts: Int = 3) {
        self.minRestartInterval = minRestartInterval
        self.maxConsecutiveRestarts = maxConsecutiveRestarts
    }

    mutating func decide(
        armed: Bool,
        verdict: VoiceGateListenerHealth.Verdict,
        now: Date
    ) -> Action {
        guard armed else { return .none }

        switch verdict {
        case .healthy:
            // Ein gesunder Durchlauf loescht die Fehlerhistorie — sonst wuerde
            // ein einzelner Ausrutscher den Wachhund dauerhaft lahmlegen.
            consecutiveRestarts = 0
            gaveUp = false
            return .none

        case .starting:
            return .none

        case .deaf:
            if gaveUp { return .none }

            if consecutiveRestarts >= maxConsecutiveRestarts {
                gaveUp = true
                return .giveUp
            }

            if let lastRestartAt, now.timeIntervalSince(lastRestartAt) < minRestartInterval {
                return .none
            }

            lastRestartAt = now
            consecutiveRestarts += 1
            return .restart
        }
    }

    /// Nach einem manuellen Aus/An darf wieder von vorn probiert werden.
    mutating func reset() {
        lastRestartAt = nil
        consecutiveRestarts = 0
        gaveUp = false
    }
}
