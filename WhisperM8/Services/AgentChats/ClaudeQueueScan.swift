import Foundation

/// Wartet in Claudes eigener Warteschlange ein Prompt des Nutzers? Gelesen aus
/// dem Transcript-Ende, das der `AgentSessionRuntimeWatcher` ohnehin liest —
/// kein zusätzliches I/O (Runde 5, R1: „Jetzt senden“).
///
/// Format (Claude Code 2.1.322): `{"type":"queue-operation","operation":…,
/// "content":…}` mit `enqueue` (hängt an), `dequeue` (nimmt das erste, ohne
/// Inhalt), `remove` (nimmt einen bestimmten, mit Inhalt; Gründe etwa
/// `absorbed_mid_turn`) und `popAll` (leert). Enqueue-Inhalte sind meist
/// Benachrichtigungen (`<task-notification>…`); eigene Prompts beginnen nicht
/// mit `<`. Claude nimmt Wartendes meist an der nächsten Tool-Grenze auf; der
/// Zustand ist oft kurz.
enum ClaudeQueueScan {
    static let marker = "\"queue-operation\""

    /// Zahl der eigenen Prompts, die nach dem Nachspielen der Operationen im
    /// Tail noch warten. Zeilen ohne Marker werden nicht geparst.
    static func pendingOwnPrompts(inTail tail: String) -> Int {
        guard tail.contains(marker) else { return 0 }
        var queue: [String?] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true) where line.contains(marker) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "queue-operation" else { continue }
            let content = object["content"] as? String
            switch object["operation"] as? String {
            case "enqueue":
                queue.append(content)
            case "dequeue":
                if !queue.isEmpty { queue.removeFirst() }
            case "remove":
                if let index = queue.firstIndex(where: { $0 == content }) {
                    queue.remove(at: index)
                } else if !queue.isEmpty, content == nil {
                    queue.removeFirst()
                }
            case "popAll":
                queue.removeAll()
            default:
                continue
            }
        }
        return queue.filter(isOwnPrompt).count
    }

    static func isOwnPrompt(_ content: String?) -> Bool {
        guard let content else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("<")
    }
}
