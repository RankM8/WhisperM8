import Foundation

// `session.submit` — `chats submit <ref>`: schickt einen Text ab, der schon im
// Eingabefeld eines Claude-Chats steht, ohne neuen Text (WM8-100). Für den
// Fall, dass ein Auftrag dort liegengeblieben ist: Noch einmal zu senden
// hängte ihn ein zweites Mal an.

extension AgentControlRequestHandler {
    static let sessionSubmitMethod = "session.submit"

    func sessionSubmit(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))

        // Zweiter Wert: abgeschickt wurde ein Auftrag, dessen Enter zurückgehalten war (WM8-123).
        let (outcome, releasedWithheld): (SendOutcome, Bool) = await MainActor.run {
            if request.isExpired() { return (.failure(.expired, Self.expiredMessage), false) }
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return (.failure(.notFound, "Session nicht gefunden oder archiviert"), false)
            }
            if let actorID, actorID == targetID {
                return (.failure(.selfSend, "Den eigenen Entwurf abzuschicken ist nicht erlaubt (Endlosschleife)"), false)
            }
            guard let controller = AgentTerminalRegistry.shared.controller(for: targetID), controller.isRunning else {
                return (.failure(.noPty, "Keine laufende PTY — Tab mit `chats resume` starten"), false)
            }
            let screen = controller.controllerScreenSnapshot()
            let status = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
            let withheld = controller.composerDraft.submittableWithheldDelivery
            switch Self.submitCheck(profile: controller.command.keyboardProfile, status: status,
                                    approvalPending: Self.approvalPending(targetID, controller),
                                    userDraft: controller.composerDraft.mayHaveUnsentInput,
                                    insertedText: controller.composerDraft.mayHoldInsertedText,
                                    withheldDelivery: withheld != nil,
                                    field: screen?.promptField, screenReadable: screen != nil) {
            case .allowed:
                controller.submitComposer()
                if let id = withheld?.queuedPromptID {
                    Self.markWithheldQueueEntryDelivered(id, sessionID: targetID)
                }
                return (.success(session), withheld != nil)
            case .refused(let code, let message):
                return (.failure(code, message), false)
            }
        }

        switch outcome {
        case .failure(let code, let message):
            await audit(request.actor, method: "submit", target: nil, outcome: code.rawValue, prompt: nil)
            return .failure(requestID: request.requestID, code: code, message: message)
        case .success(let session):
            let verdict = await Self.submitVerdict(targetID)
            let label = await sessionLabel(targetID)
            if verdict == .stuckInField {
                await audit(request.actor, method: "submit", target: label, outcome: "inInputField", prompt: nil)
                return Self.stuckInFieldResponse(requestID: request.requestID)
            }
            await audit(request.actor, method: "submit", target: label, outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ack": "submitted",
                "target": ["id": session.id.uuidString, "title": session.title],
                "submitCheck": verdict.rawValue,
                // Abgeschickt wurde ein Auftrag, dessen Enter zurückgehalten war (WM8-123).
                "withheldDelivery": releasedWithheld,
            ]))
        }
    }

    static let submitRefusedTypedMessage = "Im Eingabefeld steht vermutlich ein Entwurf des Users (getippt, nicht "
        + "abgeschickt). submit schickt nur liegengebliebene Aufträge ab, nie Text des Users. Nichts abgeschickt."

    static let submitRefusedInsertedMessage = "Im Eingabefeld steht Text, den die App eingefügt und niemand "
        + "abgeschickt hat: ein Diktat ohne Senden, „→ Jarvis“, `send --no-submit`, oder ein Auftrag, dessen Enter "
        + "wegen einer Freigabe zurückgehalten wurde und an dem seither jemand getippt, diktiert oder eingefügt hat. "
        + "submit schickt ihn nicht ab, weil er dann (auch) dem User gehört. Nichts abgeschickt. Was im Feld "
        + "steht, zeigt kein chats-Befehl. Deshalb: Direkt gesendeter Auftrag: Der User schickt ihn im Chat mit "
        + "Enter ab. Vorgemerkter Auftrag (steht noch in `chats queue <ref>`): erst "
        + "`chats dequeue <ref> <Kurz-ID>`, dann Enter durch den User, sonst kommt er doppelt; oder nach "
        + "Rückfrage beim User `whisperm8 chats interrupt <ref> --clear-input --force` (leert das ganze Feld), "
        + "dann geht er von selbst neu raus. Leeren mit --force nie ohne Rückfrage beim User."

    /// Ein vorgemerkter Auftrag, dessen Enter zurückgehalten war, ist mit dem
    /// Enter von `submit` zugestellt (höchstens einmal, wie die Warteschlange
    /// selbst). Nur, solange er noch offen ist: Ein per `dequeue` storniertes
    /// bleibt storniert.
    @MainActor
    static func markWithheldQueueEntryDelivered(_ id: UUID, sessionID: UUID,
                                                store: AgentPromptQueueStore = .shared) {
        guard store.openPrompts(for: sessionID).contains(where: { $0.id == id }) else { return }
        store.markDelivered(id: id)
        Logger.agentStore.notice(
            "queue_delivered_by_submit session=\(sessionID.uuidString, privacy: .public) id=\(id.uuidString, privacy: .public)")
    }

    enum SubmitDecision: Equatable {
        case allowed
        case refused(ChatsControlErrorCode, String)
    }

    /// Pur: Darf das Enter raus? Nur bei einem ruhenden Claude-Chat, dessen
    /// Eingabefeld sichtbar Text zeigt; nie in eine Freigabe (WM8-75) und nie
    /// für einen Entwurf des Users (Vic zu WM8-100): Den meldet der Tracker,
    /// ein liegengebliebener Auftrag gilt dort als abgeschickt.
    /// `insertedText`: Der Entwurf ist von der App eingefügter Text (WM8-121).
    /// Dazu gehört auch ein Auftrag, dessen Enter wegen einer Freigabe
    /// zurückgehalten wurde; die Meldung nennt deshalb den Weg, der dann geht.
    /// `withheldDelivery`: Der eingefügte Text ist ein beanspruchter,
    /// unberührter Auftrag, dessen Enter zurückgehalten wurde (WM8-123). Er
    /// stammt vom Absender, nicht vom User, und darf raus.
    static func submitCheck(profile: TerminalKeyboardProfile, status: AgentSessionRuntimeStatus?,
                            approvalPending: Bool, userDraft: Bool, insertedText: Bool = false,
                            withheldDelivery: Bool = false,
                            field: ControllerPromptField?, screenReadable: Bool) -> SubmitDecision {
        guard profile == .claudeCodeChat else {
            return .refused(.unsupported, "`chats submit` gibt es nur für Claude-Chats")
        }
        if approvalPending { return .refused(.approvalPending, approvalPendingMessage) }
        if userDraft, !(withheldDelivery && insertedText) {
            return .refused(.conflict, insertedText ? submitRefusedInsertedMessage : submitRefusedTypedMessage)
        }
        if let status, status != .idle {
            return .refused(.conflict, "Ziel ist \(status.rawValue) — abschicken geht nur, wenn der Chat ruht")
        }
        guard screenReadable else {
            return .refused(.conflict, "Das Eingabefeld ist nicht abzulesen (Ansicht hochgescrollt?). "
                + "Nichts abgeschickt.")
        }
        guard let field else {
            return .refused(.notReady, "Kein Eingabefeld zu sehen — der Chat lädt noch oder zeigt eine Ansicht. "
                + "Nichts abgeschickt.")
        }
        guard field.hasText else {
            return .refused(.conflict, "Im Eingabefeld steht nichts — es gibt nichts abzuschicken.")
        }
        return .allowed
    }
}
