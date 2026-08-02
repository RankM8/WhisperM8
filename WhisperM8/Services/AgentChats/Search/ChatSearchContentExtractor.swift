import Foundation

/// Zerlegt eine JSONL-Zeile beider Provider in klassifizierte Textspannen.
///
/// Bewusst getrennt von `ClaudeTranscriptReader`/`CodexTranscriptReader`: deren
/// Modell ist auf die ANZEIGE ausgelegt (ein Block pro Content-Chunk, Bilder
/// als Platzhalter). Die Suche braucht eine feinere Unterscheidung — vor allem
/// muss ein `<system-reminder>` INNERHALB einer echten Nutzernachricht als
/// eigene Spanne herausfallen, sonst gilt jede injizierte Harness-Notiz als
/// „das hat der Nutzer geschrieben".
///
/// Pur: rein rein, Spannen raus. Kein Dateizugriff, keine Uhr.
enum ChatSearchContentExtractor {
    /// Obergrenze pro Nicht-Konversations-Spanne. Tool-Outputs können einzeln
    /// zweistellige MB groß sein; für die Suche ist der Kopf aussagekräftig
    /// genug und der Index bleibt bezahlbar. Gesprächstext wird NIE gekürzt.
    static let nonConversationalTextCap = 64 * 1024

    static func spans(
        line: String,
        provider: AgentProvider,
        byteOffset: Int,
        lineNumber: Int
    ) -> [ChatSearchSpan] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        switch provider {
        case .claude:
            return claudeSpans(object, byteOffset: byteOffset, lineNumber: lineNumber)
        case .codex:
            return codexSpans(object, byteOffset: byteOffset, lineNumber: lineNumber)
        }
    }

    // MARK: - Claude

    private static func claudeSpans(
        _ object: [String: Any],
        byteOffset: Int,
        lineNumber: Int
    ) -> [ChatSearchSpan] {
        let timestamp = parseDate(object["timestamp"])
        var builder = SpanBuilder(byteOffset: byteOffset, lineNumber: lineNumber, timestamp: timestamp)

        switch object["type"] as? String {
        case "user":
            guard let message = object["message"] as? [String: Any] else { return [] }
            if let text = message["content"] as? String {
                builder.appendUserText(text)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        builder.appendUserText(block["text"] as? String ?? "")
                    case "tool_result":
                        builder.append(
                            toolResultText(block["content"]),
                            role: .user,
                            kind: .toolResult
                        )
                    default:
                        continue
                    }
                }
            }
        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return [] }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    builder.append(block["text"] as? String ?? "", role: .assistant, kind: .assistantNarrative)
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    builder.append("\(name) \(compactJSON(block["input"]))", role: .assistant, kind: .toolCall)
                case "thinking":
                    builder.append(block["thinking"] as? String ?? "", role: .assistant, kind: .thinking)
                default:
                    continue
                }
            }
        case "summary":
            builder.append(object["summary"] as? String ?? "", role: .assistant, kind: .summary)
        case "system":
            builder.append(object["content"] as? String ?? "", role: .assistant, kind: .system)
        default:
            return []
        }
        return builder.spans
    }

    // MARK: - Codex

    private static func codexSpans(
        _ object: [String: Any],
        byteOffset: Int,
        lineNumber: Int
    ) -> [ChatSearchSpan] {
        let timestamp = parseDate(object["timestamp"])
        var builder = SpanBuilder(byteOffset: byteOffset, lineNumber: lineNumber, timestamp: timestamp)

        switch object["type"] as? String {
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any] else { return [] }
            switch payload["type"] as? String {
            case "user_message":
                builder.appendUserText(payload["message"] as? String ?? "")
            case "agent_message":
                builder.append(payload["message"] as? String ?? "", role: .assistant, kind: .assistantNarrative)
            default:
                return []
            }
        case "response_item":
            guard let payload = object["payload"] as? [String: Any] else { return [] }
            switch payload["type"] as? String {
            case "function_call":
                let name = payload["name"] as? String ?? "tool"
                let arguments = payload["arguments"] as? String ?? ""
                builder.append("\(name) \(arguments)", role: .assistant, kind: .toolCall)
            case "function_call_output":
                builder.append(functionOutputText(payload["output"]), role: .user, kind: .toolResult)
            case "tool_search_call":
                builder.append("tool_search \(compactJSON(payload["arguments"]))", role: .assistant, kind: .toolCall)
            case "reasoning":
                builder.append(reasoningSummary(payload["summary"]), role: .assistant, kind: .thinking)
            default:
                // `message`-Items sind 1:1-Duplikate der event_msg-Texte (inkl.
                // AGENTS.md-Injektionen) — sie würden jeden Codex-Chat doppelt
                // in die Trefferliste bringen.
                return []
            }
        default:
            return []
        }
        return builder.spans
    }

    // MARK: - Bausteine

    /// Sammelt Spannen und vergibt fortlaufende Blockindizes.
    private struct SpanBuilder {
        let byteOffset: Int
        let lineNumber: Int
        let timestamp: Date?
        var spans: [ChatSearchSpan] = []

        mutating func append(_ text: String, role: ChatSearchRole, kind: ChatSearchContentKind) {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if !ChatSearchContentKind.conversational.contains(kind),
               value.utf8.count > nonConversationalTextCap {
                value = String(value.prefix(nonConversationalTextCap))
            }
            spans.append(ChatSearchSpan(
                byteOffset: byteOffset,
                lineNumber: lineNumber,
                blockIndex: spans.count,
                timestamp: timestamp,
                role: role,
                kind: kind,
                text: value
            ))
        }

        /// Nutzertext, aus dem injizierte Harness-Blöcke als eigene Spannen
        /// herausfallen. Ohne diesen Split zählt jeder `<system-reminder>` als
        /// Nutzereingabe — und weil dieselben Reminder in Tausenden Zeilen
        /// stehen, dominierten sie jede breite Suche.
        mutating func appendUserText(_ text: String) {
            for segment in HarnessTextSplitter.split(text) {
                append(segment.text, role: .user, kind: segment.kind)
            }
        }
    }

    private static func toolResultText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { block in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func functionOutputText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        if let dict = raw as? [String: Any] {
            if let content = dict["content"] as? String { return content }
            return compactJSON(dict)
        }
        return ""
    }

    private static func reasoningSummary(_ raw: Any?) -> String {
        guard let entries = raw as? [Any] else { return "" }
        return entries.compactMap { entry -> String? in
            if let text = entry as? String { return text }
            if let dict = entry as? [String: Any] { return dict["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    private static func compactJSON(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let text = raw as? String { return text }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        if let text = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        if let interval = raw as? TimeInterval { return Date(timeIntervalSince1970: interval) }
        return nil
    }
}

/// Trennt echten Nutzertext von injizierten Harness-Blöcken.
enum HarnessTextSplitter {
    struct Segment: Equatable {
        var text: String
        var kind: ChatSearchContentKind
    }

    /// Blöcke, die das Harness in Nutzernachrichten einbettet. Jeweils
    /// Start-/End-Tag; alles dazwischen ist `system`.
    private static let wrappedTags = ["system-reminder", "command-name", "command-message", "command-args", "local-command-stdout"]

    /// Präfixe, die eine KOMPLETTE Zeile als Harness-Inhalt markieren.
    private static let fullLineMarkers = [
        "Caveat: The messages below were generated",
        "[Request interrupted by user",
        "This session is being continued from a previous conversation",
        "[via whisperm8 chats",
    ]

    static func split(_ text: String) -> [Segment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if fullLineMarkers.contains(where: { trimmed.hasPrefix($0) }) {
            return [Segment(text: trimmed, kind: .system)]
        }
        guard trimmed.contains("<") else {
            return [Segment(text: trimmed, kind: .humanUser)]
        }

        var segments: [Segment] = []
        var remainder = Substring(trimmed)

        while !remainder.isEmpty {
            guard let opening = nextTag(in: remainder) else { break }
            let head = remainder[remainder.startIndex..<opening.range.lowerBound]
            appendIfNotEmpty(String(head), kind: .humanUser, to: &segments)

            let afterOpen = opening.range.upperBound
            if let closeRange = remainder.range(of: "</\(opening.tag)>", range: afterOpen..<remainder.endIndex) {
                appendIfNotEmpty(String(remainder[afterOpen..<closeRange.lowerBound]), kind: .system, to: &segments)
                remainder = remainder[closeRange.upperBound...]
            } else {
                // Unabgeschlossener Block: Rest konservativ als Harness werten.
                appendIfNotEmpty(String(remainder[afterOpen...]), kind: .system, to: &segments)
                remainder = remainder[remainder.endIndex...]
            }
        }
        appendIfNotEmpty(String(remainder), kind: .humanUser, to: &segments)

        return segments.isEmpty ? [Segment(text: trimmed, kind: .humanUser)] : segments
    }

    private static func nextTag(in text: Substring) -> (tag: String, range: Range<Substring.Index>)? {
        var best: (tag: String, range: Range<Substring.Index>)?
        for tag in wrappedTags {
            guard let range = text.range(of: "<\(tag)>") else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (tag, range)
            }
        }
        return best
    }

    private static func appendIfNotEmpty(
        _ text: String,
        kind: ChatSearchContentKind,
        to segments: inout [Segment]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(Segment(text: trimmed, kind: kind))
    }
}
