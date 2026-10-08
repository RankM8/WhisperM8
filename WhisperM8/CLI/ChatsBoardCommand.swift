import Foundation

// MARK: - `chats board` (wm8.board/1)

/// Jarvis-Board: Lesen direkt von Disk (App optional, wie die übrigen
/// Lese-Befehle), Handeln über den Control-Socket an die App, die einziger
/// Schreiber ist. Der JSON-Vertrag wird von der Claude-Code-Mod konsumiert —
/// Felder nur ergänzen, nie umbenennen.
enum ChatsBoardInvocation: Equatable {
    case read(ChatsBoardReadOptions)
    case set(ref: String, patch: JarvisBoardPatch, json: Bool)
    case remove(ref: String, json: Bool)
    case clear(json: Bool)
    case activate(json: Bool)
    case deactivate(json: Bool)
}

struct ChatsBoardReadOptions: Equatable {
    /// `@self` (Default), Voll-UUID oder Session-Ref.
    var owner = "@self"
    var all = false
    var json = false
}

enum ChatsBoardParser {
    typealias ParseError = AgentCLIParser.ParseError

    static func parse(_ arguments: [String]) throws -> ChatsBoardInvocation {
        switch arguments.first {
        case "set": return try parseSet(Array(arguments.dropFirst()))
        case "remove":
            let (positionals, json) = try parseSimple(Array(arguments.dropFirst()))
            guard positionals.count == 1 else {
                throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
            }
            return .remove(ref: positionals[0], json: json)
        case "clear", "activate", "deactivate":
            let (positionals, json) = try parseSimple(Array(arguments.dropFirst()))
            guard positionals.isEmpty else { throw ParseError.tooManyPositionals }
            switch arguments[0] {
            case "clear": return .clear(json: json)
            case "activate": return .activate(json: json)
            default: return .deactivate(json: json)
            }
        default:
            return .read(try parseRead(arguments))
        }
    }

    static func parseRead(_ arguments: [String]) throws -> ChatsBoardReadOptions {
        var options = ChatsBoardReadOptions()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--owner": options.owner = try value(arguments, &index, for: arg)
            case "--all": options.all = true
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                throw ParseError.tooManyPositionals
            }
            index += 1
        }
        return options
    }

    private static func parseSet(_ arguments: [String]) throws -> ChatsBoardInvocation {
        var patch = JarvisBoardPatch()
        var json = false
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--light":
                let raw = try value(arguments, &index, for: arg)
                guard let light = JarvisBoardLight(rawValue: raw) else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: JarvisBoardLight.allowedList)
                }
                patch.light = light
            case "--mission": patch.mission = try value(arguments, &index, for: arg)
            case "--needs": patch.needs = try value(arguments, &index, for: arg)
            case "--next": patch.next = try value(arguments, &index, for: arg)
            case "--json": json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
        }
        // Kürzen und Einzeilig-Machen schon hier, damit `--json` des Aufrufers
        // dieselben Werte sieht, die die App speichert (die App säubert
        // trotzdem autoritativ noch einmal).
        return .set(ref: positionals[0], patch: JarvisBoardLogic.sanitized(patch), json: json)
    }

    private static func parseSimple(_ arguments: [String]) throws -> (positionals: [String], json: Bool) {
        var positionals: [String] = []
        var json = false
        for arg in arguments {
            if arg == "--json" { json = true; continue }
            if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
            positionals.append(arg)
        }
        return (positionals, json)
    }

    /// Anders als die übrigen Parser darf ein Wert mit „-" beginnen — Texte
    /// wie „- Entscheidung offen" sind legitim. Nur das Fehlen ist ein Fehler.
    private static func value(_ arguments: [String], _ index: inout Int, for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw ParseError.missingValue(flag) }
        return arguments[index]
    }
}

// MARK: - Lese-Modell

/// Eine Board-Zeile mit allem, was die Ausgabe braucht.
struct ChatsBoardRow: Equatable {
    var entry: JarvisBoardEntry
    var title: String
    var project: String
    /// Laufzeitstatus wie in `chats list --json` (`unknown`, wenn keine Meinung).
    var status: String
    var statusSince: Date?
    var otherOwners: [UUID]
}

enum ChatsBoardReadModel {
    static let schema = JarvisBoardFile.currentSchema

