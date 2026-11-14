import Foundation

// Prüfung vor dem verzögerten Enter in `pastePrompt` (WM8-75), ausgelagert,
// weil AgentTerminalView.swift an der Dateigrenze steht.

extension AgentTerminalController {
    /// Wird gerufen, wenn ein Enter zurückgehalten wurde; die App zeigt dazu
    /// einen Hinweis in der Pille (gesetzt in `AppState`).
    @MainActor static var onDelayedEnterWithheld: ((UUID) -> Void)?

    static var delayedEnterWithheldHint: String {
        String(localized: "Not sent: the chat is asking for a decision")
    }

    /// Status im Moment des Einfügens, für `delayedEnterAllowed(statusAtPaste:)`.
    var statusForDelayedEnter: AgentSessionRuntimeStatus? {
        AgentSessionStatusCoordinator.shared.statusStore.status(for: sessionID)
    }

    /// Direkt vor dem Enter: Status und Bildschirm neu lesen. Hält es das Enter
    /// zurück, bleibt der Text als Entwurf stehen, und die Pille sagt es.
    func delayedEnterAllowed(statusAtPaste: AgentSessionRuntimeStatus?) -> Bool {
        let statusNow = statusForDelayedEnter
        // Den Bildschirm nur lesen, wenn es etwas ändern kann: Eine Freigabe
        // geht nur in einem arbeitenden Chat auf; ein schon beim Einfügen
        // offener Dialog braucht keine Prüfung. Kosten gemessen: rund 5 ms im
        // Debug-Build je Lesen (16 Zeilen), im ruhenden Chat 0.
        let mayHaveOpened = statusAtPaste == .working || statusNow == .working
        let screen = statusAtPaste != .awaitingInput && mayHaveOpened ? controllerScreenSnapshot() : nil
        guard !DelayedEnterGuard.allowsEnter(statusAtPaste: statusAtPaste, statusNow: statusNow, screen: screen) else {
            return true
        }
        noteComposerTextInserted()
        Logger.agentStore.notice(
            "delayed_enter_withheld session=\(self.sessionID.uuidString, privacy: .public) status=\(String(describing: statusNow), privacy: .public)")
        Self.onDelayedEnterWithheld?(sessionID)
        return false
    }
}
