import Foundation

/// Darf das verzögerte Enter nach einem Einfüge-Block noch raus? (WM8-75)
///
/// `sendPrompt` mit Senden schickt erst den Text und 80 ms später (nach einem
/// Leeren 230 ms) das Enter. Geht in dieser Spanne eine Freigabe auf, wählt das
/// Enter deren Vorauswahl „1. Yes“ — nachgestellt am 14.11.2026 an Claude Code
/// 2.1.325 (Bash-Freigabe, `rm` lief). Deshalb direkt vor dem Enter neu prüfen.
///
/// War beim Einfügen schon eine FRAGE offen, ist das Enter gewollt (`chats
/// send` beantwortet sie bewusst) und geht wie bisher. Eine Freigabe oder
/// Plan-Freigabe bestätigt das Enter nie (Entscheidung 14.11.2026): Der Text
/// wird dort ignoriert, das Enter wählte „Yes“, auch wenn „nein“ geschickt
/// wurde. Ist die Art nicht sicher erkennbar: kein Enter.
///
/// Ein Restfenster bleibt: Prüfen und Senden sind nicht atomar gegenüber
/// Claudes Neuzeichnen. Geht die Freigabe auf, nachdem wir den Bildschirm
/// gelesen haben, trifft das Enter sie trotzdem — das Fenster schrumpft von
/// 80 ms auf wenige Millisekunden, geschlossen ist es nicht.
enum DelayedEnterGuard {
    /// - Parameter textLooksLikeOption: Der eigene Text beginnt wie eine
    ///   Auswahlzeile („1. …“). Dann verwirft die Feld-Erkennung das Feld, und
    ///   die Zeile sähe wie ein Dialog aus — `dialogVisible` zählt dann nicht.
    static func allowsEnter(
        statusAtPaste: AgentSessionRuntimeStatus?,
        questionAtPaste: Bool = false,
        statusNow: AgentSessionRuntimeStatus?,
        screen: ControllerScreenSnapshot?,
        textLooksLikeOption: Bool = false
    ) -> Bool {
        // Codex meldet Freigaben nicht; steht unten seine Freigabe, wählte das
        // Enter „1. Yes, proceed“ (gemessen an Codex CLI 0.169.0, WM8-67).
        if screen?.codexApproval == true { return false }
        if statusAtPaste == .awaitingInput {
            // Nur eine sicher erkannte Frage, und der Bildschirm zeigt keine Freigabe.
            return questionAtPaste && !showsApproval(screen, textLooksLikeOption: textLooksLikeOption)
        }
        if statusNow == .awaitingInput { return false }
        // Statt des Eingabefelds steht ein Dialog: Auch wenn der Status noch
        // hinterherhinkt, kein Enter.
        if let screen, screen.promptField == nil {
            if screen.questionDialog { return false }
            if screen.dialogVisible, !textLooksLikeOption { return false }
        }
        return true
    }

    /// Wartet der Chat auf eine Freigabe statt auf eine Frage? Grundlage für
    /// die Ablehnung von `chats send` vor dem Einfügen. Unsicher heißt ja.
    static func approvalPending(
        status: AgentSessionRuntimeStatus?,
        lifecycle: AgentSessionLifecycleState?,
        screen: ControllerScreenSnapshot?
    ) -> Bool {
        if status == .awaitingInput {
            guard case .awaitingInput(.question)? = lifecycle else { return true }
        }
        return showsApproval(screen, textLooksLikeOption: false)
    }

    /// Bei Claude steht unten statt des Eingabefelds ein Dialog, der keine
    /// erkannte Frage ist; bei Codex steht seine Freigabe unten.
    static func showsApproval(_ screen: ControllerScreenSnapshot?, textLooksLikeOption: Bool) -> Bool {
        if screen?.codexApproval == true { return true }
        guard let screen, screen.promptField == nil, !screen.questionDialog else { return false }
        return screen.dialogVisible && !textLooksLikeOption
    }

    /// Erste nicht leere Zeile des Texts sieht aus wie „1. …“.
    static func looksLikeOption(_ text: String) -> Bool {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return ControllerScreenReading.isOptionLine(first)
    }
}