    /// Baut die Zeilen eines Boards in Anzeige-Reihenfolge.
    /// - Parameter lastTransitions: letzter Journal-Statuswechsel je Session.
    ///   Passt dessen Ziel zum aktuellen Status, ist sein Zeitpunkt das
    ///   genaueste `statusSince`; sonst die Schätzung des Probes.
    static func rows(
        board: JarvisBoard,
        file: JarvisBoardFile,
        sessions: [UUID: ChatsSessionEntry],
        runtime: [UUID: ChatsRuntimeInfo],
        lastTransitions: [UUID: ChatsStatusJournalEntry]
    ) -> [ChatsBoardRow] {
        board.sortedEntries.map { entry in
            let session = sessions[entry.sessionID]
            let info = runtime[entry.sessionID]
            let status = info?.status?.rawValue ?? "unknown"
            var since = info?.since
            if let transition = lastTransitions[entry.sessionID], transition.to == status {
                since = transition.at
            }
            return ChatsBoardRow(
                entry: entry,
                title: session?.session.title ?? ChatsOutput.shortID(entry.sessionID),
                project: session?.projectName ?? "",
                status: status,
                statusSince: since,
                otherOwners: file.owners(containing: entry.sessionID).filter { $0 != board.owner })
        }
    }

    /// Ein Board als JSON-Objekt (ohne `schema`/`cursor` — die stehen eine
    /// Ebene höher). Fehlendes Board = `isActive: false`, keine Einträge.
    static func boardJSON(owner: UUID, board: JarvisBoard?, rows: [ChatsBoardRow]) -> [String: Any] {
        [
            "owner": owner.uuidString,
            "ownerRef": ChatsOutput.shortID(owner),
            "isActive": board?.isActive ?? false,
            "entries": rows.map(entryJSON),
        ]
    }

    /// `chats board --json`: genau ein Board.
    static func readJSON(owner: UUID, board: JarvisBoard?, rows: [ChatsBoardRow], cursor: String?) -> [String: Any] {
        var payload = boardJSON(owner: owner, board: board, rows: rows)
        payload["schema"] = schema
        payload["cursor"] = cursor ?? NSNull()
        return payload
    }

    /// `chats board --all --json`: alle Boards, ein gemeinsamer Cursor.
    static func allJSON(boards: [[String: Any]], cursor: String?) -> [String: Any] {
        ["schema": schema, "cursor": cursor ?? NSNull(), "boards": boards]
    }

    static func entryJSON(_ row: ChatsBoardRow) -> [String: Any] {
        [
            "ref": ChatsOutput.shortID(row.entry.sessionID),
            "sessionID": row.entry.sessionID.uuidString,
            "title": row.title,
            "project": row.project,
            "light": row.entry.light.rawValue,
            "mission": row.entry.mission,
            "needs": row.entry.needs,
            "next": row.entry.next,
            "updatedAt": ChatsOutput.iso(row.entry.updatedAt),
            "status": row.status,
            "statusSince": row.statusSince.map(ChatsOutput.iso) ?? NSNull(),
            "otherOwners": row.otherOwners.map(ChatsOutput.shortID),
        ]
    }

    /// Letzter Statuswechsel je Session aus dem Journal (ohne Board-Ereignisse).
    static func lastTransitions(_ entries: [ChatsStatusJournalEntry]) -> [UUID: ChatsStatusJournalEntry] {
        var result: [UUID: ChatsStatusJournalEntry] = [:]
        for entry in entries where !entry.isBoardEvent {
            guard let sessionID = entry.sessionID else { continue }
            result[sessionID] = entry
        }
        return result
    }

    // MARK: Text (Diagnose)

    static func printBoard(owner: UUID, board: JarvisBoard?, rows: [ChatsBoardRow], now: Date) {
        let state = board == nil ? "kein Board" : (board!.isActive ? "aktiv" : "inaktiv")
        CLIIO.out("Jarvis-Board \(ChatsOutput.shortID(owner)) (\(state)) · \(rows.count) Chat(s)")
        for row in rows {
            let since = row.statusSince.map { " " + ChatsOutput.relative(from: $0, to: now) } ?? ""
            let name = row.project.isEmpty ? row.title : "\(row.project)/\(row.title)"
            let detail = !row.entry.needs.isEmpty ? "braucht: \(row.entry.needs)"
                : (!row.entry.next.isEmpty ? "als Nächstes: \(row.entry.next)" : row.entry.mission)
            let others = row.otherOwners.isEmpty ? ""
                : "  (auch bei \(row.otherOwners.map(ChatsOutput.shortID).joined(separator: ", ")))"
            CLIIO.out("  \(pad(lightSymbol(row.entry.light) + " " + row.entry.light.rawValue, 11))"
                      + "\(ChatsOutput.shortID(row.entry.sessionID))  \(pad(clip(name, 36), 37))"
                      + "\(pad(row.status + since, 20))\(clip(detail, 70))\(others)")
        }
    }

