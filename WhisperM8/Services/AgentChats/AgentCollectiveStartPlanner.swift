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
    /// Chat, der sie führt. Zuerst zählt der Beleg aus der eigenen
    /// Hook-Event-Datei (`AgentSessionOwnershipEvidence`, nur bei echter
    /// Dopplung gefragt): angelegt vor nur genutzt vor keinem Beleg. Erst
    /// danach von Hand angelegt, sonst der älteste. Bewusst nicht der zuletzt
    /// aktive — `lastActivityAt` setzt jede Änderung am Eintrag, auch der
    /// Start des falsch gebundenen Chats. Chats ohne ID (noch ungebunden)
    /// starten immer.
    static func plan(
        _ ids: [UUID],
        sessions: [AgentChatSession],
        evidence: (_ chat: UUID, _ sessionID: String) -> AgentSessionOwnershipEvidence = { _, _ in .none }
    ) -> Plan {
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ id: UUID) -> String? {
            guard let session = byID[id],
                  let external = session.externalSessionID?.lowercased(), !external.isEmpty else { return nil }
            return "\(session.provider.rawValue):\(external)"
        }
        var groups: [String: [AgentChatSession]] = [:]
        for id in ids {
            guard let key = key(id), let session = byID[id],
                  groups[key]?.contains(where: { $0.id == id }) != true else { continue }
            groups[key, default: []].append(session)
        }
        var winner: [String: UUID] = [:]
        for (key, members) in groups {
            guard members.count > 1 else {
                winner[key] = members.first?.id
                continue
            }
            let proof = Dictionary(uniqueKeysWithValues: members.map { member in
                (member.id, evidence(member.id, member.externalSessionID ?? ""))
            })
            winner[key] = members.sorted { lhs, rhs in
                let left = proof[lhs.id] ?? .none, right = proof[rhs.id] ?? .none
                if left != right { return left > right }
                return AgentSessionDuplicateGroup.keeperPrecedes(lhs, rhs)
            }.first?.id
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

/// Hinweis am übersprungenen Chat (Vic): Statt still gestoppt zu bleiben,
/// zeigt er beim Öffnen, welcher Chat seine Unterhaltung führt. Nur für diesen
/// App-Lauf, angezeigt einmal im Meldungsbanner der Detailansicht.
@MainActor
final class AgentCollectiveStartNotices {
    static let shared = AgentCollectiveStartNotices()

    private var keeperTitles: [UUID: String] = [:]

    func note(skipped: UUID, keeperTitle: String) {
        keeperTitles[skipped] = keeperTitle
    }

    /// Die Meldung für den Chat, einmalig (danach ist sie verbraucht).
    func takeMessage(for chat: UUID) -> String? {
        guard let keeper = keeperTitles.removeValue(forKey: chat) else { return nil }
        return Self.message(keeperTitle: keeper)
    }

    nonisolated static func message(keeperTitle: String) -> String {
        String(localized: "Not resumed: this conversation continues in the chat “\(keeperTitle)”. Both chats were bound to the same session, and only one may run it.")
    }
}
