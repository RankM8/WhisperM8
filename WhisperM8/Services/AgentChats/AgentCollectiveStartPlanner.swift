import Foundation

/// Sammel-Starts: viele Chats auf einmal fortsetzen (Absturz-Wiederaufnahme,
/// später die Rückfälle beim „Neustart ohne Chatverlust“).
///
/// Nie zwei Prozesse auf einer Sitzung: Tragen zwei vorgemerkte Chats
/// dieselbe externe Sitzung — das gibt es nur nach einer Fehlbindung (Befund
/// 13.11.2026, im echten Workspace z. B. ein laufender und ein geschlossener
/// Chat auf derselben ID) —, startet höchstens einer. Die Registry-Sperre
/// sähe den anderen beim gleichzeitigen Start noch nicht; die Reservierung
/// (`ClaudeSessionLaunchReservations`) würde zwar den zweiten abweisen, aber
/// zufällig den, der zuerst angezeigt wird. Hier wird vorher entschieden.
enum AgentCollectiveStartPlanner {
    struct Plan: Equatable {
        /// In der Reihenfolge der Eingabe.
        var start: [UUID]
        /// Nicht gestartet, weil ein anderer Chat dieselbe Sitzung führt.
        var skipped: [UUID]
    }

    /// Je Sitzung (Provider + ID, ohne Groß-/Kleinschreibung) bleibt der zuletzt
    /// aktive Chat — der, mit dem gearbeitet wurde; bei Gleichstand der erste.
    /// Chats ohne ID (noch ungebunden) starten immer.
    static func plan(_ ids: [UUID], sessions: [AgentChatSession]) -> Plan {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ id: UUID) -> String? {
            guard let session = byID[id],
                  let external = session.externalSessionID?.lowercased(), !external.isEmpty else { return nil }
            return "\(session.provider.rawValue):\(external)"
        }
        var winner: [String: UUID] = [:]
        for id in ids {
            guard let key = key(id) else { continue }
            if let current = winner[key],
               let held = byID[current]?.lastActivityAt, let candidate = byID[id]?.lastActivityAt,
               candidate <= held {
                continue
            }
            winner[key] = id
        }
        var plan = Plan(start: [], skipped: [])
        for id in ids {
            if let key = key(id), winner[key] != id {
                plan.skipped.append(id)
            } else {
                plan.start.append(id)
            }
        }
        return plan
    }
}
