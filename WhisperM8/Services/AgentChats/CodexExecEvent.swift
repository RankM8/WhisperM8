import Foundation

/// Typisierte Sicht auf die JSONL-Events von `codex exec --json`.
/// Referenz-Fixture: echter Lauf mit codex-cli 0.142.5 (siehe
/// `CodexExecFixtures` in den Tests). Das Format ist OpenAI-Implementation-
/// Detail — unbekannte Event-Typen landen in `.unknown` statt zu crashen,
/// damit ein codex-Update den Supervisor nie hart bricht.
enum CodexExecEvent: Equatable {
    /// `{"type":"thread.started","thread_id":"…"}` — die Thread-ID ist der
    /// Schlüssel für `codex exec resume` und das Rollout-JSONL in
    /// `~/.codex/sessions/`.
    case threadStarted(threadID: String)
    case turnStarted
    case itemStarted(CodexExecItem)
    case itemUpdated(CodexExecItem)
    case itemCompleted(CodexExecItem)
    case turnCompleted(usage: CodexTokenUsage?)
    case turnFailed(message: String?)
    case error(message: String?)
    /// Event-Typ, den wir (noch) nicht kennen — bewusst mit Typ-Info
    /// erhalten, damit Logs/Debugging zeigen, was das codex-Update liefert.
    case unknown(type: String)
}

/// Ein `item` aus `item.started` / `item.updated` / `item.completed`.
/// Items sind heterogen (`agent_message`, `command_execution`, `file_change`,
/// `error`, …) — wir modellieren die Vereinigungsmenge der Felder flach und
/// optional statt pro Typ zu verzweigen.
struct CodexExecItem: Equatable {
    var id: String?
    var type: String
    /// `agent_message` / `error`: der Text bzw. die Meldung.
    var text: String?
    /// `command_execution`: das ausgeführte Kommando.
    var command: String?
    /// `command_execution`: gesammelte Ausgabe (kann groß sein).
    var aggregatedOutput: String?
    var exitCode: Int?
    /// `in_progress` / `completed` / `failed`.
    var status: String?
}

/// Token-Verbrauch aus `turn.completed.usage`.
struct CodexTokenUsage: Equatable {
    var inputTokens: Int?
    var cachedInputTokens: Int?
    var outputTokens: Int?
    var reasoningOutputTokens: Int?
}
