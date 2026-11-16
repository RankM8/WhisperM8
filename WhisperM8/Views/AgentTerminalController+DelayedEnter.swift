import Foundation

// Prüfung vor dem verzögerten Enter in `pastePrompt` (WM8-75), ausgelagert,
// weil AgentTerminalView.swift an der Dateigrenze steht.

extension AgentTerminalController {
    /// Wird gerufen, wenn ein Enter zurückgehalten wurde; die App zeigt dazu
    /// einen Hinweis in der Pille (gesetzt in `AppState`).
    @MainActor static var onDelayedEnterWithheld: ((UUID) -> Void)?

    /// Wann zuletzt je Chat ein Enter zurückgehalten wurde — `chats send` fragt
    /// das kurz nach dem Einfügen ab, um nicht still „delivered“ zu melden.
    @MainActor static var lastWithheldEnterAt: [UUID: Date] = [:]

    /// Wartet, bis das verzögerte Enter entschieden ist (80 ms, nach einem
    /// Leeren 230 ms, plus Luft), und meldet, ob es zurückgehalten wurde.
    /// Für `chats send` und die Warteschlange: kein stilles „zugestellt“.
    static func enterWasWithheld(sessionID: UUID, clearedInput: Bool, since started: Date) async -> Bool {
        let wait: UInt64 = clearedInput ? 330_000_000 : 180_000_000
        try? await Task.sleep(nanoseconds: wait)
        return await MainActor.run { (lastWithheldEnterAt[sessionID] ?? .distantPast) >= started }
    }

    /// Beim Einfügen eine sicher erkannte Frage offen (`chats send` darf sie
    /// mit Enter beantworten)?
    var questionOpenForDelayedEnter: Bool {
        guard case .awaitingInput(.question)? = AgentSessionStatusCoordinator.shared.lifecycleState(for: sessionID) else {
            return false
        }
        return true
    }

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
    func delayedEnterAllowed(statusAtPaste: AgentSessionRuntimeStatus?, questionAtPaste: Bool, text: String) -> Bool {
        let statusNow = statusForDelayedEnter
        // Bildschirm immer lesen: Auch ein „ruhender“ Status kann hinterherhinken,
        // und bei offener Rückfrage unterscheidet er Frage und Freigabe. Bei
        // Claude auch hochgescrollt vom lebendigen Bildschirm (WM8-123); ein
        // Bildschirm macht hier nur strenger. Kosten gemessen: rund 5 ms im
        // Debug-Build je Lesen der untersten 16 Zeilen, einmal je Senden.
        let screen = sendCheckScreen().snapshot
        guard !DelayedEnterGuard.allowsEnter(
            statusAtPaste: statusAtPaste, questionAtPaste: questionAtPaste, statusNow: statusNow, screen: screen,
            textLooksLikeOption: DelayedEnterGuard.looksLikeOption(text)) else {
            return true
        }
        Self.lastWithheldEnterAt[sessionID] = Date()
        // Eingefügter Text; `chats send` und die Warteschlange beanspruchen
        // ihn danach als ihren Auftrag, ein Diktat nicht (WM8-123).
        noteDeliveryWithheld()
        Logger.agentStore.notice(
            "delayed_enter_withheld session=\(self.sessionID.uuidString, privacy: .public) status=\(statusNow.map { String(describing: $0) } ?? "none", privacy: .public)")
        Self.onDelayedEnterWithheld?(sessionID)
        return false
    }

    /// Hat ein Enter einen vorgemerkten Auftrag mit zurückgehaltenem Enter
    /// abgeschickt, verbucht die Warteschlange ihn als zugestellt (WM8-123).
    /// Ohne solchen Auftrag nur ein Nachsehen im Tracker, kein I/O.
    ///
    /// Erst kurz danach: Ein Enter, das nur eine Vervollständigung wählt
    /// (@-Datei, Slash-Menü), lässt den Text im Feld stehen. Dann bleibt der
    /// Auftrag vorgemerkt und gilt wieder als eingefügt; das nächste echte
    /// Enter verbucht ihn. Kosten: eine Ablesung der untersten 16 Zeilen, nur
    /// nach einem Enter auf einen solchen Auftrag.
    func bookSubmittedWithheldDelivery() {
        guard let id = takeSubmittedWithheldQueueID() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionCheckDelay) { [weak self] in
            guard let self else { return }
            let status = AgentSessionStatusCoordinator.shared.statusStore.status(for: self.sessionID)
            if Self.submitLandedInCompletion(status: status, field: self.composerFieldForSendCheck().field) {
                self.noteSubmitStayedInField(queuedPromptID: id)
                Logger.agentStore.notice(
                    "withheld_submit_stayed_in_field session=\(self.sessionID.uuidString, privacy: .public)")
                return
            }
            AgentControlRequestHandler.markWithheldQueueEntryDelivered(id, sessionID: self.sessionID)
        }
    }

    /// So lange nach dem Enter sieht die App aufs Feld.
    nonisolated static let completionCheckDelay: TimeInterval = 0.5

    /// Pur: Stand der Text nach dem Enter noch da, ohne dass ein Turn begann?
    /// Nicht ablesbar heißt: raus (wie bisher verbuchen). Irrt die Ablesung in
    /// die andere Richtung, fängt der Blick ins Transcript vor der nächsten
    /// Zustellung den Auftrag ab (`checkAlreadySent`).
    nonisolated static func submitLandedInCompletion(status: AgentSessionRuntimeStatus?,
                                                      field: ControllerPromptField?) -> Bool {
        status != .working && field?.hasText == true
    }
}
