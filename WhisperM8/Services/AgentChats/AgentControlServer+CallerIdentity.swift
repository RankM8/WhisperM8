import Foundation

extension AgentControlServer {
    /// Hintergrund-Agents erben die Umgebung des Chats, der Claudes Daemon
    /// gestartet hat — samt `WHISPERM8_SESSION_ID`/`_TOKEN`. Der Server fragt
    /// deshalb, wer wirklich anruft: Prozess-ID des Socket-Partners → nächster
    /// Claude-Prozess in Claudes Registry. Ist das ein Hintergrund-Agent mit
    /// fremder Identität, gilt der Chat, dem dieser Agent gehört — mit dessen
    /// aktuellem Token, falls sein Tab läuft, sonst als externer Aufrufer.
    /// Interaktive Chats und Aufrufe von außen bleiben unverändert.
    static func correctingCallerIdentity(_ request: ChatsControlRequest, socket fd: Int32) -> ChatsControlRequest {
        guard let peer = AgentCallerIdentityCheck.peerProcessID(socket: fd),
              let record = AgentCallerIdentityCheck.nearestClaudeRecord(startingAt: peer),
              record.isBackground else { return request }
        let claimed = request.actor.sessionID.flatMap(UUID.init(uuidString:))
        let lookup = AgentCallerIdentityCheck.lookups(sessions: AgentSessionStore().loadWorkspace().sessions)
        let verdict = AgentCallerIdentityCheck.verdict(
            claimed: claimed, record: record,
            externalSessionIDOf: lookup.externalSessionIDOf,
            sessionForExternalID: lookup.sessionForExternalID)
        guard case .replace(let owner) = verdict else { return request }
        return corrected(request, owner: owner, record: record, claimed: claimed,
                         token: owner.flatMap { AgentSessionTokenRegistry.shared.currentToken(for: $0) })
    }

    /// Pure: die korrigierte Anfrage. Ohne laufende PTY des Besitzers kein
    /// Token — dann tritt der Agent als externer Aufrufer auf, statt eine
    /// Identität zu behaupten, die er nicht belegen kann.
    static func corrected(
        _ request: ChatsControlRequest,
        owner: UUID?,
        record: ClaudeSessionRecord,
        claimed: UUID?,
        token: String?
    ) -> ChatsControlRequest {
        var corrected = request
        if let owner, let token {
            corrected.actor = ChatsControlActor(sessionID: owner.uuidString, token: token)
        } else {
            corrected.actor = ChatsControlActor()
        }
        Logger.agentStore.notice(
            "control_caller_identity_corrected claimed=\(claimed?.uuidString ?? "-", privacy: .public) agent=\(record.sessionID, privacy: .public) now=\(corrected.actor.sessionID ?? "extern", privacy: .public)"
        )
        return corrected
    }
}
