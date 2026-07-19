import Foundation

// MARK: - Exit-Code-Vertrag `whisperm8 chats`

/// Eigener Vertrag des `chats`-Namespace (dokumentiert im Hilfetext und in
/// docs/plans/whisperm8-chats-cli/): ein Agent leitet aus Exit-Code + stdout
/// allein den nächsten Schritt ab. `usage = 1` bleibt konsistent zum
/// `agent`-Namespace (Repo-Konvention vor grep-Konvention).
enum ChatsCLIExit {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    /// Referenz nicht auflösbar ODER mehrdeutig (Kandidaten auf stderr/JSON).
    static let notFound: Int32 = 3
    /// Guard-/Precondition-Konflikt (Selbst-Send, working-Ziel, tote PTY, Drift).
    static let conflict: Int32 = 4
    /// Socket-Befehl, aber App nicht erreichbar.
    static let appUnreachable: Int32 = 5
    /// Nur `wait`: Timeout ohne Ereignis.
    static let timeout: Int32 = 124
    /// SIGINT während eines blockierenden Befehls.
    static let interrupted: Int32 = 130
}

// MARK: - Dispatch

enum AgentChatsCLICommand {
    static func run(arguments: [String]) async -> Int32 {
        guard let first = arguments.first else {
            CLIIO.out(ChatsCLIHelp.text)
            return ChatsCLIExit.ok
        }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "help", "--help", "-h":
            CLIIO.out(ChatsCLIHelp.text)
            return ChatsCLIExit.ok
        case "list":
            return await ChatsListCommand.run(rest, board: false)
        case "overview":
            // Alias: `list --sort attention --format board` — eine Logik,
            // ein JSON-Schema (Plan Paket 01).
            return await ChatsListCommand.run(rest, board: true)
        case "show":
            return await ChatsShowCommand.run(rest)
        case "tail":
            return await ChatsTailCommand.run(rest)
        case "wait":
            return ChatsWaitCommand.run(rest)
        case "send":
            return ChatsSendCommand.run(rest)
        case "interrupt":
            return ChatsInterruptCommand.run(rest)
        case "open":
            return ChatsOpenCommand.run(rest)
        case "close":
            return ChatsCloseCommand.run(rest)
        case "resume":
            return ChatsResumeCommand.run(rest)
        case "new":
            return ChatsNewCommand.run(rest)
        case "rename":
            return ChatsMutationCommand.run(rest, kind: .rename)
        case "group":
            return ChatsMutationCommand.run(rest, kind: .group)
        case "archive":
            return ChatsMutationCommand.run(rest, kind: .archive)
        case "workspace":
            return ChatsWorkspaceCommand.run(rest)
        case "audit":
            return ChatsAuditCommand.run(rest)
        default:
            CLIIO.err("Unbekannter chats-Befehl: \(first)")
            CLIIO.out(ChatsCLIHelp.text)
            return ChatsCLIExit.usage
        }
    }
}

// MARK: - Options + Parser

struct ChatsListOptions: Equatable {
    var project: String?
    var status: String?
    var attentionOnly = false
    var all = false
    /// Deckt sich mit den Sidebar-Filtern der App: active = laufend ∪ offener
    /// Tab ∪ gepinnt · recent = active ∪ Aktivität < 14 Tage · all = alles.
    /// `nil` = Default (recent). `--all` ist Alias für `--scope all`.
    var scope: String?
    var openOnly = false           // nur offene Tabs
    var pinnedOnly = false         // nur gepinnte
    var sort = "activity"          // activity | attention
    var format = "table"           // table | board
    /// Zeilen-Deckel der Tabelle (Board kollabiert idle ohnehin). 0 = kein Limit.
    var limit = 50
    var json = false
}

/// `close` nimmt bewusst NUR explizite Refs (auch mehrere) — kein `--all`,
/// kein Filter-Flag: die Kandidatenauswahl trifft der Aufrufer (Jarvis) über
/// `list --open --json` + Bestätigung, die CLI schließt nie pauschal.
struct ChatsCloseOptions: Equatable {
    var refs: [String] = []
    var json = false
}

