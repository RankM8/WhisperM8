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

        let outcome: SendOutcome = await MainActor.run {
            if request.isExpired() { return .failure(.expired, Self.expiredMessage) }
            let workspace = AgentWorkspaceUIModel.shared.workspace
            guard let session = workspace.sessions.first(where: { $0.id == targetID }),
                  session.status != .archived else {
                return .failure(.notFound, "Session nicht gefunden oder archiviert")
            }
            if let actorID, actorID == targetID {
                return .failure(.selfSend, "Den eigenen Entwurf abzuschicken ist nicht erlaubt (Endlosschleife)")
            }
            guard let controller = AgentTerminalRegistry.shared.controller(for: targetID), controller.isRunning else {
                return .failure(.noPty, "Keine laufende PTY — Tab mit `chats resume` starten")
            }
            let screen = controller.controllerScreenSnapshot()
            let status = AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
            switch Self.submitCheck(profile: controller.command.keyboardProfile, status: status,
                                    approvalPending: Self.approvalPending(targetID, controller),
                                    userDraft: controller.composerDraft.mayHaveUnsentInput,
                                    insertedText: controller.composerDraft.mayHoldInsertedText,
                                    field: screen?.promptField, screenReadable: screen != nil) {
            case .allowed:
                controller.submitComposer()
                return .success(session)
            case .refused(let code, let message):
                return .failure(code, message)
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
            ]))
        }
    }

    static let submitRefusedTypedMessage = "Im Eingabefeld steht vermutlich ein Entwurf des Users (getippt, nicht "
        + "abgeschickt). submit schickt nur liegengebliebene Aufträge ab, nie Text des Users. Nichts abgeschickt."

    static let submitRefusedInsertedMessage = "Im Eingabefeld steht Text, den die App eingefügt und niemand "
        + "abgeschickt hat: ein Diktat ohne Senden, „→ Jarvis“, `send --no-submit` oder ein Auftrag, dessen Enter "
        + "wegen einer Freigabe zurückgehalten wurde. submit schickt ihn nicht ab, weil die App nicht unterscheiden "
        + "kann, ob er dem User gehört. Nichts abgeschickt. Was im Feld steht, zeigt kein chats-Befehl; der User "
        + "kann nach der Freigabe weitergetippt oder diktiert haben. Deshalb: Direkt gesendeter Auftrag: Der User "
        + "schickt ihn im Chat mit Enter ab. Vorgemerkter Auftrag (steht noch in `chats queue <ref>`): erst "
        + "`chats dequeue <ref> <Kurz-ID>`, dann Enter durch den User, sonst kommt er doppelt; oder nach "
        + "Rückfrage beim User `whisperm8 chats interrupt <ref> --clear-input --force` (leert das ganze Feld), "
        + "dann geht er von selbst neu raus. Leeren mit --force nie ohne Rückfrage beim User."

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
    static func submitCheck(profile: TerminalKeyboardProfile, status: AgentSessionRuntimeStatus?,
                            approvalPending: Bool, userDraft: Bool, insertedText: Bool = false,
                            field: ControllerPromptField?, screenReadable: Bool) -> SubmitDecision {
        guard profile == .claudeCodeChat else {
            return .refused(.unsupported, "`chats submit` gibt es nur für Claude-Chats")
        }
        if approvalPending { return .refused(.approvalPending, approvalPendingMessage) }
        if userDraft {
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
