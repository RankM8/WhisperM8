import Foundation

// MARK: - Ausführung von `whisperm8 tickets …`

enum TicketsCLIRunner {
    struct Output: Equatable {
        var exitCode: Int32
        var stdout: String = ""
        var stderr: String = ""
    }

    /// Fehler mit fertigem Exit-Code, damit die Befehle gerade durchlaufen.
    private struct Failure: Error {
        var exitCode: Int32
        var message: String
    }

    static func execute(_ arguments: TicketsCLIArguments, environment env: TicketsCLIEnvironment, json: Bool = false) async -> Output {
        // Der Prüfbericht geht immer nach stdout; nur der Exit-Code zeigt ein Problem.
        if case .doctor(let asJSON) = arguments {
            let report = await doctor(env)
            return Output(exitCode: report.allSatisfy(\.ok) ? TicketsCLIExit.ok : TicketsCLIExit.unavailable,
                          stdout: TicketsCLIFormatter.doctor(report, json: asJSON))
        }
        do {
            let text = try await run(arguments, env)
            guard json, arguments.isWrite else { return Output(exitCode: TicketsCLIExit.ok, stdout: text) }
            var object: [String: Any] = ["ok": true, "message": text]
            // `new` nennt die neue Nummer am Anfang seiner Meldung.
            let firstWord = text.split(separator: " ").first.map(String.init) ?? ""
            if let key = arguments.ticketKey ?? (firstWord.contains("-") ? firstWord : nil) {
                object["key"] = key
            }
            return Output(exitCode: TicketsCLIExit.ok, stdout: TicketsCLIFormatter.jsonString(object))
        } catch let failure as Failure {
            return Output(exitCode: failure.exitCode, stderr: failure.message)
        } catch let error as TicketSourceError {
            return Output(exitCode: exitCode(for: error), stderr: error.message)
        } catch {
            return Output(exitCode: TicketsCLIExit.unavailable, stderr: "Unerwarteter Fehler: \(error)")
        }
    }

    static func exitCode(for error: TicketSourceError) -> Int32 {
        switch error {
        case .notFound: return TicketsCLIExit.notFound
        case .ambiguous: return TicketsCLIExit.conflict
        case .notConfigured, .unauthorized, .rateLimited, .network, .rejected, .invalidResponse:
            return TicketsCLIExit.unavailable
        }
    }