    private static func lightSymbol(_ light: JarvisBoardLight) -> String {
        switch light {
        case .needsYou: return "◆"
        case .done: return "✓"
        case .running: return "▶"
        case .parked: return "‖"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func clip(_ text: String, _ maxChars: Int) -> String {
        text.count <= maxChars ? text : String(text.prefix(maxChars - 1)) + "…"
    }
}

// MARK: - Befehl

enum ChatsBoardCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let invocation: ChatsBoardInvocation
        do {
            invocation = try ChatsBoardParser.parse(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return ChatsCLIExit.usage
        }
        switch invocation {
        case .read(let options):
            return await read(options)
        case .set(let ref, let patch, let json):
            return mutate(.set, ref: ref, patch: patch, json: json)
        case .remove(let ref, let json):
            return mutate(.remove, ref: ref, patch: nil, json: json)
        case .clear(let json):
            return mutate(.clear, ref: nil, patch: nil, json: json)
        case .activate(let json):
            return mutate(.activate, ref: nil, patch: nil, json: json)
        case .deactivate(let json):
            return mutate(.deactivate, ref: nil, patch: nil, json: json)
        }
    }

    // MARK: Lesen

    private static func read(_ options: ChatsBoardReadOptions) async -> Int32 {
        let context = ChatsCommandContext.load()
        let enabled = JarvisBoardSettings.isEnabled()
        let file = visibleFile(enabled: enabled) { JarvisBoardStore.load() }
        let cursor = ChatsStatusJournal.currentCursor()

        let owners: [UUID]
        if options.all {
            owners = file.boards.map(\.owner)
        } else {
            guard let owner = resolveOwner(options.owner, context: context) else { return ChatsCLIExit.notFound }
            owners = [owner]
        }

        // Status nur für Chats, die auf den gezeigten Boards stehen.
        let boardSessionIDs = Set(owners.compactMap { file.board(owner: $0) }.flatMap(\.entries).map(\.sessionID))
        let sessions = Dictionary(
            context.view.entries.filter { boardSessionIDs.contains($0.session.id) }.map { ($0.session.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var runtime: [UUID: ChatsRuntimeInfo] = [:]
        if !sessions.isEmpty {
            let live = ChatsLiveMerge.fetch()
            let estimates = await ChatsStatusProbe.probeAll(entries: Array(sessions.values), now: context.now)
            for (id, estimate) in estimates {
                runtime[id] = ChatsLiveMerge.merge(estimate: estimate, live: live?[id])
            }
        }
        let transitions = boardSessionIDs.isEmpty ? [:]
            : ChatsBoardReadModel.lastTransitions(ChatsStatusJournal.readAll(fileURL: ChatsStatusJournal.defaultFileURL()))

        func rows(for owner: UUID) -> (JarvisBoard?, [ChatsBoardRow]) {
            guard let board = file.board(owner: owner) else { return (nil, []) }
            return (board, ChatsBoardReadModel.rows(board: board, file: file, sessions: sessions,
                                                     runtime: runtime, lastTransitions: transitions))
        }

        if options.json {
            if options.all {
                let boards = owners.map { owner -> [String: Any] in
                    let (board, boardRows) = rows(for: owner)
                    return ChatsBoardReadModel.boardJSON(owner: owner, board: board, rows: boardRows)
                }
                CLIIO.out(ChatsOutput.encodeJSON(ChatsBoardReadModel.allJSON(boards: boards, cursor: cursor)))
            } else {
                let (board, boardRows) = rows(for: owners[0])
                CLIIO.out(ChatsOutput.encodeJSON(
                    ChatsBoardReadModel.readJSON(owner: owners[0], board: board, rows: boardRows, cursor: cursor)))
            }
        } else {
            if !enabled { CLIIO.err("Hinweis: \(JarvisBoardSettings.disabledMessage)") }
            if owners.isEmpty { CLIIO.out("Keine Boards.") }
            for owner in owners {
                let (board, boardRows) = rows(for: owner)
                ChatsBoardReadModel.printBoard(owner: owner, board: board, rows: boardRows, now: context.now)
            }
        }
        return ChatsCLIExit.ok
    }

    /// Abgeschaltet = es gibt kein Board (Lesen bleibt Exit 0, die Datei
    /// wird gar nicht erst gelesen).
    static func visibleFile(enabled: Bool, load: () -> JarvisBoardFile) -> JarvisBoardFile {
        enabled ? load() : JarvisBoardFile()
    }

    /// `@self` braucht die Session-Umgebung, muss aber NICHT im Workspace
    /// stehen (frisch gestartete Chats sind dort wegen des Debounce evtl. noch
    /// nicht). Eine Voll-UUID wird ebenso direkt genommen — ein Board kann
    /// seinen Chat überleben.
    static func resolveOwner(_ raw: String, context: ChatsCommandContext) -> UUID? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "@self" {
            guard let selfID = context.caller.sessionID else {
                CLIIO.err("@self funktioniert nur innerhalb einer WhisperM8-Session (WHISPERM8_SESSION_ID fehlt) — sonst --owner <ref>.")
                return nil
            }
            return selfID
        }
        if let uuid = UUID(uuidString: trimmed) { return uuid }
        switch context.resolve(ref: trimmed, includeArchived: true) {
        case .success(let entry): return entry.session.id
        case .failure: return nil
        }
    }

    // MARK: Handeln

    private static func mutate(_ op: JarvisBoardOp, ref: String?, patch: JarvisBoardPatch?, json: Bool) -> Int32 {
        guard JarvisBoardSettings.isEnabled() else {
            CLIIO.err("Fehler: \(JarvisBoardSettings.disabledMessage)")
            return ChatsCLIExit.usage
        }
        let caller = ChatsCallerIdentity.fromEnvironment()
        guard let owner = caller.sessionID else {
            CLIIO.err("Fehler: Board-Befehle gehen nur aus einer WhisperM8-Session (WHISPERM8_SESSION_ID fehlt) — das Board gehört dem aufrufenden Chat.")
            return ChatsCLIExit.usage
        }

        var params: [String: Any] = [:]
        if let ref {
            // Entfernen geht auch für archivierte Chats (Aufräumen), Eintragen nicht.
            switch ChatsLiveSupport.resolveTarget(ref: ref, includeArchived: op == .remove) {
            case .failed(let code): return code
            case .resolved(let id, _):
                guard id != owner else {
                    CLIIO.err("Fehler: Der eigene Chat kann nicht auf das eigene Board.")
                    return ChatsCLIExit.conflict
                }
                params["targetSessionID"] = id.uuidString
            }
        }
        if let patch {
            if let light = patch.light { params["light"] = light.rawValue }
            if let mission = patch.mission { params["mission"] = mission }
            if let needs = patch.needs { params["needs"] = needs }
            if let next = patch.next { params["next"] = next }
        }

        switch ChatsLiveSupport.perform(method: "board.\(op.rawValue)", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: json) { result in
                humanLine(op: op, result: result)
            }
            return ChatsCLIExit.ok
        }
    }

    static func humanLine(op: JarvisBoardOp, result: ChatsControlJSON) -> String {
        let changed = result["changed"]?.boolValue ?? false
        let ref = result["ref"]?.stringValue ?? "?"
        switch op {
        case .set:
            let light = result["light"]?.stringValue ?? "?"
            return changed ? "✓ Board: \(ref) → \(light)" : "Board: \(ref) unverändert (\(light))"
        case .remove:
            return changed ? "✓ Board: \(ref) entfernt" : "Board: \(ref) stand nicht drauf"
        case .clear:
            let count = result["removedCount"]?.intValue ?? 0
            return changed ? "✓ Board geleert (\(count) Einträge)" : "Board war schon leer"
        case .activate:
            return changed ? "✓ Board aktiv" : "Board war schon aktiv"
        case .deactivate:
            return changed ? "✓ Board inaktiv" : "Board war schon inaktiv"
        }
    }
}
