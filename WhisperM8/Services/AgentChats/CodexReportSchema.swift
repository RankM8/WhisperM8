import Foundation

/// Report-Vertrag für Subagent-Turns: Der Codex-Subagent MUSS seinen letzten
/// Turn mit diesem JSON beenden — erzwungen via `codex exec --output-schema`.
///
/// Bewusst als eingebetteter String statt Bundle-Ressource: das Schema wird
/// vor jedem Spawn in eine Datei geschrieben (Job-Verzeichnis bzw. Temp),
/// und ein eingebetteter String funktioniert auch im nackten
/// `.build/…/WhisperM8`-Binary ohne App-Bundle.
///
/// Grundsatz (beschlossen): Das Modell berichtet nur, was es selbst weiß
/// (status/summary/…) — harte Metadaten (Dauer, diffStat, Turns) misst der
/// Supervisor und legt sie in `state.json.metrics`.
enum CodexReportSchema {
    static let json = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["status", "summary", "filesChanged", "commits", "testsRun", "openQuestions"],
      "properties": {
        "status": { "type": "string", "enum": ["success", "partial", "failure"] },
        "summary": { "type": "string", "description": "2-5 Saetze: was getan wurde und was offen ist" },
        "filesChanged": { "type": "array", "items": { "type": "string" } },
        "commits": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["sha", "message"],
            "properties": {
              "sha": { "type": "string" },
              "message": { "type": "string" }
            }
          }
        },
        "testsRun": {
          "type": ["object", "null"],
          "additionalProperties": false,
          "required": ["command", "passed"],
          "properties": {
            "command": { "type": "string" },
            "passed": { "type": "boolean" }
          }
        },
        "openQuestions": { "type": "array", "items": { "type": "string" } }
      }
    }
    """

    static func write(to url: URL) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Schreibt das Schema in ein Temp-File (Slice-1-Pfad ohne Job-Verzeichnis).
    static func writeToTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-agent-report-schema-\(UUID().uuidString).json")
        try write(to: url)
        return url
    }
}

// MARK: - Geparster Report

/// Der vom Subagent gelieferte Abschluss-Report (Inhalt von
/// `--output-last-message`). Parsing ist tolerant: auch mit `--output-schema`
/// kann das Modell theoretisch Müll liefern — dann `nil`, und der Aufrufer
/// reicht den Rohtext durch statt still zu verwerfen.
struct AgentReport: Codable, Equatable {
    enum Status: String, Codable {
        case success, partial, failure
    }

    struct Commit: Codable, Equatable {
        var sha: String
        var message: String
    }

    struct TestsRun: Codable, Equatable {
        var command: String
        var passed: Bool
    }

    var status: Status
    var summary: String
    var filesChanged: [String]
    var commits: [Commit]
    var testsRun: TestsRun?
    var openQuestions: [String]

    /// Parst die letzte Agent-Message. Toleriert Markdown-Code-Fences
    /// (```json … ```) um das eigentliche JSON — Modelle wrappen gern.
    static func parse(lastMessage: String) -> AgentReport? {
        let unfenced = stripCodeFence(lastMessage)
        guard let data = unfenced.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentReport.self, from: data)
    }

    /// Entfernt einen umschließenden Markdown-Code-Fence, falls vorhanden.
    static func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        // Erste Zeile (``` oder ```json) und schließenden Fence abschneiden.
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        if let closingRange = text.range(of: "```", options: .backwards) {
            text = String(text[..<closingRange.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
