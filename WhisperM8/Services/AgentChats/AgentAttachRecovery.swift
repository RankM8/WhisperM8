import Foundation

/// Was passiert, wenn ein `claude attach` an einen Hintergrund-Agent endet.
/// Pure Entscheidungen, damit die Detailansicht nur noch ausführt
/// (Review-Befunde 11.11.2026).
enum AgentAttachRecovery {
    /// Ende eines PTY-Prozesses, dekodiert aus dem rohen `waitpid`-Status.
    enum ProcessEnd: Equatable {
        case exited(Int32)
        case signaled(Int32)
        case unknown
    }

    /// Ein Attach, der länger lief, ist kein „gescheiterter Start" mehr —
    /// dann endete der Agent selbst (Daemon-Neustart, `claude stop`, Absturz)
    /// und der Tab bleibt beendet stehen.
    static let quickFailureWindow: TimeInterval = 10
    /// Pause vor dem einen erneuten Attach, wenn der Worker noch im Roster steht.
    static let reattachDelay: TimeInterval = 1.5
    /// So lange zählt ein erneuter Attach als „schon versucht".
    static let reattachMemory: TimeInterval = 60

    /// SwiftTerm liefert im forkpty-Pfad (`LocalProcess.processTerminated`) den
    /// ROHEN `waitpid`-Status: `exit(1)` kommt als 256, ein Signal als dessen
    /// Nummer. Die Makros WIFEXITED/WEXITSTATUS/WIFSIGNALED gibt es in Swift
    /// nicht, deshalb hier von Hand.
    static func decode(waitStatus raw: Int32?) -> ProcessEnd {
        guard let raw else { return .unknown }
        let low = raw & 0x7f
        if low == 0 { return .exited((raw >> 8) & 0xff) }
        if low != 0x7f { return .signaled(low) }
        return .unknown
    }

    /// Kommt ein Rückweg überhaupt in Frage? Nur bei einem Attach-Start, der
    /// von selbst mit Fehler endete (kein Signal, kein Exit 0) und das
    /// schnell — ein bewusst gestoppter oder lange gelaufener Agent kommt
    /// nicht ungefragt wieder.
    static func isQuickFailedAttach(
        isBackgroundAttachFallback: Bool,
        end: ProcessEnd,
        runDuration: TimeInterval?
    ) -> Bool {
        guard isBackgroundAttachFallback,
              case .exited(let code) = end, code != 0,
              let runDuration, runDuration < quickFailureWindow else { return false }
        return true
    }

    enum Step: Equatable {
        /// Worker steht noch im Roster: kurz warten, einmal erneut anhängen.
        case reattach
        /// Worker fehlt ganz: normales `--resume` (nie wieder Attach).
        case resume
        /// Erneuter Attach schon versucht und Worker noch da: Tab bleibt
        /// beendet, kein zweiter Prozess.
        case giveUp
    }

    static func nextStep(workerStillListed: Bool, reattachAlreadyTried: Bool) -> Step {
        guard workerStillListed else { return .resume }
        return reattachAlreadyTried ? .giveUp : .reattach
    }

    /// Ist der Chat noch irgendwo offen (Tab in einem Fenster oder Grid-Platz)?
    /// Ein geschlossener Tab bekommt keinen unsichtbaren Neustart.
    static func isOpen(_ sessionID: UUID, in state: AgentUIState) -> Bool {
        state.openTabIDs.contains(sessionID)
            || state.windows.contains { $0.openTabIDs.contains(sessionID) }
            || state.gridWorkspaces.contains { $0.slots.contains(sessionID) }
    }

    // MARK: Gedächtnis für den einen erneuten Attach

    @MainActor private static var reattachTriedAt: [UUID: Date] = [:]

    @MainActor static func reattachAlreadyTried(_ sessionID: UUID, now: Date = Date()) -> Bool {
        guard let at = reattachTriedAt[sessionID] else { return false }
        return now.timeIntervalSince(at) < reattachMemory
    }

    @MainActor static func noteReattach(_ sessionID: UUID, now: Date = Date()) {
        reattachTriedAt[sessionID] = now
    }
}
