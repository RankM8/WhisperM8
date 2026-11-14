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
        statusNow: AgentSessionRuntimeStatus?,
        screen: ControllerScreenSnapshot?,
        textLooksLikeOption: Bool = false
    ) -> Bool {
        if statusAtPaste == .awaitingInput { return true }
        if statusNow == .awaitingInput { return false }
        // Statt des Eingabefelds steht ein Dialog: Auch wenn der Status noch
        // hinterherhinkt, kein Enter.
        if let screen, screen.promptField == nil {
            if screen.questionDialog { return false }
            if screen.dialogVisible, !textLooksLikeOption { return false }
        }
        return true
    }

    /// Erste nicht leere Zeile des Texts sieht aus wie „1. …“.
    static func looksLikeOption(_ text: String) -> Bool {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return ControllerScreenReading.isOptionLine(first)
    }
}
