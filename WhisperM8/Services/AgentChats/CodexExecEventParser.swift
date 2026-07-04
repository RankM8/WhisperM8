import Foundation

/// Zeilenweiser Parser für den `codex exec --json`-Stream. Defensiv wie
/// `SupervisorJobReader`: JSONSerialization + optionale Casts, wirft nie.
/// `nil` heißt "Zeile ist kein Event" (leer, kein JSON, kein Objekt) — der
/// Aufrufer zählt solche Zeilen höchstens als skipped.
enum CodexExecEventParser {
    static func parse(line: String) -> CodexExecEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let type = raw["type"] as? String, !type.isEmpty else {
            return .unknown(type: "")
        }

        switch type {
        case "thread.started":
            // Ohne thread_id ist das Event für uns wertlos (kein Resume
            // möglich) — als unknown durchreichen statt eine leere ID zu
            // erfinden.
            guard let threadID = raw["thread_id"] as? String, !threadID.isEmpty else {
                return .unknown(type: type)
            }
            return .threadStarted(threadID: threadID)
        case "turn.started":
            return .turnStarted
        case "item.started":
            return .itemStarted(parseItem(raw["item"]))
        case "item.updated":
            return .itemUpdated(parseItem(raw["item"]))
        case "item.completed":
            return .itemCompleted(parseItem(raw["item"]))
        case "turn.completed":
            return .turnCompleted(usage: parseUsage(raw["usage"]))
        case "turn.failed":
            return .turnFailed(message: extractMessage(raw))
        case "error":
            return .error(message: extractMessage(raw))
        default:
            return .unknown(type: type)
        }
    }

    // MARK: - Teil-Parser

    private static func parseItem(_ value: Any?) -> CodexExecItem {
        guard let dict = value as? [String: Any] else {
            return CodexExecItem(type: "")
        }
        return CodexExecItem(
            id: nonEmptyString(dict["id"]),
            type: (dict["type"] as? String) ?? "",
            text: nonEmptyString(dict["text"]) ?? nonEmptyString(dict["message"]),
            command: nonEmptyString(dict["command"]),
            aggregatedOutput: dict["aggregated_output"] as? String,
            exitCode: intValue(dict["exit_code"]),
            status: nonEmptyString(dict["status"])
        )
    }

    private static func parseUsage(_ value: Any?) -> CodexTokenUsage? {
        guard let dict = value as? [String: Any] else { return nil }
        return CodexTokenUsage(
            inputTokens: intValue(dict["input_tokens"]),
            cachedInputTokens: intValue(dict["cached_input_tokens"]),
            outputTokens: intValue(dict["output_tokens"]),
            reasoningOutputTokens: intValue(dict["reasoning_output_tokens"])
        )
    }

    /// `turn.failed`/`error` liefern die Meldung mal flach (`message`),
    /// mal genestet (`error.message`) — beide Formen akzeptieren.
    private static func extractMessage(_ raw: [String: Any]) -> String? {
        if let message = nonEmptyString(raw["message"]) { return message }
        if let error = raw["error"] as? [String: Any] {
            return nonEmptyString(error["message"])
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// JSON-Zahlen können als Int oder Double ankommen (JSONSerialization
    /// entscheidet je nach Payload) — beides auf Int abbilden.
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        return nil
    }
}
