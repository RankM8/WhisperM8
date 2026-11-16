import Foundation

/// Stellt vorgemerkte Folgeaufträge zu, sobald ein Chat seinen Turn beendet.
///
/// Zustellfenster ist ausschließlich das Turn-Ende (`AgentSessionEffect
/// .turnCompleted`). Bei `awaitingInput` wird NICHT zugestellt — dort wartet
/// der Chat auf die Antwort zu einer konkreten Rückfrage, und ein
/// Folgeauftrag würde als diese Antwort interpretiert.
///
/// Zustellgarantie: **höchstens einmal.** Der Zustand `delivering` wird vor
/// dem Paste persistiert; bricht die App dazwischen ab, wird der Auftrag beim
/// Start als `unknown` markiert statt erneut gesendet. Eine doppelt erteilte
/// Beauftragung ist teurer als eine sichtbare Rückfrage.
@MainActor
final class AgentPromptQueueDelivery {
    static let shared = AgentPromptQueueDelivery()

    let store: AgentPromptQueueStore
    /// Kurze Wartezeit zwischen Turn-Ende und Paste: die TUI muss ihren
    /// Prompt wieder anzeigen, sonst landet der Text im Nirgendwo.
    private let settleDelay: TimeInterval
    /// Hinweis am Chat, solange Meldungen wegen des Eingabefelds warten (WM8-123).
    let notices: QueueHoldNotices
    /// Je Chat höchstens ein geplanter neuer Versuch; ein neuer ersetzt ihn.
    private var heldRetryToken: [UUID: UUID] = [:]
    private var lastReturnRetryAt: [UUID: Date] = [:]
    /// So oft sieht die Warteschlange nach, solange eine Meldung wegen Text im
    /// Feld oder einer offenen Ansicht wartet. Sonst stieß nur das nächste
    /// Turn-Ende an, und das kommt bei einem ruhenden Chat nie.
    static let heldRetrySeconds: TimeInterval = 30

    init(store: AgentPromptQueueStore = .shared, settleDelay: TimeInterval = 0.6,
         notices: QueueHoldNotices = .shared) {
        self.store = store
        self.settleDelay = settleDelay
        self.notices = notices
    }

