import Foundation

// `chats send` und offene Freigaben (WM8-75, Entscheidung 14.11.2026): `send`
// bestätigt nie eine Freigabe. Vorher wurde der Text dort ignoriert und das
// Enter wählte die Vorauswahl „Yes“, auch wenn „nein“ geschickt wurde.

extension AgentControlRequestHandler {
    static let approvalPendingMessage =
        "Im Ziel ist eine Freigabe oder ein Dialog offen — send bestätigt keine Freigaben, sie gehen an den User. Später erneut oder `enqueue`."
    static let enterWithheldMessage =
        "Text eingefügt, aber nicht abgeschickt: Zwischen Einfügen und Enter ging eine Freigabe auf. Der Text steht im Eingabefeld — nicht neu senden (auch nicht per enqueue); die Freigabe geht an den User."

    /// Vor dem Einfügen: Wartet das Ziel auf eine Freigabe, ist die Art
    /// unklar, oder steht bei Claude statt des Eingabefelds ein Dialog? Gilt
    /// auch mit `--force`.
    @MainActor
    static func approvalPending(_ targetID: UUID, _ controller: AgentTerminalController) -> Bool {
        let coordinator = AgentSessionStatusCoordinator.shared
        return DelayedEnterGuard.approvalPending(
            status: coordinator.statusStore.status(for: targetID),
            lifecycle: coordinator.lifecycleState(for: targetID),
            screen: controller.controllerScreenSnapshot())
    }

    /// Antwort, wenn das Enter nach dem Einfügen zurückgehalten wurde: kein
    /// „delivered“; der Text steht im Feld, ein erneutes Senden wäre doppelt.
    static func enterWithheldResponse(requestID: String) -> ChatsControlResponse {
        .failure(requestID: requestID, code: .approvalPending, message: enterWithheldMessage,
                 detail: .object(["textInField": .bool(true), "resend": .bool(false)]))
    }
}
