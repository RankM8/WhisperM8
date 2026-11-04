import Foundation

// MARK: - Methoden der Feature-Erweiterungen

/// Board, Debug, Ansagen und Zwischenablage haben je eine eigene Datei
/// (`AgentControlRequestHandler+…`). Ihre Methoden-Sets landen hier, damit der
/// zentrale Switch nicht mit jedem Feature wächst.
extension AgentControlRequestHandler {
    func featureRequest(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        switch request.method {
        case let method where Self.boardMethods.contains(method):
            return await boardMutation(request)
        case let method where Self.debugMethods.contains(method):
            return await debugRequest(request)
        case let method where Self.speechMethods.contains(method):
            return await speechRequest(request)
        case let method where Self.clipboardMethods.contains(method):
            return await clipboardRequest(request)
        default:
            return .failure(requestID: request.requestID, code: .unsupported,
                            message: "Unbekannte Methode: \(request.method)")
        }
    }
}
