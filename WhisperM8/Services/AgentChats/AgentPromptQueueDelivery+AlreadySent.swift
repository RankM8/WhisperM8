import Foundation

// Vorgemerkter Auftrag mit einmal zurückgehaltenem Enter (WM8-123): Vor einer
// erneuten Zustellung im Transcript nachsehen, ob er schon raus ist.
//
// Der Fall: Eine Freigabe hielt das Enter zurück, der Text stand im Feld.
// Giuliano beantwortete die Freigabe mit Enter und drückte sofort ein zweites
// Enter, um den Auftrag abzuschicken. Der Status meldete da noch „wartet“, also
// galt das zweite Enter als Antwort im Dialog; der Auftrag war raus, aber nicht
// verbucht, und die Warteschlange stellte ihn beim nächsten Turn-Ende noch
// einmal zu.

extension AgentPromptQueueDelivery {
    /// Liest das Ende des Transcripts abseits des Main Threads und verbucht
    /// den Auftrag als zugestellt, wenn die letzte Nachricht des Users genau
    /// ihn enthält; sonst die normale Zustellung. Nur für Claude-Chats mit
    /// bekannter Sitzung; sonst gleich weiter wie bisher.
    func checkAlreadySent(_ prompt: QueuedPrompt, sessionID: UUID) {
        let workspace = AgentWorkspaceUIModel.shared.workspace
        guard let session = workspace.sessions.first(where: { $0.id == sessionID }),
              session.provider == .claude,
              let externalID = session.externalSessionID, !externalID.isEmpty,
              let project = workspace.projects.first(where: { $0.id == session.projectID }) else {
            deliverNow(for: sessionID, transcriptChecked: true)
            return
        }
        let path = project.path
        Task.detached(priority: .utility) { [weak self] in
            let transcript = ClaudeTranscriptReader.readTail(cwd: path, sessionID: externalID,
                                                             tailBytes: Self.alreadySentTailBytes)
            let lastUserText = Self.lastUserText(in: transcript?.messages ?? [])
            await MainActor.run { [weak self] in
                guard let self else { return }
                if Self.alreadySent(prompt: prompt.prompt, lastUserText: lastUserText),
                   self.markAlreadySent(prompt.id, sessionID: sessionID) {
                    // Der Nächste in der Schlange darf jetzt.
                    self.deliverNext(for: sessionID)
                } else {
                    self.deliverNow(for: sessionID, transcriptChecked: true)
                }
            }
        }
    }

    /// Verbucht ihn, solange er noch offen ist (ein `dequeue` dazwischen
    /// bleibt ein Storno). - Returns: verbucht?
    func markAlreadySent(_ id: UUID, sessionID: UUID) -> Bool {
        guard store.openPrompts(for: sessionID).contains(where: { $0.id == id && $0.state == .pending }) else {
            return false
        }
        store.markDelivered(id: id)
        notices.clear(sessionID)
        Logger.agentStore.notice(
            "queue_already_sent session=\(sessionID.uuidString, privacy: .public) id=\(id.uuidString, privacy: .public)")
        return true
    }

    /// Das Gesprächsende reicht: Gesucht ist nur die letzte Nachricht des Users.
    nonisolated static let alreadySentTailBytes = 256 * 1024

    /// Text der letzten echten Nachricht des Users (ohne Tool-Ergebnisse, die
    /// bei Claude ebenfalls als User-Nachricht im Transcript stehen).
    nonisolated static func lastUserText(in messages: [AgentChatMessage]) -> String? {
        for message in messages.reversed() where message.role == .user {
            let texts = message.blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    /// Pur: Ist die letzte Nachricht des Users dieser Auftrag? Sie muss die
    /// Marker-Zeile der Zustellung tragen (sonst schrieb der User selbst) und
    /// den ganzen Auftragstext enthalten.
    nonisolated static func alreadySent(prompt: String, lastUserText: String?) -> Bool {
        let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastUserText, !body.isEmpty,
              lastUserText.contains(AgentControlRequestHandler.markerPrefix) else { return false }
        return lastUserText.contains(body)
    }
}
