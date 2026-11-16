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
        // Standard nur „ruht“: In eine offene Rückfrage geht ein Prompt nur auf
        // ausdrücklichen Wunsch (`--answer`), sonst stünde er als Antwort des
        // Users im Dialog (WM8-71/85).
        let ifStatus = request.params["ifStatus"]?.arrayValue?.compactMap { $0.stringValue } ?? ["idle"]

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
        // Nur ein geprüfter Absender zählt für Board-Hinweise (WM8-119).
        let verifiedActor = actorID.flatMap {
            AgentSessionTokenRegistry.shared.verify(sessionID: $0, token: request.actor.token) ? $0 : nil
        }

        let sentAt = Date()
        // ATOMARER MainActor-Block: Guards + Paste ohne await dazwischen.
        let (outcome, clearedInput, usageWarning, verify) = await MainActor.run { () -> (SendOutcome, Bool, String?, Bool) in
            var clearedInput = false
            var usageWarning: String?
            var verify = false
            let outcome: SendOutcome = {
                // Unmittelbar vor der Wirkung: Hat der Client inzwischen aufgegeben
                // (MainActor hing), nicht mehr einfügen (WM8-85).
                if request.isExpired() { return .failure(.expired, Self.expiredMessage) }
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
                // WM8-100: Auch „bereit“ heißt im Startfenster erst etwas, wenn
                // Claudes Eingabefeld am Bildschirm steht.
                let coordinator = AgentSessionStatusCoordinator.shared
                let inputPending = coordinator.startupInputPending(targetID)
                let readiness = ChatsSendReadinessGuard.decide(
                    lifecycle: coordinator.lifecycleState(for: targetID), inputPending: inputPending)
                if case .notReady = readiness {
                    let adopted = coordinator.adoptedSessions.contains(targetID)
                    return .failure(.notReady, ChatsSendReadinessGuard.message(
                        for: readiness, adopted: adopted, inputPending: inputPending) ?? "Chat startet noch")
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
                // Ein Enter wartet noch auf den Text davor (WM8-119): Jetzt
                // eingefügt, verschmölzen beide zu einer Meldung. Auch mit
                // --force nicht; `notReady` lässt die CLI vormerken.
                if AgentTerminalController.enterPending(for: targetID) {
                    return .failure(.notReady, DelayedEnterLanding.enterPendingMessage)
                }
                if Self.approvalPending(targetID, controller) { return .failure(.approvalPending, Self.approvalPendingMessage) } // WM8-75, auch mit --force
                // Status-Guard (--if-status). --force überstimmt ihn (nie den
                // Selbst-Send-Schutz).
                let force = request.params["force"]?.boolValue ?? false
                if let message = Self.statusGuardMessage(runtime, allowed: ifStatus, force: force) {
                    return .failure(.conflict, message)
                }
                // Ein sichtbar leeres Feld schlägt die Tasten-Schätzung (WM8-64),
                // aber nur, wenn die Ansicht unten steht. Sichtbarer Text sperrt
                // auch hochgescrollt (WM8-123).
                let profile = controller.command.keyboardProfile
                let reading = controller.composerFieldForSendCheck()
                // Eine offene Ansicht nähme das Enter (Zurückspulen: „Enter to
                // continue“), auch mit --force nicht (WM8-123).
                if reading.openView != nil { return .failure(.conflict, PromptDeliveryGate.viewOpenMessage) }
                if PromptDeliveryGate.sendBlockedByDraft(
                    mayHaveUnsentInput: controller.composerDraft.mayHaveUnsentInput, force: force,
                    fieldVisiblyEmpty: PromptSubmitCheck.fieldVisiblyEmpty(field: reading.fieldForRelease, profile: profile)) {
                    return .failure(.conflict, PromptDeliveryGate.draftMessage(
                        insertedText: controller.composerDraft.mayHoldInsertedText))
                }
                // WM8-100: Was am Bildschirm im Feld steht, zählt auch, wenn die
                // Schätzung es für abgeschickt hält (liegengebliebener Auftrag).
                if !force, runtime == .idle, PromptSubmitCheck.visibleDraft(
                    field: reading.field, profile: profile,
                    clearsBeforeSubmit: controller.composerDraft.shouldClearBeforeSubmit) {
                    return .failure(.conflict, PromptSubmitCheck.visibleDraftMessage)
                }
                verify = PromptSubmitCheck.applies(submit: submit, profile: profile, statusAtSend: runtime)
                // Marker-Zeile voranstellen (Kennzeichnung + Ein-Hop) — nur bei Agent-Chats, nie in eine Shell.
                let marked = Self.deliveredPrompt(prompt, actor: markerActor, toShell: controller.command.keyboardProfile == .plainShell)
                clearedInput = controller.sendPrompt(marked, submit: submit)
                if submit {
                    // Wer wen anstößt, für das Turn-Ende im Journal (WM8-119).
                    TurnContactLedger.shared.noteDelivered(to: targetID, from: verifiedActor, at: sentAt)
                    TurnContactLedger.shared.noteMessaged(from: verifiedActor, to: targetID, at: sentAt)
                }
                return .success(session)
            }()
            return (outcome, clearedInput, usageWarning, verify)
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
                // Der Text im Feld ist dieser Auftrag: `chats submit` darf ihn
                // nach der Freigabe abschicken (WM8-123).
                await MainActor.run {
                    _ = AgentTerminalRegistry.shared.controller(for: targetID)?.claimWithheldDelivery(queuedPromptID: nil)
                }
                releaseIdempotency(request.requestID)
                await audit(request.actor, method: "send", target: await sessionLabel(targetID), outcome: "withheld", prompt: prompt)
                return Self.enterWithheldResponse(requestID: request.requestID)
            }
            // Erst „zugestellt“, wenn der Text raus ist (WM8-100). Steht er noch
            // im Feld, bleibt die Anfrage verbraucht: ein Wiederholen fügte ihn
            // ein zweites Mal ein.
            let verdict = verify ? await Self.submitVerdict(targetID) : nil
            completeIdempotency(request.requestID)
            let targetLabel = await sessionLabel(targetID)
            if verdict == .stuckInField {
                await audit(request.actor, method: "send", target: targetLabel, outcome: "inInputField", prompt: prompt)
                return Self.stuckInFieldResponse(requestID: request.requestID)
            }
            await audit(request.actor, method: "send", target: targetLabel, outcome: "ok", prompt: prompt)
            return .success(requestID: request.requestID, result: .object([
                "ack": "delivered",
                "target": ["id": session.id.uuidString, "title": session.title],
                "promptChars": prompt.count,
                "requestID": request.requestID,
                "clearedInput": clearedInput,
                "submitCheck": verdict.map { ChatsControlJSON.string($0.rawValue) } ?? ChatsControlJSON.null,
                "warning": usageWarning.map { ChatsControlJSON.string($0) } ?? ChatsControlJSON.null,
            ]))
        }
    }
}

