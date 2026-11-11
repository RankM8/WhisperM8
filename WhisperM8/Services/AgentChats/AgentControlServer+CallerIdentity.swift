import Foundation

extension AgentControlServer {
    /// Eine behauptete Chat-Identität gilt nur, wenn die PTY dieses Chats in
    /// der Prozesskette des Aufrufers steht (Prozess-ID des Socket-Partners →
    /// Eltern per `sysctl`). Claudes Daemon und seine Worker erben Umgebung samt
    /// `WHISPERM8_SESSION_ID`/`_TOKEN` des Chats, der den Daemon gestartet hat,
    /// sind aber keine Nachfahren seiner PTY — ihre Aufrufe gelten damit als
    /// extern, unabhängig davon, ob Claudes Registry sie (schon) kennt.
    static func correctingCallerIdentity(_ request: ChatsControlRequest, socket fd: Int32) -> ChatsControlRequest {
        guard let claimed = request.actor.sessionID.flatMap(UUID.init(uuidString:)),
              let ptyPID = AgentSessionTokenRegistry.shared.processID(for: claimed),
              let peer = AgentCallerIdentityCheck.peerProcessID(socket: fd) else { return request }
        let chain = AgentCallerIdentityCheck.processChain(startingAt: peer)
        return corrected(request, claimed: claimed, ptyPID: ptyPID, chain: chain)
    }

    /// Pure: Steht die PTY nicht in der Kette, wird der Aufrufer extern.
    static func corrected(
        _ request: ChatsControlRequest,
        claimed: UUID,
        ptyPID: Int32,
        chain: [Int32]
    ) -> ChatsControlRequest {
        guard !chain.contains(ptyPID) else { return request }
        var corrected = request
        corrected.actor = ChatsControlActor()
        Logger.agentStore.notice(
            "control_caller_identity_dropped claimed=\(claimed.uuidString, privacy: .public) pty=\(ptyPID, privacy: .public) peer=\(chain.first ?? -1, privacy: .public) — PTY nicht in der Prozesskette"
        )
        return corrected
    }
}
