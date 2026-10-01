import Foundation

/// Selbstheilung für Claude-Chats, deren `externalSessionID` auf eine Session
/// ohne Transcript zeigt (Vorfall 2026-09-30, Chat 06760440: nach dem
/// Umwandeln in einen Background-Agent war die leere Vordergrund-Session der
/// TUI gebunden, der echte Verlauf lag unverändert unter der alten ID).
///
/// Quelle ist das Hook-Event-File des Chats (`claude-session-events/<localID>.jsonl`):
/// Es hält jede Session-ID fest, die je in diesem Chat einen Turn hatte, samt
/// `transcript_path`. Gewählt wird die ID mit dem JÜNGSTEN Turn-Beleg, deren
/// Datei noch existiert — also genau der Verlauf, an dem der User zuletzt
/// gearbeitet hat.
enum ClaudeExternalIDRecovery {
    /// Turn-Events, die belegen, dass eine Session wirklich gearbeitet hat
    /// (und damit ein Transcript schreibt). Bewusst ohne SessionStart/-End.
    private static let turnEventMarkers = [
        "\"hook_event_name\":\"UserPromptSubmit\"",
        "\"hook_event_name\":\"Stop\"",
    ]

    /// - Returns: Session-ID, auf die der Chat zurückfallen sollte, oder `nil`.
    static func recoverableSessionID(
        eventLines: some Sequence<Substring>,
        brokenID: String,
        transcriptExists: (String) -> Bool
    ) -> String? {
        // Reihenfolge des letzten Turn-Belegs pro ID + jüngster Pfad.
        var lastTurnIndex: [String: Int] = [:]
        var pathByID: [String: String] = [:]
        var index = 0
        for line in eventLines {
            index += 1
            // Billiger Vorfilter: Tool-Events tragen teils MB-große Payloads
            // (Base64-Screenshots) — nur Turn-Zeilen werden geparst.
            guard turnEventMarkers.contains(where: { line.contains($0) }),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["session_id"] as? String,
                  !sessionID.isEmpty, sessionID != brokenID,
                  let path = object["transcript_path"] as? String, !path.isEmpty
            else { continue }
            lastTurnIndex[sessionID] = index
            pathByID[sessionID] = path
        }
        let newestFirst = lastTurnIndex.sorted { $0.value > $1.value }.map(\.key)
        return newestFirst.first { id in pathByID[id].map(transcriptExists) ?? false }
    }

    /// Liest das Event-File und liefert die Rückfall-ID (oder `nil`).
    static func recoverableSessionID(
        eventFileURL: URL,
        brokenID: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard let data = try? Data(contentsOf: eventFileURL, options: .mappedIfSafe) else { return nil }
        // Tolerant dekodieren: ein kaputtes Byte darf die Heilung nicht verhindern.
        let text = String(decoding: data, as: UTF8.self)
        return recoverableSessionID(
            eventLines: text.split(separator: "\n", omittingEmptySubsequences: true),
            brokenID: brokenID,
            transcriptExists: { fileManager.fileExists(atPath: $0) }
        )
    }

    struct Recovery: Equatable {
        let localID: UUID
        let brokenID: String
        let recoveredID: String
    }

    /// Je (localID, kaputte ID) nur EIN Versuch pro App-Lauf — die Sidebar
    /// berechnet „tote Zeiger" bei jedem Workspace-Reload neu, und nach
    /// Claudes 30-Tage-Cleanup gibt es viele echte Tote ohne Rückfall-ID.
    private static let attemptedLock = NSLock()
    nonisolated(unsafe) private static var attempted: Set<String> = []

    /// Prüft die Claude-Sessions unter `candidates` (tote Zeiger) auf eine
    /// Rückfall-ID. Off-main gedacht (liest Event-Files).
    static func recoveries(
        candidates: [AgentChatSession],
        hookPaths: ClaudeHookPaths = ClaudeHookPaths()
    ) -> [Recovery] {
        var result: [Recovery] = []
        for session in candidates where session.provider == .claude {
            guard let broken = session.externalSessionID, !broken.isEmpty else { continue }
            let key = "\(session.id.uuidString)|\(broken)"
            attemptedLock.lock()
            let isNew = attempted.insert(key).inserted
            attemptedLock.unlock()
            guard isNew,
                  let recovered = recoverableSessionID(
                    eventFileURL: hookPaths.eventFileURL(localSessionID: session.id),
                    brokenID: broken)
            else { continue }
            result.append(Recovery(localID: session.id, brokenID: broken, recoveredID: recovered))
        }
        return result
    }
}
