import Foundation

// MARK: - `whisperm8 tickets …` (Tickets und ihre Chats)

/// Pure Argument-Auswertung, testbar ohne Netz und ohne App.
enum TicketsCLIArguments: Equatable {
    case help
    case board(team: String?, all: Bool, json: Bool)
    case list(team: String?, filter: TicketsListFilter, json: Bool)
    case show(key: String, json: Bool)
    case mine(chat: String?, json: Bool)
    case link(key: String, chat: String?, keepStatus: Bool)
    case done(key: String, chat: String?, status: String?, note: TicketsText?)
    case unlink(key: String, chat: String?)
    case status(key: String, name: String)
    case note(key: String, text: TicketsText)
    case comment(key: String, text: TicketsText)
    case new(TicketsNewOptions)
    case assign(key: String, person: String)
    case label(key: String, add: [String], remove: [String])
    case setup(keyFromStdin: Bool, project: String?, team: String?)
    case doctor(json: Bool)

    enum ParseError: Error, Equatable {
        case usage(String)
    }

    /// `--json` gilt für jeden Befehl und steht vor einem `--`.
    static func wantsJSON(_ arguments: [String]) -> Bool {
        arguments.prefix { $0 != "--" }.contains("--json")
    }

    /// Schreibende Befehle: Mit `--json` kommt ihre Meldung als Objekt.
    var isWrite: Bool {
        switch self {
        case .link, .done, .unlink, .status, .note, .comment, .new, .assign, .label, .setup: return true
        case .help, .board, .list, .show, .mine, .doctor: return false
        }
    }

    var ticketKey: String? {
        switch self {
        case .show(let key, _), .link(let key, _, _), .done(let key, _, _, _), .unlink(let key, _), .status(let key, _),
             .note(let key, _), .comment(let key, _), .assign(let key, _), .label(let key, _, _):
            return key
        case .help, .board, .list, .mine, .new, .setup, .doctor:
            return nil
        }
    }

