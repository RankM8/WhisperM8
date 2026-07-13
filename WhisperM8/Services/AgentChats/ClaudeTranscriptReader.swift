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
    /// Encoding via `AgentTranscriptLocator.encodeClaudeCwd` (P3 S1 — vorher
    /// wurde hier nur `/`→`-` ersetzt; Pfade mit `.`/`_`/Leerzeichen landeten
    /// damit in einem anderen Verzeichnisnamen als dem, den Claude wirklich
    /// schreibt). Worktree-Stripping via canonicalProjectPath bleibt erhalten.
    static func transcriptURL(forCwd cwd: String, sessionID: String) -> URL {
        let canonical = AgentSessionStore.canonicalProjectPath(cwd)
        let encoded = AgentTranscriptLocator.encodeClaudeCwd(canonical)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    /// `true` nur wenn für (cwd, sessionID) ein **resumebares** Transkript auf
    /// der Platte liegt — also die `<id>.jsonl`-DATEI. Ein gleichnamiges
    /// `<id>/`-VERZEICHNIS (Subagent-/Workflow-Begleitdaten, das Claude bei
    /// workflow-/subagent-lastigen Sessions anlegt) zählt bewusst NICHT:
    /// `claude --resume` braucht die JSONL, nicht das Begleitverzeichnis.
    /// Grundlage für die „nie --resume ohne Transkript"-Garantie beim Launch.
    ///
    /// Multi-Account: sucht über ALLE Account-Roots (main + Profile) inkl.
    /// Session-ID-Fallback des Locators. Vorher prüfte diese Funktion NUR
    /// `~/.claude/projects` — der Launch-Guard hat dadurch Sessions, deren
    /// Transcript in einem Profil-Root lag, fälschlich als „tot" resettet
    /// und ihren Verlauf abgekoppelt (Vorfall 2026-07-13).
    static func transcriptExists(forCwd cwd: String, sessionID: String) -> Bool {
        let canonical = AgentSessionStore.canonicalProjectPath(cwd)
        guard let url = AgentTranscriptLocator.locate(
            provider: .claude, externalSessionID: sessionID, cwd: canonical
        ) else {
            return false
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    /// Liest das Transcript fuer eine (cwd, sessionID)-Kombi. Liefert `nil`
    /// wenn die Datei nicht existiert; wirft NICHT bei kaputten Zeilen — die
    /// werden uebersprungen und geloggt. Sucht wie `transcriptExists` über
    /// alle Account-Roots.
    static func read(cwd: String, sessionID: String) -> AgentChatTranscript? {
        let canonical = AgentSessionStore.canonicalProjectPath(cwd)
        guard let url = AgentTranscriptLocator.locate(
            provider: .claude, externalSessionID: sessionID, cwd: canonical
        ) else {
            return nil
        }
        return read(fileURL: url)
    }

    /// Eigene Reader-Methode fuer Tests + direkte URL-Pfade.
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

        Logger.terminalSnapshot.debug("claude_transcript_read url=\(fileURL.lastPathComponent, privacy: .public) lines=\(lineNumber) messages=\(messages.count) skipped=\(skipped)")

        return AgentChatTranscript(messages: messages, isLiveSourcePossible: true)
    }

    /// P3 S6: Bounded Tail-Read — parst nur die letzten `tailBytes` statt der
    /// ganzen Datei (Transcripts können >50 MB groß sein). Für Konsumenten,
    /// die nur das Gesprächsende brauchen (Diktat-Kontext-Tail). Sucht wie
    /// `transcriptExists` über alle Account-Roots.
    static func readTail(cwd: String, sessionID: String, tailBytes: Int = TranscriptTailReader.defaultTailBytes) -> AgentChatTranscript? {
        let canonical = AgentSessionStore.canonicalProjectPath(cwd)
        guard let url = AgentTranscriptLocator.locate(
            provider: .claude, externalSessionID: sessionID, cwd: canonical
        ) else {
            return nil
        }
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
/// P3 S6: Liefert die letzten `tailBytes` einer Datei als vollständige
/// Zeilen. Die erste, ggf. angeschnittene Zeile wird verworfen — gleicher
/// Absorb-Ansatz wie beim Runtime-Watcher-Tail-Read.
enum TranscriptTailReader {
    static let defaultTailBytes: Int = 256 * 1024

    static func tailLines(fileURL: URL, tailBytes: Int) -> [String] {
        tailLinesWithTruncation(fileURL: fileURL, tailBytes: tailBytes).lines
    }

    /// Wie `tailLines`, meldet aber zusaetzlich, ob VOR dem Fenster noch
    /// Dateiinhalt liegt — Basis fuer "Früheren Verlauf laden" in der UI.
    static func tailLinesWithTruncation(fileURL: URL, tailBytes: Int) -> (lines: [String], truncatedHead: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return ([], false) }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = UInt64(max(0, Int64(size) - Int64(tailBytes)))
            try handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: tailBytes)
            var lines = String(decoding: data, as: UTF8.self)
                .split(omittingEmptySubsequences: true) { $0.isNewline }
                .map(String.init)
            if offset > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            return (lines, offset > 0)
        } catch {
            return ([], false)
        }
    }
}

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
