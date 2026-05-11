import Foundation

/// Liest und parsed Claude-Code-JSONL-Transcripts in unsere generische
/// `AgentChatTranscript`-Repraesentation.
///
/// Claude schreibt pro Session eine append-only JSONL-Datei nach
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Jede Zeile ist ein
/// JSON-Objekt mit `type` + payload. Die fuer uns relevanten Typen:
///
/// - `user`     — User-Prompt (Text / Image / Tool-Result als content-Array)
/// - `assistant` — Claude-Response (Content-Array mit text / tool_use / thinking)
///
/// Alles andere (`queue-operation`, `ai-title`, `last-prompt`, `system`,
/// `attachment`, `permission-mode`, `file-history-snapshot`) wird beim
/// Parsen uebersprungen — die UI braucht es nicht.
///
/// Robustheit:
/// - Kaputte Zeilen werden geloggt + ignoriert, der Parser bricht nicht ab.
/// - Bei sehr grossen Files (>50 MB) ist Streaming pflicht — wir lesen
///   zeilenweise, nicht den ganzen File in einen String.
/// - Base64-Image-Daten werden NICHT in den Heap geladen, nur die Byte-Laenge
///   gespeichert.
enum ClaudeTranscriptReader {

    /// Liefert den erwarteten JSONL-Pfad fuer eine (cwd, sessionID)-Kombi.
    /// Encoding-Regel: jeder Slash im CWD wird zu `-`. Beispiel:
    /// `/Users/foo/repos/whisperm8` → `-Users-foo-repos-whisperm8`.
    static func transcriptURL(forCwd cwd: String, sessionID: String) -> URL {
        let canonical = AgentSessionStore.canonicalProjectPath(cwd)
        let encoded = canonical.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    /// Liest das Transcript fuer eine (cwd, sessionID)-Kombi. Liefert `nil`
    /// wenn die Datei nicht existiert; wirft NICHT bei kaputten Zeilen — die
    /// werden uebersprungen und geloggt.
    static func read(cwd: String, sessionID: String) -> AgentChatTranscript? {
        let url = transcriptURL(forCwd: cwd, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return read(fileURL: url)
    }

    /// Eigene Reader-Methode fuer Tests + direkte URL-Pfade.
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

        Logger.terminalSnapshot.debug("claude_transcript_read url=\(fileURL.lastPathComponent, privacy: .public) lines=\(lineNumber) messages=\(messages.count) skipped=\(skipped)")

        return AgentChatTranscript(messages: messages, isLiveSourcePossible: true)
    }

    /// Parsed eine einzelne JSONL-Zeile zu einer `AgentChatMessage`, falls
    /// sie ein anzeigbarer Typ ist (`user` oder `assistant`).
    static func parseEntry(_ obj: [String: Any]) -> AgentChatMessage? {
        let type = obj["type"] as? String ?? ""
        switch type {
        case "user":
            return parseUserEntry(obj)
        case "assistant":
            return parseAssistantEntry(obj)
        default:
            return nil
        }
    }

    private static func parseUserEntry(_ obj: [String: Any]) -> AgentChatMessage? {
        let timestamp = parseDate(obj["timestamp"] as? String)
        var blocks: [AgentChatBlock] = []

        guard let messageDict = obj["message"] as? [String: Any] else {
            return nil
        }

        if let content = messageDict["content"] as? String {
            // Einfacher Text-Prompt
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(.text(content))
            }
        } else if let contentArray = messageDict["content"] as? [[String: Any]] {
            // Strukturierter content: text / image / tool_result
            for chunk in contentArray {
                if let chunkType = chunk["type"] as? String {
                    switch chunkType {
                    case "text":
                        if let text = chunk["text"] as? String, !text.isEmpty {
                            blocks.append(.text(text))
                        }
                    case "image":
                        let mediaType = (chunk["source"] as? [String: Any])?["media_type"] as? String ?? "image/png"
                        let byteSize = ((chunk["source"] as? [String: Any])?["data"] as? String)?.count ?? 0
                        blocks.append(.imagePlaceholder(mediaType: mediaType, byteSize: byteSize))
                    case "tool_result":
                        let isError = chunk["is_error"] as? Bool ?? false
                        let content = extractToolResultText(chunk["content"])
                        if !content.isEmpty {
                            blocks.append(.toolResult(content: content, isError: isError))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !blocks.isEmpty else { return nil }
        return AgentChatMessage(
            id: UUID(),
            role: .user,
            timestamp: timestamp,
            blocks: blocks
        )
    }

    private static func parseAssistantEntry(_ obj: [String: Any]) -> AgentChatMessage? {
        let timestamp = parseDate(obj["timestamp"] as? String)
        var blocks: [AgentChatBlock] = []

        guard let messageDict = obj["message"] as? [String: Any],
              let contentArray = messageDict["content"] as? [[String: Any]] else {
            return nil
        }

        for chunk in contentArray {
            guard let chunkType = chunk["type"] as? String else { continue }
            switch chunkType {
            case "text":
                if let text = chunk["text"] as? String, !text.isEmpty {
                    blocks.append(.text(text))
                }
            case "tool_use":
                let name = chunk["name"] as? String ?? "tool"
                let input = formatToolInput(chunk["input"])
                blocks.append(.toolUse(name: name, input: input))
            case "thinking":
                if let text = chunk["thinking"] as? String, !text.isEmpty {
                    blocks.append(.thinking(text))
                }
            default:
                break
            }
        }

        guard !blocks.isEmpty else { return nil }
        return AgentChatMessage(
            id: UUID(),
            role: .assistant,
            timestamp: timestamp,
            blocks: blocks
        )
    }

    /// Tool-Inputs sind beliebig strukturiert (Dictionary, Array, String).
    /// Wir formatieren als kompaktes JSON, damit die UI's Code-Block-Renderer
    /// es vernuenftig anzeigt.
    private static func formatToolInput(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let str = raw as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: raw)
    }

    /// Tool-Results sind entweder String oder Array von {type: "text", text: ...}.
    private static func extractToolResultText(_ raw: Any?) -> String {
        if let str = raw as? String { return str }
        if let array = raw as? [[String: Any]] {
            return array.compactMap { chunk in
                (chunk["type"] as? String == "text") ? (chunk["text"] as? String) : nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Streaming-Reader, der eine Datei zeilenweise liefert — ohne den ganzen
/// Inhalt auf einmal in den Heap zu laden. Wichtig fuer mehrstellige MB
/// JSONL-Files.
struct LineStream: Sequence, IteratorProtocol {
    private let handle: FileHandle?
    private var buffer = Data()
    private let chunkSize = 64 * 1024
    private var atEOF = false

    init(fileURL: URL) {
        self.handle = try? FileHandle(forReadingFrom: fileURL)
    }

    mutating func next() -> String? {
        guard let handle else { return nil }
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0a) { // '\n'
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            if atEOF {
                if !buffer.isEmpty {
                    let trailing = String(data: buffer, encoding: .utf8) ?? ""
                    buffer.removeAll()
                    return trailing.isEmpty ? nil : trailing
                }
                try? handle.close()
                return nil
            }
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty {
                atEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }
}
