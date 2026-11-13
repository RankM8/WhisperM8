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
///
/// Grenzen (Opus-Review): Die Datei wird bei jedem Start des Chats neu
/// angelegt — der Beleg gilt also nur für den LETZTEN Start. Ein Besitzer, der
/// seine Sitzung zuletzt fortgesetzt hat, hat nur `.mentioned`. Und nach
/// `/background` schreibt der Worker mit den Settings des Ursprungschats in
/// dessen Datei (`SessionStart` mit `source: fork`): `fork` zählt deshalb nur
/// bei Abzweigen und Hintergrund-Chats als „angelegt“.
enum AgentSessionOwnershipEvidence: Int, Comparable {
    /// Die Datei nennt die Sitzung nicht (oder es gibt keine Datei, etwa Codex).
    case noEvidence = 0
    /// Die Sitzung lief beim letzten Start dieses Chats (Resume, Turns),
    /// angelegt wurde sie dort nicht.
    case mentioned = 1
    /// Ein `SessionStart` des letzten Starts hat die Sitzung angelegt
    /// (`startup`, `clear`; `fork` nur, wenn der Chat selbst ein Abzweig ist).
    case created = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let sessionStartMarker = Array("\"hook_event_name\":\"SessionStart\"".utf8)
    private static let startupSources = ["startup", "clear"].map { Array("\"source\":\"\($0)\"".utf8) }
    private static let forkSource = Array("\"source\":\"fork\"".utf8)
    /// `SessionStart`-Zeilen sind kurz; lange Turn-Zeilen (Tool-Eingaben)
    /// werden nur am Anfang auf die Marker geprüft.
    private static let markerWindow = 4096

    /// Beleg für einen Chat des Workspaces: Codex hat keine Hook-Datei.
    static func live(for session: AgentChatSession, hookPaths: ClaudeHookPaths) -> Self {
        guard session.provider == .claude, let id = session.externalSessionID, !id.isEmpty else { return .noEvidence }
        return read(eventFile: hookPaths.eventFileURL(localSessionID: session.id), sessionID: id,
                    forkCreates: session.forkSourceSessionID != nil || session.isBackgroundChat)
    }

    /// Liest die Datei gemappt; geparst wird nichts, nur Bytes gesucht. Die
    /// Dateien können Hunderte MB groß sein — gefragt wird nur bei einer
    /// echten Dopplung.
    static func read(eventFile: URL, sessionID: String, forkCreates: Bool) -> Self {
        guard let data = try? Data(contentsOf: eventFile, options: .alwaysMapped) else { return .noEvidence }
        return scan(data: data, sessionID: sessionID, forkCreates: forkCreates)
    }

    static func scan(data: Data, sessionID: String, forkCreates: Bool) -> Self {
        let needle = Array("\"session_id\":\"\(sessionID.lowercased())\"".utf8)
        let creating = forkCreates ? startupSources + [forkSource] : startupSources
        var result = Self.noEvidence
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
                let line = base + lineStart, length = min(lineEnd - lineStart, markerWindow)
                func contains(_ marker: [UInt8]) -> Bool {
                    marker.withUnsafeBytes { memmem(line, length, $0.baseAddress!, marker.count) != nil }
                }
                if contains(sessionStartMarker), creating.contains(where: contains) {
                    result = .created
                }
                offset = lineEnd + 1
            }
        }
        return result
    }
}
