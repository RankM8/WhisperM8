import Foundation

/// Verdichtet eine Codex-CLI-Fehlerausgabe auf eine knappe, nutzerlesbare
/// Meldung — aus `CodexPostProcessor` herausgezogen (Phase-3 Test-Seam),
/// damit die Priorisierung (Update-Hinweis vor Login-Hinweis vor letzter
/// nicht-leerer Zeile vor Fallback) ohne Subprozess testbar ist. Verhalten 1:1.
enum CodexErrorSummary {
    static func concise(from output: String) -> String {
        if output.contains("requires a newer version of Codex") {
            return "Codex CLI needs an update before post-processing can run."
        }
        if output.lowercased().contains("not logged in") {
            return "Codex is not signed in with ChatGPT."
        }
        if let lastLine = output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return lastLine
        }
        return "Codex post-processing failed."
    }
}