struct ChatsShowOptions: Equatable {
    var ref = ""
    var all = false
    var json = false
}

struct ChatsTailOptions: Equatable {
    var ref = ""
    var turns = ChatsTailFormatter.defaultTurns
    var chars = ChatsTailFormatter.defaultMaxChars
    var raw = false
    var all = false
    var json = false
}

enum ChatsCLIParser {
    typealias ParseError = AgentCLIParser.ParseError

    static func parseList(_ arguments: [String]) throws -> ChatsListOptions {
        var options = ChatsListOptions()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--project":
                options.project = try nextValue(arguments, &index, for: arg)
            case "--status":
                let raw = try nextValue(arguments, &index, for: arg)
                guard AgentSessionRuntimeStatus(rawValue: raw) != nil else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "working, awaitingInput, idle, stopped, errored")
                }
                options.status = raw
            case "--attention":
                options.attentionOnly = true
            case "--all":
                options.all = true
            case "--scope":
                let raw = try nextValue(arguments, &index, for: arg)
                guard raw == "active" || raw == "recent" || raw == "all" else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "active, recent, all")
                }
                options.scope = raw
            case "--open":
                options.openOnly = true
            case "--pinned":
                options.pinnedOnly = true
            case "--sort":
                let raw = try nextValue(arguments, &index, for: arg)
                guard raw == "activity" || raw == "attention" else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "activity, attention")
                }
                options.sort = raw
            case "--format":
                let raw = try nextValue(arguments, &index, for: arg)
                guard raw == "table" || raw == "board" else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "table, board")
                }
                options.format = raw
            case "--limit":
                let raw = try nextValue(arguments, &index, for: arg)
                guard let value = Int(raw), value >= 0 else {
                    throw ParseError.invalidValue(flag: arg, value: raw, allowed: "Ganzzahl >= 0 (0 = kein Limit)")
                }
                options.limit = value
            case "--json":
                options.json = true
            default:
                throw ParseError.unknownFlag(arg)
            }
            index += 1
        }
        return options
    }

    static func parseClose(_ arguments: [String]) throws -> ChatsCloseOptions {
        var options = ChatsCloseOptions()
        for arg in arguments {
            switch arg {
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                options.refs.append(arg)
            }
        }
        guard !options.refs.isEmpty else { throw ParseError.missingShortID }
        return options
    }

    static func parseShow(_ arguments: [String]) throws -> ChatsShowOptions {
        var options = ChatsShowOptions()
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--all": options.all = true
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
        }
        options.ref = positionals[0]
        return options
    }

    static func parseTail(_ arguments: [String]) throws -> ChatsTailOptions {
        var options = ChatsTailOptions()
        var positionals: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--turns":
                options.turns = try positiveInt(arguments, &index, for: arg)
            case "--chars":
                options.chars = try positiveInt(arguments, &index, for: arg)
            case "--raw": options.raw = true
            case "--all": options.all = true
            case "--json": options.json = true
            default:
                if arg.hasPrefix("-") { throw ParseError.unknownFlag(arg) }
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals.count == 1 else {
            throw positionals.isEmpty ? ParseError.missingShortID : ParseError.tooManyPositionals
        }
        options.ref = positionals[0]
        return options
    }

    // MARK: Helpers

    private static func nextValue(_ arguments: [String], _ index: inout Int, for flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw ParseError.missingValue(flag) }
        let value = arguments[index]
        if value.hasPrefix("-") { throw ParseError.missingValue(flag) }
        return value
    }

    private static func positiveInt(_ arguments: [String], _ index: inout Int, for flag: String) throws -> Int {
        let raw = try nextValue(arguments, &index, for: flag)
        guard let value = Int(raw), value > 0 else {
            throw ParseError.invalidValue(flag: flag, value: raw, allowed: "positive Ganzzahl")
        }
        return value
    }
}

// MARK: - Gemeinsame Lade-/Auflösungs-Schicht

