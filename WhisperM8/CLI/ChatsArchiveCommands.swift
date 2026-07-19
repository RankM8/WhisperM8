import Foundation

// MARK: - Archiv-Suche + gezieltes Reaktivieren

/// Strikte Aktions-Trennung (Produktsemantik, nie vermischen):
/// `close` schließt nur UI-Tabs · `archive` setzt die Archiv-Markierung ·
/// `unarchive` entfernt NUR diese Markierung (kein Start, kein Tab) ·
/// `resume` startet/verbindet eine (nicht archivierte) Session. Der einzige
/// Compound ist EXPLIZIT: `unarchive <ref> --resume|--open`.

struct ChatsArchivedOptions: Equatable {
    var query: String?
    var project: String?
    var group: String?
    var provider: String?
    var since: String?
    var until: String?
    var content: String?
    var limit = 50
    var json = false
}

struct ChatsUnarchiveOptions: Equatable {
    var ref = ""
    var resume = false
    var open = false
    var json = false
}

// MARK: - Purer Filter-/Such-Kern (testbar)

enum ChatsArchivedSupport {
    /// Referenz-Zeitpunkt einer archivierten Session: der Archiv-Zeitstempel,
    /// bei Alt-Daten ohne `archivedAt` die letzte Aktivität.
    static func archivedDate(_ session: AgentChatSession) -> Date {
        session.archivedAt ?? session.lastActivityAt
    }

    /// `--since/--until`-Werte: absolutes ISO-Datum (`yyyy-MM-dd`) oder
    /// relativ zu `now` (`14d`, `8w`). `nil` = nicht parsebar.
    static func parseWhen(_ raw: String, now: Date) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // Relativ: "<zahl>d" (Tage) oder "<zahl>w" (Wochen) zurück von jetzt.
        if let unit = trimmed.last, unit == "d" || unit == "w" {
            let digits = String(trimmed.dropLast())
            if !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) {
                let seconds = Double(value) * (unit == "d" ? 86_400 : 7 * 86_400)
                return now.addingTimeInterval(-seconds)
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: trimmed)
    }

    /// Metadaten-Filter über die archivierten Einträge. `query` sucht
    /// normalisiert (Diakritika/Trenner-tolerant) über Projekt, Titel und
    /// Gruppe. Ergebnis absteigend nach Archiv-Zeitpunkt.
    static func filter(
        entries: [ChatsSessionEntry],
        query: String? = nil,
        project: String? = nil,
        group: String? = nil,
        provider: String? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) -> [ChatsSessionEntry] {
        var result = entries.filter { $0.session.status == .archived }
        if let query {
            let norm = SessionRefResolver.normalize(query)
            result = result.filter {
                SessionRefResolver.normalize($0.projectName).contains(norm)
                    || SessionRefResolver.normalize($0.session.title).contains(norm)
                    || SessionRefResolver.normalize($0.session.groupName ?? "").contains(norm)
            }
        }
        if let project {
            let norm = SessionRefResolver.normalize(project)
            result = result.filter {
                SessionRefResolver.normalize($0.projectName).contains(norm)
                    || SessionRefResolver.normalize(($0.projectPath as NSString).lastPathComponent).contains(norm)
            }
        }
        if let group {
            let norm = SessionRefResolver.normalize(group)
            result = result.filter { SessionRefResolver.normalize($0.session.groupName ?? "").contains(norm) }
        }
        if let provider {
            result = result.filter { $0.session.provider.rawValue == provider }
        }
        if let since {
            result = result.filter { archivedDate($0.session) >= since }
        }
        if let until {
            result = result.filter { archivedDate($0.session) <= until }
        }
        return result.sorted { archivedDate($0.session) > archivedDate($1.session) }
    }

    /// Ergebnis der Transcript-Inhaltssuche für eine Datei.
    enum ContentMatch: Equatable {
        case hit
        /// Treffer im nur TEILWEISE gelesenen Tail (Datei > Cap).
        case hitTruncated
        case miss
        /// Kein Treffer, aber nur der Tail wurde durchsucht — kein Beweis
        /// für Abwesenheit.
        case missTruncated
        case unreadable
    }

    /// Größen-Cap der Inhaltssuche: größere Transcripte werden nur im
    /// letzten `contentSearchCapBytes`-Fenster durchsucht (Robustheit vor
    /// Vollständigkeit; das Ende enthält die jüngste Arbeit).
    static let contentSearchCapBytes = 64 * 1_048_576

    /// Case-insensitive Substring-Suche im ROHEN Transcript-JSONL. Bewusst
    /// pragmatisch: JSON escapet nur Anführungszeichen/Backslashes/Steuer-
    /// zeichen — normale Wörter (auch Umlaute, UTF-8) matchen direkt.
    static func contentMatches(fileURL: URL, query: String, capBytes: Int = contentSearchCapBytes) -> ContentMatch {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return .unreadable }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let truncated = size > capBytes
        let start = truncated ? size - capBytes : 0
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? handle.readToEnd() else { return .unreadable }
        let haystack = String(decoding: data, as: UTF8.self)
        let hit = haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        switch (hit, truncated) {
        case (true, false): return .hit
        case (true, true): return .hitTruncated
        case (false, false): return .miss
        case (false, true): return .missTruncated
        }
    }
}

