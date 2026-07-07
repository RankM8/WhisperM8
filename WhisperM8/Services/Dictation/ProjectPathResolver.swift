import Foundation

/// Löst auf, in welchem Projekt ein Codex-Post-Processing-Lauf arbeitet
/// (`-C <pfad>` + Working Directory). Pure Funktion — beide Aufrufstellen
/// (CodexPostProcessor für den echten Lauf, TranscriptRunReportStore für die
/// commandPreview im Report) nutzen dieselbe Logik.
enum ProjectPathResolver {
    /// - Modi mit `projectAccess == .off` laufen ohne Projekt (temp dir).
    /// - Task behält bewusst ausschließlich den konfigurierten Default-Pfad:
    ///   er läuft nicht-ephemeral und `latestTaskAgentSession()` matcht die
    ///   entstandene Session über genau diesen Pfad — ein Agent-Chat-Pfad
    ///   würde das Matching still brechen.
    /// - Prompt-bauende Modi bevorzugen das Projekt des aktiven Agent-Chats
    ///   und fallen auf den Default-Pfad zurück; ohne beides degradiert der
    ///   Lauf sauber zum projektlosen Verhalten (nil).
    static func resolvedProjectPath(
        mode: OutputMode,
        agentChatProjectPath: String?,
        defaultProjectPath: String?
    ) -> String? {
        guard mode.projectAccess == .readOnly else { return nil }
        if mode.id == OutputMode.taskID {
            return normalized(defaultProjectPath)
        }
        return normalized(agentChatProjectPath) ?? normalized(defaultProjectPath)
    }

    private static func normalized(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
