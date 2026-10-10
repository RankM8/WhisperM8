import Foundation

// MARK: - speech.speak (`whisperm8 speak "<text>"`)

/// Gesprochene Ansage eines Chats. Die App stellt den Namen des Chats voran —
/// aber nur mit gültigem Session-Token; ohne (Terminal, fremder Prozess)
/// spricht sie den Text ohne Namen. Den Text selbst protokolliert sie nie,
/// auch nicht im Audit-Log (nur die Länge).
extension AgentControlRequestHandler {
    static let speechMethods: Set<String> = ["speech.speak"]

    func speechRequest(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let text = request.params["text"]?.stringValue ?? ""
        let verified: UUID? = request.actor.sessionID
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in
                AgentSessionTokenRegistry.shared.verify(sessionID: id, token: request.actor.token) ? id : nil
            }
        let response: ChatsControlResponse = await MainActor.run {
            let center = SpeechCalloutCenter.shared
            guard center.isEnabled else {
                return .failure(requestID: request.requestID, code: .unsupported, message: SpeechCalloutSettings.disabledMessage)
            }
            let title = verified.flatMap { id in
                AgentWorkspaceUIModel.shared.workspace.sessions.first(where: { $0.id == id })?.title
            }
            let outcome = center.enqueue(
                sessionID: verified,
                speaker: title.flatMap(SpeechCalloutText.spokenName(fromTitle:)),
                text: text
            )
            guard outcome != .empty else {
                return .failure(requestID: request.requestID, code: .invalid, message: "Kein Text zum Vorlesen.")
            }
            return .success(requestID: request.requestID, result: .object(outcome.json))
        }
        await audit(request.actor, method: "speak", target: nil,
                    outcome: response.ok ? (response.result?["status"]?.stringValue ?? "ok") : (response.error?.code ?? "error"),
                    prompt: nil)
        return response
    }
}

enum SpeechCalloutSettings {
    static let disabledMessage =
        "Ansagen sind abgeschaltet (defaults write com.whisperm8.app speechCalloutsEnabled -bool YES schaltet sie ein)."
}
