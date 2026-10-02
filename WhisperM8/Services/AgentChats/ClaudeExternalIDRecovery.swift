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
    private static let sessionStartMarker = "\"hook_event_name\":\"SessionStart\""
    private static let forkSourceMarker = "\"source\":\"fork\""

    /// Rückfall-Kandidat: Session-ID + wo ihr Transcript HEUTE liegt.
    struct Candidate: Equatable {
        let sessionID: String
        let transcriptURL: URL
    }

    /// - Parameter locateTranscript: (Session-ID, im Hook protokollierter
    ///   Pfad) → heutiger Ort der Datei oder `nil`. Der protokollierte Pfad
    ///   allein reicht nicht: ein Kontowechsel (`move-account`, Kontextmenü)
    ///   verschiebt das Transcript in ein anderes Profil (Vorfall 2026-10-01:
    ///   ac020fd4 lag danach unter PowerUser2 statt RankM8).
    /// - Returns: Kandidat mit dem jüngsten Turn, dessen Datei existiert.
    static func recoverableCandidate(
        eventLines: some Sequence<Substring>,
        brokenID: String,
        locateTranscript: (String, String) -> URL?
    ) -> Candidate? {
        // Reihenfolge des letzten Turn-Belegs pro ID + jüngster Pfad.
        var lastTurnIndex: [String: Int] = [:]
        var pathByID: [String: String] = [:]
        // Background-Forks (`SessionStart` mit `source: fork`) schreiben ihre
        // Turns ins selbe Event-File und sind jünger als das Original — ohne
        // Ausschluss fiele der Chat auf den bg-Agent zurück (Review 2026-10-02).
        var forkIDs = Set<String>()
        var index = 0
        for line in eventLines {
            index += 1
            if line.contains(sessionStartMarker), line.contains(forkSourceMarker),
               let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sessionID = object["session_id"] as? String {
                forkIDs.insert(sessionID)
                continue
            }
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
        for id in lastTurnIndex.sorted(by: { $0.value > $1.value }).map(\.key) where !forkIDs.contains(id) {
            if let url = locateTranscript(id, pathByID[id] ?? "") {
                return Candidate(sessionID: id, transcriptURL: url)
            }
        }
        return nil
    }

    /// Liest das Event-File und liefert den Rückfall-Kandidaten (oder `nil`).
    /// Default-Suche: protokollierter Pfad, sonst der Locator über ALLE
    /// Profil-Roots (inkl. cwd-verifiziertem Glob).
    static func recoverableCandidate(
        eventFileURL: URL,
        brokenID: String,
        projectPath: String,
        locateTranscript: ((String, String) -> URL?)? = nil
    ) -> Candidate? {
        guard let data = try? Data(contentsOf: eventFileURL, options: .mappedIfSafe) else { return nil }
        // Tolerant dekodieren: ein kaputtes Byte darf die Heilung nicht verhindern.
        let text = String(decoding: data, as: UTF8.self)
        return recoverableCandidate(
            eventLines: text.split(separator: "\n", omittingEmptySubsequences: true),
            brokenID: brokenID,
            locateTranscript: locateTranscript ?? { id, loggedPath in
                if !loggedPath.isEmpty, FileManager.default.fileExists(atPath: loggedPath) {
                    return URL(fileURLWithPath: loggedPath)
                }
                return AgentTranscriptLocator.locate(
                    provider: .claude, externalSessionID: id, cwd: projectPath)
            }
        )
    }

    struct Recovery: Equatable {
        let localID: UUID
        let brokenID: String
        let recoveredID: String
        /// Profil des Chats beim Scan — angewendet wird nur, wenn es noch
        /// gilt (ein Kontowechsel dazwischen gewinnt).
        var expectedProfileName: String? = nil
        /// Profil, unter dem das Transcript heute liegt (`nil` = main).
        /// `--resume` findet die Session nur unter diesem Config-Dir — liegt
        /// die Datei nach einem Kontowechsel woanders, zieht das Profil des
        /// Chats mit.
        let recoveredProfileName: String?
    }

    /// Je (localID, kaputte ID) nur EIN Versuch pro App-Lauf — die Sidebar
    /// berechnet „tote Zeiger" bei jedem Workspace-Reload neu, und nach
    /// Claudes 30-Tage-Cleanup gibt es viele echte Tote ohne Rückfall-ID.
    private static let attemptedLock = NSLock()
    nonisolated(unsafe) private static var attempted: Set<String> = []

    /// Prüft die Claude-Sessions unter `candidates` (tote Zeiger) auf eine
    /// Rückfall-ID. Off-main gedacht (liest Event-Files).
    ///
    /// - Parameter boundExternalIDs: externe IDs ALLER Sessions im Workspace.
    ///   Ist die Rückfall-ID schon an einen anderen Chat gebunden (z. B. den
    ///   Ersatz-Chat, in dem der User weitergearbeitet hat), wird NICHT
    ///   geheilt — zwei Chats auf derselben Claude-Session schreiben beim
    ///   gleichzeitigen Resume in dasselbe Transcript.
    static func recoveries(
        candidates: [AgentChatSession],
        projectPathByID: [UUID: String],
        boundExternalIDs: Set<String>,
        hookPaths: ClaudeHookPaths = ClaudeHookPaths(),
        locateTranscript: ((String, String) -> URL?)? = nil
    ) -> [Recovery] {
        var result: [Recovery] = []
        for session in candidates where session.provider == .claude {
            guard let broken = session.externalSessionID, !broken.isEmpty,
                  let projectPath = projectPathByID[session.projectID] else { continue }
            let key = "\(session.id.uuidString)|\(broken)"
            attemptedLock.lock()
            let isNew = attempted.insert(key).inserted
            attemptedLock.unlock()
            guard isNew,
                  let candidate = recoverableCandidate(
                    eventFileURL: hookPaths.eventFileURL(localSessionID: session.id),
                    brokenID: broken,
                    projectPath: projectPath,
                    locateTranscript: locateTranscript)
            else { continue }
            guard !boundExternalIDs.contains(candidate.sessionID) else {
                Logger.claudeBinding.notice("binding_recovery_skipped_bound_elsewhere localID=\(session.id.uuidString, privacy: .public) candidate=\(candidate.sessionID, privacy: .public)")
                continue
            }
            result.append(Recovery(
                localID: session.id,
                brokenID: broken,
                recoveredID: candidate.sessionID,
                expectedProfileName: session.claudeProfileName,
                recoveredProfileName: ClaudeAccountProfiles.profileName(
                    forTranscriptPath: candidate.transcriptURL.path)))
        }
        return result
    }
}
