import Foundation

// Text in Claudes offene Frage (AskUserQuestion), WM8-66: Diktat und Einfügen
// per Controller. Prüfung in `ClaudeQuestionTextGate`.

extension AgentTerminalController {
    /// Steht gerade Claudes Frage-Dialog mit freiem Textfeld offen? Liest den
    /// unteren Bildschirmrand, also nur im Ereignis-Pfad aufrufen (Diktat,
    /// Controller-Eingabe), nie in einem Body.
    func questionAcceptsText(screen: ControllerScreenSnapshot? = nil) -> Bool {
        let coordinator = AgentSessionStatusCoordinator.shared
        let status = coordinator.statusStore.status(for: sessionID)
        guard status == .awaitingInput else { return false }
        return ClaudeQuestionTextGate.acceptsText(
            status: status,
            activity: coordinator.activityStore.activity(for: sessionID),
            screen: screen ?? controllerScreenSnapshot())
    }

    /// Text als ein Einfüge-Block in die offene Frage, ohne Enter. Anders als
    /// `sendPrompt` kein Leeren vorher und kein Vermerk im Entwurfs-Tracker:
    /// Der Text steht im Dialog, nicht im Eingabefeld. Prüft die Frage direkt
    /// vor dem Schreiben noch einmal; `false`, wenn nichts geschrieben wurde.
    @discardableResult
    func sendQuestionText(_ text: String) -> Bool {
        guard isRunning, questionAcceptsText() else { return false }
        terminal.send(txt: TerminalPasteSanitizer.bracketedPastePayload(text))
        return true
    }
}
