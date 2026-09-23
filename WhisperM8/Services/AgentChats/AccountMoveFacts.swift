import Foundation

/// Faktensammlung und Move-Aufbau fuer den Konto-Umzug — geteilt von der
/// Oberflaeche (`AgentChatsView+AccountMove`) und dem Control-Server
/// (`whisperm8 chats move-account`). Beide Wege muessen dieselben Fakten an
/// den `AccountMovePlanner` geben, sonst entschieden GUI und CLI fuer
/// denselben Chat verschieden.
///
/// Pur bis auf die Kollisionspruefung (ein `stat()` je Chat ueber
/// `ClaudeAccountProfiles`); ob eine Session laeuft, liefert der Aufrufer.
enum AccountMoveFacts {
    /// Pfad, unter dem Claude das Transcript ablegt: Subagent-Jobs arbeiten
    /// ggf. in einem eigenen cwd (Worktree), alle anderen im Projektpfad.
    static func cwd(for session: AgentChatSession, projects: [AgentProject]) -> String? {
        session.subagentCwd ?? projects.first(where: { $0.id == session.projectID })?.path
    }

    /// Das Ergebnis ist ein Snapshot: die Kollisionspruefung wird beim
    /// tatsaechlichen Move erneut gemacht, weil zwischen Vorschau und
    /// Ausfuehrung Zeit vergeht.
    static func candidates(
        for sessions: [AgentChatSession],
        projects: [AgentProject],
        target: String?,
        profiles: ClaudeAccountProfiles = ClaudeAccountProfiles(),
        isRunning: (UUID) -> Bool
    ) -> [AccountMovePlanner.Candidate] {
        sessions.map { session in
            let conflict: Bool = {
                guard let externalID = session.externalSessionID, !externalID.isEmpty,
                      let cwd = cwd(for: session, projects: projects) else { return false }
                return profiles.transcriptConflictExists(
                    externalSessionID: externalID, cwd: cwd, toProfile: target
                )
            }()
            return AccountMovePlanner.Candidate(
                sessionID: session.id,
                title: session.title,
                currentProfile: session.claudeProfileName,
                provider: session.provider,
                kind: session.effectiveKind,
                isRunning: isRunning(session.id),
                hasTargetConflict: conflict
            )
        }
    }

    /// Baut aus den umziehbaren Kandidaten eines Plans die ausfuehrungs-
    /// fertigen Bewegungen. Kandidaten ohne auffindbare Session oder ohne
    /// Projektpfad landen in `unresolved` — die Oberflaeche liess sie frueher
    /// wortlos fallen, die CLI meldet sie als Fehler.
    static func moves(
        for plan: AccountMovePlanner.Plan,
        sessions: [AgentChatSession],
        projects: [AgentProject]
    ) -> (moves: [AccountMoveService.Move], unresolved: [AccountMovePlanner.Candidate]) {
        let sessionsByID = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var moves: [AccountMoveService.Move] = []
        var unresolved: [AccountMovePlanner.Candidate] = []
        for candidate in plan.movable {
            guard let session = sessionsByID[candidate.sessionID],
                  let cwd = cwd(for: session, projects: projects) else {
                unresolved.append(candidate)
                continue
            }
            moves.append(AccountMoveService.Move(
                sessionID: session.id,
                title: session.title,
                externalSessionID: session.externalSessionID,
                cwd: cwd,
                fromProfile: session.claudeProfileName,
                toProfile: plan.targetProfile
            ))
        }
        return (moves, unresolved)
    }
}
