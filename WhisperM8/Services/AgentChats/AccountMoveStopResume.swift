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
    /// Ein Turn wurde abgebrochen (ESC, `chats interrupt`): Die Claude-CLI legt
    /// dessen Prompt in den Composer zurück. Ein programmatischer Versand
    /// hängte seinen Text daran an — der Send-Guard blockte die Wiedervorlage
    /// samt neuem Prompt, der verloren ging, obwohl `chats send` „zugestellt“
    /// meldete (E2E 17.10.2026).
    private(set) var mayHoldRestoredPrompt = false

    /// Vor einem programmatischen Versand zuerst leeren? Nur bei vermutetem
    /// zurückgelegtem Prompt — der steht schon im Transcript. Ein eigener
    /// Entwurf des Users (auch ein bearbeiteter Rückleger) bleibt unangetastet.
    var shouldClearBeforeSubmit: Bool {
        mayHoldRestoredPrompt && !mayHaveUnsentInput
    }

    /// Ein Turn läuft an — also wurde abgeschickt. Ein danach Getipptes
    /// setzt die Schätzung wieder.
    mutating func recordSubmittedByTurnStart() {
        mayHaveUnsentInput = false
        mayHoldRestoredPrompt = false
    }

    mutating func recordTurnInterrupted() {
        mayHoldRestoredPrompt = true
    }

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
                mayHoldRestoredPrompt = false
            }
        case 8 where flags.contains(.control):
            // Ctrl+C leert in Claude Code den Composer (bzw. bricht ab).
            mayHaveUnsentInput = false
            mayHoldRestoredPrompt = false
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
        mayHoldRestoredPrompt = false
    }
}

/// Wartet, bis ein beendeter PTY-Prozess wirklich weg ist. Erst dann ist
/// sicher, dass er nichts mehr in sein Transcript schreibt — ein Umzug davor
/// koennte eine spaete Zeile an den alten Ort schreiben lassen, und der
/// Verlauf laege danach in zwei Dateien.
enum ProcessExitWaiter {
    /// `true`, wenn der Prozess nicht mehr existiert oder nur noch als Zombie
    /// auf sein `waitpid` wartet — beendet ist er dann, schreiben kann er
    /// nicht mehr.
    ///
    /// Der Status kommt bewusst aus `sysctl(KERN_PROC_PID)`: `proc_pidinfo`
    /// liefert für einen Zombie 0 Bytes, und genau daran scheiterte der
    /// Kontowechsel im Feld (Vorfall 11.10.2026: Claude meldete `SessionEnd`
    /// und war weg, der Zombie galt 5 s lang als „läuft noch" → `stopTimeout`,
    /// kein Umzug, kein Neustart).
    static func hasExited(pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 {
            // EPERM hiesse: existiert, gehoert aber jemand anderem.
            return errno == ESRCH
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return false
        }
        return info.kp_proc.p_stat == SZOMB
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

/// Holt einen beendeten PTY-Kindprozess ab (`waitpid`). SwiftTerms
/// `terminate()` bricht seinen eigenen Prozess-Monitor ab — danach ruft
/// niemand mehr `waitpid`, und jeder angehaltene Chat blieb bis zum App-Ende
/// als Zombie in der Prozesstabelle (Befund 11.10.2026). Eine Dispatch-Quelle
/// meldet das Prozessende, dann wird abgeholt; ein Prozess, der schon vor dem
/// Einrichten endete, wird sofort abgeholt.
enum ChildProcessReaper {
    private static let queue = DispatchQueue(label: "com.whisperm8.child-reaper")
    private static var sources: [pid_t: DispatchSourceProcess] = [:]

    static func reap(pid: pid_t) {
        guard pid > 0 else { return }
        queue.async {
            guard sources[pid] == nil else { return }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler {
                collect(pid)
            }
            sources[pid] = source
            source.resume()
            // Schon vorher beendet? Dann feuert die Quelle unter Umständen nie.
            collect(pid)
        }
    }

    /// Nur auf `queue`. `WNOHANG`: läuft er noch, bleibt die Quelle bestehen.
    private static func collect(_ pid: pid_t) {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        // pid = abgeholt; -1/ECHILD = schon abgeholt bzw. nicht unser Kind.
        guard result == pid || (result == -1 && errno == ECHILD) else { return }
        sources.removeValue(forKey: pid)?.cancel()
    }
}