    private static func run(_ arguments: TicketsCLIArguments, _ env: TicketsCLIEnvironment) async throws -> String {
        switch arguments {
        case .help:
            return TicketsCLICommand.help

        case .board(let team, let all, let json):
            let (model, snapshot, reachable) = try await board(team: team, env)
            return TicketsCLIFormatter.board(model, snapshot: snapshot, includeBacklog: true, includeClosed: all,
                                             appReachable: reachable, json: json)

        case .list(let team, let filter, let json):
            let (model, _, reachable) = try await board(team: team, env)
            var boardFilter = TicketBoardFilter(agent: filter.agent, project: filter.project)
            if filter.unassigned { boardFilter.person = .unassigned }
            if let query = filter.person {
                boardFilter.person = .person(id: try await env.source.person(matching: query).id)
            }
            var entries = boardFilter.apply(to: model.entries)
            if let status = filter.status?.lowercased() {
                entries = entries.filter { $0.ticket.status.name.lowercased() == status || $0.ticket.status.kind.rawValue == status }
            }
            return TicketsCLIFormatter.list(entries.sorted(by: TicketBoardLayout.order), appReachable: reachable, json: json)

        case .show(let key, let json):
            let context = try await env.source.ticket(key: key)
            let (chats, reachable) = env.chats()
            return TicketsCLIFormatter.show(context, chats: chats, appReachable: reachable, json: json)

        case .mine(let chatRef, let json):
            let chat = try callerChat(chatRef, env)
            let tickets = try await env.source.tickets(linkedTo: chat.id)
            return TicketsCLIFormatter.mine(tickets, chat: chat, json: json)

        case .link(let key, let chatRef, let keepStatus):
            let chat = try callerChat(chatRef, env)
            let context = try await env.source.ticket(key: key)
            try await env.source.saveLink(ticketID: context.ticket.id, chat: chat, active: true, at: env.now())
            var statusName = context.ticket.status.name
            let notStarted: Set<TicketStatusKind> = [.backlog, .unstarted, .triage]
            if !keepStatus, notStarted.contains(context.ticket.status.kind), let started = context.firstStatus(of: .started) {
                try await env.source.setStatus(ticketID: context.ticket.id, statusID: started.id)
                statusName = started.name
            }
            var lines = ["\(key) „\(context.ticket.title)“ hängt jetzt an Chat „\(chat.title)“. Status: \(statusName)"]
            let (allChats, _) = env.chats()
            for other in context.ticket.activeLinks where other.chatID != chat.id {
                let name = allChats.first { $0.id == other.chatID }?.shortName ?? other.title
                lines.append("Hinweis: An dem Ticket sitzt schon \(name).")
            }
            if context.ticket.status.kind.isClosed {
                lines.append("Hinweis: Das Ticket ist \(context.ticket.status.name). Für neue Arbeit erst den Status ändern.")
            }
            return lines.joined(separator: "\n")

        case .done(let key, let chatRef, let status, let note):
            let chat = try callerChat(chatRef, env)
            let context = try await env.source.ticket(key: key)
            // Erst alles prüfen, dann schreiben: Ein falscher Statusname oder ein
            // leerer Text soll nichts halb ändern.
            let target = try status.map { try resolveStatus($0, in: context) }
            let noteText = try note.map { try text($0, env) }
            // Nur eine laufende Verknüpfung beenden; eine schon beendete behält ihre Zeit.
            let wasActive = context.ticket.activeLinks.contains { $0.chatID == chat.id }
            if wasActive {
                try await env.source.saveLink(ticketID: context.ticket.id, chat: chat, active: false, at: env.now())
            }
            if let noteText {
                try await env.source.setDescription(
                    ticketID: context.ticket.id,
                    description: TicketStandLine.apply(noteText, to: context.ticket.description, on: env.now()))
            }
            if let target, target.id != context.ticket.status.id {
                try await env.source.setStatus(ticketID: context.ticket.id, statusID: target.id)
            }
            let linked = wasActive ? "Verknüpfung mit „\(chat.shortName)“ beendet."
                : "„\(chat.shortName)“ war nicht (mehr) verknüpft."
            return "\(key): \(linked) Status: \((target ?? context.ticket.status).name)"

        case .unlink(let key, let chatRef):
            let chat = try callerChat(chatRef, env)
            let context = try await env.source.ticket(key: key)
            let mine = context.ticket.links.filter { $0.chatID == chat.id }
            for link in mine { try await env.source.removeLink(id: link.id) }
            return mine.isEmpty ? "\(key): „\(chat.shortName)“ war nicht verknüpft." : "\(key): Verknüpfung mit „\(chat.shortName)“ entfernt."

        case .status(let key, let name):
            let context = try await env.source.ticket(key: key)
            let target = try resolveStatus(name, in: context)
            if target.id == context.ticket.status.id { return "\(key) steht schon auf \(target.name)." }
            try await env.source.setStatus(ticketID: context.ticket.id, statusID: target.id)
            return "\(key): \(context.ticket.status.name) → \(target.name)"

        case .note(let key, let raw):
            let context = try await env.source.ticket(key: key)
            let note = try text(raw, env)
            try await env.source.setDescription(
                ticketID: context.ticket.id,
                description: TicketStandLine.apply(note, to: context.ticket.description, on: env.now()))
            return "\(key): Stand-Zeile aktualisiert."

        case .comment(let key, let raw):
            let context = try await env.source.ticket(key: key)
            try await env.source.addComment(ticketID: context.ticket.id, body: try text(raw, env))
            return "\(key): Kommentar angelegt."

        case .new(let options):
            let team = try resolveTeam(options.team, env)
            let assignee = try await options.assignee.asyncMap { try await env.source.person(matching: $0).id }
            let created = try await env.source.create(TicketDraft(
                team: team, title: options.title,
                description: try options.description.map { try text($0, env) } ?? "",
                project: options.project, statusName: options.status, priority: options.priority,
                labels: options.labels, assigneeID: assignee))
            return "\(created.key) angelegt: \(created.title)" + (created.url.map { "\n\($0)" } ?? "")

        case .assign(let key, let query):
            let context = try await env.source.ticket(key: key)
            if query == "none" {
                try await env.source.assign(ticketID: context.ticket.id, personID: nil)
                return "\(key): niemandem zugewiesen."
            }
            let person = try await env.source.person(matching: query)
            try await env.source.assign(ticketID: context.ticket.id, personID: person.id)
            return "\(key): \(person.name) zugewiesen."

        case .label(let key, let add, let remove):
            let context = try await env.source.ticket(key: key)
            try await env.source.changeLabels(ticketID: context.ticket.id, team: context.team, add: add, remove: remove)
            var parts: [String] = []
            if !add.isEmpty { parts.append("+" + add.joined(separator: ", ")) }
            if !remove.isEmpty { parts.append("−" + remove.joined(separator: ", ")) }
            return "\(key): Labels \(parts.joined(separator: " "))"

        case .setup(let keyFromStdin, let project, let team):
            return try await setup(keyFromStdin: keyFromStdin, project: project, team: team, env)

        case .doctor(let json):
            // Wird in `execute` behandelt (Bericht immer nach stdout).
            return TicketsCLIFormatter.doctor(await doctor(env), json: json)
        }
    }