// MARK: - Parser

extension ChatsCLIParser {
    static func parseArchived(_ arguments: [String]) throws -> ChatsArchivedOptions {
        var options = ChatsArchivedOptions()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--project": options.project = try nextArchivedValue(arguments, &index, for: arg)
            case "--group": options.group = try nextArchivedValue(arguments, &index, for: arg)
            case "--provider":
                let raw = try nextArchivedValue(arguments, &index, for: arg)
                guard raw == "claude" || raw == "codex" else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "claude, codex")
                }
                options.provider = raw
            case "--since": options.since = try nextArchivedValue(arguments, &index, for: arg)
            case "--until": options.until = try nextArchivedValue(arguments, &index, for: arg)
            case "--content": options.content = try nextArchivedValue(arguments, &index, for: arg)
            case "--limit":
                let raw = try nextArchivedValue(arguments, &index, for: arg)
                guard let value = Int(raw), value >= 0 else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "Ganzzahl >= 0 (0 = kein Limit)")
                }
                options.limit = value
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                guard options.query == nil else { throw ParseError.tooManyPositionals }
                options.query = arg
            }
            index += 1
        }
        return options
    }

    static func parseUnarchive(_ arguments: [String]) throws -> ChatsUnarchiveOptions {
        var options = ChatsUnarchiveOptions()
        var positionals: [String] = []
        for arg in arguments {
            switch arg {
            case "--resume": options.resume = true
            case "--open": options.open = true
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
        }
        if options.resume && options.open {
            throw ParseError.invalidValue(flag: "--open", value: "--resume",
                                          allowed: "entweder --resume ODER --open")
        }
        options.ref = positionals[0]
        return options
    }

    private static func nextArchivedValue(_ arguments: [String], _ index: inout Int, for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw ParseError.missingValue(flag) }
        return arguments[index]
    }
}

// MARK: - archived (Lesen, app-unabhängig)

