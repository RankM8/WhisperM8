import Foundation

/// Geparstes Hook-Event aus Claude-Code. Wir interessieren uns primaer fuer
/// `session_id`, `hook_event_name` und (bei SessionEnd) `reason` — der
/// Rest des Payloads landet in `rawJSON` fuer Debugging.
struct ClaudeHookEvent: Equatable, Codable {
    enum EventName: String, Codable, Equatable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        /// Vor jedem Tool-Aufruf — wir nutzen das aktuell nur als
        /// Aktivitaets-Signal („arbeitet"), nicht zum Blockieren.
        case preToolUse = "PreToolUse"
        /// Permission-Prompts und andere Notifications. Fuer
        /// Background-Sessions das wichtigste „needs input"-Signal,
        /// denn dort gibt es keinen interaktiven Prompt im PTY.
        case notification = "Notification"
        case other
    }

    var hookEventName: EventName
    var sessionID: String?
    var transcriptPath: String?
    var cwd: String?
    /// Bei SessionEnd: `"resume"` signalisiert interaktiven /resume-Wechsel.
    var reason: String?
    var rawJSON: String
}

/// Tail-Reader fuer das JSONL-File einer lokalen Session. Speichert pro
/// Datei den letzten gelesenen Byte-Offset, damit wir bei jedem Tick nur
/// die neuen Zeilen parsen.
final class ClaudeHookEventStore {
    private struct Cursor {
        var offset: UInt64 = 0
    }
    private var cursors: [URL: Cursor] = [:]

    /// Liest alle neuen Zeilen seit dem letzten Aufruf. Idempotent: wenn die
    /// Datei nicht existiert oder leer ist, leeres Array.
    func readNewEvents(from url: URL) -> [ClaudeHookEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let cursor = cursors[url] ?? Cursor()
        var newCursor = cursor

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: cursor.offset)
        } catch {
            // Datei wurde verkleinert oder umbenannt - reset Cursor.
            newCursor.offset = 0
            try? handle.seek(toOffset: 0)
        }

        let data = handle.readDataToEndOfFile()
        let newOffset = cursor.offset + UInt64(data.count)
        newCursor.offset = newOffset
        cursors[url] = newCursor

        guard !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return Self.parseLines(text)
    }

    /// Pure Parser-Logik — extrahiert pro Zeile ein `ClaudeHookEvent`.
    /// Robust gegen ungueltige Zeilen (ignoriert sie still).
    static func parseLines(_ text: String) -> [ClaudeHookEvent] {
        var events: [ClaudeHookEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let event = parseLine(trimmed) else { continue }
            events.append(event)
        }
        return events
    }

    static func parseLine(_ line: String) -> ClaudeHookEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let nameRaw = (object["hook_event_name"] as? String) ?? "other"
        let name = ClaudeHookEvent.EventName(rawValue: nameRaw) ?? .other
        return ClaudeHookEvent(
            hookEventName: name,
            sessionID: object["session_id"] as? String,
            transcriptPath: object["transcript_path"] as? String,
            cwd: object["cwd"] as? String,
            reason: object["reason"] as? String,
            rawJSON: line
        )
    }

    /// Reset Cursor fuer eine Datei (z. B. wenn die Session beendet ist und
    /// die naechste mit derselben localID einen frischen Stream beginnt).
    func resetCursor(for url: URL) {
        cursors.removeValue(forKey: url)
    }
}
