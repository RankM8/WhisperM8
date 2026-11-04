import Foundation

// MARK: - clipboard.copy (`whisperm8 clipboard copy <nr|id>`)

/// Legt einen Eintrag des Verlaufs wieder in die Zwischenablage. Das ist eine
/// Änderung am System und läuft deshalb über die App (einziger Schreiber);
/// Lesen macht die CLI direkt von Disk. Inhalte protokolliert der
/// Audit-Eintrag nie, nur die Referenz.
extension AgentControlRequestHandler {
    static let clipboardMethods: Set<String> = ["clipboard.copy"]

    func clipboardRequest(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        let ref = request.params["ref"]?.stringValue ?? ""
        let response: ChatsControlResponse = await MainActor.run {
            let settings = ClipboardSettings.readLive()
            guard settings.enabled else {
                return .failure(requestID: request.requestID, code: .unsupported, message: ClipboardSettings.disabledMessage)
            }
            guard settings.agentAccess else {
                return .failure(requestID: request.requestID, code: .unsupported, message: ClipboardSettings.agentAccessDeniedMessage)
            }
            let controller = ClipboardHistoryController.shared
            switch ClipboardHistoryCore.resolve(ref, in: controller.store.snapshot()) {
            case .failure(let error):
                return .failure(requestID: request.requestID, code: .notFound, message: ClipboardCLIText.message(for: error))
            case .success(let entry):
                guard controller.copyToPasteboard(entry) else {
                    return .failure(requestID: request.requestID, code: .conflict,
                                    message: "Der Eintrag ließ sich nicht in die Zwischenablage legen (Inhalt fehlt?).")
                }
                return .success(requestID: request.requestID, result: .object([
                    "copied": entry.id, "kind": entry.kind.rawValue,
                ]))
            }
        }
        await audit(request.actor, method: "clipboard.copy", target: ref,
                    outcome: response.ok ? "ok" : (response.error?.code ?? "error"), prompt: nil)
        return response
    }
}
