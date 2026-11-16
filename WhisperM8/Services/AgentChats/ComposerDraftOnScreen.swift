import Foundation

/// Steht vielleicht ein nicht abgeschickter Entwurf im Feld, nach Schätzung
/// und Bildschirm zusammen (WM8-123)? Für den Kontowechsel nach dem Turn und
/// `move-account`: Vorher fragten sie nur die Schätzung, und ein Diktat ohne
/// Senden, das Giuliano mit der Rücktaste wieder gelöscht hatte, hielt den
/// Wechsel bis zum nächsten Enter auf (die Rücktaste ändert die Schätzung
/// nicht). Dieselbe Zuordnung wie Board-Chat und Warteschlange: sichtbar leer
/// gibt frei (nur, wenn die Ansicht unten steht), sichtbarer Text hält (auch
/// hochgescrollt), sonst entscheidet die Schätzung.
enum ComposerDraftOnScreen {
    static func mayHaveUnsentInput(estimate: Bool, field: BoardChatFieldVisibility) -> Bool {
        switch field {
        case .empty: return false
        case .hasText: return true
        case .unknown: return estimate
        }
    }

    /// Nur bei diesen Status liest der Kontowechsel den Entwurf überhaupt
    /// (`AccountSwitchPlanner.waitReason`); sonst wartet er ohnehin aufs
    /// Turn-Ende, und der Bildschirm muss nicht gelesen werden.
    static func readsScreen(status: AgentSessionRuntimeStatus?) -> Bool {
        switch status {
        case .idle?, .stopped?, .errored?: return true
        default: return false
        }
    }
}

extension AgentTerminalController {
    /// Entwurf im Feld für den Kontowechsel: Schätzung plus Bildschirm
    /// (`composerFieldForSendCheck`, wie die Warteschlange). Kosten: bei einem
    /// ruhenden Claude-Chat eine Ablesung der untersten 16 Zeilen je Prüfung,
    /// also höchstens alle 2 s je vorgemerktem Chat; sonst nur die Schätzung.
    func mayHaveUnsentInputForAccountSwitch(status: AgentSessionRuntimeStatus?) -> Bool {
        let estimate = composerDraft.mayHaveUnsentInput
        guard ComposerDraftOnScreen.readsScreen(status: status) else { return estimate }
        let field = BoardChatFieldVisibility(
            reading: composerFieldForSendCheck(), profile: command.keyboardProfile,
            clearsBeforeSubmit: composerDraft.shouldClearBeforeSubmit)
        return ComposerDraftOnScreen.mayHaveUnsentInput(estimate: estimate, field: field)
    }
}
