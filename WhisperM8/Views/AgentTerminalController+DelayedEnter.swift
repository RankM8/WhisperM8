import Foundation

// Das verzögerte Enter in `pastePrompt`: Planung, Warten auf den Text im Feld
// (WM8-119) und Prüfung davor (WM8-75). Ausgelagert, weil
// AgentTerminalView.swift an der Dateigrenze steht.

extension AgentTerminalController {
    /// Wird gerufen, wenn ein Enter zurückgehalten wurde; die App zeigt dazu
    /// einen Hinweis in der Pille (gesetzt in `AppState`).
    @MainActor static var onDelayedEnterWithheld: ((UUID) -> Void)?

    /// Wann zuletzt je Chat ein Enter zurückgehalten wurde — `chats send` fragt
    /// das kurz nach dem Einfügen ab, um nicht still „delivered“ zu melden.
    @MainActor static var lastWithheldEnterAt: [UUID: Date] = [:]

    /// Seit wann je Chat ein Enter darauf wartet, dass sein Text im Feld steht
    /// (WM8-119). Gesetzt beim Einfügen, gelöscht, sobald das Enter entschieden ist.
    @MainActor static var pendingEnterSince: [UUID: Date] = [:]

    /// Wartet bei diesem Chat ein Enter auf seinen Text? (`DelayedEnterLanding.enterPending`)
    @MainActor static func enterPending(for sessionID: UUID, now: Date = Date()) -> Bool {
        DelayedEnterLanding.enterPending(since: pendingEnterSince[sessionID], now: now)
    }

