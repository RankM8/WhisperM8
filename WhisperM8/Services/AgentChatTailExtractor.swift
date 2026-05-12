import Foundation

/// Liest einen kurzen "Conversation Tail" aus dem JSONL-Transcript einer
/// aktiven Agent-Session — typischerweise die letzte User-Message + die
/// letzte Assistant-Antwort, gekuerzt auf ein Token-vertraegliches Budget.
///
/// Wird vom `RecordingCoordinator` beim Recording-Start aufgerufen, um den
/// laufenden Chat-Kontext mit ins Post-Processing-Prompt-Paket zu schreiben.
/// Niemals den ganzen Transcript einbinden — das wuerde bei langen Sessions
/// das Modell-Kontextfenster sprengen und ist meist gar nicht hilfreich.
enum AgentChatTailExtractor {
    /// Default-Limit fuer die zusammengebaute Tail-Zeichenkette. ~600 Chars
    /// ≈ 150 Tokens; reicht fuer "worum geht's gerade".
    static let defaultMaxCharacters = 600

    /// Liefert den Tail fuer eine `AgentChatContextRef`. Wenn die Session
    /// keine `externalSessionID` hat (z. B. `.agentView`-TUI oder
    /// Background-Chat ohne Roster-Bindung), gibt es `nil` zurueck.
    /// Liest das JSONL nicht-blockierend genug, dass der Caller das gerne
    /// im Recording-Start-Pfad awaiten kann.
    static func extract(
        for ref: AgentChatContextRef,
        maxCharacters: Int = defaultMaxCharacters
    ) -> String? {
        guard let externalID = ref.externalSessionID, !externalID.isEmpty else {
            return nil
        }
        let transcript: AgentChatTranscript?
        switch ref.provider {
        case .claude:
            transcript = ClaudeTranscriptReader.read(cwd: ref.projectPath, sessionID: externalID)
        case .codex:
            transcript = CodexTranscriptReader.read(sessionID: externalID)
        }
        guard let transcript, !transcript.messages.isEmpty else { return nil }
        return summarize(messages: transcript.messages, maxCharacters: maxCharacters)
    }

    /// Pure-Funktion fuer Tests: nimmt eine Message-Liste, sucht die letzten
    /// User+Assistant-Messages, baut einen kompakten String.
    static func summarize(
        messages: [AgentChatMessage],
        maxCharacters: Int = defaultMaxCharacters
    ) -> String? {
        let lastAssistant = messages.last(where: { $0.role == .assistant })
        let lastUser = messages.last(where: { $0.role == .user })
        var lines: [String] = []
        if let user = lastUser, let text = plainText(from: user) {
            lines.append("[user] \(text)")
        }
        if let assistant = lastAssistant, let text = plainText(from: assistant) {
            lines.append("[assistant] \(text)")
        }
        guard !lines.isEmpty else { return nil }
        let joined = lines.joined(separator: "\n\n")
        return truncate(joined, maxCharacters: maxCharacters)
    }

    /// Reduziert eine Message auf einen Plain-Text-Anteil. Wir ignorieren
    /// Tool-Aufrufe, Tool-Results, Thinking-Bloecke und Bilder — die wuerden
    /// die Prompt-Groesse aufblaehen ohne neue inhaltliche Information ueber
    /// "worum geht's gerade" zu liefern. Wenn eine Message ausschliesslich
    /// aus Tool-Use besteht, liefern wir `nil` und der Caller fallback'd.
    static func plainText(from message: AgentChatMessage) -> String? {
        var parts: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            case .toolUse, .toolResult, .imagePlaceholder, .thinking:
                continue
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// Schneidet einen langen String hart auf `maxCharacters` ab und haengt
    /// "…" an, damit das Modell erkennen kann, dass der Tail abgeschnitten
    /// wurde. Kein Wort-Boundary-Match — der Tail soll deterministisch
    /// reproduzierbar sein.
    static func truncate(_ raw: String, maxCharacters: Int) -> String {
        guard maxCharacters > 1, raw.count > maxCharacters else { return raw }
        let prefix = raw.prefix(maxCharacters - 1)
        return String(prefix) + "…"
    }
}