    // MARK: Bausteine

    private static func board(team: String?, _ env: TicketsCLIEnvironment) async throws
        -> (TicketBoardModel, TicketBoardSnapshot, Bool) {
        let resolved = try resolveTeam(team, env)
        let snapshot = try await env.source.board(team: resolved)
        let (chats, reachable) = env.chats()
        let config = env.config()
        // „Ohne Ticket“ meint Chats dieses Projekts, nicht alle Chats des Rechners.
        // Wer ausdrücklich ein Team nennt, meint dessen Projekt, nicht den Ordner, in dem er steht.
        let projectPath = team == nil
            ? config.projectPath(forDirectory: env.currentDirectory()) ?? config.projectPaths(forTeam: resolved).first
            : config.projectPaths(forTeam: resolved).first
        let model = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: projectPath)
        return (model, snapshot, reachable)
    }

    static func resolveTeam(_ explicit: String?, _ env: TicketsCLIEnvironment) throws -> String {
        if let explicit { return explicit.uppercased() }
        let config = env.config()
        if let team = config.team(forDirectory: env.currentDirectory()) ?? config.onlyTeam { return team }
        throw Failure(exitCode: TicketsCLIExit.usage, message: """
        Team unklar: Dieser Ordner ist keinem Team zugeordnet.
        Entweder --team WM8 angeben oder einmal zuordnen: whisperm8 tickets setup --project <Ordner> --team WM8
        """)
    }

    private static func resolveStatus(_ name: String, in context: TicketContext) throws -> TicketStatus {
        if let status = context.status(named: name) { return status }
        throw Failure(exitCode: TicketsCLIExit.notFound,
                      message: "Status „\(name)“ gibt es im Team \(context.team) nicht. Möglich: "
                        + context.statuses.map(\.name).joined(separator: ", "))
    }

    /// Der Chat, in dem der Befehl läuft, oder der mit `--chat` genannte.
    private static func callerChat(_ ref: String?, _ env: TicketsCLIEnvironment) throws -> TicketChat {
        let (chats, _) = env.chats()
        if let ref {
            switch TicketChatRef.resolve(ref, in: chats) {
            case .found(let chat): return chat
            case .none:
                throw Failure(exitCode: TicketsCLIExit.notFound, message: "Chat „\(ref)“ nicht gefunden (IDs: whisperm8 chats list).")
            case .ambiguous(let count):
                throw Failure(exitCode: TicketsCLIExit.conflict, message: "„\(ref)“ passt auf \(count) Chats. Mehr Zeichen der ID angeben.")
            }
        }
        guard let id = env.callerChatID(), let chat = chats.first(where: { $0.id == id }) else {
            throw Failure(exitCode: TicketsCLIExit.usage,
                          message: "Dieser Befehl läuft in keinem WhisperM8-Chat. Chat mit --chat <ID-Anfang> angeben.")
        }
        return chat
    }

    private static func text(_ argument: TicketsText, _ env: TicketsCLIEnvironment) throws -> String {
        let value: String
        switch argument {
        case .literal(let text):
            value = text
        case .stdin:
            value = env.readStdin()
        case .file(let path):
            guard let content = env.readFile(path) else {
                throw Failure(exitCode: TicketsCLIExit.usage, message: "Datei nicht lesbar: \(path)")
            }
            value = content
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(exitCode: TicketsCLIExit.usage, message: "Leerer Text.") }
        return trimmed
    }

    // MARK: Einrichten und prüfen

    private static func setup(keyFromStdin: Bool, project: String?, team: String?, _ env: TicketsCLIEnvironment) async throws -> String {
        var lines: [String] = []
        if keyFromStdin {
            let key = env.readStdin().trimmingCharacters(in: .whitespacesAndNewlines)
            guard TicketCredentialStore.isStorable(key) else {
                throw Failure(exitCode: TicketsCLIExit.usage, message: "Kein gültiger Key auf stdin (erwartet: der kopierte Linear-API-Key).")
            }
            switch await env.validateKey(key) {
            case .failure(let error):
                throw Failure(exitCode: exitCode(for: error), message: "Key nicht gespeichert. " + error.message)
            case .success(let account):
                guard env.credential.write(key) else {
                    throw Failure(exitCode: TicketsCLIExit.unavailable, message: "Der Schlüsselbund-Eintrag ließ sich nicht schreiben.")
                }
                lines.append("Key im Schlüsselbund. Gehört zu \(account.workspace) als \(account.userName)\(account.isAdmin ? ", Admin" : "").")
            }
        }
        if let project, let team {
            var config = env.config()
            let path = (project as NSString).isAbsolutePath ? project
                : ((env.currentDirectory() as NSString).appendingPathComponent(project) as NSString).standardizingPath
            config.set(team: team, forProject: path)
            try env.saveConfig(config)
            lines.append("\(TicketConfig.normalized(path)) gehört zum Team \(team).")
        }
        if lines.isEmpty {
            let config = env.config()
            lines.append("Linear-Key: " + (env.credential.read() == nil ? "fehlt (whisperm8 tickets setup --key-stdin)" : "hinterlegt"))
            if config.teamsByProjectPath.isEmpty {
                lines.append("Zuordnung: keine (whisperm8 tickets setup --project <Ordner> --team WM8)")
            }
            for (path, team) in config.teamsByProjectPath.sorted(by: { $0.key < $1.key }) {
                lines.append("Zuordnung: \(path) → \(team)")
            }
        }
        return lines.joined(separator: "\n")
    }

    struct Check: Equatable {
        var name: String
        var ok: Bool
        var detail: String
    }

    static func doctor(_ env: TicketsCLIEnvironment) async -> [Check] {
        var checks: [Check] = []
        guard env.credential.read() != nil else {
            return [Check(name: "Linear-Key", ok: false, detail: "fehlt. Einrichten: whisperm8 tickets setup --key-stdin")]
        }
        do {
            let account = try await env.source.account()
            checks.append(Check(name: "Linear-Zugang", ok: true,
                                detail: "\(account.workspace) als \(account.userName)\(account.isAdmin ? ", Admin" : "")"))
        } catch {
            let message = (error as? TicketSourceError)?.message ?? "\(error)"
            return [Check(name: "Linear-Zugang", ok: false, detail: message)]
        }
        let config = env.config()
        if config.teamsByProjectPath.isEmpty {
            checks.append(Check(name: "Zuordnung", ok: false,
                                detail: "kein Projekt zugeordnet. whisperm8 tickets setup --project <Ordner> --team WM8"))
        }
        for team in Set(config.teamsByProjectPath.values).sorted() {
            do {
                let snapshot = try await env.source.board(team: team)
                let open = snapshot.tickets.filter { !$0.status.kind.isClosed }
                checks.append(Check(name: "Team \(team)", ok: true,
                                    detail: "\(open.count) offene Tickets, \(open.filter { !$0.activeLinks.isEmpty }.count) mit Agent"))
            } catch {
                checks.append(Check(name: "Team \(team)", ok: false, detail: (error as? TicketSourceError)?.message ?? "\(error)"))
            }
        }
        let (chats, reachable) = env.chats()
        // Ohne App gehen alle Befehle, nur der Zustand der Chats fehlt: kein Fehler.
        checks.append(Check(name: "App", ok: true,
                            detail: reachable ? "erreichbar, \(chats.filter(\.isRunning).count) Chats laufen"
                                : "nicht erreichbar, Zustand der Chats bleibt leer"))
        return checks
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}

