import Darwin
import Foundation

/// Entscheidet, wann das Beenden eines laufenden Prozesses nachfragen muss
/// (LR-AU-005): Terminal schließen, Restart, Hintergrund-Agent entfernen,
/// Projekt löschen, Bulk-Archivieren. Reine Funktionen — der Dialog selbst
/// bleibt dünn (Muster `QuitConfirmation`).
enum ProcessEndConfirmation {
    /// Shell-Terminal: nur mit laufendem Kindprozess (Dev-Server, Build, …).
    /// Eine Shell am leeren Prompt verliert nichts.
    /// Ein Tab mit festem Befehl (`chats new --provider terminal --command`)
    /// fragt immer nach, solange er läuft: `/bin/sh -c` ersetzt sich oft
    /// durch den Befehl, der dann ohne Kindprozess oberster Prozess ist.
    static func terminalNeedsConfirmation(isRunning: Bool, shellHasChildProcess: Bool,
                                          runsFixedCommand: Bool = false) -> Bool {
        isRunning && (shellHasChildProcess || runsFixedCommand)
    }

    /// Restart bricht einen Turn ab und verwirft einen Entwurf im Composer:
    /// nachfragen, wenn der Chat arbeitet, auf eine Antwort wartet oder
    /// vermutlich ungesendeten Text trägt. Ruhender Chat: direkt.
    static func restartNeedsConfirmation(
        isRunning: Bool,
        runtime: AgentSessionRuntimeStatus?,
        mayHaveUnsentInput: Bool
    ) -> Bool {
        guard isRunning else { return false }
        return runtime == .working || runtime == .awaitingInput || mayHaveUnsentInput
    }

    /// „Vom Supervisor entfernen" löscht den Agent endgültig: nachfragen, wenn
    /// er arbeitet, wartet oder ein Terminal daran hängt.
    static func backgroundRemoveNeedsConfirmation(
        isRunning: Bool,
        runtime: AgentSessionRuntimeStatus?
    ) -> Bool {
        isRunning || runtime == .working || runtime == .awaitingInput
    }
}

enum ProcessChildren {
    /// Hat der Prozess mindestens einen Kindprozess? (`proc_listchildpids`)
    static func hasChildProcess(of pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var children = [Int32](repeating: 0, count: 8)
        let bytes = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<Int32>.size))
        return bytes > 0
    }
}
