import Foundation

/// Eine native Nachricht einer anderen Claude-Sitzung (`SendMessage`), wie
/// Claude sie in den Verlauf des Empfängers schreibt (WM8-85).
struct ClaudePeerMessage: Equatable {
    var messageID: String
    /// Adresse des Absenders (`uds:/tmp/cc-socks/<pid>.sock`).
    var from: String
    /// Name, den der Absender selbst angibt — nicht vertrauenswürdig.
    var name: String?
    /// PID, die Claude beim Empfang geprüft hat.
    var verifiedPeerPid: Int?
    var body: String
    var timestamp: Date?
}

/// Native Nachrichten aus dem Transcript-Ende, das der Watcher ohnehin liest
/// (kein zusätzliches I/O). Format, gemessen an Claude Code 2.1.325: eine
/// `user`-Zeile mit `isMeta` und `"origin":{"kind":"peer","from":…,
/// "verifiedPeerPid":…,"msg_id":…,"name":…,"body":…}`. Zeilen ohne diesen
/// Marker werden nicht geparst.
enum ClaudePeerMessageScan {
    static let marker = "\"kind\":\"peer\""

    static func messages(inTail tail: String) -> [ClaudePeerMessage] {
        guard tail.contains(marker) else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [ClaudePeerMessage] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) where line.contains(marker) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "user",
                  let origin = object["origin"] as? [String: Any],
                  origin["kind"] as? String == "peer",
                  let messageID = origin["msg_id"] as? String,
                  let from = origin["from"] as? String else { continue }
            result.append(ClaudePeerMessage(
                messageID: messageID,
                from: from,
                name: origin["name"] as? String,
                verifiedPeerPid: origin["verifiedPeerPid"] as? Int,
                body: origin["body"] as? String ?? "",
                timestamp: (object["timestamp"] as? String).flatMap(formatter.date(from:))))
        }
        return result
    }

    /// Neue Nachrichten seit dem letzten Blick. Beim ersten Blick (`seen` ist
    /// `nil`) wird nur gemerkt, nichts gemeldet: Nach einem App-Start stünde
    /// sonst alles im Tail noch einmal im Audit.
    static func newMessages(_ messages: [ClaudePeerMessage], seen: Set<String>?) -> (new: [ClaudePeerMessage], seen: Set<String>) {
        let ids = Set(messages.map(\.messageID))
        guard let seen else { return ([], ids) }
        let fresh = messages.filter { !seen.contains($0.messageID) }
        // Nur merken, was noch im Tail steht: hält die Menge klein.
        return (fresh, ids)
    }

    /// Audit-Eintrag: wer wem nativ geschrieben hat.
    static func auditEntry(_ message: ClaudePeerMessage, target: String, now: Date = Date()) -> ChatsAuditEntry {
        let sender = message.name.map { "\($0) (\(message.from))" } ?? message.from
        return ChatsAuditEntry(
            at: message.timestamp ?? now, actor: "nativ · \(sender)",
            verified: message.verifiedPeerPid != nil, method: "native-message",
            target: target, outcome: "ok",
            promptChars: message.body.count, promptHead: ChatsAuditLog.promptHead(message.body))
    }
}

extension AgentSessionStatusCoordinator {
    /// Native Nachrichten gehen an `chats send` vorbei; damit Giuliano
    /// trotzdem sieht, wer wem was geschrieben hat, landen sie im Audit
    /// (`chats audit`, WM8-85).
    @MainActor
    static func auditPeerMessages(sessionID: UUID, messages: [ClaudePeerMessage]) {
        let workspace = AgentWorkspaceUIModel.shared.workspace
        let target: String = {
            guard let session = workspace.sessions.first(where: { $0.id == sessionID }) else { return sessionID.uuidString }
            let project = workspace.projects.first(where: { $0.id == session.projectID })?.name ?? "?"
            return "\(project)/\(session.title)"
        }()
        for message in messages {
            ChatsAuditLog.shared.append(ClaudePeerMessageScan.auditEntry(message, target: target))
        }
    }
}
