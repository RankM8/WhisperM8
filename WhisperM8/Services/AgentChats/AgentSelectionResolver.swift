import Foundation

/// Reine Auflösung der „aktuellen" Session für die Ansicht (LR-AU-018).
///
/// Vorher baute der Rückfall (`selectedSessionID` zeigt auf einen archivierten
/// oder fehlenden Chat) pro Aufruf ein Dictionary über ALLE Sessions
/// (`headerTabs`) — und der Getter lief je Grid-Pane und Body-Auswertung.
/// Jetzt ein linearer Durchlauf ohne Hilfsstruktur über die Sessions.
enum AgentSelectionResolver {
    /// - Returns: die ausgewählte, nicht archivierte Session; sonst die erste
    ///   offene (nicht archivierte) in Tab-Reihenfolge; sonst `nil`.
    static func selected(
        sessions: [AgentChatSession],
        selectedID: UUID?,
        openTabIDs: [UUID]
    ) -> AgentChatSession? {
        if let selectedID,
           let hit = sessions.first(where: { $0.id == selectedID && $0.status != .archived }) {
            return hit
        }
        guard !openTabIDs.isEmpty else { return nil }
        var rank: [UUID: Int] = [:]
        rank.reserveCapacity(openTabIDs.count)
        for (index, id) in openTabIDs.enumerated() where rank[id] == nil { rank[id] = index }
        var best: (rank: Int, session: AgentChatSession)?
        for session in sessions where session.status != .archived {
            guard let r = rank[session.id] else { continue }
            if best == nil || r < best!.rank { best = (r, session) }
        }
        return best?.session
    }
}
