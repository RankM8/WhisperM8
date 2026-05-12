import Foundation

/// Liest und parsed Codex-CLI JSONL-Transcripts in unsere generische
/// `AgentChatTranscript`-Repraesentation.
///
/// Codex legt jede Session unter
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl` ab.
/// Schema unterscheidet sich von Claude:
///
/// - `session_meta` (1× am Anfang)
/// - `turn_context`
/// - `response_item` — granulare Events (message, function_call,
///   function_call_output, reasoning, ...)
/// - `event_msg` — High-Level-Events:
///   - `user_message` (das, was der Nutzer tatsaechlich getippt hat)
///   - `agent_message` (Codex' finale Antwort)
///   - `exec_command_end`, `token_count`, `task_*` (Status, fuer uns
///     uninteressant)
///
/// Fuer die Chat-Ansicht nehmen wir die `event_msg`-Variante (user_message
/// + agent_message) — das ist Codex' eigene "high-level dialog"-Semantik
/// und matched 1:1 wie Claude's user/assistant.
enum CodexTranscriptReader {

    /// Loest den JSONL-Pfad fuer eine (cwd, sessionID)-Kombi auf. Codex
    /// ordnet die Files nach Datum, der Filename enthaelt aber die
    /// Session-ID — wir scannen kurz alle Files und finden den match.
    /// Resultat wird nicht gecached weil das nur on-demand passiert.
    static func transcriptURL(forSessionID sessionID: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let suffix = "-\(sessionID).jsonl"
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if url.lastPathComponent.hasSuffix(suffix) {
                return url
            }
        }
        return nil
    }

    /// Liest das Transcript fuer eine Session-ID. Liefert `nil` wenn die
    /// Datei nicht gefunden wurde.
    static func read(sessionID: String) -> AgentChatTranscript? {
        guard let url = transcriptURL(forSessionID: sessionID) else {
            return nil
        }
        return read(fileURL: url)
    }

    static func read(fileURL: URL) -> AgentChatTranscript {
        var messages: [AgentChatMessage] = []
        var lineNumber = 0
        var skipped = 0

        let stream = LineStream(fileURL: fileURL)
        for line in stream {
            lineNumber += 1
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                skipped += 1
                continue
            }
            if let message = parseEntry(obj) {
                messages.append(message)
            }
        }

        Logger.terminalSnapshot.debug("codex_transcript_read url=\(fileURL.lastPathComponent, privacy: .public) lines=\(lineNumber) messages=\(messages.count) skipped=\(skipped)")

        return AgentChatTranscript(messages: messages, isLiveSourcePossible: true)
    }

    /// Parst eine JSONL-Zeile zur `AgentChatMessage`, falls's ein anzeigbarer
    /// Eintrag ist.
    static func parseEntry(_ obj: [String: Any]) -> AgentChatMessage? {
        let outerType = obj["type"] as? String ?? ""
        let timestamp = parseDate(obj["timestamp"] as? String)

        switch outerType {
        case "event_msg":
            guard let payload = obj["payload"] as? [String: Any] else { return nil }
            let payloadType = payload["type"] as? String ?? ""
            switch payloadType {
            case "user_message":
                guard let message = payload["message"] as? String, !message.isEmpty else { return nil }
                return AgentChatMessage(
                    id: UUID(),
                    role: .user,
                    timestamp: timestamp,
                    blocks: [.text(message)]
                )
            case "agent_message":
                guard let message = payload["message"] as? String, !message.isEmpty else { return nil }
                return AgentChatMessage(
                    id: UUID(),
                    role: .assistant,
                    timestamp: timestamp,
                    blocks: [.text(message)]
                )
            default:
                return nil
            }
        case "response_item":
            // Optionaler Pfad: function_call als zusaetzliche Assistant-Block.
            // Aktuell skippen wir die Detail-Events; agent_message liefert die
            // Endsumme. Falls man spaeter feingranular zeigen will, hier
            // erweitern.
            return nil
        default:
            return nil
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
