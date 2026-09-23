import Foundation

/// Liest den Titel, den das CLI selbst für eine Session vergeben hat — ohne
/// eigenen Modellaufruf (ersetzt 2026-09-23 den früheren Headless-Title-
/// Generator, der pro Session einen `claude -p`/`codex exec`-Prozess startete).
///
/// **Claude Code** schreibt zwei Titel ins Transcript (verifiziert CLI 2.1.280,
/// Doku „Manage sessions → Name your sessions"):
/// - `{"type":"custom-title","customTitle":…}` — `/rename`, `claude -n`,
///   `Ctrl+R` im Resume-Picker. Hat Vorrang.
/// - `{"type":"ai-title","aiTitle":…}` — Zusammenfassung des ersten Prompts
///   durch das kleine Modell; beim Annehmen eines Plans ersetzt.
///
/// Beide können mehrfach vorkommen (Claude hängt Metadaten beim Umschreiben
/// des Transcripts neu an) — es gilt jeweils der **letzte** Eintrag.
/// Fehlt beides (z. B. Session begann mit einem lokalen Befehl wie `/model`,
/// dann erzeugt Claude keinen Titel), gilt der erste echte Prompt — genau so,
/// wie Claudes eigener Resume-Picker Sessions ohne Titel anzeigt.
///
/// **Codex** führt für CLI-Sessions keinen Titel (gemessen 2026-09-23: 0 von 60
/// Rollouts in `~/.codex/session_index.jsonl`) → erster echter Prompt.
///
/// Das Transcript-Format ist laut Anthropic intern; bricht es, fällt die
/// Anzeige auf den ersten Prompt bzw. den bisherigen Titel zurück — nie Absturz.
enum NativeSessionTitle {
    /// Höchstlänge eines abgeleiteten Prompt-Titels (Zeichen, ohne „…").
    static let promptTitleLength = 60

    /// Head/Tail-Fenster: ai-title steht meist oben (Median Zeile 0, 90 % bis
    /// Zeile 25), custom-title wird angehängt. Beide Fenster zusammen decken
    /// auch 50-MB-Transcripts ab, ohne sie komplett zu lesen.
    static let headBytes = 1 * 1024 * 1024
    static let tailBytes = 2 * 1024 * 1024

    static func resolve(provider: AgentProvider, transcriptURL: URL) -> String? {
        let text = headAndTail(of: transcriptURL)
        guard !text.isEmpty else { return nil }
        switch provider {
        case .claude: return claudeTitle(fromJSONL: text)
        case .codex: return codexTitle(fromJSONL: text)
        }
    }

    // MARK: Claude

    static func claudeTitle(fromJSONL text: String) -> String? {
        var customTitle: String?
        var aiTitle: String?
        var firstPrompt: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Schneller Vorfilter: nur Zeilen parsen, die relevant sein können.
            let isTitle = line.contains("\"custom-title\"") || line.contains("\"ai-title\"")
            let isUser = firstPrompt == nil && line.contains("\"type\":\"user\"")
            guard isTitle || isUser,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            switch object["type"] as? String {
            case "custom-title":
                if let value = cleaned(object["customTitle"] as? String) { customTitle = value }
            case "ai-title":
                if let value = cleaned(object["aiTitle"] as? String) { aiTitle = value }
            case "user":
                // Tool-Ergebnisse und Meta-Einträge sind auch `type: user`.
                guard object["isMeta"] as? Bool != true,
                      let message = object["message"] as? [String: Any] else { break }
                firstPrompt = promptTitle(fromContent: message["content"])
            default:
                break
            }
        }
        return customTitle ?? aiTitle ?? firstPrompt
    }

    // MARK: Codex

    static func codexTitle(fromJSONL text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"user\"") || line.contains("\"user_message\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if object["type"] as? String == "event_msg",
               payload["type"] as? String == "user_message",
               let title = promptTitle(fromContent: payload["message"]) {
                return title
            }
            if object["type"] as? String == "response_item",
               payload["role"] as? String == "user",
               let title = promptTitle(fromContent: payload["content"]) {
                return title
            }
        }
        return nil
    }

    // MARK: Prompt → Titel

    /// Erster Textteil, der kein Steuer-/Kontextblock ist (`<local-command-…>`,
    /// `<command-message>`, `<environment_context>`, Tool-Ergebnisse …).
    static func promptTitle(fromContent content: Any?) -> String? {
        var texts: [String] = []
        if let string = content as? String {
            texts = [string]
        } else if let parts = content as? [[String: Any]] {
            texts = parts.compactMap { part in
                let type = part["type"] as? String
                guard type == nil || type == "text" || type == "input_text" else { return nil }
                return part["text"] as? String
            }
        }
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("# AGENTS.md") else { continue }
            // Bild-Platzhalter vorne abschneiden, der Rest trägt den Inhalt.
            var body = trimmed
            while body.hasPrefix("[Image #"), let close = body.firstIndex(of: "]") {
                body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let title = cleaned(body) else { continue }
            return shortened(title)
        }
        return nil
    }

    static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func shortened(_ text: String) -> String {
        guard text.count > promptTitleLength else { return text }
        return String(text.prefix(promptTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Datei

    /// Anfang und Ende der Datei (bei kleinen Dateien einmal komplett). Die
    /// erste Zeile des Tail-Fensters kann angeschnitten sein — sie wird
    /// verworfen, ein halbes JSON parst ohnehin nicht.
    static func headAndTail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        if size <= UInt64(headBytes + tailBytes) {
            return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(tailBytes))
        var tail = (try? handle.readToEnd()) ?? Data()
        if let newline = tail.firstIndex(of: 10) {
            tail = tail[tail.index(after: newline)...]
        }
        // Head-Ende ebenfalls auf eine vollständige Zeile kürzen.
        var headData = head
        if let lastNewline = headData.lastIndex(of: 10) {
            headData = headData[...lastNewline]
        }
        return String(decoding: headData, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }
}
