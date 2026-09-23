import AppKit
import Darwin
import Foundation

/// `whisperm8 chats move-account --stop-and-resume`: welche Chats, die der
/// `AccountMovePlanner` nur wegen „laeuft gerade" uebersprungen hat, duerfen
/// angehalten, umgezogen und im Zielkonto neu gestartet werden?
///
/// Pur — die Fakten (arbeitet? Entwurf im Composer? eigene Session?) liefert
/// der Aufrufer. Alle anderen Skip-Gruende bleiben unangetastet: ein
/// Hintergrund-Agent oder ein Codex-Chat wird auch mit diesem Flag nie
/// gestoppt, weil er danach ohnehin nicht umziehen duerfte.
enum AccountMoveStopResumePlanner {
    enum BlockReason: String, Equatable {
        /// Ein laufender Turn wuerde abgebrochen — nur mit `--force`.
        case working
        /// Im Composer steht vermutlich ungesendeter Text; das Beenden der TUI
        /// verwirft ihn unwiederbringlich — nur mit `--force`.
        case unsentInput
        /// Die aufrufende Session selbst: sie wuerde ihren eigenen Prozess
        /// beenden, waehrend sie auf die Antwort wartet. Auch `--force` hebt
        /// das nicht auf.
        case ownSession

        var label: String {
            switch self {
            case .working: return "arbeitet gerade — nur mit --force"
            case .unsentInput: return "Eingabefeld enthält vermutlich ungesendeten Text — nur mit --force"
            case .ownSession: return "eigene Session — kann sich nicht selbst anhalten"
            }
        }
    }

    struct Blocked: Equatable {
        var candidate: AccountMovePlanner.Candidate
        var reason: BlockReason
    }

    struct Selection: Equatable {
        /// Anhalten, umziehen, neu starten.
        var toStop: [AccountMovePlanner.Candidate] = []
        /// Wuerden umziehen, wenn sie nicht liefen — bleiben aber stehen.
        var blocked: [Blocked] = []
    }

    static func select(
        plan: AccountMovePlanner.Plan,
        force: Bool,
        isCaller: (UUID) -> Bool,
        isWorking: (UUID) -> Bool,
        mayHaveUnsentInput: (UUID) -> Bool
    ) -> Selection {
        let running = plan.skipped.filter { $0.reason == .running }.map(\.candidate)
        guard !running.isEmpty else { return Selection() }
        // Neu planen, als liefen sie nicht: so greifen die uebrigen Regeln
        // (z. B. Kollision im Ziel) vor dem Stop — ein Chat, der danach doch
        // nicht umziehen duerfte, wird gar nicht erst angehalten.
        let replanned = AccountMovePlanner.plan(
            candidates: running.map { candidate in
                var stopped = candidate
                stopped.isRunning = false
                return stopped
            },
            targetProfile: plan.targetProfile,
            targetIsLoggedIn: true
        )
        var selection = Selection()
        for candidate in replanned.movable {
            let id = candidate.sessionID
            if isCaller(id) {
                selection.blocked.append(Blocked(candidate: candidate, reason: .ownSession))
            } else if !force, isWorking(id) {
                selection.blocked.append(Blocked(candidate: candidate, reason: .working))
            } else if !force, mayHaveUnsentInput(id) {
                selection.blocked.append(Blocked(candidate: candidate, reason: .unsentInput))
            } else {
                selection.toStop.append(candidate)
            }
        }
        return selection
    }
}

/// Schaetzt konservativ, ob im Composer einer Claude-/Codex-TUI ungesendeter
/// Text stehen koennte. Der Inhalt selbst ist von aussen nicht lesbar; ein
/// Beenden der TUI verwirft ihn aber — deshalb verweigert
/// `--stop-and-resume` ohne `--force`, solange diese Schaetzung anschlaegt.
///
/// Konservativ heisst: im Zweifel „vielleicht Entwurf". Ein Fehlalarm kostet
/// nur ein `--force`, ein uebersehener Entwurf waere verlorene Eingabe.
struct TerminalComposerDraftTracker: Equatable {
    private(set) var mayHaveUnsentInput = false

    /// Tastendruck, der an die Terminal-View ging.
    mutating func recordKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case 36, 76:
            // Return/Enter schickt ab; mit Shift/Option ist es ein Zeilenumbruch
            // im Entwurf.
            if flags.contains(.shift) || flags.contains(.option) {
                mayHaveUnsentInput = true
            } else {
                mayHaveUnsentInput = false
            }
        case 8 where flags.contains(.control):
            // Ctrl+C leert in Claude Code den Composer (bzw. bricht ab).
            mayHaveUnsentInput = false
        case 9 where flags.contains(.command):
            // Cmd+V fuegt ein.
            mayHaveUnsentInput = true
        case 53, 48, 51, 117, 115, 119, 116, 121, 123, 124, 125, 126:
            // ESC, Tab, Loeschen, Navigation: fuegen keinen neuen Text ein. Ein
            // nach ESC-Abbruch zurueckgelegter Prompt steht bereits im
            // Transcript — ihn zu verwerfen verliert nichts.
            break
        default:
            // Andere Cmd-/Ctrl-Kuerzel sind Bedienung, kein Text.
            if flags.contains(.command) || flags.contains(.control) { break }
            mayHaveUnsentInput = true
        }
    }

    /// Programmatisch eingefuegter Text ohne Absenden (Datei-Drop,
    /// Report-Routing, `chats send --no-submit`).
    mutating func recordTextInserted() {
        mayHaveUnsentInput = true
    }

    /// Programmatisch abgeschickt (`chats send`, Queue-Zustellung).
    mutating func recordSubmitted() {
        mayHaveUnsentInput = false
    }
}

/// Wartet, bis ein beendeter PTY-Prozess wirklich weg ist. Erst dann ist
/// sicher, dass er nichts mehr in sein Transcript schreibt — ein Umzug davor
/// koennte eine spaete Zeile an den alten Ort schreiben lassen, und der
/// Verlauf laege danach in zwei Dateien.
enum ProcessExitWaiter {
    /// `true`, wenn der Prozess nicht mehr existiert oder nur noch als Zombie
    /// auf sein `waitpid` wartet (SwiftTerm raeumt nach `terminate()` nicht
    /// mehr ab — beendet ist er trotzdem, schreiben kann er nicht mehr).
    static func hasExited(pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 {
            // EPERM hiesse: existiert, gehoert aber jemand anderem.
            return errno == ESRCH
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return false
        }
        return info.pbi_status == UInt32(SZOMB)
    }

    /// - Returns: `true`, sobald `hasExited` zutrifft; `false` nach Ablauf
    ///   von `timeout`.
    static func waitForExit(
        pid: pid_t,
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1,
        hasExited: (pid_t) -> Bool = ProcessExitWaiter.hasExited(pid:)
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if hasExited(pid) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }
}
