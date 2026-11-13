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
//
// Für Claude gibt es eine exakte Quelle: Claudes Registry
// (`<config-dir>/sessions/<pid>.json`) nennt zu jeder PID die Sitzungs-ID,
// geschrieben beim Prozessstart, also vor dem ersten Turn. Claude läuft als
// direktes Kind der App im PTY, die PID des Chats ist bekannt. Der Weg über
// Ordner und Zeitfenster bleibt nur als letzter Versuch und für Codex.
extension AgentSessionStore {
    /// Nächster Schritt des Pollers für einen Claude-Chat.
    enum ClaudeFallbackStep: Equatable {
        /// Registry-Eintrag des eigenen Prozesses: genau diese Sitzung.
        case bind(String)
        /// Noch kein Eintrag; nächster Versuch.
        case wait
        /// Letzter Versuch ohne Eintrag: Transcript im Ordner suchen.
        case transcriptFallback
    }

    /// Gemessen am 13.11.2026 mit Claude Code 2.1.323, je dreimal und ohne
    /// Login (`scripts/measure-claude-registry.py`): Schon der erste
    /// Registry-Eintrag trägt die endgültige ID, dieselbe wie der
    /// SessionStart-Hook — frisch eine neue, bei `--resume` die fortgesetzte,
    /// bei `--fork-session` die neue Fork-ID, nie die Quelle oder eine
    /// vorläufige ID (nach 0,25 bis 1,2 s). Ausgenommen bleibt `attach`: Das
    /// führt einen Background-Agent. Dort und ohne Registry-Schalter gilt der
    /// bisherige Weg über Transcripts.
    static func claudeFallbackStep(
        launchArguments: [String]?,
        registryEnabled: Bool,
        processID: Int32?,
        processStartedAt: Date?,
        records: [ClaudeSessionRecord],
        isLastAttempt: Bool
    ) -> ClaudeFallbackStep {
        guard registryEnabled, let launchArguments, isForegroundClaudeStart(arguments: launchArguments) else {
            return .transcriptFallback
        }
        if let processID,
           let record = records.first(where: { record in
               record.pid == processID && !record.isBackground && !record.sessionID.isEmpty
                   // Wiederverwendete PID: ein liegengebliebener Eintrag ist älter als unser Prozess.
                   && (record.startedAt == nil || processStartedAt == nil
                       || record.startedAt! >= processStartedAt!.addingTimeInterval(-2))
           }) {
            return .bind(record.sessionID)
        }
        return isLastAttempt ? .transcriptFallback : .wait
    }

    static func isForegroundClaudeStart(arguments: [String]) -> Bool {
        arguments.first != "attach"
    }

    /// IDs, die andere Chats als `localSessionID` tragen (klein geschrieben).
    static func externalIDsBound(in workspace: AgentWorkspace, except localSessionID: UUID) -> Set<String> {
        Set(workspace.sessions.compactMap { session in
            session.id == localSessionID || session.isTerminal ? nil : session.externalSessionID?.lowercased()
        })
    }

    /// Bindet die Sitzung, die Claudes Registry für den Prozess des Chats
    /// nennt — nur, solange der Chat noch ungebunden ist (der Hook kann
    /// schneller gewesen sein).
    @discardableResult
    func bindRegistryExternalSessionID(localSessionID: UUID, externalSessionID: String) throws -> AgentChatSession? {
        let bound: AgentChatSession? = try mutateWorkspace { workspace in
            guard let index = workspace.sessions.firstIndex(where: { $0.id == localSessionID }),
                  !workspace.sessions[index].isTerminal,
                  workspace.sessions[index].externalSessionID == nil else { return nil }
            workspace.sessions[index].externalSessionID = externalSessionID
            return workspace.sessions[index]
        }
        if bound != nil { flushNow(reason: "binding") }
        return bound
    }

    /// Fenster, in dem ein anderer ungebundener Chat als Mitbewerber um
    /// dasselbe Transcript gilt (gleichzeitig gestartete Chats).
    static let fallbackBindingRivalWindow: TimeInterval = 30

    /// Pur: welches indexierte Transcript der Poller `session` geben darf.
    /// - nie eines, das schon ein anderer Chat trägt;
    /// - bei Claude gar keines, solange ein anderer ungebundener Claude-Chat im
    ///   selben Ordner etwa gleichzeitig gestartet ist — dann entscheiden Hook
    ///   und Registry, die die Sitzung genau kennen. Codex hat beides nicht und
    ///   bliebe sonst für immer ungebunden; dort reicht der Ausschluss
    ///   vergebener Transcripts (zwei gleichzeitige Codex-Chats können ihre
    ///   Transcripts noch tauschen, aber nie teilen).
    static func fallbackBindingCandidate(
        for session: AgentChatSession,
        projectPath: String,
        provider: AgentProvider,
        workspace: AgentWorkspace,
        indexedSessions: [IndexedAgentSession]
    ) -> IndexedAgentSession? {
        let standardizedPath = canonicalProjectPath(projectPath)
        let taken = externalIDsBound(in: workspace, except: session.id)
        let rivals = provider != .claude ? [] : workspace.sessions.filter { other in
            other.id != session.id && !other.isTerminal && !other.isAgentView && !other.isBackgroundChat
                && other.status != .archived
                && other.provider == provider
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