/// Geladener Kontext für einen Lese-Befehl: Workspace-Sicht + Identität.
struct ChatsCommandContext {
    var view: ChatsWorkspaceReader.View
    var caller: ChatsCallerIdentity
    var now: Date

    static func load(now: Date = Date()) -> ChatsCommandContext {
        ChatsCommandContext(
            view: ChatsWorkspaceReader().load(),
            caller: .fromEnvironment(),
            now: now
        )
    }

    /// Default-Scope der Lese-Befehle: aktive Sessions (nicht archiviert,
    /// Aktivität < 14 Tage). `all` hebt beides auf.
    func scopedEntries(all: Bool) -> [ChatsSessionEntry] {
        guard !all else { return view.entries }
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        return view.entries.filter {
            $0.session.status != .archived && $0.session.lastActivityAt > cutoff
        }
    }

    func isOpen(_ id: UUID) -> Bool { view.openTabIDs.contains(id) }
    func isPinned(_ id: UUID) -> Bool { view.pinnedSessionIDs.contains(id) }

    /// Scope-Auflösung mit App-Semantik (Sidebar-Filter Aktiv/Zuletzt/Alle).
    /// `active` = laufend (Live-Merge) ∪ offener Tab ∪ gepinnt.
    /// `liveAvailable == false` (App zu): persistierter Status `.running`
    /// zählt zusätzlich als aktiv — fängt App-Crash-Reste und extern laufende
    /// Sessions ab (GPT-Review). Läuft die App, ist ihr Live-Status
    /// autoritativ und der persistierte Status wird ignoriert.
    func scopedEntries(scope: String, liveRunningIDs: Set<UUID>, liveAvailable: Bool = true) -> [ChatsSessionEntry] {
        switch scope {
        case "all":
            return view.entries
        case "active":
            return view.entries.filter { entry in
                let id = entry.session.id
                let offlineRunning = !liveAvailable && entry.session.status == .running
                return entry.session.status != .archived
                    && (liveRunningIDs.contains(id) || isOpen(id) || isPinned(id) || offlineRunning)
            }
        default: // recent
            return scopedEntries(all: false)
        }
    }

    enum ResolveOutcome {
        case success(ChatsSessionEntry)
        case failure(Int32)
    }

    /// Ref auflösen und RefError einheitlich nach stderr + Exit-Code mappen.
    func resolve(ref: String, includeArchived: Bool) -> ResolveOutcome {
        let result = SessionRefResolver.resolve(
            ref: ref,
            entries: view.entries,
            selfID: caller.sessionID,
            includeArchived: includeArchived
        )
        switch result {
        case .success(let entry):
            return .success(entry)
        case .failure(.noSelfContext):
            CLIIO.err("@self funktioniert nur innerhalb einer WhisperM8-Session (WHISPERM8_SESSION_ID fehlt).")
            return .failure(ChatsCLIExit.notFound)
        case .failure(.notFound(let ref)):
            CLIIO.err("Keine Session gefunden für: \(ref)")
            return .failure(ChatsCLIExit.notFound)
        case .failure(.ambiguous(let ref, let candidates)):
            CLIIO.err("Fehler: „\(ref)\" ist mehrdeutig (\(candidates.count) Treffer):")
            for candidate in candidates {
                let short = ChatsOutput.shortID(candidate.id)
                CLIIO.err("  \(short)  \(candidate.projectName)/\(candidate.title)")
            }
            CLIIO.err("Präzisiere: projekt/titel oder UUID-Präfix.")
            return .failure(ChatsCLIExit.notFound)
        }
    }
}

// MARK: - list / overview

