import Foundation

/// `whisperm8 chats duplicates`: Chats, die dieselbe externe Sitzung tragen.
/// Nur Anzeige mit Vorschlag — archiviert wird nichts automatisch.
enum ChatsDuplicatesCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        guard arguments.allSatisfy({ $0 == "--json" }) else {
            CLIIO.err("Usage: whisperm8 chats duplicates [--json]")
            return ChatsCLIExit.usage
        }
        // Dieselbe Ordnung wie die Wiederaufnahme: Beleg aus der Hook-Event-Datei zuerst.
        let hookPaths = ClaudeHookPaths()
        let groups = AgentSessionDuplicateGroup.groups(
            in: ChatsWorkspaceReader().load().workspace,
            evidence: { AgentSessionOwnershipEvidence.live(for: $0, hookPaths: hookPaths) })
        if json {
            let payload: [[String: Any]] = groups.map { group in
                [
                    "externalSessionID": group.externalSessionID,
                    "keep": ["id": group.keeper.id.uuidString, "title": group.keeper.title],
                    "archiveSuggestions": group.duplicates.map { ["id": $0.id.uuidString, "title": $0.title] },
                ]
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
            CLIIO.out(String(decoding: data, as: UTF8.self))
            return 0
        }
        guard !groups.isEmpty else {
            CLIIO.out("Keine Doppel: jede externe Sitzung gehört genau einem Chat.")
            return 0
        }
        for group in groups {
            CLIIO.out("Sitzung \(group.externalSessionID)")
            CLIIO.out("  behalten:   \(short(group.keeper.id)) \(group.keeper.title)")
            for duplicate in group.duplicates {
                CLIIO.out("  Vorschlag:  whisperm8 chats archive \(short(duplicate.id))   # \(duplicate.title)")
            }
        }
        return 0
    }

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}