    static func parse(_ arguments: [String]) throws -> TicketsCLIArguments {
        guard let command = arguments.first else { return .help }
        var rest = Array(arguments.dropFirst())
        // Alles nach `--` ist wörtlicher Text, auch wenn er mit `-` oder `@` beginnt.
        var literal: [String] = []
        if let separator = rest.firstIndex(of: "--") {
            literal = Array(rest[(separator + 1)...])
            rest = Array(rest[..<separator])
        }
        var used = Set<String>()

        func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            used.insert(name)
            return true
        }
        func value(_ name: String) throws -> String? {
            guard let index = rest.firstIndex(of: name) else { return nil }
            guard index + 1 < rest.count else { throw ParseError.usage("\(name) braucht einen Wert") }
            let found = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            used.insert(name)
            return found
        }
        let json = flag("--json")
        func list(_ name: String) throws -> [String] {
            (try value(name) ?? "").split(whereSeparator: { $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        /// Positions-Argumente (vor und nach `--`); danach darf nichts übrig
        /// sein. `-` allein ist Text (stdin), keine Option.
        func positional(_ count: Int, _ what: String) throws -> [String] {
            if let option = rest.first(where: { $0.hasPrefix("--") }) {
                throw ParseError.usage(used.contains(option) ? "\(option) ist doppelt angegeben" : "Unbekannte Option: \(option)")
            }
            guard rest.count + literal.count == count else { throw ParseError.usage("Erwartet: \(what)") }
            return rest + literal
        }
        /// Text an der Position `index`: nach `--` wörtlich, sonst `-` = stdin, `@pfad` = Datei.
        func text(_ parts: [String], at index: Int) -> TicketsText {
            index >= rest.count ? .literal(parts[index]) : TicketsText(parts[index])
        }
        func key(_ raw: String) throws -> String {
            let upper = raw.uppercased()
            guard upper.range(of: #"^[A-Z][A-Z0-9]*-[0-9]+$"#, options: .regularExpression) != nil else {
                throw ParseError.usage("„\(raw)“ ist keine Ticket-Nummer (erwartet z. B. WM8-12)")
            }
            return upper
        }

        switch command {
        case "help", "--help", "-h":
            return .help
        case "board":
            let all = flag("--all"), team = try value("--team")
            _ = try positional(0, "tickets board [--team T] [--all] [--json]")
            return .board(team: team?.uppercased(), all: all, json: json)
        case "list", "ls":
            var filter = TicketsListFilter()
            if flag("--mine") { filter.person = "me" }
            if flag("--unassigned") { filter.unassigned = true }
            if let person = try value("--person") { filter.person = person }
            if flag("--no-agent") { filter.agent = .withoutAgent }
            if flag("--with-agent") { filter.agent = .withAgent }
            filter.project = try value("--project")
            filter.status = try value("--status")
            let team = try value("--team")
            if filter.unassigned, filter.person != nil { throw ParseError.usage("--unassigned und --person/--mine schließen sich aus") }
            _ = try positional(0, "tickets list [Filter] [--json]")
            return .list(team: team?.uppercased(), filter: filter, json: json)
        case "show":
            return .show(key: try key(try positional(1, "tickets show <Ticket>")[0]), json: json)
        case "mine":
            let chat = try value("--chat")
            _ = try positional(0, "tickets mine [--chat REF] [--json]")
            return .mine(chat: chat, json: json)
        case "link":
            let keep = flag("--no-status"), chat = try value("--chat")
            return .link(key: try key(try positional(1, "tickets link <Ticket> [--chat REF] [--no-status]")[0]), chat: chat, keepStatus: keep)
        case "done":
            let chat = try value("--chat"), status = try value("--status"), note = try value("--note").map(TicketsText.init)
            return .done(key: try key(try positional(1, "tickets done <Ticket> [--status S] [--note TEXT]")[0]),
                         chat: chat, status: status, note: note)
        case "unlink":
            let chat = try value("--chat")
            return .unlink(key: try key(try positional(1, "tickets unlink <Ticket> [--chat REF]")[0]), chat: chat)
        case "status":
            let parts = try positional(2, "tickets status <Ticket> <Status>")
            return .status(key: try key(parts[0]), name: parts[1])
        case "note":
            let parts = try positional(2, "tickets note <Ticket> <Text | - | @Datei>")
            return .note(key: try key(parts[0]), text: text(parts, at: 1))
        case "comment":
            let parts = try positional(2, "tickets comment <Ticket> <Text | - | @Datei>")
            return .comment(key: try key(parts[0]), text: text(parts, at: 1))
        case "new":
            var options = TicketsNewOptions()
            options.team = try value("--team")?.uppercased()
            options.description = try value("--description").map(TicketsText.init)
            options.project = try value("--project")
            options.status = try value("--status")
            options.assignee = try value("--assignee")
            options.labels = try list("--labels")
            if let raw = try value("--priority") {
                guard let priority = TicketsNewOptions.priority(raw) else {
                    throw ParseError.usage("--priority: urgent, high, medium, low oder 1 bis 4")
                }
                options.priority = priority
            }
            options.title = try positional(1, "tickets new <Titel> [--description …] [--project …]")[0]
            guard !options.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ParseError.usage("Titel fehlt") }
            return .new(options)
        case "assign":
            let parts = try positional(2, "tickets assign <Ticket> <me | none | Name>")
            return .assign(key: try key(parts[0]), person: parts[1])
        case "label":
            let add = try list("--add"), remove = try list("--remove")
            guard !add.isEmpty || !remove.isEmpty else { throw ParseError.usage("--add und/oder --remove angeben") }
            return .label(key: try key(try positional(1, "tickets label <Ticket> --add a,b --remove c")[0]), add: add, remove: remove)
        case "setup":
            let stdin = flag("--key-stdin"), project = try value("--project"), team = try value("--team")
            guard (project == nil) == (team == nil) else { throw ParseError.usage("--project und --team gehören zusammen") }
            _ = try positional(0, "tickets setup [--key-stdin] [--project ORDNER --team T]")
            return .setup(keyFromStdin: stdin, project: project, team: team?.uppercased())
        case "doctor":
            _ = try positional(0, "tickets doctor [--json]")
            return .doctor(json: json)
        default:
            throw ParseError.usage("Unbekannter Befehl: \(command)")
        }
    }
}

/// Text für `note`, `comment`, `--note` und `--description`.
enum TicketsText: Equatable {
    case literal(String)
    case stdin
    case file(String)