    /// Stellt den nächsten offenen Auftrag der Session zu, falls einer wartet.
    func deliverNext(for sessionID: UUID) {
        guard !store.openPrompts(for: sessionID).isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            self.deliverNow(for: sessionID)
        }
    }

    /// Der eigentliche Zustellschritt — Reservierung, Guards und Paste in
    /// einem MainActor-Durchlauf ohne `await` dazwischen (gleiche
    /// TOCTOU-Freiheit wie die Send-Pipeline).
    func deliverNow(for sessionID: UUID, transcriptChecked: Bool = false) {
        // Wurde das Enter dieses Auftrags einmal zurückgehalten, kann er
        // inzwischen raus sein, ohne dass die App es verbuchen konnte: erst
        // im Transcript nachsehen, abseits des Main Threads (WM8-123).
        if !transcriptChecked, let next = store.openPrompts(for: sessionID).first,
           next.state == .pending, next.enterWithheld {
            checkAlreadySent(next, sessionID: sessionID)
            return
        }
        // Fehlt nach dem Start das Eingabefeld, gar nicht erst reservieren:
        // sonst schriebe jeder Versuch die Queue-Datei zweimal (Vic zu WM8-100).
        if AgentSessionStatusCoordinator.shared.startupInputPending(sessionID),
           !store.openPrompts(for: sessionID).isEmpty {
            retryAfterStartup(sessionID)
            return
        }
        // Ein Enter wartet noch auf den Text davor (WM8-119, etwa eine
        // Meldung mit Bildpfaden): gleich wieder nachsehen, nicht reservieren.
        // Danach arbeitet der Chat meist, dann stellt das Turn-Ende zu.
        if AgentTerminalController.enterPending(for: sessionID), !store.openPrompts(for: sessionID).isEmpty {
            retryAfterPendingEnter(sessionID)
            return
        }
        guard let reserved = store.reserveNext(for: sessionID) else { return }

        let workspace = AgentWorkspaceUIModel.shared.workspace
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              session.status != .archived else {
            store.markFailed(id: reserved.id, error: "Session nicht gefunden oder archiviert", retry: false)
            return
        }
        guard let controller = AgentTerminalRegistry.shared.controller(for: sessionID),
              controller.isRunning else {
            // Kein Prozess mehr: zurück in die Warteschlange. Der Auftrag
            // bleibt sichtbar und geht nicht verloren — nach `resume` läuft
            // er beim nächsten Turn-Ende an.
            notices.clear(sessionID)
            store.markFailed(id: reserved.id, error: "Keine laufende PTY — wartet auf Start", retry: true)
            return
        }
        // Am Nutzungslimit würde der Auftrag verbraucht (WM8-69): liegen
        // lassen; nach dem Limit stößt der Koordinator die Zustellung an.
        if let message = ChatsSendReadinessGuard.usageLimitMessage(session.blockingUsageLimit(in: workspace.sessions)) {
            store.markFailed(id: reserved.id, error: message, retry: true)
            return
        }
        // Status erneut prüfen: zwischen Turn-Ende und Settle-Delay kann der
        // Chat schon wieder arbeiten (z. B. weil jemand direkt getippt hat).
        let coordinator = AgentSessionStatusCoordinator.shared
        let runtime = coordinator.statusStore.status(for: sessionID)
        let profile = controller.command.keyboardProfile
        let inputPending = coordinator.startupInputPending(sessionID)
        switch currentDecision(sessionID, controller) {
        case .deliver:
            notices.clear(sessionID)
        case .busy(let runtime):
            notices.clear(sessionID)
            store.markFailed(id: reserved.id, error: "Ziel ist \(runtime) — wartet, bis der Chat fertig ist", retry: true)
            return
        case .notReady:
            notices.clear(sessionID)
            store.markFailed(id: reserved.id, error: "Chat startet noch — Zustellung, sobald er bereit ist", retry: true)
            // Gilt der Chat schon als bereit, fehlt aber das Eingabefeld, stößt
            // kein Zustandswechsel mehr an: selbst nachsehen (WM8-100). Endet
            // spätestens mit dem Startfenster. (Meist greift schon die Prüfung
            // vor dem Reservieren oben.)
            if inputPending { retryAfterStartup(sessionID) }
            return
        case .draftPending:
            store.markFailed(id: reserved.id, error: Self.draftPendingError(controller.composerDraft), retry: true)
            hold(sessionID, reason: .textInField, profile: profile)
            return
        case .viewOpen:
            store.markFailed(id: reserved.id, error: Self.viewOpenError, retry: true)
            hold(sessionID, reason: .viewOpen, profile: profile)
            return
        }
        // Freigabe oder Dialog statt des Eingabefelds (Status hinkt hinterher):
        // nie zustellen, der Auftrag bleibt vorgemerkt (WM8-75). Das Rennen
        // „Freigabe geht in den 80 ms bis zum Enter auf“ gibt es hier nicht —
        // die Queue stellt nur an einen ruhenden Chat zu.
        if DelayedEnterGuard.approvalPending(
            status: coordinator.statusStore.status(for: sessionID),
            lifecycle: coordinator.lifecycleState(for: sessionID),
            screen: controller.sendCheckScreen().snapshot) {
            store.markFailed(id: reserved.id, error: "Freigabe oder Dialog offen — wartet, bis der Chat fertig ist", retry: true)
            return
        }

        let marked = AgentControlRequestHandler.deliveredPrompt(
            reserved.prompt, actor: "Warteschlange · \(reserved.enqueuedBy)",
            toShell: controller.command.keyboardProfile == .plainShell)
        // Ein Entwurf des Users hält die Zustellung oben an (`draftPending`,
        // bleibt in der Queue); ein vermuteter alter Rückleger wird geräumt.
        let sentAt = Date()
        let verify = PromptSubmitCheck.applies(submit: true, profile: profile, statusAtSend: runtime)
        let clearedInput = controller.sendPrompt(marked, submit: true)
        let title = session.title
        // Erst verbuchen, wenn das verzögerte Enter raus ist (WM8-75): Hält die
        // Prüfung es zurück, bleibt der Auftrag vorgemerkt statt „zugestellt“.
        Task { @MainActor [store] in
            if await AgentTerminalController.enterWasWithheld(
                sessionID: sessionID, clearedInput: clearedInput, since: sentAt) {
                store.markEnterWithheld(id: reserved.id, error: Self.withheldError, text: marked, at: sentAt)
                // Mit der ID: `chats submit` verbucht ihn dann als zugestellt (WM8-123).
                AgentTerminalRegistry.shared.controller(for: sessionID)?.claimWithheldDelivery(queuedPromptID: reserved.id)
                Logger.agentStore.notice(
                    "queue_withheld session=\(sessionID.uuidString, privacy: .public) id=\(reserved.id.uuidString, privacy: .public)")
                return
            }
            // Steht der Text nach dem Enter noch im Feld, ist er nicht zugestellt —
            // und wird auch nicht noch einmal eingefügt (WM8-100).
            if verify, await AgentControlRequestHandler.submitVerdict(sessionID) == .stuckInField {
                store.markFailed(id: reserved.id, error: Self.stuckError, retry: false)
                self.notifySenderOfStuck(reserved, targetTitle: title, targetID: sessionID)
                Logger.agentStore.notice(
                    "queue_stuck_in_field session=\(sessionID.uuidString, privacy: .public) id=\(reserved.id.uuidString, privacy: .public)")
                return
            }
            store.markDelivered(id: reserved.id)
            ChatsAuditLog.shared.append(Self.deliveryAuditEntry(for: reserved, target: title, at: Date()))
            Logger.agentStore.notice(
                "queue_delivered session=\(sessionID.uuidString, privacy: .public) id=\(reserved.id.uuidString, privacy: .public) clearedInput=\(clearedInput, privacy: .public)")
        }
    }

    // MARK: Warten wegen des Eingabefelds (WM8-123)

    private func currentDecision(_ sessionID: UUID, _ controller: AgentTerminalController) -> PromptDeliveryGate.Decision {
        let coordinator = AgentSessionStatusCoordinator.shared
        return Self.gateDecision(
            draft: controller.composerDraft,
            reading: controller.composerFieldForSendCheck(),
            profile: controller.command.keyboardProfile,
            runtime: coordinator.statusStore.status(for: sessionID),
            lifecycle: coordinator.lifecycleState(for: sessionID),
            inputPending: coordinator.startupInputPending(sessionID))
    }

    /// Meldung wartet wegen Text im Feld oder einer Ansicht: Hinweis am Chat
    /// zeigen und in 30 s wieder nachsehen.
    private func hold(_ sessionID: UUID, reason: QueueHoldNotices.Reason, profile: TerminalKeyboardProfile) {
        notices.set(.init(count: store.openPrompts(for: sessionID).count, reason: reason,
                          fieldReadable: Self.fieldReadable(profile)), for: sessionID)
        scheduleHeldRetry(sessionID, after: Self.heldRetrySeconds)
    }

    /// Das Feld liest die App nur bei Claude-Chats ab (`composerFieldForSendCheck`).
    nonisolated static func fieldReadable(_ profile: TerminalKeyboardProfile) -> Bool {
        profile == .claudeCodeChat
    }

    /// Die Warteschlange des Chats hat sich außerhalb der Zustellung geändert
    /// (`chats dequeue`): Hinweis sofort nachführen statt erst beim nächsten
    /// Versuch in bis zu 30 s. Ist nichts mehr offen, verschwindet die Pille
    /// und der geplante Versuch entfällt. Nur Speicher und ein Lesen der Queue.
    func noteQueueChanged(_ sessionID: UUID) {
        guard let current = notices.notices[sessionID] else { return }
        let next = QueueHoldNotices.notice(current, afterOpenCount: store.openPrompts(for: sessionID).count)
        notices.set(next, for: sessionID)
        if next == nil { heldRetryToken[sessionID] = nil }
    }

    private func scheduleHeldRetry(_ sessionID: UUID, after seconds: TimeInterval) {
        let token = UUID()
        heldRetryToken[sessionID] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.heldRetryToken[sessionID] == token else { return }
            self.retryHeld(sessionID)
        }
    }

    /// Neuer Versuch für eine wartende Meldung. Sieht erst nach, ohne zu
    /// reservieren: Wartet sie weiter, wird die Queue-Datei nicht geschrieben,
    /// nur der Hinweis nachgeführt. Arbeitet der Chat oder startet er noch,
    /// übernehmen die üblichen Anstöße (Turn-Ende, bereit).
    private func retryHeld(_ sessionID: UUID) {
        heldRetryToken[sessionID] = nil
        let controller = AgentTerminalRegistry.shared.controller(for: sessionID)
        let running = controller?.isRunning == true
        let decision = running ? controller.map { currentDecision(sessionID, $0) } : nil
        switch Self.retryAction(openCount: store.openPrompts(for: sessionID).count, decision: decision) {
        case .deliver:
            deliverNow(for: sessionID)
        case .hold(let reason):
            hold(sessionID, reason: reason, profile: controller?.command.keyboardProfile ?? .claudeCodeChat)
        case .stop:
            notices.clear(sessionID)
        }
    }

    enum HeldRetryAction: Equatable {
        case deliver
        case hold(QueueHoldNotices.Reason)
        /// Nichts mehr offen, kein Prozess, oder der Chat arbeitet bzw.
        /// startet: Dann übernehmen die üblichen Anstöße.
        case stop
    }

    /// Pur: Was ein neuer Versuch für eine wartende Meldung tut. `decision`
    /// ist `nil` ohne laufenden Prozess.
    nonisolated static func retryAction(openCount: Int, decision: PromptDeliveryGate.Decision?) -> HeldRetryAction {
        guard openCount > 0, let decision else { return .stop }
        switch decision {
        case .deliver: return .deliver
        case .draftPending: return .hold(.textInField)
        case .viewOpen: return .hold(.viewOpen)
        case .busy, .notReady: return .stop
        }
    }

    /// Das Terminal steht wieder unten (Scroll-Ereignis der Ansicht): Jetzt ist
    /// ein leeres Feld ablesbar. Wartet eine Meldung, gleich nachsehen statt
    /// erst nach 30 s. Höchstens einmal je Sekunde; ohne wartende Meldung nur
    /// ein Nachschlagen im Speicher.
    func noteReturnedToBottom(_ sessionID: UUID, now: Date = Date()) {
        guard notices.notices[sessionID] != nil,
              Self.returnRetryAllowed(last: lastReturnRetryAt[sessionID], now: now) else { return }
        lastReturnRetryAt[sessionID] = now
        scheduleHeldRetry(sessionID, after: settleDelay)
    }

    nonisolated static func returnRetryAllowed(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= 1
    }

    /// Entscheidung der Warteschlange aus Status, Entwurfs-Schätzung und dem
    /// am Bildschirm abgelesenen Eingabefeld. Pur und für Tests offen, damit
    /// sie genau die Zusammensetzung der Zustellung prüfen (WM8-121). Sichtbarer
    /// Text sperrt auch hochgescrollt; ein leeres Feld gibt nur unten frei
    /// (WM8-123).
    nonisolated static func gateDecision(
        draft: TerminalComposerDraftTracker,
        reading: ComposerFieldReading,
        profile: TerminalKeyboardProfile,
        runtime: AgentSessionRuntimeStatus?,
        lifecycle: AgentSessionLifecycleState?,
        inputPending: Bool
    ) -> PromptDeliveryGate.Decision {
        PromptDeliveryGate.forQueue(
            runtime: runtime,
            lifecycle: lifecycle,
            mayHaveUnsentInput: draft.mayHaveUnsentInput,
            inputPending: inputPending,
            visibleDraft: PromptSubmitCheck.visibleDraft(
                field: reading.field, profile: profile, clearsBeforeSubmit: draft.shouldClearBeforeSubmit),
            fieldVisiblyEmpty: PromptSubmitCheck.fieldVisiblyEmpty(field: reading.fieldForRelease, profile: profile),
            viewOpen: reading.openView != nil)
    }

    /// Wie oben, mit einem Feld, das unten abgelesen wurde (Tests).
    nonisolated static func gateDecision(
        draft: TerminalComposerDraftTracker,
        field: ControllerPromptField?,
        profile: TerminalKeyboardProfile,
        runtime: AgentSessionRuntimeStatus?,
        lifecycle: AgentSessionLifecycleState?,
        inputPending: Bool
    ) -> PromptDeliveryGate.Decision {
        gateDecision(draft: draft, reading: ComposerFieldReading(field: field, atBottom: true), profile: profile,
                     runtime: runtime, lifecycle: lifecycle, inputPending: inputPending)
    }

    /// Grund der Wartezeit für `chats queue`. Eingefügter Text hat einen
    /// eigenen: Er wartet nicht auf das Turn-Ende, sondern darauf, dass er
    /// abgeschickt oder gelöscht wird (WM8-121).
    nonisolated static func draftPendingError(_ draft: TerminalComposerDraftTracker) -> String {
        draft.mayHoldInsertedText ? insertedTextError : "Entwurf im Eingabefeld — wartet, bis der Chat fertig ist"
    }

    nonisolated static let viewOpenError = "Ansicht von Claude offen (Transkript, /tasks, Agent-Liste, /config …) — "
        + "wartet, bis sie geschlossen ist"

    nonisolated static let insertedTextError = "Eingefügter, nicht abgeschickter Text im Eingabefeld (Diktat ohne Senden, "
        + "„→ Jarvis“, `send --no-submit`) — wartet, bis er abgeschickt oder gelöscht ist. Ist das Feld leer, "
        + "zählt das erst, wenn das Terminal ganz unten steht; dann geht die Meldung beim nächsten Turn-Ende "
        + "oder `enqueue` raus"

    static let stuckError = "Steht im Eingabefeld, nicht abgeschickt — `chats submit` schickt ihn ab"

    nonisolated static let withheldError = "Enter zurückgehalten: Freigabe ging auf — Text steht im Feld. Nach der "
        + "Freigabe schickt `chats submit` ihn ab und verbucht ihn hier als zugestellt"

    /// Der Absender erfährt es von selbst, nicht erst über `chats queue`
    /// (Vic zu WM8-100): Hinter einem stehengebliebenen Auftrag staut sich
    /// sonst alles, ohne dass es jemand merkt. Nur an einen belegten Chat,
    /// nie an den Empfänger selbst; die Meldung selbst meldet nichts weiter.
    private func notifySenderOfStuck(_ prompt: QueuedPrompt, targetTitle: String, targetID: UUID) {
        guard let sender = Self.stuckNoticeRecipient(for: prompt, targetID: targetID) else { return }
        let notice = Self.stuckNotice(targetTitle: targetTitle, targetID: targetID)
        guard (try? store.enqueue(sessionID: sender, prompt: notice, by: "WhisperM8", verified: true)) != nil else { return }
        deliverNext(for: sender)
    }

    nonisolated static func stuckNoticeRecipient(for prompt: QueuedPrompt, targetID: UUID) -> UUID? {
        guard let sender = prompt.enqueuedBySessionID, sender != targetID else { return nil }
        return sender
    }

    nonisolated static func stuckNotice(targetTitle: String, targetID: UUID, at: Date = Date()) -> String {
        // Mit Uhrzeit: Die Meldung kann erst Tage später ankommen (Vic).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM. HH:mm"
        return "Stand \(formatter.string(from: at)): Dein vorgemerkter Auftrag an „\(targetTitle)“ steht dort im "
            + "Eingabefeld und wurde nicht abgeschickt. "
            + "Nicht noch einmal senden: `whisperm8 chats submit \(ChatsOutput.shortID(targetID))` schickt ihn ab, "
            + "`whisperm8 chats tail \(ChatsOutput.shortID(targetID))` zeigt den Stand."
    }

    /// Neuer Versuch, sobald das wartende Enter entschieden sein kann
    /// (höchstens 3 s, alle 0,5 s nachsehen; nur ein Nachschlagen im Speicher).
    private func retryAfterPendingEnter(_ sessionID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.deliverNow(for: sessionID)
        }
    }

    /// Neuer Versuch eine Sekunde später, solange das Eingabefeld nach dem
    /// Start fehlt.
    private func retryAfterStartup(_ sessionID: UUID) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(AgentSessionStatusCoordinator.startupInputPollSeconds * 1_000_000_000))
            self.deliverNow(for: sessionID)
        }
    }

    /// Audit-Eintrag der Zustellung: Absender und Verifikation stammen aus dem
    /// Moment des Einstellens (LR-CLI-011), der Kopf ist einzeilig wie bei `send`.
    nonisolated static func deliveryAuditEntry(for prompt: QueuedPrompt, target: String, at date: Date) -> ChatsAuditEntry {
        ChatsAuditEntry(
            at: date, actor: prompt.enqueuedBy, verified: prompt.enqueuedVerified,
            method: "queue-deliver",
            target: target, outcome: "ok",
            promptChars: prompt.prompt.count,
            promptHead: ChatsAuditLog.promptHead(prompt.prompt))
    }
}
