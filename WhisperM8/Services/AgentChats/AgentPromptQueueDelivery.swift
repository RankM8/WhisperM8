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
        // Status erneut prüfen: zwischen Turn-Ende und Settle-Delay kann der
        // Chat schon wieder arbeiten (z. B. weil jemand direkt getippt hat).
        let runtime = AgentSessionStatusCoordinator.shared.statusStore.status(for: sessionID)
        if let runtime, runtime != .idle {
            store.markFailed(id: reserved.id, error: "Ziel ist \(runtime.rawValue) — wartet auf nächstes Turn-Ende", retry: true)
            return
        }

        let marked = AgentControlRequestHandler.markedPrompt(
            reserved.prompt, actor: "Warteschlange · \(reserved.enqueuedBy)")
        // Zustell-Token VOR dem Paste — gleicher Wiedervorlage-Schutz wie in
        // der Send-Pipeline (UserPromptSubmit-Guard konsumiert es).
        SendDeliveryTokenStore().stage(promptText: marked)
        controller.sendPrompt(marked, submit: true)
        store.markDelivered(id: reserved.id)

        ChatsAuditLog.shared.append(ChatsAuditEntry(
            at: Date(), actor: reserved.enqueuedBy, verified: true,
            method: "queue-deliver",
            target: "\(session.title)", outcome: "ok",
            promptChars: reserved.prompt.count,
            promptHead: String(reserved.prompt.prefix(80))))

        Logger.agentStore.notice(
            "queue_delivered session=\(sessionID.uuidString, privacy: .public) id=\(reserved.id.uuidString, privacy: .public)")
    }
}
