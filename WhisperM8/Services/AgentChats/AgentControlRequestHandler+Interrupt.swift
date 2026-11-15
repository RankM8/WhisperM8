import Foundation

// `session.interrupt` — aus dem Request-Handler ausgelagert (Größen-Grenze,
// WM8-85: Prüfung auf veraltete Anfrage direkt vor dem ESC).

extension AgentControlRequestHandler {
    // MARK: session.interrupt

    func sessionInterrupt(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))

        let clearInput = request.params["clearInput"]?.boolValue ?? false
        let outcome: SendOutcome = await MainActor.run {
            let registry = AgentTerminalRegistry.shared
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert")
            }
            if let actorID, actorID == targetID {
                return .failure(.selfSend, "Sich selbst zu unterbrechen ist nicht erlaubt")
            }
            guard let controller = registry.controller(for: targetID), controller.isRunning else {
                return .failure(.noPty, "Keine laufende PTY")
            }
            // Hing die App, bis der Client aufgab, kein ESC mehr: Es träfe
            // einen späteren Turn (WM8-85).
            if request.isExpired() { return .failure(.expired, Self.expiredMessage) }
            // Guard: nur working-Ziele interrupten (sonst sinnlos).
            let ifStatus = request.params["ifStatus"]?.arrayValue?.compactMap { $0.stringValue } ?? ["working"]
            let force = request.params["force"]?.boolValue ?? false
            let runtime = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
            if !force, let runtime, !ifStatus.contains(runtime.rawValue) {
                return .failure(.conflict, "Ziel ist \(runtime.rawValue), nicht working")
            }
            controller.sendInterrupt()
            controller.noteInterruptSent(status: runtime)
            // Abort-Verdacht anmelden: Der Stop-Hook feuert bei
            // ESC-Interrupts nicht — ohne die Verifikation bliebe die
            // Session im working-Stau (QA-Befund 2026-08-17). Der
            // Coordinator bestätigt nur, wenn der Turn binnen 5 s weder
            // Hook- noch Transcript-Aktivität zeigt.
            AgentSessionStatusCoordinator.shared.suspectTurnAborted(targetID)
            // `--clear-input` (opt-in, löscht auch einen User-Entwurf): leert
            // den zurückgelegten Prompt verzögert, aber nur, wenn bis dahin
            // nichts anderes ins Feld geschrieben hat (Review R1).
            if clearInput { controller.clearComposerAfterInterrupt() }
            return .success(session)
        }

        switch outcome {
        case .failure(let code, let message):
            await audit(request.actor, method: "interrupt", target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let targetLabel = await sessionLabel(targetID)
            await audit(request.actor, method: "interrupt", target: targetLabel, outcome: "ok", prompt: nil)
            var payload: [String: Any] = [
                "ack": "interrupted",
                "target": ["id": session.id.uuidString, "title": session.title],
            ]
            if clearInput { payload["clearInput"] = true }
            return .success(requestID: request.requestID, result: .object(payload))
        }
    }
}
