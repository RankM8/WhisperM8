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
            let lastUser = Self.lastUserMessage(in: transcript?.messages ?? [])
            await MainActor.run { [weak self] in
                guard let self else { return }
                if Self.alreadySent(withheldText: prompt.withheldText, withheldAt: prompt.withheldAt,
                                    lastUser: lastUser),
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

    /// Text und Zeitpunkt der letzten echten Nachricht des Users (ohne
    /// Tool-Ergebnisse, die bei Claude ebenfalls als User-Nachricht im
    /// Transcript stehen).
    nonisolated static func lastUserMessage(in messages: [AgentChatMessage]) -> (text: String, at: Date?)? {
        for message in messages.reversed() where message.role == .user {
            let texts = message.blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }
            if !texts.isEmpty { return (texts.joined(separator: "\n"), message.timestamp) }
        }
        return nil
    }

    /// Pur: Ist die letzte Nachricht des Users genau dieser Auftrag? Sie muss
    /// nach dem Einfügen geschrieben sein und mit genau dem eingefügten Text
    /// beginnen (Marker-Zeile mit Absender und Uhrzeit plus Auftrag; Giuliano
    /// darf vor dem Enter etwas angehängt haben). Ohne gemerkten Text oder
    /// Zeitpunkt, oder ohne Zeitstempel im Transcript: nicht gesendet. Im
    /// Zweifel kommt der Auftrag lieber noch einmal, als nie anzukommen.
    nonisolated static func alreadySent(withheldText: String?, withheldAt: Date?,
                                        lastUser: (text: String, at: Date?)?) -> Bool {
        guard let withheldText, let withheldAt, let lastUser, let writtenAt = lastUser.at,
              writtenAt >= withheldAt else { return false }
        let expected = normalized(withheldText)
        guard expected.hasPrefix(AgentControlRequestHandler.markerPrefix), expected.count > 0 else { return false }
        return normalized(lastUser.text).hasPrefix(expected)
    }

    /// Zeilenenden vereinheitlichen, Leerraum am Rand weg.
    nonisolated static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