// MARK: - Nachsehen nach dem Enter (WM8-100)

extension AgentControlRequestHandler {
    /// Liest Status und Eingabefeld, bis klar ist, ob der Text raus ist.
    static func submitVerdict(_ sessionID: UUID) async -> PromptSubmitCheck.Verdict {
        await PromptSubmitCheck.waitForVerdict(probe: {
            let status = AgentSessionStatusCoordinator.shared.statusStore.status(for: sessionID)
            let field = AgentTerminalRegistry.shared.controller(for: sessionID)?.controllerScreenSnapshot()?.promptField
            return (status, field)
        })
    }

    /// Text steht im Feld: kein „delivered“, nie neu senden oder vormerken
    /// (`resend: false` wertet die CLI wie beim zurückgehaltenen Enter aus).
    static func stuckInFieldResponse(requestID: String) -> ChatsControlResponse {
        .failure(requestID: requestID, code: .conflict, message: PromptSubmitCheck.stuckMessage,
                 detail: .object(["textInField": .bool(true), "resend": .bool(false),
                                  "reason": .string("inInputField")]))
    }
}

// MARK: - Status-Konflikt (WM8-85)

extension AgentControlRequestHandler {
    /// Status-Guard. `--force` überspringt ihn, aber nie den Schutz einer
    /// offenen Frage: Die beantwortet nur `--answer` (bzw. `awaitingInput` in
    /// `--if-status`), Entscheidung Jarvis nach dem Vorfall vom 14.11.
    static func statusGuardMessage(_ runtime: AgentSessionRuntimeStatus?, allowed: [String], force: Bool) -> String? {
        guard let runtime, !allowed.contains(runtime.rawValue) else { return nil }
        if force, runtime != .awaitingInput { return nil }
        return statusConflictMessage(runtime, allowed: allowed)
    }

    static func statusConflictMessage(_ runtime: AgentSessionRuntimeStatus, allowed: [String]) -> String {
        if runtime == .awaitingInput, !allowed.contains(runtime.rawValue) {
            return "Ziel wartet auf eine Antwort (Rückfrage an den User). send beantwortet sie nicht von sich aus. "
                + "Vorgemerkt kommt der Prompt nach der Antwort; bewusst antworten: `chats send <ref> --answer …`."
        }
        return "Ziel ist \(runtime.rawValue) (erlaubt: \(allowed.joined(separator: ",")))"
    }
}

// MARK: - Veraltete Anfrage (WM8-85)

extension AgentControlRequestHandler {
    static let expiredMessage = "Anfrage verworfen: Der Client hatte schon aufgegeben (keine Antwort in seiner Frist). "
        + "Nichts ausgeführt."

    static func expiredResponse(_ request: ChatsControlRequest) -> ChatsControlResponse {
        .failure(requestID: request.requestID, code: .expired, message: expiredMessage)
    }
}
