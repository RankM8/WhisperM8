import Foundation

// `app.handover`: Neustart, Chats laufen weiter (`make dev`, Test-Instanz
// `restart --keep-chats`). Gibt die Chats an den Aufbewahrer ab und beendet die
// App danach selbst. Wirkt nur mit eingeschaltetem Labs-Schalter; sonst kommt
// `classic` zurück, und der Aufrufer beendet die App wie bisher.
extension AgentControlRequestHandler {
    static let appHandoverMethod = "app.handover"

    func appHandover(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let result = await MainActor.run {
            HandoverRestartService.shared.requestRestart(trigger: .restartRequest)
        }
        return .success(requestID: request.requestID, result: Self.json(result))
    }

    static func json(_ result: HandoverRestartService.Result) -> ChatsControlJSON {
        var object: [String: ChatsControlJSON] = [
            "outcome": .string(result.kind.rawValue),
            "handedOver": .array(result.handedOver.map { .string($0.uuidString) }),
            "notHandedOver": .array(result.notHandedOver.map { .string($0.uuidString) }),
        ]
        if let reason = result.reason { object["reason"] = .string(reason) }
        if let runID = result.runID { object["runID"] = .string(runID) }
        if let pid = result.keeperPID { object["keeperPID"] = .number(Double(pid)) }
        return .object(object)
    }
}