    /// `-` = stdin, `@pfad` = Datei, sonst der Text selbst.
    init(_ raw: String) {
        if raw == "-" {
            self = .stdin
        } else if raw.hasPrefix("@"), raw.count > 1 {
            self = .file(String(raw.dropFirst()))
        } else {
            self = .literal(raw)
        }
    }
}

struct TicketsListFilter: Equatable {
    var agent: TicketAgentFilter = .all
    /// „me“, eine ID oder ein Namensteil.
    var person: String?
    var unassigned = false
    var project: String?
    var status: String?
}

struct TicketsNewOptions: Equatable {
    var team: String?
    var title = ""
    var description: TicketsText?
    var project: String?
    var status: String?
    var priority: Int?
    var labels: [String] = []
    var assignee: String?

    static func priority(_ raw: String) -> Int? {
        switch raw.lowercased() {
        case "1", "urgent", "dringend": return 1
        case "2", "high", "hoch": return 2
        case "3", "medium", "mittel": return 3
        case "4", "low", "niedrig": return 4
        default: return nil
        }
    }
}

enum TicketsCLIExit {
    static let ok: Int32 = 0
    static let usage: Int32 = 1
    /// Ticket, Status, Person, Chat oder Team nicht gefunden.
    static let notFound: Int32 = 3
    /// Mehrdeutig oder widersprüchlich.
    static let conflict: Int32 = 4
    /// Ticket-Werkzeug nicht eingerichtet, nicht erreichbar oder lehnt ab.
    static let unavailable: Int32 = 5
}

enum TicketsCLICommand {
    static let help = """
    whisperm8 tickets: Tickets aus Linear und die Chats, die daran arbeiten

    LESEN
      whisperm8 tickets board [--team T] [--all] [--json]
                Tickets nach Status mit Chat und dessen Zustand; dazu laufende
                Chats ohne offenes Ticket und die Supervisor-Chats.
      whisperm8 tickets list [--mine | --unassigned | --person NAME]
                             [--no-agent | --with-agent] [--project VORHABEN]
                             [--status STATUS] [--team T] [--json]
      whisperm8 tickets show <Ticket> [--json]
      whisperm8 tickets mine [--chat REF] [--json]     Tickets dieses Chats

    CHAT UND TICKET
      whisperm8 tickets link <Ticket> [--chat REF] [--no-status]
                Hängt den Chat ans Ticket. Ein Ticket, das noch nicht in Arbeit
                ist, wechselt auf den ersten „in Arbeit“-Status.
      whisperm8 tickets done <Ticket> [--status S] [--note TEXT] [--chat REF]
                Beendet die Verknüpfung; setzt auf Wunsch Status und Stand-Zeile.
      whisperm8 tickets unlink <Ticket> [--chat REF]   Falsch verknüpft: entfernen.

    STATUS UND TEXT
      whisperm8 tickets status <Ticket> <Status>       z. B. "Merge-bereit", "Done"
      whisperm8 tickets note <Ticket> <Text>           ersetzt die Zeile „**Stand …:**“
      whisperm8 tickets comment <Ticket> <Text>
                Text: direkt, `-` für stdin oder `@datei`. Markdown. Beginnt der
                Text selbst mit `-` oder `@`, gehört er hinter `--`:
                tickets comment WM8-12 -- "@Giuliano bitte prüfen"

    ANLEGEN UND ZUORDNEN
      whisperm8 tickets new <Titel> [--description TEXT] [--project VORHABEN]
                            [--status S] [--priority high] [--labels a,b]
                            [--assignee me|NAME] [--team T]
      whisperm8 tickets assign <Ticket> <me | none | NAME>
      whisperm8 tickets label <Ticket> [--add a,b] [--remove c]

    EINRICHTEN
      whisperm8 tickets setup --key-stdin              Linear-Key aus stdin in den Schlüsselbund
      whisperm8 tickets setup --project ORDNER --team T
      whisperm8 tickets setup                          zeigt die Einrichtung
      whisperm8 tickets doctor [--json]                prüft Zugang, Zuordnung und App

    Jeder Befehl kennt `--json`; schreibende Befehle antworten dann mit
    {"ok": true, "key": …, "message": …}. Fehler stehen auf stderr, der
    Exit-Code sagt, welcher Art.

    Der Chat ist der, in dem der Befehl läuft; `--chat` nimmt den Anfang einer
    Chat-ID aus `whisperm8 chats list`. Das Team ergibt sich aus dem Projekt
    des aktuellen Ordners, sonst `--team`. Der Zustand der Chats kommt aus der
    laufenden App; ohne App bleibt er leer.

    Exit: 0 ok, 1 Aufruf falsch, 3 nicht gefunden, 4 mehrdeutig, 5 Linear
    nicht eingerichtet, nicht erreichbar oder lehnt ab.
    """

