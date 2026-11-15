import Foundation

// `queue.enqueue` und `queue.cancel` — aus dem Request-Handler ausgelagert
// (Größen-Grenze, WM8-100).

extension AgentControlRequestHandler {
    /// Längstens so lange wartet `enqueue` auf das Ergebnis einer sofortigen
    /// Zustellung (Nachsehen nach dem Enter: höchstens 4 s).
    static let enqueueSettleSeconds: TimeInterval = 6

    // MARK: queue.enqueue / queue.cancel

    /// Folgeaufträge vormerken und stornieren. Das LESEN der Warteschlange
    /// läuft bewusst nicht über den Socket — die CLI liest die Queue-Datei
    /// direkt, damit `chats queue` auch bei geschlossener App funktioniert.
    func queueMutation(_ request: ChatsControlRequest) async -> ChatsControlResponse {
        guard let targetString = request.params["targetSessionID"]?.stringValue,
              let targetID = UUID(uuidString: targetString) else {
            return .failure(requestID: request.requestID, code: .invalid, message: "targetSessionID fehlt/ungültig")
        }
        let store = AgentPromptQueueStore.shared
        let actorLabel = await auditActorLabel(request.actor)

        if request.method == "queue.cancel" {
            let ids = request.params["ids"]?.arrayValue?.compactMap { $0.stringValue }
                .compactMap(UUID.init(uuidString:))
            let cancelled = store.cancel(sessionID: targetID, ids: ids.map(Set.init))
            await audit(request.actor, method: "queue-cancel", target: await sessionLabel(targetID),
                        outcome: "ok", prompt: nil)
            return .success(requestID: request.requestID, result: .object([
                "ok": .bool(true),
                "cancelled": .number(Double(cancelled.count)),
                // Je Auftrag ID und Textanfang: Wer storniert, sieht, was (WM8-64).
                "items": .array(cancelled.map { prompt in
                    .object([
                        "id": .string(prompt.id.uuidString),
                        "head": .string(ChatsQueueSupport.head(of: prompt.prompt)),
                    ])
                }),
                "remaining": .number(Double(store.openPrompts(for: targetID).count)),
            ]))
        }

        guard let prompt = request.params["prompt"]?.stringValue,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(requestID: request.requestID, code: .invalid, message: "prompt fehlt/leer")
        }

        // Dieselben Grundregeln wie `send`: kein Selbst-Auftrag, kein Ziel im
        // Archiv. Der Status-Guard entfällt bewusst — ein Chat, der ARBEITET,
        // ist genau der Grund, warum es diesen Befehl gibt.
        let actorID = request.actor.sessionID.flatMap(UUID.init(uuidString:))
        if let actorID, actorID == targetID {
            return .failure(requestID: request.requestID, code: .selfSend,
                            message: "An sich selbst kann kein Folgeauftrag vorgemerkt werden")
        }
        let valid: Bool = await MainActor.run {
            AgentWorkspaceUIModel.shared.workspace.sessions
                .contains { $0.id == targetID && $0.status != .archived }
        }
        guard valid else {
            return .failure(requestID: request.requestID, code: .notFound,
                            message: "Session nicht gefunden oder archiviert")
        }

        // Hat der Client schon aufgegeben (MainActor hing), nicht mehr
        // vormerken: Seine Wiederholung käme sonst doppelt an (WM8-85).
        if request.isExpired() {
            await audit(request.actor, method: "queue-enqueue", target: await sessionLabel(targetID),
                        outcome: "expired", prompt: prompt)
            return Self.expiredResponse(request)
        }
        let enqueuedVerified = actorID.map {
            AgentSessionTokenRegistry.shared.verify(sessionID: $0, token: request.actor.token)
        } ?? false
        let entry: QueuedPrompt
        do {
            entry = try store.enqueue(sessionID: targetID, prompt: prompt, by: actorLabel, verified: enqueuedVerified,
                                      bySession: enqueuedVerified ? actorID : nil)
        } catch {
            // Nicht gesichert → kein Erfolg melden (LR-AK-018).
            await audit(request.actor, method: "queue-enqueue", target: await sessionLabel(targetID),
                        outcome: "failed", prompt: prompt)
            return .failure(requestID: request.requestID, code: .internalError,
                            message: "Folgeauftrag konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
        let open = store.openPrompts(for: targetID)
        let position = (open.firstIndex { $0.id == entry.id }).map { $0 + 1 } ?? open.count

        // Wartet das Ziel gerade ohnehin, kann der Auftrag sofort laufen —
        // sonst läge er bis zum nächsten Turn-Ende brach, das nie kommt.
        let runtime = await MainActor.run {
            AgentSessionStatusCoordinator.shared.statusStore.status(for: targetID)
        }
        var deliveredNow = false
        var stuckInField = false
        if runtime == .idle || runtime == nil {
            await MainActor.run { AgentPromptQueueDelivery.shared.deliverNow(for: targetID) }
            // Verbucht wird erst nach dem Nachsehen (WM8-75, WM8-100): kurz
            // abwarten, sonst hieße ein laufendes Zustellen „vorgemerkt“.
            for _ in 0..<Int(Self.enqueueSettleSeconds / 0.1) {
                guard store.all().first(where: { $0.id == entry.id })?.state == .delivering else { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let settled = store.all().first { $0.id == entry.id }
            deliveredNow = settled?.state == .delivered
            stuckInField = settled?.state == .failed && settled?.lastError == AgentPromptQueueDelivery.stuckError
        }

        await audit(request.actor, method: "queue-enqueue", target: await sessionLabel(targetID),
                    outcome: "ok", prompt: prompt)
        return .success(requestID: request.requestID, result: .object([
            "ok": true,
            "id": entry.id.uuidString,
            "position": position,
            "queued": store.openPrompts(for: targetID).count,
            "deliveredImmediately": deliveredNow,
            "stuckInField": stuckInField,
            "runtimeStatus": runtime?.rawValue ?? "unknown",
            "target": ["id": targetID.uuidString],
        ]))
    }
}
