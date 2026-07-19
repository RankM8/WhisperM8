import Foundation

// MARK: - Transcript-Tail → lesbare Turns

/// Formatiert ein `AgentChatTranscript` als kompakte, agentenfreundliche
/// Turn-Ansicht. Pur und mit Fixtures testbar.
enum ChatsTailFormatter {
    static let defaultTurns = 3
    static let defaultMaxChars = 6000
    static let toolLineMaxChars = 100

    struct RenderedTail: Equatable {
        var text: String
        var wasTruncated: Bool
        var turnCount: Int
    }

    /// - Parameter turns: letzte N User→Assistant-Runden.
    /// - Parameter maxChars: harter Deckel; gekürzt wird am ANFANG (die
    ///   jüngsten Inhalte sind die relevanten).
    static func render(
        transcript: AgentChatTranscript,
        turns: Int = defaultTurns,
        maxChars: Int = defaultMaxChars
    ) -> RenderedTail {
        let groups = turnGroups(messages: transcript.messages)
        let selected = groups.suffix(max(1, turns))
        var lines: [String] = []
        if transcript.hasTruncatedHead || groups.count > selected.count {
            lines.append("…")
        }
        for group in selected {
            for message in group {
                guard let rendered = render(message: message) else { continue }
                lines.append(rendered)
                lines.append("")
            }
        }
        var text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var truncated = false
        if text.count > maxChars {
            truncated = true
            let tail = String(text.suffix(maxChars))
            // Am nächsten Zeilenanfang aufsetzen, damit keine halbe Zeile führt.
            if let newlineIndex = tail.firstIndex(of: "\n") {
                text = "… [gekürzt]\n" + tail[tail.index(after: newlineIndex)...]
            } else {
                text = "… [gekürzt]\n" + tail
            }
        }
        return RenderedTail(text: text, wasTruncated: truncated, turnCount: selected.count)
    }

    /// Nur die letzte Assistant-Message, ungekürzt — für `tail --raw`.
    static func lastAssistantText(transcript: AgentChatTranscript) -> String? {
        for message in transcript.messages.reversed() where message.role == .assistant {
            let text = message.blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// Erster nicht-leerer Assistant-Text der letzten Assistant-Message,
    /// auf eine Zeile reduziert und gedeckelt — der Tier-1-Einzeiler in
    /// `list`/`overview`.
    static func lastAssistantLine(transcript: AgentChatTranscript, maxChars: Int = 80) -> String? {
        guard let full = lastAssistantText(transcript: transcript) else { return nil }
        let oneLine = full
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        if oneLine.count <= maxChars { return oneLine }
        return String(oneLine.prefix(maxChars - 1)) + "…"
    }

    // MARK: - Intern

    /// Gruppiert Messages in Turns: jede ECHTE User-Eingabe (Text-Block, kein
    /// reines Tool-Result) beginnt einen neuen Turn.
    private static func turnGroups(messages: [AgentChatMessage]) -> [[AgentChatMessage]] {
        var groups: [[AgentChatMessage]] = []
        var current: [AgentChatMessage] = []
        for message in messages {
            if isRealUserMessage(message), !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func isRealUserMessage(_ message: AgentChatMessage) -> Bool {
        guard message.role == .user else { return false }
        return message.blocks.contains { block in
            if case .text(let text) = block {
                return !text.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return false
        }
    }

    private static func render(message: AgentChatMessage) -> String? {
        let roleLabel: String
        switch message.role {
        case .user: roleLabel = "user"
        case .assistant: roleLabel = "assistant"
        case .system: roleLabel = "system"
        }
        var body: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { body.append(trimmed) }
            case .toolUse(let name, let input):
                body.append("⏺ \(name): \(oneLine(input, maxChars: toolLineMaxChars))")
            case .toolResult(let content, let isError):
                if isError {
                    body.append("⚠︎ tool error: \(oneLine(content, maxChars: toolLineMaxChars))")
                }
            case .imagePlaceholder(let mediaType, _):
                body.append("[Bild · \(mediaType)]")
            case .thinking:
                continue
            }
        }
        guard !body.isEmpty else { return nil }
        let time = message.timestamp.map { " · \(Self.timeFormatter.string(from: $0))" } ?? ""
        return "[\(roleLabel)\(time)]\n" + body.joined(separator: "\n")
    }

    private static func oneLine(_ raw: String, maxChars: Int) -> String {
        let flattened = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if flattened.count <= maxChars { return flattened }
        return String(flattened.prefix(maxChars - 1)) + "…"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