    static func run(arguments: [String]) async -> Int32 {
        let parsed: TicketsCLIArguments
        do {
            parsed = try TicketsCLIArguments.parse(arguments)
        } catch TicketsCLIArguments.ParseError.usage(let message) {
            CLIIO.err("Fehler: \(message)")
            CLIIO.err("Hilfe: whisperm8 tickets --help")
            return TicketsCLIExit.usage
        } catch {
            return TicketsCLIExit.usage
        }
        let output = await TicketsCLIRunner.execute(parsed, environment: .live, json: TicketsCLIArguments.wantsJSON(arguments))
        if !output.stdout.isEmpty { CLIIO.out(output.stdout) }
        if !output.stderr.isEmpty { CLIIO.err(output.stderr) }
        return output.exitCode
    }
}

// MARK: - Umgebung

/// Alles, was der Befehl von außen braucht, als Closures: Tests ersetzen Netz,
/// Schlüsselbund, App und Dateien.
struct TicketsCLIEnvironment {
    var source: TicketSource
    var config: () -> TicketConfig
    var saveConfig: (TicketConfig) throws -> Void
    var credential: TicketCredentialStore
    /// Prüft einen neuen Key, bevor er gespeichert wird.
    var validateKey: (String) async -> Result<TicketAccount, TicketSourceError>
    /// Alle Chats samt Zustand; `appReachable` sagt, ob der Zustand echt ist.
    var chats: () -> (chats: [TicketChat], appReachable: Bool)
    var callerChatID: () -> UUID?
    var currentDirectory: () -> String
    var readStdin: () -> String
    var readFile: (String) -> String?
    var now: () -> Date

    static var live: TicketsCLIEnvironment {
        let configStore = TicketConfigStore.live
        return TicketsCLIEnvironment(
            source: LinearTicketSource(),
            config: { configStore.load() },
            saveConfig: { try configStore.save($0) },
            credential: .live,
            validateKey: { key in
                var client = LinearGraphQLClient.live
                client.apiKey = { key }
                do { return .success(try await LinearTicketSource(client: client).account()) } catch let error as TicketSourceError {
                    return .failure(error)
                } catch {
                    return .failure(.network("Netzfehler"))
                }
            },
            chats: { TicketsLiveChats.load() },
            callerChatID: {
                ChatsCallerIdentity.checked(sessions: { ChatsWorkspaceReader().load().entries.map(\.session) }).sessionID
            },
            currentDirectory: { FileManager.default.currentDirectoryPath },
            readStdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) },
            readFile: { try? String(contentsOfFile: ($0 as NSString).expandingTildeInPath, encoding: .utf8) },
            now: Date.init
        )
    }
}

/// Chats aus dem Workspace (von Disk) mit dem Live-Zustand der App.
enum TicketsLiveChats {
    static func load() -> (chats: [TicketChat], appReachable: Bool) {
        let entries = ChatsWorkspaceReader().load().entries
        let live = ChatsLiveMerge.fetch()
        let running = live?.attachedIDs ?? []
        let chats = entries.map { entry in
            TicketChat(
                id: entry.session.id,
                title: entry.session.title,
                projectName: entry.projectName,
                projectPath: TicketConfig.normalized(entry.projectPath),
                state: live.map { TicketChatState($0[entry.session.id]?.runtimeStatus) },
                isRunning: running.contains(entry.session.id)
            )
        }
        return (chats, live != nil)
    }
}
