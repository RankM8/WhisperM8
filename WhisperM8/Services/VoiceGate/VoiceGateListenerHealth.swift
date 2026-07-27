import Foundation

// ==============================================================================
// Lebenszeichen des Listeners.
//
// Der Gerätewechsel-Fehler vom 27.07.2026 war deshalb so aergerlich, weil der
// Listener NICHT abstuerzte: Engine lief, `isRunning` blieb true, das Gate
// meldete „scharf" — nur kamen keine Puffer mehr. Ohne Lebenszeichen sieht
// eine gesunde Sitzung im Log genauso aus wie eine taube.
//
// Primaersignal ist bewusst der AUDIO-PUFFER, nicht die Erkennung: Der Tap
// feuert unabhaengig davon, ob jemand spricht (~40–130 ms Takt). Ausbleibende
// Hypothesen waeren dagegen auch bei legitimer Stille normal.
// ==============================================================================

struct VoiceGateListenerHealth: Equatable {
    enum Verdict: Equatable {
        /// Frisch gestartet, erster Puffer steht noch aus.
        case starting
        case healthy
        /// Seit `gap` Sekunden kein Puffer mehr.
        case deaf(gap: TimeInterval)
    }

    /// Ab dieser Luecke gilt der Listener als taub.
    var deafThreshold: TimeInterval = 5
    /// Schonfrist nach Start/Rebind, bis der erste Puffer eintrifft.
    var startupGrace: TimeInterval = 3

    private var startedAt: Date?
    private var lastBufferAt: Date?

    init(deafThreshold: TimeInterval = 5, startupGrace: TimeInterval = 3) {
        self.deafThreshold = deafThreshold
        self.startupGrace = startupGrace
    }

    /// Start oder Rebind — die Uhr laeuft neu.
    mutating func markStarted(at date: Date) {
        startedAt = date
        lastBufferAt = nil
    }

    mutating func recordBuffer(at date: Date) {
        lastBufferAt = date
    }

    mutating func markStopped() {
        startedAt = nil
        lastBufferAt = nil
    }

    func verdict(now: Date) -> Verdict {
        guard let startedAt else { return .starting }

        if let lastBufferAt {
            let gap = now.timeIntervalSince(lastBufferAt)
            return gap > deafThreshold ? .deaf(gap: gap) : .healthy
        }

        // Noch kein einziger Puffer seit dem Start.
        let waited = now.timeIntervalSince(startedAt)
        return waited > startupGrace ? .deaf(gap: waited) : .starting
    }

    /// Fuers Log — wie lange der letzte Puffer her ist.
    func millisecondsSinceLastBuffer(now: Date) -> Int? {
        guard let lastBufferAt else { return nil }
        return Int(now.timeIntervalSince(lastBufferAt) * 1000)
    }
}
