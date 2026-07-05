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
///   function_call_output, reasoning, tool_search_call, ...)
/// - `event_msg` — High-Level-Events:
///   - `user_message` (das, was der Nutzer tatsaechlich getippt hat)
///   - `agent_message` (Codex' Antwort-Texte, phase commentary|final_answer)
///   - `token_count`, `task_*` (Status, fuer uns uninteressant)
///
/// Quellen-Aufteilung (verifiziert an echten Rollouts, codex 0.142.5):
/// - **Texte** aus `event_msg` (user_message + agent_message) — die
///   `response_item/message`-Zeilen sind 1:1-DUPLIKATE derselben Texte
///   (role user/assistant/developer, inkl. AGENTS.md-Injektionen) und
///   werden deshalb bewusst uebersprungen.
/// - **Tool-Aktivitaet** NUR aus `response_item`: `function_call` →
///   `.toolUse`, `function_call_output` → `.toolResult` (isError aus dem
///   "Process exited with code N"-Praefix), `tool_search_call` →
///   `.toolUse`.
/// - `reasoning` ist verschluesselt (`encrypted_content`); lesbar ist
///   hoechstens `summary` — nur dann wird ein `.thinking`-Block erzeugt.
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
        var idGenerator = TranscriptStableIDGenerator()

        let stream = LineStream(fileURL: fileURL)
        for line in stream {
            lineNumber += 1
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                skipped += 1
                continue
            }
            if let message = parseEntry(obj) {
                messages.append(idGenerator.assign(message))
            }
        }

        Logger.terminalSnapshot.debug("codex_transcript_read url=\(fileURL.lastPathComponent, privacy: .public) lines=\(lineNumber) messages=\(messages.count) skipped=\(skipped)")

        return AgentChatTranscript(messages: messages, isLiveSourcePossible: true)
    }

    /// P3 S6: Bounded Tail-Read — siehe ClaudeTranscriptReader.readTail.
    static func readTail(sessionID: String, tailBytes: Int = TranscriptTailReader.defaultTailBytes) -> AgentChatTranscript? {
        guard let url = transcriptURL(forSessionID: sessionID) else { return nil }
        return readTail(fileURL: url, tailBytes: tailBytes)
    }

    static func readTail(fileURL: URL, tailBytes: Int = TranscriptTailReader.defaultTailBytes) -> AgentChatTranscript {
        var idGenerator = TranscriptStableIDGenerator()
        let (lines, truncatedHead) = TranscriptTailReader.tailLinesWithTruncation(fileURL: fileURL, tailBytes: tailBytes)
        let messages = lines
            .compactMap { line -> AgentChatMessage? in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return parseEntry(obj)
            }
            .map { idGenerator.assign($0) }
        return AgentChatTranscript(messages: messages, isLiveSourcePossible: true, hasTruncatedHead: truncatedHead)
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
            guard let payload = obj["payload"] as? [String: Any] else { return nil }
            return parseResponseItem(payload, timestamp: timestamp)
        default:
            return nil
        }
    }

    /// Tool-Aktivitaet aus dem granularen `response_item`-Strom.
    /// `message`-Items werden bewusst NICHT gemappt (Duplikate der
    /// event_msg-Texte — siehe Header-Kommentar).
    private static func parseResponseItem(_ payload: [String: Any], timestamp: Date?) -> AgentChatMessage? {
        switch payload["type"] as? String ?? "" {
        case "function_call":
            let name = payload["name"] as? String ?? "tool"
            let input = payload["arguments"] as? String ?? ""
            return AgentChatMessage(
                id: UUID(),
                role: .assistant,
                timestamp: timestamp,
                blocks: [.toolUse(name: name, input: input)]
            )
        case "function_call_output":
            let output = extractFunctionOutput(payload["output"])
            guard !output.isEmpty else { return nil }
            return AgentChatMessage(
                id: UUID(),
                role: .user, // Claude-Konvention: Results kommen als User-Message zurueck
                timestamp: timestamp,
                blocks: [.toolResult(content: output, isError: outputIndicatesFailure(output))]
            )
        case "tool_search_call":
            let input: String
            if let arguments = payload["arguments"],
               let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                input = str
            } else {
                input = ""
            }
            return AgentChatMessage(
                id: UUID(),
                role: .assistant,
                timestamp: timestamp,
                blocks: [.toolUse(name: "tool_search", input: input)]
            )
        case "reasoning":
            // encrypted_content ist per Design unlesbar — nur eine ggf.
            // vorhandene Klartext-Summary wird angezeigt.
            let summary = extractReasoningSummary(payload["summary"])
            guard !summary.isEmpty else { return nil }
            return AgentChatMessage(
                id: UUID(),
                role: .assistant,
                timestamp: timestamp,
                blocks: [.thinking(summary)]
            )
        default:
            return nil
        }
    }

    /// Outputs sind in der Praxis Strings; defensiv auch Dicts tolerieren.
    private static func extractFunctionOutput(_ raw: Any?) -> String {
        if let str = raw as? String { return str }
        if let dict = raw as? [String: Any] {
            if let content = dict["content"] as? String { return content }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        return ""
    }

    /// Codex praefixt Kommando-Outputs mit "Process exited with code N".
    private static func outputIndicatesFailure(_ output: String) -> Bool {
        guard let range = output.range(of: #"Process exited with code (\d+)"#, options: .regularExpression) else {
            return false
        }
        let digits = output[range].components(separatedBy: " ").last ?? "0"
        return Int(digits).map { $0 != 0 } ?? false
    }

    /// Summary-Eintraege sind Strings oder {type, text}-Dicts — tolerant lesen.
    private static func extractReasoningSummary(_ raw: Any?) -> String {
        guard let array = raw as? [Any], !array.isEmpty else { return "" }
        return array.compactMap { entry -> String? in
            if let str = entry as? String { return str }
            if let dict = entry as? [String: Any] { return dict["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
