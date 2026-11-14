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
    /// zurück, steht der Text meist noch im Feld (hat Claude ihn wegen eines
    /// schon offenen Dialogs ignoriert, nicht; ein Diktat liegt dann in der
    /// Zwischenablage), und die Pille sagt es.
    func delayedEnterAllowed(statusAtPaste: AgentSessionRuntimeStatus?, text: String) -> Bool {
        let statusNow = statusForDelayedEnter
        // Bildschirm immer lesen, außer bei einer schon beim Einfügen offenen
        // Rückfrage: Auch ein „ruhender“ Status kann hinterherhinken. Nur
        // Claude (sonst `nil`), nur ganz unten. Kosten gemessen: rund 5 ms im
        // Debug-Build je Lesen der untersten 16 Zeilen, einmal je Senden.
        let screen = statusAtPaste == .awaitingInput ? nil : controllerScreenSnapshot()
        guard !DelayedEnterGuard.allowsEnter(
            statusAtPaste: statusAtPaste, statusNow: statusNow, screen: screen,
            textLooksLikeOption: DelayedEnterGuard.looksLikeOption(text)) else {
            return true
        }
        noteComposerTextInserted()
        Logger.agentStore.notice(
            "delayed_enter_withheld session=\(self.sessionID.uuidString, privacy: .public) status=\(statusNow.map { String(describing: $0) } ?? "none", privacy: .public)")
        Self.onDelayedEnterWithheld?(sessionID)
        return false
    }
}