enum ChatsListCommand {
    static func run(_ arguments: [String], board: Bool) async -> Int32 {
        let options: ChatsListOptions
        do {
            var parsed = try board
                ? ChatsCLIParser.parseList(arguments)
                : ChatsCLIParser.parseList(arguments)
            if board {
                parsed.sort = "attention"
                parsed.format = "board"
            }
            options = parsed
        } catch {
            CLIIO.err(error.localizedDescription)
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        // Live-Merge zuerst — der App-Status (laufende PTYs) speist sowohl den
        // active-Scope als auch den Status-Merge.
        let live = ChatsLiveMerge.fetch()
        let liveRunningIDs = Set((live ?? [:]).filter { $0.value.isAttachedPTY }.map(\.key))

        // Scope auflösen: explizites --scope gewinnt, sonst --all → all, sonst
        // recent. --open/--pinned sind explizite Mitgliedschafts-Filter (offener
        // Tab / gepinnt) und dürfen NICHT recency-begrenzt sein — sie decken
        // sich mit den App-Sektionen (alle offenen Tabs / „Gepinnt N"), also
        // vollen Scope nehmen, wenn kein expliziter --scope gesetzt ist.
        let membershipFilter = options.openOnly || options.pinnedOnly
        let effectiveScope = options.scope
            ?? (options.all || membershipFilter ? "all" : "recent")
        var entries = context.scopedEntries(scope: effectiveScope, liveRunningIDs: liveRunningIDs,
                                            liveAvailable: live != nil)

        if options.openOnly { entries = entries.filter { context.isOpen($0.session.id) } }
        if options.pinnedOnly { entries = entries.filter { context.isPinned($0.session.id) } }

        if let projectFragment = options.project {
            let normalized = SessionRefResolver.normalize(projectFragment)
            let matchingProjects = Set(context.view.projects.filter {
                SessionRefResolver.normalize($0.name).contains(normalized)
                    || SessionRefResolver.normalize(($0.path as NSString).lastPathComponent).contains(normalized)
            }.map(\.id))
            guard !matchingProjects.isEmpty else {
                CLIIO.err("Kein Projekt gefunden für: \(projectFragment)")
                return ChatsCLIExit.notFound
            }
            entries = entries.filter { matchingProjects.contains($0.session.projectID) }
        }

        let runtimeByID = await ChatsStatusProbe.probeAll(entries: entries, now: context.now)
        var items: [(entry: ChatsSessionEntry, runtime: ChatsRuntimeInfo)] = entries.map {
            let estimate = runtimeByID[$0.session.id] ?? ChatsRuntimeInfo(
                status: nil, source: "transcriptEstimate", since: nil, revision: nil,
                transcriptPath: nil, transcriptSizeBytes: nil, availability: .unsupported)
            return ($0, ChatsLiveMerge.merge(estimate: estimate, live: live?[$0.session.id]))
        }

        if let statusFilter = options.status {
            items = items.filter { $0.runtime.status?.rawValue == statusFilter }
        }

        let boardModel = AttentionModelBuilder.build(items: items, now: context.now)
        var boardItems = boardModel.items
        if options.attentionOnly {
            boardItems = boardItems.filter { $0.category == .needsYou || $0.category == .freshDone }
        }
        if options.sort == "activity" {
            boardItems.sort { $0.entry.session.lastActivityAt > $1.entry.session.lastActivityAt }
        }

        if options.json {
            let payload = ChatsOutput.listJSON(
                items: boardItems,
                counts: boardModel.counts,
                selfID: context.caller.sessionID,
                generatedAt: context.now,
                live: live != nil,
                openTabIDs: context.view.openTabIDs,
                pinnedIDs: context.view.pinnedSessionIDs
            )
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else if options.format == "board" {
            ChatsOutput.printBoard(items: boardItems, counts: boardModel.counts,
                                   selfID: context.caller.sessionID, showAll: options.all, now: context.now,
                                   openTabIDs: context.view.openTabIDs, pinnedIDs: context.view.pinnedSessionIDs)
        } else {
            var tableItems = boardItems
            if options.limit > 0, tableItems.count > options.limit {
                tableItems = Array(tableItems.prefix(options.limit))
                CLIIO.err("Zeige \(options.limit) von \(boardItems.count) Sessions — mehr mit --limit N (0 = alle).")
            }
            ChatsOutput.printTable(items: tableItems, selfID: context.caller.sessionID, now: context.now,
                                   openTabIDs: context.view.openTabIDs, pinnedIDs: context.view.pinnedSessionIDs)
        }
        return ChatsCLIExit.ok
    }
}

// MARK: - show

enum ChatsShowCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let options: ChatsShowOptions
        do {
            options = try ChatsCLIParser.parseShow(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        let entry: ChatsSessionEntry
        switch context.resolve(ref: options.ref, includeArchived: options.all) {
        case .success(let resolved): entry = resolved
        case .failure(let code): return code
        }

        let live = ChatsLiveMerge.fetch()
        let runtime = ChatsLiveMerge.merge(
            estimate: ChatsStatusProbe.probe(entry: entry, now: context.now),
            live: live?[entry.session.id])

        let isOpen = context.isOpen(entry.session.id)
        let isPinned = context.isPinned(entry.session.id)
        if options.json {
            var payload = ChatsOutput.sessionJSON(
                entry: entry, runtime: runtime,
                selfID: context.caller.sessionID, live: live != nil,
                liveStatus: live?[entry.session.id],
                isOpen: isOpen, isPinned: isPinned
            )
            payload["schemaVersion"] = 1
            payload["generatedAt"] = ChatsOutput.iso(context.now)
            payload["detail"] = ChatsOutput.detailJSON(entry: entry)
            CLIIO.out(ChatsOutput.encodeJSON(payload))
        } else {
            ChatsOutput.printShow(entry: entry, runtime: runtime,
                                  selfID: context.caller.sessionID, now: context.now,
                                  isOpen: isOpen, isPinned: isPinned)
        }
        return ChatsCLIExit.ok
    }
}

// MARK: - tail

enum ChatsTailCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let options: ChatsTailOptions
        do {
            options = try ChatsCLIParser.parseTail(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return ChatsCLIExit.usage
        }

        let context = ChatsCommandContext.load()
        let entry: ChatsSessionEntry
        switch context.resolve(ref: options.ref, includeArchived: options.all) {
        case .success(let resolved): entry = resolved
        case .failure(let code): return code
        }

        let runtime = ChatsStatusProbe.probe(entry: entry, now: context.now)
        guard runtime.availability == .available, let path = runtime.transcriptPath else {
            // Kein Transcript ist eine gültige Antwort, kein Fehler (Plan Paket 01).
            let reason: String
            switch runtime.availability {
            case .missingExternalSessionID:
                reason = "Session hat noch keine externe Session-ID — Transcript entsteht mit dem ersten Prompt."
            case .missingTranscript:
                reason = "Transcript-Datei nicht gefunden (evtl. bereinigt oder Session nie gestartet)."
            case .unsupported:
                reason = "Session-Art \(entry.session.effectiveKind.displayName) hat kein eigenes Transcript."
            case .available:
                reason = ""
            }
            if options.json {
                CLIIO.out(ChatsOutput.encodeJSON([
                    "schemaVersion": 1,
                    "availability": runtime.availability.rawValue,
                    "turns": [Any](),
                ]))
            } else {
                CLIIO.out("Kein Transcript verfügbar: \(reason)")
            }
            return ChatsCLIExit.ok
        }

        let fileURL = URL(fileURLWithPath: path)
        // Tail-Bytes proportional zum Zeichen-Budget wählen — Standard 256 KB
        // reicht für die Default-Turns; große Budgets lesen mehr.
        let tailBytes = max(262_144, options.chars * 8)
        let transcript = entry.session.provider == .claude || entry.session.effectiveKind == .backgroundChat
            ? ClaudeTranscriptReader.readTail(fileURL: fileURL, tailBytes: tailBytes)
            : CodexTranscriptReader.readTail(fileURL: fileURL, tailBytes: tailBytes)

        if options.raw {
            guard let text = ChatsTailFormatter.lastAssistantText(transcript: transcript) else {
                CLIIO.out("Keine Assistant-Message im Tail gefunden.")
                return ChatsCLIExit.ok
            }
            if options.json {
                CLIIO.out(ChatsOutput.encodeJSON(["schemaVersion": 1, "raw": text]))
            } else {
                CLIIO.outRaw(text + "\n")
            }
            return ChatsCLIExit.ok
        }

        let rendered = ChatsTailFormatter.render(
            transcript: transcript, turns: options.turns, maxChars: options.chars
        )
        if options.json {
            CLIIO.out(ChatsOutput.encodeJSON([
                "schemaVersion": 1,
                "availability": "available",
                "turnCount": rendered.turnCount,
                "truncated": rendered.wasTruncated,
                "text": rendered.text,
            ]))
        } else {
            let header = "\(entry.projectName)/\(entry.session.title) · \(entry.session.provider.rawValue)"
                + " · \(runtime.status?.rawValue ?? "unknown")"
                + (runtime.transcriptSizeBytes.map { " · Transcript \(ChatsOutput.byteString($0))" } ?? "")
            CLIIO.err(header)
            if rendered.wasTruncated {
                CLIIO.err("Hinweis: Ausgabe auf \(options.chars) Zeichen gekürzt (--chars).")
            }
            CLIIO.out(rendered.text)
        }
        return ChatsCLIExit.ok
    }
}

// MARK: - Hilfetext

enum ChatsCLIHelp {
    static let text = """
    whisperm8 chats — Agent-Sessions sehen und verwalten (Jarvis-CLI)

    LESEN (App optional; ohne App: Status aus Transcripts geschätzt)
      whisperm8 chats list [--project P] [--status S] [--attention]
                           [--scope active|recent|all] [--open] [--pinned] [--all]
                           [--sort activity|attention] [--format table|board] [--json]
      whisperm8 chats overview [--json]        Alias: list --sort attention --format board
      whisperm8 chats show <ref> [--all] [--json]
      whisperm8 chats tail <ref> [--turns N] [--chars N] [--raw] [--all] [--json]
      whisperm8 chats wait [--ref R]… [--until attention|idle|statusChange]
                           [--since REV] [--timeout SEC] [--json]
      whisperm8 chats audit [--limit N] [--session <ref>] [--json]

    HANDELN (App muss laufen — sonst Exit 5)
      whisperm8 chats send <ref> [--] "<prompt>" [--if-status S,S] [--no-submit] [--force] [--json]
      whisperm8 chats interrupt <ref> [--force] [--json]   ESC an working-Session
      whisperm8 chats open <ref> [--json]
      whisperm8 chats close <ref> [<ref>…] [--json]      NUR den UI-Tab schließen — Session,
                                                         PTY, Pin und Transcript bleiben
      whisperm8 chats resume <ref> [--json]              geschlossenen Chat wieder hochfahren
      whisperm8 chats new --project <pfad|name> [--provider claude|codex] [--title T] [--prompt "…"] [--json]
      whisperm8 chats rename <ref> "<titel>" [--json]
      whisperm8 chats group <ref> "<gruppe>" | --clear [--json]
      whisperm8 chats archive <ref> [--force] [--json]
      whisperm8 chats workspace list [--json]            Grid-Workspaces (Sidebar-Sektion)
      whisperm8 chats workspace rename <name|id> "<neu>" [--json]

    REFERENZEN (<ref>)
      projekt/titel-fragment   Fuzzy, muss eindeutig sein (sonst Exit 3 + Kandidaten)
      titel-fragment           Fuzzy über alle Projekte
      UUID oder Präfix ≥ 8     exakt
      @self                    die aufrufende Session (WHISPERM8_SESSION_ID)

    EXIT-CODES
      0 ok · 1 Usage · 3 nicht gefunden/mehrdeutig · 4 Guard-Konflikt
      5 App nicht erreichbar · 124 wait-Timeout · 130 unterbrochen

    Alle --json-Objekte tragen schemaVersion und markieren geschätzte Status
    mit "source": "transcriptEstimate". Ergebnis auf stdout, Rest auf stderr.
    """
}
