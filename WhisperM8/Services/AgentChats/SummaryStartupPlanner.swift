import Foundation

/// Purer Planer für den Summary-Abgleich beim App-Start: aus den beim
/// letzten Lauf offenen Tabs die wenigen Sessions bestimmen, die eine
/// (neue) Zusammenfassung brauchen. Deckt normalen Quit UND Force-Quit ab —
/// und verarbeitet NIE die gesamte Historie.
enum SummaryStartupPlanner {

    static func plan(
        openTabIDs: [UUID],
        sessions: [AgentChatSession],
        now: Date,
        isStale: (AgentChatSession) -> Bool,
        maxCandidates: Int = 6,
        maxAge: TimeInterval = 7 * 24 * 3600
    ) -> [UUID] {
        // R4-AS-11: nie `uniqueKeysWithValues` auf persistierte IDs — ein
        // duplizierter Bestand (defekte Datei, Merge-Fehler) trappt sonst den
        // App-Start. Erste Row gewinnt, wie bei allen `first(where:)`-Lookups.
        let sessionByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        let candidates = openTabIDs.compactMap { id -> AgentChatSession? in
            guard seen.insert(id).inserted, let session = sessionByID[id] else { return nil }
            // Subagents haben Report-Summaries; Agent-Views/BG-Chats haben
            // kein direkt lesbares Transcript; Archiv bleibt unangetastet.
            guard !session.isSubagentJob, !session.isAgentView, !session.isBackgroundChat else { return nil }
            guard session.status != .archived else { return nil }
            guard let externalID = session.externalSessionID, !externalID.isEmpty else { return nil }
            guard now.timeIntervalSince(session.lastActivityAt) <= maxAge else { return nil }
            guard isStale(session) else { return nil }
            return session
        }
        return candidates
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(maxCandidates)
            .map(\.id)
    }
}