    /// Wartet, bis das verzögerte Enter entschieden ist (80 ms, nach einem
    /// Leeren 230 ms, plus Luft; wartet es auf den Text im Feld, bis zu 3 s
    /// länger), und meldet, ob es zurückgehalten wurde.
    /// Für `chats send` und die Warteschlange: kein stilles „zugestellt“. Erst
    /// danach beginnt das Nachsehen nach dem Enter; ein noch leeres Feld hieße
    /// dort sonst „abgeschickt“.
    static func enterWasWithheld(sessionID: UUID, clearedInput: Bool, since started: Date) async -> Bool {
        let wait: UInt64 = clearedInput ? 330_000_000 : 180_000_000
        try? await Task.sleep(nanoseconds: wait)
        let deadline = Date().addingTimeInterval(DelayedEnterLanding.maxWaitSeconds + 0.5)
        while await MainActor.run(body: { pendingEnterSince[sessionID] != nil }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await MainActor.run { (lastWithheldEnterAt[sessionID] ?? .distantPast) >= started }
    }

    /// Plant das Enter nach einem Einfüge-Block (aus `pastePrompt`): nach
    /// 80 ms, bei einem ruhenden Claude-Chat erst, wenn der Text im Feld steht
    /// (`DelayedEnterLanding`, WM8-119), und nur, wenn `delayedEnterAllowed`
    /// es erlaubt (WM8-75). Kosten: je Versuch eine Ablesung der untersten
    /// 16 Zeilen; die gab es schon vorher einmal je Senden. Gewartet wird nur,
    /// solange das Feld leer aussieht, also meist gar nicht, mit Bildpfaden
    /// höchstens 30 Versuche.
    func scheduleDelayedEnter(statusAtPaste: AgentSessionRuntimeStatus?, questionAtPaste: Bool, text: String) {
        let pastedAt = Date()
        // Stand des Felds nach dem Einfügen: Ändert er sich während des
        // Wartens, hat jemand anderes ins Feld geschrieben oder es abgeschickt.
        let marks = (writes: composerDraft.programmaticWrites, resets: composerDraft.fieldResets)
        Self.pendingEnterSince[sessionID] = pastedAt
        attemptDelayedEnter(statusAtPaste: statusAtPaste, questionAtPaste: questionAtPaste, text: text,
                            pastedAt: pastedAt, marks: marks, waited: false,
                            after: DelayedEnterLanding.firstDelaySeconds)
    }

    private func attemptDelayedEnter(statusAtPaste: AgentSessionRuntimeStatus?, questionAtPaste: Bool, text: String,
                                     pastedAt: Date, marks: (writes: Int, resets: Int), waited: Bool,
                                     after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let sessionID = self.sessionID
            // Ein neuerer Einfüge-Block hat das Enter übernommen.
            guard Self.pendingEnterSince[sessionID] == pastedAt else { return }
            guard self.isRunning else {
                Self.pendingEnterSince[sessionID] = nil
                return
            }
            // Einmal lesen, für die Prüfung hier und für `delayedEnterAllowed`.
            let screen = self.sendCheckScreen().snapshot
            let draft = self.composerDraft
            let touched = draft.mayHaveUnsentInput
                || draft.programmaticWrites != marks.writes || draft.fieldResets != marks.resets
            let elapsed = Date().timeIntervalSince(pastedAt)
            switch DelayedEnterLanding.step(
                profile: self.command.keyboardProfile, statusAtPaste: statusAtPaste, field: screen?.promptField,
                elapsed: elapsed, waited: waited, touched: touched) {
            case .wait:
                self.attemptDelayedEnter(statusAtPaste: statusAtPaste, questionAtPaste: questionAtPaste, text: text,
                                         pastedAt: pastedAt, marks: marks, waited: true,
                                         after: DelayedEnterLanding.pollSeconds)
            case .skip:
                Self.pendingEnterSince[sessionID] = nil
                Logger.agentStore.notice(
                    "delayed_enter_skipped_field_touched session=\(sessionID.uuidString, privacy: .public) waitedMs=\(Int(elapsed * 1000), privacy: .public)")
            case .send:
                Self.pendingEnterSince[sessionID] = nil
                if waited {
                    // Selten (Bildpfade); Dauer und Ausgang helfen, die Frist zu prüfen.
                    let landed = screen?.promptField.map { !DelayedEnterLanding.notLandedYet($0) } ?? true
                    Logger.agentStore.notice(
                        "delayed_enter_after_wait session=\(sessionID.uuidString, privacy: .public) waitedMs=\(Int(elapsed * 1000), privacy: .public) landed=\(landed, privacy: .public)")
                }
                guard self.delayedEnterAllowed(statusAtPaste: statusAtPaste, questionAtPaste: questionAtPaste,
                                               text: text, screen: screen) else { return }
                self.terminal.send([0x0D])
            }
        }
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
    /// `screen`: eben gelesen (`sendCheckScreen`), im selben Main-Thread-Durchlauf.
    func delayedEnterAllowed(statusAtPaste: AgentSessionRuntimeStatus?, questionAtPaste: Bool, text: String,
                             screen: ControllerScreenSnapshot?) -> Bool {
        let statusNow = statusForDelayedEnter
        // Bildschirm immer lesen: Auch ein „ruhender“ Status kann hinterherhinken,
        // und bei offener Rückfrage unterscheidet er Frage und Freigabe. Bei
        // Claude auch hochgescrollt vom lebendigen Bildschirm (WM8-123); ein
        // Bildschirm macht hier nur strenger. Kosten gemessen: rund 5 ms im
        // Debug-Build je Lesen der untersten 16 Zeilen, einmal je Versuch
        // (`scheduleDelayedEnter`).
        guard !DelayedEnterGuard.allowsEnter(
            statusAtPaste: statusAtPaste, questionAtPaste: questionAtPaste, statusNow: statusNow, screen: screen,
            textLooksLikeOption: DelayedEnterGuard.looksLikeOption(text)) else {
            return true
        }
        Self.lastWithheldEnterAt[sessionID] = Date()
        // Eingefügter Text; `chats send` und die Warteschlange beanspruchen
        // ihn danach als ihren Auftrag, ein Diktat nicht (WM8-123). Der Text
        // bleibt am Vermerk: `submit` schickt nur ab, wenn genau er im Feld steht.
        noteDeliveryWithheld(text: text)
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
