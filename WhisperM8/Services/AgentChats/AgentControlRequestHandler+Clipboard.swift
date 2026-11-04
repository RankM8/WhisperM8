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
        let response = await Self.clipboardCopy(
            ref: ref, requestID: request.requestID,
            settings: ClipboardSettings.readLive(),
            entries: { await MainActor.run { ClipboardHistoryController.shared.entries } },
            copy: { entry in await ClipboardHistoryController.shared.copyToPasteboard(entry) }
        )
        await audit(request.actor, method: "clipboard.copy", target: ref,
                    outcome: response.ok ? "ok" : (response.error?.code ?? "error"), prompt: nil)
        return response
    }

    /// Rein bis auf die übergebenen Zugriffe, damit Schalter, Auflösung und
    /// Antworten ohne laufende App testbar sind.
    static func clipboardCopy(
        ref: String,
        requestID: String,
        settings: ClipboardSettings,
        entries: () async -> [ClipboardEntry],
        copy: (ClipboardEntry) async -> Bool
    ) async -> ChatsControlResponse {
        guard settings.enabled else {
            return .failure(requestID: requestID, code: .unsupported, message: ClipboardSettings.disabledMessage)
        }
        guard settings.agentAccess else {
            return .failure(requestID: requestID, code: .unsupported, message: ClipboardSettings.agentAccessDeniedMessage)
        }
        switch ClipboardHistoryCore.resolve(ref, in: await entries()) {
        case .failure(let error):
            return .failure(requestID: requestID, code: .notFound, message: ClipboardCLIText.message(for: error))
        case .success(let entry):
            guard await copy(entry) else {
                return .failure(requestID: requestID, code: .conflict,
                                message: "Der Eintrag ließ sich nicht in die Zwischenablage legen (Inhalt fehlt?).")
            }
            return .success(requestID: requestID, result: .object([
                "copied": .string(entry.id), "kind": .string(entry.kind.rawValue),
            ]))
        }
    }
}
