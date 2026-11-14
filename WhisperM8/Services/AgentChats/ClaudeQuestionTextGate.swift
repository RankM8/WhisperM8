import Foundation

/// Darf Text in eine offene Rückfrage? Nur in Claudes Frage-Dialog
/// (AskUserQuestion) mit freiem Textfeld, nie in eine Freigabe (WM8-66).
///
/// Doppelt erkannt, weil jede Quelle allein irren kann:
/// - **Werkzeug:** Der Chat wartet auf eine Frage (`awaitingKind == .question`),
///   und das jüngste Werkzeug im Transcript ist AskUserQuestion
///   (`detail == .question`). Die Warte-Art allein reicht nicht: Claudes
///   Registry meldet „input needed“ auch, wenn ein MCP-Werkzeug auf den Nutzer
///   wartet (gesehen am 14.11.2026 bei einem Chrome-Werkzeug ohne Textfeld).
/// - **Bildschirm:** Unten steht der Frage-Dialog mit seiner Hinweiszeile, keine
///   Freigabe (`ControllerScreenReading.isQuestionDialog`).
///
/// Gemessen an Claude Code 2.1.325: Eingefügter Text (Bracketed Paste) landet in
/// der Frage im Feld „Type something“, Ziffern darin wählen nichts aus; in einer
/// Freigabe wird derselbe Einfüge-Block ignoriert, eine einzeln getippte „1“
/// gibt sie dagegen frei. Deshalb geht hier nur ein Einfüge-Block hinein, nie
/// einzelne Tasten und nie ein Enter.
enum ClaudeQuestionTextGate {
    static func acceptsText(
        status: AgentSessionRuntimeStatus?,
        activity: AgentSessionActivity?,
        screen: ControllerScreenSnapshot?
    ) -> Bool {
        guard status == .awaitingInput,
              activity?.awaitingKind == .question,
              case .question? = activity?.detail,
              screen?.questionDialog == true else { return false }
        return true
    }
}
