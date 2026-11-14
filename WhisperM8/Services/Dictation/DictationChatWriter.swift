import Foundation

/// Schreibt ein fertiges Diktat direkt in das Terminal eines Agent-Chats.
/// Der Coordinator bekommt es injiziert, Tests reichen einen Spy ein.
@MainActor
protocol DictationChatWriting: AnyObject {
    func state(of sessionID: UUID) -> DictationChatState
    /// `false`, wenn nichts geschrieben wurde (kein laufendes Terminal).
    func write(_ text: String, to sessionID: UUID, submit: Bool) -> Bool
    /// In Claudes offene Frage, ohne Enter. `false`, wenn die Frage inzwischen
    /// nicht mehr als solche erkannt wird.
    func writeToQuestion(_ text: String, to sessionID: UUID) -> Bool
}

/// Echte Fassung über die Terminal-Registry. Fasst die Singletons erst beim
/// Aufruf an, nicht beim Erzeugen — ein Coordinator im Test bleibt so frei davon.
@MainActor
final class LiveDictationChatWriter: DictationChatWriting {
    func state(of sessionID: UUID) -> DictationChatState {
        guard let controller = AgentTerminalRegistry.shared.controller(for: sessionID),
              controller.isRunning else {
            return .notRunning
        }
        let statusCoordinator = AgentSessionStatusCoordinator.shared
        if statusCoordinator.statusStore.status(for: sessionID) == .awaitingInput {
            return controller.questionAcceptsText() ? .questionAcceptsText : .awaitingInput
        }
        // Dieselbe Bereitschaftsprüfung wie `chats send`: Eine TUI, die noch
        // hochfährt, verschluckt den Paste oder liefert ihn später doppelt.
        if case .notReady = ChatsSendReadinessGuard.decide(
            lifecycle: statusCoordinator.lifecycleState(for: sessionID)
        ) {
            return .starting
        }
        return .ready
    }

    func write(_ text: String, to sessionID: UUID, submit: Bool) -> Bool {
        guard let controller = AgentTerminalRegistry.shared.controller(for: sessionID),
              controller.isRunning else {
            return false
        }
        // Bewusst ohne `PromptDeliveryGate`: Der Nutzer diktiert selbst in
        // seinen sichtbaren Chat und darf an einen vorhandenen Entwurf
        // anhängen. Bracketed Paste, ein Block, Return nur mit `submit`.
        controller.sendPrompt(text, submit: submit)
        controller.noteControllerDraftInput(submitted: submit)
        return true
    }

    func writeToQuestion(_ text: String, to sessionID: UUID) -> Bool {
        AgentTerminalRegistry.shared.controller(for: sessionID)?.sendQuestionText(text) ?? false
    }
}
