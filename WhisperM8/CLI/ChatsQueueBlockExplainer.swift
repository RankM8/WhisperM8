import Foundation

/// Erklärt, warum ein vorgemerkter Folgeauftrag nicht abfließt.
///
/// Hintergrund: Die Zustellung hängt am Turn-Ende. Meldet ein Ziel dauerhaft
/// `working`, ohne dass sein Transkript wächst, wartet der Auftrag unbegrenzt —
/// und `queue` zeigte bisher nur „wartet seit X". Bei der Untersuchung eines
/// realen Staus war genau das die fehlende Information.
///
/// Bewusst pur: keine Uhr, kein Dateizugriff. Die Bewertung „Status
/// unglaubwürdig" ist eine Heuristik und muss unter allen Zeitkombinationen
/// prüfbar bleiben.
enum ChatsQueueBlockExplainer {
    /// Ab wann ein `working` ohne Transkript-Fortschritt als unglaubwürdig
    /// gilt. Bewusst großzügiger als die 120 s des Runtime-Watchers: Ein
    /// langer Build oder eine lange Websuche schreibt minutenlang nichts und
    /// ist trotzdem echte Arbeit.
    static let stallSeconds: TimeInterval = 300

    enum Reason: Equatable {
        /// Nichts wartet — keine Meldung nötig.
        case none
        /// Ziel arbeitet und schreibt; der Auftrag geht nach dem Turn raus.
        case waitingForTurnEnd(status: String)
        /// Ziel meldet Arbeit, das Transkript steht aber still.
        case stalled(status: String, statusAgeSec: Int, transcriptAgeSec: Int)
        /// Kein Prozess — die Session muss erst wieder laufen.
        case noProcess
    }

    /// - Parameter openCount: wartende Aufträge (0 = nichts zu erklären).
    /// - Parameter runtimeStatus: gemeldeter Laufzeitstatus.
    /// - Parameter statusSince: seit wann dieser Status gilt.
    /// - Parameter transcriptModifiedAt: letzte Änderung des Transkripts.
    /// - Parameter hasProcess: läuft eine PTY?
    static func reason(
        openCount: Int,
        runtimeStatus: String?,
        statusSince: Date?,
        transcriptModifiedAt: Date?,
        hasProcess: Bool,
        now: Date
    ) -> Reason {
        guard openCount > 0 else { return .none }
        guard hasProcess else { return .noProcess }
        guard let status = runtimeStatus, status != "idle" else {
            // idle + wartender Auftrag ist ein Übergangszustand (Zustellung
            // läuft gleich an) — keine Warnung, sonst wäre sie Dauerrauschen.
            return .none
        }
        let statusAge = statusSince.map { max(0, now.timeIntervalSince($0)) }
        let transcriptAge = transcriptModifiedAt.map { max(0, now.timeIntervalSince($0)) }

        if let transcriptAge, transcriptAge > stallSeconds,
           let statusAge, statusAge > stallSeconds {
            return .stalled(status: status,
                            statusAgeSec: Int(statusAge),
                            transcriptAgeSec: Int(transcriptAge))
        }
        return .waitingForTurnEnd(status: status)
    }

    /// Menschlicher Einzeiler; `nil` = nichts zu melden.
    static func line(for reason: Reason) -> String? {
        switch reason {
        case .none:
            return nil
        case .waitingForTurnEnd(let status):
            return "Ziel ist \(status) — Zustellung beim nächsten Turn-Ende."
        case .noProcess:
            return "Kein laufender Prozess — Zustellung erst nach `resume`."
        case .stalled(let status, let statusAge, let transcriptAge):
            return "⚠︎ Ziel meldet seit \(minutes(statusAge)) „\(status)\", das Transkript ist seit "
                + "\(minutes(transcriptAge)) unverändert — Status unglaubwürdig, der Auftrag fließt nicht ab. "
                + "Prüfe mit `tail`; erzwinge nichts automatisch."
        }
    }

    /// Maschinenlesbarer Code fürs JSON.
    static func code(for reason: Reason) -> String? {
        switch reason {
        case .none: return nil
        case .waitingForTurnEnd: return "waitingForTurnEnd"
        case .noProcess: return "noProcess"
        case .stalled: return "stalled"
        }
    }

    private static func minutes(_ seconds: Int) -> String {
        seconds < 90 ? "\(seconds) s" : "\(seconds / 60) min"
    }
}
