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

    private let store: AgentPromptQueueStore
    /// Kurze Wartezeit zwischen Turn-Ende und Paste: die TUI muss ihren
    /// Prompt wieder anzeigen, sonst landet der Text im Nirgendwo.
    private let settleDelay: TimeInterval

    init(store: AgentPromptQueueStore = .shared, settleDelay: TimeInterval = 0.6) {
        self.store = store
        self.settleDelay = settleDelay
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
    func deliverNow(for sessionID: UUID) {
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
        switch PromptDeliveryGate.forQueue(
            runtime: coordinator.statusStore.status(for: sessionID),
            lifecycle: coordinator.lifecycleState(for: sessionID),
            mayHaveUnsentInput: controller.composerDraft.mayHaveUnsentInput
        ) {
        case .deliver:
            break
        case .busy(let runtime):
            store.markFailed(id: reserved.id, error: "Ziel ist \(runtime) — wartet, bis der Chat fertig ist", retry: true)
            return
        case .notReady:
            store.markFailed(id: reserved.id, error: "Chat startet noch — Zustellung, sobald er bereit ist", retry: true)
            return
        case .draftPending:
            store.markFailed(id: reserved.id, error: "Entwurf im Eingabefeld — wartet, bis der Chat fertig ist", retry: true)
            return
        }
        // Freigabe oder Dialog statt des Eingabefelds (Status hinkt hinterher):
        // nie zustellen, der Auftrag bleibt vorgemerkt (WM8-75). Das Rennen
        // „Freigabe geht in den 80 ms bis zum Enter auf“ gibt es hier nicht —
        // die Queue stellt nur an einen ruhenden Chat zu.
        if DelayedEnterGuard.approvalPending(
            status: coordinator.statusStore.status(for: sessionID),
            lifecycle: coordinator.lifecycleState(for: sessionID),
            screen: controller.controllerScreenSnapshot()) {
            store.markFailed(id: reserved.id, error: "Freigabe oder Dialog offen — wartet, bis der Chat fertig ist", retry: true)
            return
        }

        let marked = AgentControlRequestHandler.deliveredPrompt(
            reserved.prompt, actor: "Warteschlange · \(reserved.enqueuedBy)",
            toShell: controller.command.keyboardProfile == .plainShell)
        // Ein Entwurf des Users hält die Zustellung oben an (`draftPending`,
        // bleibt in der Queue); ein vermuteter alter Rückleger wird geräumt.
        let sentAt = Date()
        let clearedInput = controller.sendPrompt(marked, submit: true)
        let title = session.title
        // Erst verbuchen, wenn das verzögerte Enter raus ist (WM8-75): Hält die
        // Prüfung es zurück, bleibt der Auftrag vorgemerkt statt „zugestellt“.
        Task { @MainActor [store] in
            if await AgentTerminalController.enterWasWithheld(
                sessionID: sessionID, clearedInput: clearedInput, since: sentAt) {
                store.markFailed(id: reserved.id, error: "Enter zurückgehalten: Freigabe ging auf — Text steht im Feld", retry: true)
                Logger.agentStore.notice(
                    "queue_withheld session=\(sessionID.uuidString, privacy: .public) id=\(reserved.id.uuidString, privacy: .public)")
                return
            }
            store.markDelivered(id: reserved.id)
            ChatsAuditLog.shared.append(Self.deliveryAuditEntry(for: reserved, target: title, at: Date()))
            Logger.agentStore.notice(
                "queue_delivered session=\(sessionID.uuidString, privacy: .public) id=\(reserved.id.uuidString, privacy: .public) clearedInput=\(clearedInput, privacy: .public)")
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
