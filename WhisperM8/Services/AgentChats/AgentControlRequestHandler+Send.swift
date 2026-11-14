import Foundation

// `session.send` — der Sende-Weg von `chats send`, aus dem Request-Handler
// ausgelagert (Größen-Grenze; WM8-69, ohne Verhaltensänderung). Guards und
// Paste laufen weiter in EINEM MainActor-Block ohne await dazwischen.

extension AgentControlRequestHandler {
    // MARK: session.send

    func sessionSend(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        guard let prompt = request.params["prompt"]?.stringValue, !prompt.isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "prompt fehlt/leer")
        }
        let submit = request.params["submit"]?.boolValue ?? true
        let ifStatus = request.params["ifStatus"]?.arrayValue?.compactMap { $0.stringValue } ?? ["awaitingInput", "idle"]

        // Idempotenz — atomar reservieren VOR der Ausführung. Ein bekanntes
        // Duplikat pastet nie erneut; ein noch LAUFENDES Original meldet
        // „inFlight" (Ausgang offen) statt eines falschen Erfolgs.
        switch reserveIdempotency(request.requestID) {
        case .fresh:
            break
        case .completedEarlier(let date):
            return .success(requestID: request.requestID, result: .object([
                "ack": "duplicate", "target": ["id": targetString],
                "at": ISO8601DateFormatter().string(from: date),
            ]))
        case .stillInFlight:
            return .failure(requestID: request.requestID, code: .conflict,
                            message: "Anfrage mit dieser requestID läuft noch — Ausgang per `chats audit` prüfen")
        }

        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))
        let markerActor = await auditActorLabel(request.actor)

        let sentAt = Date()
        // ATOMARER MainActor-Block: Guards + Paste ohne await dazwischen.
        let (outcome, clearedInput, usageWarning) = await MainActor.run { () -> (SendOutcome, Bool, String?) in
            var clearedInput = false
            var usageWarning: String?
            let outcome: SendOutcome = {
                let registry = AgentTerminalRegistry.shared
                let workspace = AgentWorkspaceUIModel.shared.workspace
                guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                      session.status != .archived else {
                    return .failure(.notFound, "Session nicht gefunden oder archiviert")
                }
                // Selbst-Send-Schutz — nie, auch nicht mit force.
                if let actorID, actorID == targetID {
                    return .failure(.selfSend, "An sich selbst senden ist nicht erlaubt (Endlosschleife)")
                }
                guard let controller = registry.controller(for: targetID), controller.isRunning else {
                    return .failure(.noPty, "Keine laufende PTY — Tab mit `chats open` starten")
                }
                // Start-Race: Ein frisch resumter Chat meldet `idle` (launching
                // bildet bewusst darauf ab), ist aber noch nicht aufnahmebereit.
                // `sendPrompt` schreibt blind — der Paste ginge verloren oder käme
                // beim Retry doppelt an. Kein --force-Bypass: hier gibt es nichts
                // zu erzwingen, nur einen sicheren Weg (`enqueue`).
                let readiness = ChatsSendReadinessGuard.decide(
                    lifecycle: AgentSessionStatusCoordinator.shared.lifecycleState(for: targetID))
                if case .notReady = readiness {
                    let adopted = AgentSessionStatusCoordinator.shared.adoptedSessions.contains(targetID)
                    return .failure(.notReady,
                                    ChatsSendReadinessGuard.message(for: readiness, adopted: adopted) ?? "Chat startet noch")
                }
                // Am Nutzungslimit würde der Prompt verbraucht, ohne dass der Chat
                // arbeitet (WM8-69). Kein --force-Bypass, sicherer Weg: `enqueue`.
                // Auch ein Chat, der ruhte, als sein Konto ans Limit kam, hat keine
                // eigene Limit-Zeile: die kontoweite Sicht hält ihn ebenso auf.
                if !AgentUsageLimit.isSlashCommand(prompt),
                   let message = ChatsSendReadinessGuard.usageLimitMessage(
                       session.blockingUsageLimit(in: workspace.sessions)) {
                    return .failure(.notReady, message)
                }
                usageWarning = AgentUsageLimit.isSlashCommand(prompt) ? nil
                    : session.usageLimitWarning(in: workspace.sessions).map(ChatsSendReadinessGuard.creditsWarning)
                let runtime = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
                if Self.approvalPending(targetID, controller) { return .failure(.approvalPending, Self.approvalPendingMessage) } // WM8-75, auch mit --force
                // Status-Guard (--if-status). --force überstimmt ihn (nie den
                // Selbst-Send-Schutz).
                let force = request.params["force"]?.boolValue ?? false
                if !force, let runtime, !ifStatus.contains(runtime.rawValue) {
                    return .failure(.conflict, "Ziel ist \(runtime.rawValue) (erlaubt: \(ifStatus.joined(separator: ",")))")
                }
                if PromptDeliveryGate.sendBlockedByDraft(
                    mayHaveUnsentInput: controller.composerDraft.mayHaveUnsentInput, force: force) {
                    return .failure(.conflict, PromptDeliveryGate.draftMessage)
                }
                // Marker-Zeile voranstellen (Kennzeichnung + Ein-Hop) — nur bei Agent-Chats, nie in eine Shell.
                let marked = Self.deliveredPrompt(prompt, actor: markerActor, toShell: controller.command.keyboardProfile == .plainShell)
                clearedInput = controller.sendPrompt(marked, submit: submit)
                return .success(session)
            }()
            return (outcome, clearedInput, usageWarning)
        }

        switch outcome {
        case .failure(let code, let message):
            // Kein Paste passiert → Reservierung freigeben, damit ein Retry
            // nach behobenem Konflikt (z. B. Ziel wird idle) nicht als Duplikat
            // abgewiesen wird.
            releaseIdempotency(request.requestID)
            await audit(request.actor, method: "send", target: nil, outcome: code.rawValue,
                        prompt: prompt)
            return .failure(requestID: request.requestID, code: code, message: message,
                            detail: nil)
        case .success(let session):
            // Zurückgehaltenes Enter (WM8-75) nie als Erfolg, Idempotenz erst danach.
            if submit, await AgentTerminalController.enterWasWithheld(sessionID: targetID, clearedInput: clearedInput, since: sentAt) {
                releaseIdempotency(request.requestID)
                await audit(request.actor, method: "send", target: await sessionLabel(targetID), outcome: "withheld", prompt: prompt)
                return Self.enterWithheldResponse(requestID: request.requestID)
            }
            completeIdempotency(request.requestID)
            let targetLabel = await sessionLabel(targetID)
            await audit(request.actor, method: "send", target: targetLabel, outcome: "ok", prompt: prompt)
            return .success(requestID: request.requestID, result: .object([
                "ack": "delivered",
                "target": ["id": session.id.uuidString, "title": session.title],
                "promptChars": prompt.count,
                "requestID": request.requestID,
                "clearedInput": clearedInput,
                "warning": usageWarning.map { ChatsControlJSON.string($0) } ?? ChatsControlJSON.null,
            ]))
        }
    }
}
