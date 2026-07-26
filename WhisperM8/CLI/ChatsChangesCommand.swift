import Foundation

// MARK: - `chats since` und `chats watch` (wm8.changes/1)

/// Cursorbasierte Änderungsabfrage und Streaming.
///
/// Beide lesen dasselbe Journal — `watch` ist ausdrücklich KEIN zweiter
/// Ereignisweg, sondern eine dünne Sicht darauf. Damit kann ein Stream
/// abbrechen, ohne dass Ereignisse verloren gehen: Der Cursor holt sie nach.
enum ChatsChangesCommand {
    static let schema = "wm8.changes/1"

    // MARK: since

    static func since(_ arguments: [String]) -> Int32 {
        var cursor: String?
        var limit = 64
        var json = true
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--cursor":
                index += 1
                guard index < arguments.count else {
                    CLIIO.err("--cursor erwartet einen Wert (aus `snapshot` oder einem früheren `since`).")
                    return ChatsCLIExit.usage
                }
                cursor = arguments[index]
            case "--limit":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    CLIIO.err("--limit erwartet eine Ganzzahl > 0.")
                    return ChatsCLIExit.usage
                }
                limit = value
            case "--json": json = true
            case "--text": json = false
            default:
                CLIIO.err("Unbekannte Option: \(arg)")
                return ChatsCLIExit.usage
            }
            index += 1
        }

        let result = ChatsStatusJournal.changes(since: cursor, limit: limit)
        let now = Date()

        if json {
            var payload: [String: Any] = [
                "schema": schema,
                "asOf": ChatsOutput.iso(now),
                "gap": result.gap,
                "hasMore": result.hasMore,
                "changes": result.entries.map(changeJSON),
            ]
            if let from = cursor { payload["fromCursor"] = from }
            if let next = result.cursor { payload["cursor"] = next }
            if result.gap {
                // Der Aufrufer MUSS wissen, dass zwischen seinem Cursor und
                // jetzt Ereignisse fehlen — sonst liest er die leere Liste als
                // „nichts passiert".
                payload["recovery"] = [
                    "reason": "cursorExpired",
                    "action": "snapshot",
                    "hint": "Cursor stammt aus einer älteren Journal-Generation — `chats snapshot` ziehen und neu ansetzen.",
                ]
            }
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else {
            if result.gap { CLIIO.out("⚠︎ Cursor abgelaufen — `chats snapshot` ziehen.") }
            for entry in result.entries {
                CLIIO.out("\(entry.seq)  \(ChatsOutput.shortID(entry.sessionID))  "
                          + "\(entry.from ?? "–") → \(entry.to ?? "–")  (\(entry.signal), \(entry.source))")
            }
            if result.entries.isEmpty, !result.gap { CLIIO.out("Keine Änderungen.") }
        }
        return ChatsCLIExit.ok
    }

    // MARK: watch

    /// Langlebiger NDJSON-Stream: eine Zeile pro Ereignis, jede mit Cursor.
    /// Für Sidecars und Skripte — ein LLM sollte `since` im Long-Poll nutzen.
    static func watch(_ arguments: [String]) -> Int32 {
        var cursor: String?
        var intervalSeconds: Double = 2
        var maxSeconds: Double = 0   // 0 = unbegrenzt
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--cursor":
                index += 1
                guard index < arguments.count else {
                    CLIIO.err("--cursor erwartet einen Wert.")
                    return ChatsCLIExit.usage
                }
                cursor = arguments[index]
            case "--interval":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value >= 0.5 else {
                    CLIIO.err("--interval erwartet Sekunden >= 0.5.")
                    return ChatsCLIExit.usage
                }
                intervalSeconds = value
            case "--timeout":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    CLIIO.err("--timeout erwartet Sekunden > 0.")
                    return ChatsCLIExit.usage
                }
                maxSeconds = value
            default:
                CLIIO.err("Unbekannte Option: \(arg)")
                return ChatsCLIExit.usage
            }
            index += 1
        }

        // Ohne Cursor ab jetzt beginnen — und das kenntlich machen, damit
        // niemand die erste leere Phase als „nichts passiert" liest.
        var position = cursor ?? ChatsStatusJournal.currentCursor()
        let startedAt = Date()
        CLIIO.out(ChatsOutput.encodeJSON([
            "schema": schema,
            "event": "started",
            "startedAt": ChatsOutput.iso(startedAt),
            "cursor": position ?? NSNull(),
            "resumed": cursor != nil,
        ]))

        while true {
            let result = ChatsStatusJournal.changes(since: position, limit: 128)
            if result.gap {
                CLIIO.out(ChatsOutput.encodeJSON([
                    "schema": schema, "event": "gap", "action": "snapshot",
                ]))
                return ChatsCLIExit.conflict
            }
            for entry in result.entries {
                var line = changeJSON(entry)
                line["schema"] = schema
                line["cursor"] = ChatsStatusJournal.cursor(journalId: entry.journalId, seq: entry.seq)
                CLIIO.out(ChatsOutput.encodeJSON(line))
            }
            if let next = result.cursor { position = next }
            if maxSeconds > 0, Date().timeIntervalSince(startedAt) >= maxSeconds {
                CLIIO.out(ChatsOutput.encodeJSON([
                    "schema": schema, "event": "timeout", "cursor": position ?? NSNull(),
                ]))
                return ChatsCLIExit.ok
            }
            Thread.sleep(forTimeInterval: intervalSeconds)
        }
    }

    // MARK: Gemeinsam

    static func changeJSON(_ entry: ChatsStatusJournalEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "seq": entry.seq,
            "at": ChatsOutput.iso(entry.at),
            "ref": ChatsOutput.shortID(entry.sessionID),
            "sessionID": entry.sessionID.uuidString,
            "kind": "conversation",
            "signal": entry.signal,
            "evidence": entry.source == "hook" ? "observed" : "inferred",
        ]
        if let from = entry.from { dict["from"] = from }
        if let to = entry.to { dict["to"] = to }
        return dict
    }
}
