import Foundation

// Rückfall-Bindung neuer Chats an ihr Transcript (Poller in
// `AgentSessionDetailView.bindExternalSessionIDWhenAvailable`, nur für den
// Fall, dass kein SessionStart-Hook kommt).
//
// Befund 13.11.2026 (Test-Instanz, „soak bash“/„soak question“): Zwei Chats im
// selben Ordner starteten 3 s nacheinander. Der Poller des zweiten lief vor
// dessen Hook und nahm das jüngste Transcript im Ordner — das des ersten,
// den sein Hook längst gebunden hatte. Beide trugen dieselbe Claude-Sitzung;
// der richtige SessionStart wurde danach zurückgestellt (`postpone`).
extension AgentSessionStore {
    /// Fenster, in dem ein anderer ungebundener Chat als Mitbewerber um
    /// dasselbe Transcript gilt (gleichzeitig gestartete Chats).
    static let fallbackBindingRivalWindow: TimeInterval = 30

    /// Pur: welches indexierte Transcript der Poller `session` geben darf.
    /// - nie eines, das schon ein anderer Chat trägt;
    /// - gar keines, solange ein anderer ungebundener Chat desselben Providers
    ///   im selben Ordner etwa gleichzeitig gestartet ist — dann entscheidet
    ///   der Hook, der seine Sitzung genau kennt.
    static func fallbackBindingCandidate(
        for session: AgentChatSession,
        projectPath: String,
        provider: AgentProvider,
        workspace: AgentWorkspace,
        indexedSessions: [IndexedAgentSession]
    ) -> IndexedAgentSession? {
        let standardizedPath = canonicalProjectPath(projectPath)
        let others = workspace.sessions.filter { $0.id != session.id && !$0.isTerminal }
        let taken = Set(others.compactMap { $0.externalSessionID?.lowercased() })
        let rivals = others.filter { other in
            other.provider == provider
                && other.externalSessionID == nil
                && abs(other.createdAt.timeIntervalSince(session.createdAt)) <= fallbackBindingRivalWindow
                && workspace.projects.first(where: { $0.id == other.projectID })
                    .map { canonicalProjectPath($0.path) == standardizedPath } == true
        }
        guard rivals.isEmpty else { return nil }
        return indexedSessions
            .filter {
                $0.provider == provider
                    && !isClaudeWorktreePath($0.cwd)
                    && canonicalProjectPath($0.cwd) == standardizedPath
                    && $0.createdAt >= session.createdAt.addingTimeInterval(-5)
                    && !taken.contains($0.externalSessionID.lowercased())
            }
            .max(by: { $0.lastActivityAt < $1.lastActivityAt })
    }
}