// MARK: - Chat-Referenz

enum TicketChatRef {
    enum Outcome: Equatable {
        case found(TicketChat)
        case none
        case ambiguous(Int)
    }

    /// Volle ID oder ihr Anfang (mindestens vier Zeichen, ohne Groß/Klein).
    static func resolve(_ ref: String, in chats: [TicketChat]) -> Outcome {
        let wanted = ref.lowercased()
        guard wanted.count >= 4 else { return .none }
        let hits = chats.filter { $0.id.uuidString.lowercased().hasPrefix(wanted) }
        switch hits.count {
        case 0: return .none
        case 1: return .found(hits[0])
        default: return .ambiguous(hits.count)
        }
    }
}

// MARK: - Ausgabe

enum TicketsCLIFormatter {
    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        let cut = text.count > width ? String(text.prefix(width - 1)) + "…" : text
        return cut.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func stateLabel(_ chat: TicketChat?) -> String {
        guard let chat else { return "anderer Rechner oder gelöscht" }
        return chat.state?.cliLabel ?? "Zustand unbekannt"
    }

    static func agentText(_ entry: TicketBoardEntry) -> String {
        if entry.isHandedOver { return "abgegeben von " + entry.handedOverBy.joined(separator: ", ") }
        return agentText(entry.agents)
    }