enum ChatsArchivedCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let options: ChatsArchivedOptions
        do {
            options = try ChatsCLIParser.parseArchived(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err("Usage: whisperm8 chats archived [query] [--project P] [--group G] [--provider claude|codex] [--since D] [--until D] [--content \"text\"] [--limit N] [--json]")
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        var since: Date?
        var until: Date?
        if let raw = options.since {
            guard let parsed = ChatsArchivedSupport.parseWhen(raw, now: context.now) else {
                CLIIO.err("Ungültiger Wert '\(raw)' für --since. Erlaubt: yyyy-MM-dd oder relativ (14d, 8w).")
                return ChatsCLIExit.usage
            }
            since = parsed
        }
        if let raw = options.until {
            guard let parsed = ChatsArchivedSupport.parseWhen(raw, now: context.now) else {
                CLIIO.err("Ungültiger Wert '\(raw)' für --until. Erlaubt: yyyy-MM-dd oder relativ (14d, 8w).")
                return ChatsCLIExit.usage
            }
            until = parsed
        }

        var matches = ChatsArchivedSupport.filter(
            entries: context.view.entries,
            query: options.query, project: options.project, group: options.group,
            provider: options.provider, since: since, until: until)

        // Transcript-Verfügbarkeit IMMER erheben (billig: stat) — sie ist die
        // zentrale Kontext-Info fürs Reaktivieren („Resume startet frisch?").
        var probeByID: [UUID: ChatsRuntimeInfo] = [:]
        for entry in matches {
            probeByID[entry.session.id] = ChatsStatusProbe.probe(entry: entry, now: context.now)
        }

        // Inhaltssuche erst NACH den Metadaten-Filtern (nur Kandidaten lesen).
        var contentByID: [UUID: ChatsArchivedSupport.ContentMatch] = [:]
        if let content = options.content {
            matches = matches.filter { entry in
                guard let path = probeByID[entry.session.id]?.transcriptPath else {
                    contentByID[entry.session.id] = .unreadable
                    return false
                }
                let match = ChatsArchivedSupport.contentMatches(
                    fileURL: URL(fileURLWithPath: path), query: content)
                contentByID[entry.session.id] = match
                return match == .hit || match == .hitTruncated
            }
        }

        let total = matches.count
        if options.limit > 0, matches.count > options.limit {
            matches = Array(matches.prefix(options.limit))
        }

        if options.json {
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "generatedAt": ChatsOutput.iso(context.now),
                "total": total,
                "entries": matches.map { entry -> [String: Any] in
                    let probe = probeByID[entry.session.id]
                    var dict: [String: Any] = [
                        "id": entry.session.id.uuidString,
                        "shortID": ChatsOutput.shortID(entry.session.id),
                        "project": entry.projectName,
                        "title": entry.session.title,
                        "provider": entry.session.provider.rawValue,
                        "archivedAt": ChatsOutput.iso(ChatsArchivedSupport.archivedDate(entry.session)),
                        "lastActivityAt": ChatsOutput.iso(entry.session.lastActivityAt),
                        "transcript": [
                            "availability": probe?.availability.rawValue ?? "unsupported",
                            "sizeBytes": probe?.transcriptSizeBytes as Any,
                        ],
                    ]
                    if let group = entry.session.groupName { dict["group"] = group }
                    if let match = contentByID[entry.session.id] {
                        dict["contentMatch"] = String(describing: match)
                    }
                    return dict
                },
            ]
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else if matches.isEmpty {
            CLIIO.out("Keine archivierten Sessions gefunden\(options.content != nil ? " (Inhaltssuche aktiv)" : "").")
        } else {
            for entry in matches {
                let short = ChatsOutput.shortID(entry.session.id)
                let when = ChatsOutput.relative(from: ChatsArchivedSupport.archivedDate(entry.session), to: context.now)
                let group = entry.session.groupName.map { "  [\($0)]" } ?? ""
                let probe = probeByID[entry.session.id]
                let transcriptMark = probe?.availability == .available
                    ? "" : "  ⚠︎ kein Transcript — Resume startet frisch"
                let contentMark: String
                switch contentByID[entry.session.id] {
                case .hitTruncated: contentMark = "  (Treffer im Tail, Datei > Cap)"
                default: contentMark = ""
                }
                CLIIO.out("\(short)  \(entry.projectName)/\(entry.session.title)\(group)  · \(entry.session.provider.rawValue) · archiviert vor \(when)\(transcriptMark)\(contentMark)")
            }
            if total > matches.count {
                CLIIO.err("Zeige \(matches.count) von \(total) — mehr mit --limit N (0 = alle).")
            }
        }
        return ChatsCLIExit.ok
    }
}

// MARK: - unarchive (Handeln, Socket)

enum ChatsUnarchiveCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let options: ChatsUnarchiveOptions
        do {
            options = try ChatsCLIParser.parseUnarchive(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            CLIIO.err("Usage: whisperm8 chats unarchive <ref> [--resume|--open] [--json]")
            return ChatsCLIExit.usage
        }

        let targetID: UUID
        switch ChatsLiveSupport.resolveTarget(ref: options.ref, includeArchived: true) {
        case .resolved(let id, _): targetID = id
        case .failed(let code): return code
        }

        let params: [String: Any] = [
            "targetSessionID": targetID.uuidString,
            "resume": options.resume,
            "open": options.open,
        ]
        switch ChatsLiveSupport.perform(method: "workspace.unarchive", params: params) {
        case .failed(let code): return code
        case .ok(let response):
            guard response.ok else { return ChatsLiveSupport.mapError(response) }
            ChatsLiveSupport.printResult(response, json: options.json) { result in
                let title = result["target"]?["title"]?.stringValue ?? options.ref
                let base = result["outcome"]?.stringValue == "alreadyActive"
                    ? "– war nicht archiviert: \(title)"
                    : "✓ entarchiviert: \(title)"
                if result["resumed"]?.boolValue == true { return base + " · Resume angestoßen" }
                if result["opened"]?.boolValue == true { return base + " · Tab fokussiert" }
                return base + " (kein Start — Session ist wieder in der Sidebar)"
            }
            return ChatsCLIExit.ok
        }
    }
}
