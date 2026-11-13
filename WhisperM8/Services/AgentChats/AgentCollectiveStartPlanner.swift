import Foundation

/// Sammel-Starts: viele Chats auf einmal fortsetzen (Absturz-Wiederaufnahme,
/// später die Rückfälle beim „Neustart ohne Chatverlust“).
///
/// Nie zwei Prozesse auf einer Sitzung: Tragen zwei vorgemerkte Chats
/// dieselbe externe Sitzung — das gibt es nur nach einer Fehlbindung (Befund
/// 13.11.2026, im echten Workspace z. B. ein laufender und ein geschlossener
/// Chat auf derselben ID) —, startet höchstens einer. Die Registry-Sperre
/// sähe den anderen beim gleichzeitigen Start noch nicht, und eine Sperre im
/// Startpfad träfe zufällig den, der zuerst angezeigt wird; für Codex gibt
/// es dort gar keine. Hier wird vorher entschieden, nach derselben Regel wie
/// `whisperm8 chats duplicates` (`AgentSessionDuplicateGroup.keeperPrecedes`).
enum AgentCollectiveStartPlanner {
    struct Plan: Equatable {
        /// In der Reihenfolge der Eingabe.
        var start: [UUID]
        /// Nicht gestartet, weil ein anderer Chat dieselbe Sitzung führt.
        var skipped: [UUID]
        /// Übersprungener Chat → der Chat, der die Sitzung stattdessen führt.
        var keeperOf: [UUID: UUID] = [:]
    }

    /// Je Sitzung (Provider + ID, ohne Groß-/Kleinschreibung) startet nur der
    /// Chat, der sie führt: von Hand angelegt, sonst der älteste. Bewusst nicht
    /// der zuletzt aktive — `lastActivityAt` setzt jede Änderung am Eintrag,
    /// auch der Start des falsch gebundenen Chats. Chats ohne ID (noch
    /// ungebunden) starten immer.
    static func plan(_ ids: [UUID], sessions: [AgentChatSession]) -> Plan {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ id: UUID) -> String? {
            guard let session = byID[id],
                  let external = session.externalSessionID?.lowercased(), !external.isEmpty else { return nil }
            return "\(session.provider.rawValue):\(external)"
        }
        var winner: [String: UUID] = [:]
        for id in ids {
            guard let key = key(id), let candidate = byID[id] else { continue }
            if let current = winner[key].flatMap({ byID[$0] }),
               !AgentSessionDuplicateGroup.keeperPrecedes(candidate, current) {
                continue
            }
            winner[key] = id
        }
        var plan = Plan(start: [], skipped: [])
        for id in ids {
            if let key = key(id), let keeper = winner[key], keeper != id {
                plan.skipped.append(id)
                plan.keeperOf[id] = keeper
            } else {
                plan.start.append(id)
            }
        }
        return plan
    }
}