    static func agentText(_ agents: [TicketAgent]) -> String {
        if agents.isEmpty { return "kein Agent" }
        return agents.map { agent in
            let name = agent.chat?.shortName ?? agent.link.title.replacingOccurrences(of: "Chat: ", with: "")
            return "\(name) (\(stateLabel(agent.chat)))"
        }.joined(separator: ", ")
    }

    static func ticketObject(_ ticket: Ticket) -> [String: Any] {
        var object: [String: Any] = [
            "key": ticket.key, "title": ticket.title, "status": ticket.status.name, "statusKind": ticket.status.kind.rawValue,
            "priority": ticket.priority, "labels": ticket.labels, "blocked": ticket.isBlocked,
        ]
        if let project = ticket.project { object["project"] = project }
        if let milestone = ticket.milestone { object["milestone"] = milestone }
        if let assignee = ticket.assignee { object["assignee"] = assignee.name }
        if let url = ticket.url { object["url"] = url }
        return object
    }

    static func entryObject(_ entry: TicketBoardEntry) -> [String: Any] {
        var object = ticketObject(entry.ticket)
        if entry.isHandedOver { object["handedOverBy"] = entry.handedOverBy }
        object["agents"] = entry.agents.map { agent -> [String: Any] in
            var item: [String: Any] = ["chatID": agent.link.chatID.uuidString, "onThisMac": agent.chat != nil, "since": agent.link.subtitle]
            if let chat = agent.chat {
                item["chat"] = chat.title
                if let state = chat.state { item["state"] = state.rawValue }
            }
            if let creator = agent.link.creatorName { item["linkedBy"] = creator }
            return item
        }
        return object
    }

