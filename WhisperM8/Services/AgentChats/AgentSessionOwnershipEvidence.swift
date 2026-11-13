import Foundation

/// Wem gehört eine Claude-Sitzung, wenn zwei Chats sie tragen? Beleg ist die
/// eigene Hook-Event-Datei des Chats (`claude-session-events/<localID>.jsonl`):
/// Dort stehen die rohen Hook-Zeilen der Prozesse genau dieses Chats.
///
/// Hintergrund (Vic, 13.11.2026): Der alte Rückfall-Poller hatte keine obere
/// Zeitgrenze. Ein älterer, ungebundener Chat ohne Prompt konnte das
/// Transcript eines jüngeren erwischen — „der älteste“ wählte dann genau den
/// falsch gebundenen. Seine Datei kennt die Sitzung höchstens aus einem
/// späteren Resume, die des echten Besitzers aus dem Start, der sie anlegte.
enum AgentSessionOwnershipEvidence: Int, Comparable {
    /// Die Datei nennt die Sitzung nicht (oder es gibt keine Datei, etwa Codex).
    case none = 0
    /// Die Sitzung lief in diesem Chat (Resume, Turns), angelegt wurde sie woanders.
    case mentioned = 1
    /// Ein `SessionStart` dieses Chats hat die Sitzung angelegt
    /// (`startup`, `clear` oder `fork`).
    case created = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let sessionStartMarker = Array("\"hook_event_name\":\"SessionStart\"".utf8)
    private static let creatingSources = ["startup", "clear", "fork"].map { Array("\"source\":\"\($0)\"".utf8) }

    /// Liest die Datei gemappt; geparst wird nichts, nur Bytes gesucht. Die
    /// Dateien können Hunderte MB groß sein — gefragt wird nur bei einer
    /// echten Dopplung.
    static func read(eventFile: URL, sessionID: String) -> Self {
        guard let data = try? Data(contentsOf: eventFile, options: .alwaysMapped) else { return .none }
        return scan(data: data, sessionID: sessionID)
    }

    static func scan(data: Data, sessionID: String) -> Self {
        let needle = Array("\"session_id\":\"\(sessionID.lowercased())\"".utf8)
        var result = Self.none
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, !needle.isEmpty else { return }
            let count = raw.count
            var offset = 0
            while offset < count, result != .created {
                guard let hit = needle.withUnsafeBytes({
                    memmem(base + offset, count - offset, $0.baseAddress!, needle.count)
                }) else { break }
                let hitOffset = UnsafeRawPointer(hit) - base
                result = .mentioned
                // Zeilengrenzen um den Treffer.
                var lineStart = hitOffset
                while lineStart > 0, raw[lineStart - 1] != 0x0A { lineStart -= 1 }
                let lineEnd = memchr(base + hitOffset, 0x0A, count - hitOffset)
                    .map { UnsafeRawPointer($0) - base } ?? count
                let line = base + lineStart, length = lineEnd - lineStart
                func contains(_ marker: [UInt8]) -> Bool {
                    marker.withUnsafeBytes { memmem(line, length, $0.baseAddress!, marker.count) != nil }
                }
                if contains(sessionStartMarker), creatingSources.contains(where: contains) {
                    result = .created
                }
                offset = lineEnd + 1
            }
        }
        return result
    }
}
