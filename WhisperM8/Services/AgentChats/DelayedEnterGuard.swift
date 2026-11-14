import Foundation

/// Darf das verzögerte Enter nach einem Einfüge-Block noch raus? (WM8-75)
///
/// `sendPrompt` mit Senden schickt erst den Text und 80 ms später (nach einem
/// Leeren 230 ms) das Enter. Geht in dieser Spanne eine Freigabe auf, wählt das
/// Enter deren Vorauswahl „1. Yes“ — nachgestellt am 14.11.2026 an Claude Code
/// 2.1.325 (Bash-Freigabe, `rm` lief). Deshalb direkt vor dem Enter neu prüfen.
///
/// War die Rückfrage schon beim Einfügen offen, ist das Enter gewollt
/// (`chats send` beantwortet eine Frage bewusst) und geht wie bisher.
enum DelayedEnterGuard {
    static func allowsEnter(
        statusAtPaste: AgentSessionRuntimeStatus?,
        statusNow: AgentSessionRuntimeStatus?,
        screen: ControllerScreenSnapshot?
    ) -> Bool {
        if statusAtPaste == .awaitingInput { return true }
        if statusNow == .awaitingInput { return false }
        // Statt des Eingabefelds steht ein Dialog: Auch wenn der Status noch
        // hinterherhinkt (Codex meldet Freigaben gar nicht), kein Enter.
        if let screen, screen.promptField == nil, screen.dialogVisible || screen.questionDialog { return false }
        return true
    }
}
