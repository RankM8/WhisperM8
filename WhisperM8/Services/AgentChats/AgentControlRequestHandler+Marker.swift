import Foundation

/// Markerzeile vor Prompts, die `chats send` und die Warteschlange zustellen
/// (Kennzeichnung + Ein-Hop-Regel für Claude- und Codex-Chats).
extension AgentControlRequestHandler {
    /// Präfix der Markerzeile — die einzige Quelle dieser Zeile ist die App.
    static let markerPrefix = "[via whisperm8 chats"

    /// Marker-Zeile für gesendete Prompts (Kennzeichnung + Ein-Hop-Regel).
    static func markedPrompt(_ prompt: String, actor: String) -> String {
        let time = markerTimeFormatter.string(from: Date())
        return "\(markerPrefix) · von \(actor) · \(time)]\n\(prompt)"
    }

    /// Was tatsächlich ins Terminal geht. In eine Shell nie die Markerzeile:
    /// Ihr Zeilenumbruch schickte `[via …` als Befehl ab (E2E-Befund
    /// 12.11.2026), und eine Shell hat keinen Agenten, für den die
    /// Ein-Hop-Regel gälte. Die Herkunft steht ohnehin im Audit-Log.
    static func deliveredPrompt(_ prompt: String, actor: String, toShell: Bool) -> String {
        toShell ? prompt : markedPrompt(prompt, actor: actor)
    }

    private static let markerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