    static func chatObject(_ chat: TicketChat) -> [String: Any] {
        var object: [String: Any] = ["id": chat.id.uuidString, "shortID": String(chat.id.uuidString.prefix(8)).lowercased(), "title": chat.title]
        if let state = chat.state { object["state"] = state.rawValue }
        return object
    }

    private static let columnTitles: [TicketStatusKind: String] = [.started: "In Arbeit", .unstarted: "Als Nächstes", .backlog: "Backlog"]

    static func board(_ model: TicketBoardModel, snapshot: TicketBoardSnapshot, includeBacklog: Bool, includeClosed: Bool,
                      appReachable: Bool, json: Bool) -> String {
        let columns = TicketBoardLayout.columns(model.entries)
        let closed = includeClosed ? snapshot.tickets.filter { $0.status.kind.isClosed } : []
        if json {
            var object: [String: Any] = [
                "team": snapshot.team,
                "fetchedAt": ISO8601DateFormatter().string(from: snapshot.fetchedAt),
                "appReachable": appReachable,
                "tickets": columns.flatMap(\.entries).map(entryObject),
                "chatsWithoutOpenTicket": model.looseChats.map { loose -> [String: Any] in
                    var item = chatObject(loose.chat)
                    item["earlier"] = loose.earlier
                    return item
                },
                "supervisors": model.supervisors.map(chatObject),
            ]
            if includeClosed { object["closedWithLink"] = closed.map(ticketObject) }
            return jsonString(object)
        }
        var lines: [String] = []
        for column in columns {
            lines.append("== \(columnTitles[column.kind] ?? column.kind.rawValue)  (\(column.entries.count) Tickets, \(column.agentCount) mit Agent)")
            for entry in column.entries {
                let ticket = entry.ticket
                var marks = ticket.status.name
                if ticket.isBlocked { marks += ", blockiert" }
                lines.append("  \(pad(ticket.key, 8))\(pad(ticket.title, 50)) | \(pad(marks, 24)) | \(pad(ticket.assignee?.name.components(separatedBy: " ").first ?? "–", 9)) | \(agentText(entry))")
            }
            lines.append("")
        }
        if !model.looseChats.isEmpty {
            lines.append("== Laufende Chats ohne offenes Ticket (\(model.looseChats.count))")
            for loose in model.looseChats {
                let trail = loose.earlier.isEmpty ? "noch nie verknüpft" : "zuletzt an " + loose.earlier.suffix(2).joined(separator: ", ")
                lines.append("  \(String(loose.chat.id.uuidString.prefix(8)).lowercased())  \(pad(loose.chat.title, 52)) | \(pad(stateLabel(loose.chat), 15)) | \(trail)")
            }
            lines.append("")
        }
        if !model.supervisors.isEmpty {
            lines.append("== Supervisor (\(model.supervisors.count), ohne Ticket vorgesehen)")
            for chat in model.supervisors {
                lines.append("  \(String(chat.id.uuidString.prefix(8)).lowercased())  \(pad(chat.title, 52)) | \(stateLabel(chat))")
            }
            lines.append("")
        }
        if !closed.isEmpty {
            lines.append("== Erledigt, mit Chat-Spur (\(closed.count))")
            for ticket in closed { lines.append("  \(pad(ticket.key, 8))\(pad(ticket.title, 50)) | \(ticket.status.name)") }
            lines.append("")
        }
        if !appReachable {
            lines.append("Hinweis: Die App ist nicht erreichbar. Zustand der Chats und „ohne Ticket“ fehlen.")
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func list(_ entries: [TicketBoardEntry], appReachable: Bool, json: Bool) -> String {
        if json { return jsonString(entries.map(entryObject)) }
        if entries.isEmpty { return "(keine Tickets für diesen Filter)" }
        return entries.map { entry in
            let ticket = entry.ticket
            return "\(pad(ticket.key, 8))\(pad(ticket.status.name, 13)) \(pad(ticket.assignee?.name.components(separatedBy: " ").first ?? "–", 9)) \(pad(ticket.project ?? "–", 22)) \(pad(ticket.title, 54)) | \(agentText(entry))"
        }.joined(separator: "\n")
    }

    static func show(_ context: TicketContext, chats: [TicketChat], appReachable: Bool, json: Bool) -> String {
        let ticket = context.ticket
        let byID = Dictionary(chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = ticket.activeLinks.map { TicketAgent(link: $0, chat: byID[$0.chatID]) }
        if json {
            var object = entryObject(TicketBoardEntry(ticket: ticket, agents: agents))
            object["description"] = ticket.description
            object["team"] = context.team
            object["statuses"] = context.statuses.map(\.name)
            object["earlierChats"] = ticket.links.filter { !$0.isActive }.map { $0.title.replacingOccurrences(of: "Chat: ", with: "") }
            return jsonString(object)
        }
        var lines = [
            "\(ticket.key)  \(ticket.title)",
            "Status: \(ticket.status.name)\(ticket.isBlocked ? " (blockiert)" : "") | Priorität: \(priorityName(ticket.priority)) | Zugewiesen: \(ticket.assignee?.name ?? "niemand")",
            "Vorhaben: \(ticket.project ?? "–")\(ticket.milestone.map { " · \($0)" } ?? "") | Labels: \(ticket.labels.isEmpty ? "–" : ticket.labels.joined(separator: ", "))",
            "Agent: \(agentText(agents))",
        ]
        let earlier = ticket.links.filter { !$0.isActive }
        if !earlier.isEmpty {
            lines.append("Früher: " + earlier.map { "\($0.title.replacingOccurrences(of: "Chat: ", with: "")) (\($0.subtitle.components(separatedBy: " · ").first ?? ""))" }.joined(separator: "; "))
        }
        if let url = ticket.url { lines.append(url) }
        if !ticket.description.isEmpty { lines.append(""); lines.append(ticket.description) }
        return lines.joined(separator: "\n")
    }

    static func mine(_ tickets: [Ticket], chat: TicketChat, json: Bool) -> String {
        let rows = tickets.sorted { TicketBoardBuilder.keyOrder($0.key, $1.key) }
        if json {
            return jsonString(rows.map { ticket -> [String: Any] in
                var object = ticketObject(ticket)
                object["active"] = ticket.links.contains { $0.chatID == chat.id && $0.isActive }
                return object
            })
        }
        if rows.isEmpty { return "An „\(chat.shortName)“ hängt kein Ticket." }
        return rows.map { ticket in
            let link = ticket.links.first { $0.chatID == chat.id }
            return "\(pad(ticket.key, 8))\(pad(ticket.status.name, 13)) \(pad(ticket.title, 60)) | \(link?.subtitle.components(separatedBy: " · ").first ?? "")"
        }.joined(separator: "\n")
    }

    static func doctor(_ checks: [TicketsCLIRunner.Check], json: Bool) -> String {
        if json { return jsonString(checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] as [String: Any] }) }
        return checks.map { "\($0.ok ? "ok    " : "FEHLER") \(pad($0.name, 14)) \($0.detail)" }.joined(separator: "\n")
    }

    static func priorityName(_ priority: Int) -> String {
        switch priority {
        case 1: return "dringend"
        case 2: return "hoch"
        case 3: return "mittel"
        case 4: return "niedrig"
        default: return "keine"
        }
    }
}
