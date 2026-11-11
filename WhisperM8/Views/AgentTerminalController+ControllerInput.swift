import Foundation

// Eingaben des Controllers ins Eingabefeld, die über einzelne Tasten
// (`sendKey`) hinausgehen. Ausgelagert, damit AgentTerminalView.swift unter
// der Größengrenze bleibt.

extension AgentTerminalController {
    /// Controller hat etwas ins Eingabefeld geschrieben oder daraus gelöscht
    /// (Rücktaste, Leerzeichen, Wort löschen, Text oder Diktat ohne Senden).
    /// Gelöscht, sobald gesendet wird. Kreuz darf bei arbeitendem Chat nur
    /// nach einer solchen Eingabe Enter schicken (`confirmAllowed`).
    func noteControllerDraftInput(submitted: Bool, now: Date = Date()) {
        lastControllerDraftInputAt = submitted ? nil : now
    }

    /// R3 halten: ganze Eingabe leeren (`TerminalControlKey.clearInputBursts`),
    /// in Stößen alle 15 ms über den Main-Run-Loop, ohne zu blockieren. Nicht
    /// in einer Rückfrage. Der Entwurfs-Tracker gilt danach als leer.
    /// - Returns: `false`, wenn kein Prozess läuft oder eine Rückfrage offen ist.
    @discardableResult
    func clearInputFromController() -> Bool {
        guard isRunning else { return false }
        let status = AgentSessionStatusCoordinator.shared.statusStore.status(for: sessionID)
        guard TerminalControlKey.controllerAllows(.killLineStart, status: status) else { return false }
        noteComposerCleared()
        lastControllerDraftInputAt = nil
        for (index, burst) in TerminalControlKey.clearInputBursts.enumerated() {
            let bytes = burst.flatMap { $0.bytes(applicationCursor: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015 * Double(index)) { [weak self] in
                guard let self, self.isRunning else { return }
                self.terminal.send(bytes)
            }
        }
        return true
    }
}
