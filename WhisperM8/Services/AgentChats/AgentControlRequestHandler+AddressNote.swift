import Foundation

// MARK: - audit.note (LR-CLI-007)

extension AgentControlRequestHandler {
    /// `whisperm8 chats address` liest nur Claudes Registry — die native
    /// SendMessage-Brücke danach läuft an `session.send` (Marker, Zustell-Token,
    /// Audit, Selbst-Send-Schutz) vorbei. Damit wenigstens die Adressvergabe eine
    /// Spur hinterlässt und der Selbstschutz greift, meldet die CLI jede Abfrage
    /// vor der Ausgabe hierher: Audit-Zeile (Akteur → Ziel, nie Inhalt) und
    /// Ablehnung, wenn ein Chat die eigene Adresse erfragt.
    func auditNote(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let raw = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: raw) else {
            return .failure(requestID: request.requestID, code: .invalid,
                            message: "targetSessionID fehlt/ungültig")
        }
        if let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:)), actorID == targetID {
            await audit(request.actor, method: "address", target: raw, outcome: "selfSend", prompt: nil)
            return .failure(requestID: request.requestID, code: .selfSend,
                            message: "Die eigene Adresse ist nicht erlaubt (Selbst-Nachricht)")
        }
        await audit(request.actor, method: "address", target: raw, outcome: "issued", prompt: nil)
        return .success(requestID: request.requestID, result: .object(["noted": true]))
    }
}
