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

    /// Wählt je Team die Quelle des richtigen Workspaces und hält die
    /// Projektgrenze ein: Aus einem Projekt wird nicht in den Workspace eines
    /// anderen geschrieben. Zwei Firmen, zwei Workspaces; ein Chat der einen
    /// soll die Tickets der anderen lesen, aber nie versehentlich ändern.
    private final class Access {
        let env: TicketsCLIEnvironment
        let isWrite: Bool
        let allowOther: Bool
        /// Zuletzt angesprochener Workspace, für Fehlermeldungen zum Zugang.
        private(set) var used: String?

        init(env: TicketsCLIEnvironment, isWrite: Bool, allowOther: Bool) {
            self.env = env
            self.isWrite = isWrite
            self.allowOther = allowOther
        }

        func workspace(forTeam team: String) throws -> String {
            let config = env.config()
            guard let target = config.workspace(forTeam: team) else {
                if config.knownWorkspaces.isEmpty { throw TicketSourceError.notConfigured }
                throw Failure(exitCode: TicketsCLIExit.usage, message: """
                Team \(team) ist keinem Workspace zugeordnet (eingerichtet: \(config.knownWorkspaces.joined(separator: ", "))).
                Einmal zuordnen: whisperm8 tickets setup --team \(team)
                """)
            }
            if isWrite, !allowOther, let home = home(config), home.workspace != target {
                throw Failure(exitCode: TicketsCLIExit.conflict, message: """
                Team \(team) liegt im Workspace „\(target)“, \(home.who) gehört zu „\(home.workspace)“. Aus einem Projekt wird \
                nicht in den Workspace eines anderen geschrieben; lesen geht.
                Nur wenn der Nutzer es ausdrücklich verlangt: --other-workspace
                """)
            }
            return target
        }

        /// Wohin der Aufrufer gehört. Ist er ein Chat, zählt das Projekt des
        /// Chats, egal in welchem Ordner seine Shell gerade steht (/tmp, Home,
        /// eine Arbeitskopie neben dem Projekt). Der Ordner zählt nur, wenn
        /// kein Chat ruft oder dessen Projekt keinem Workspace zugeordnet ist.
        private func home(_ config: TicketConfig) -> (workspace: String, who: String)? {
            if let id = env.callerChatID(), let chat = env.chats().chats.first(where: { $0.id == id }),
               let workspace = config.workspace(forDirectory: chat.projectPath) {
                return (workspace, "dieser Chat (Projekt \(chat.projectName))")
            }
            return config.workspace(forDirectory: env.currentDirectory()).map { ($0, "dieser Ordner") }
        }

        func source(forTeam team: String) throws -> TicketSource {
            source(in: try workspace(forTeam: team))
        }

        func source(forKey key: String) throws -> TicketSource {
            try source(forTeam: TicketConfig.team(ofKey: key))
        }

        func source(in workspace: String) -> TicketSource {
            used = workspace
            return env.source(workspace)
        }

        /// Ein Chat hängt nur an Tickets des Workspaces, zu dem sein Projekt gehört.
        func guardChat(_ chat: TicketChat, key: String) throws {
            let config = env.config()
            guard !allowOther, let target = config.workspace(forTeam: TicketConfig.team(ofKey: key)),
                  let home = config.workspace(forDirectory: chat.projectPath), home != target else { return }
            throw Failure(exitCode: TicketsCLIExit.conflict, message: """
            Chat „\(chat.shortName)“ gehört zum Projekt \(chat.projectName) (Workspace „\(home)“), \(key) liegt in „\(target)“.
            Nur wenn der Nutzer es ausdrücklich verlangt: --other-workspace
            """)
        }
    }

    static func execute(_ arguments: TicketsCLIArguments, environment env: TicketsCLIEnvironment, json: Bool = false,
                        otherWorkspace: Bool = false) async -> Output {
        // Der Prüfbericht geht immer nach stdout; nur der Exit-Code zeigt ein Problem.
        if case .doctor(let asJSON) = arguments {
            let report = await doctor(env)
            return Output(exitCode: report.allSatisfy(\.ok) ? TicketsCLIExit.ok : TicketsCLIExit.unavailable,
                          stdout: TicketsCLIFormatter.doctor(report, json: asJSON))
        }
        let access = Access(env: env, isWrite: arguments.isWrite, allowOther: otherWorkspace)
        do {
            let text = try await run(arguments, env, access)
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
            // Bei mehreren Zugängen zählt, welcher gemeint ist.
            var message = error.message
            if let workspace = access.used, error == .notConfigured || error == .unauthorized {
                message += " Betroffen: Workspace „\(workspace)“."
            }
            return Output(exitCode: exitCode(for: error), stderr: message)
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

    private static func run(_ arguments: TicketsCLIArguments, _ env: TicketsCLIEnvironment, _ access: Access) async throws -> String {
        switch arguments {
        case .help:
            return TicketsCLICommand.help

        case .board(let team, let all, let json):
            let (model, snapshot, reachable, _) = try await board(team: team, env, access)
            return TicketsCLIFormatter.board(model, snapshot: snapshot, includeBacklog: true, includeClosed: all,
                                             appReachable: reachable, json: json)

        case .list(let team, let filter, let json):
            let (model, _, reachable, source) = try await board(team: team, env, access)
            var boardFilter = TicketBoardFilter(agent: filter.agent, project: filter.project)
            if filter.unassigned { boardFilter.person = .unassigned }
            if let query = filter.person {
                boardFilter.person = .person(id: try await source.person(matching: query).id)
            }
            var entries = boardFilter.apply(to: model.entries)
            if let status = filter.status?.lowercased() {
                entries = entries.filter { $0.ticket.status.name.lowercased() == status || $0.ticket.status.kind.rawValue == status }
            }
            return TicketsCLIFormatter.list(entries.sorted(by: TicketBoardLayout.order), appReachable: reachable, json: json)

        case .show(let key, let json):
            let context = try await access.source(forKey: key).ticket(key: key)
            let (chats, reachable) = env.chats()
            return TicketsCLIFormatter.show(context, chats: chats, appReachable: reachable, json: json)

        case .mine(let chatRef, let json):
            let chat = try callerChat(chatRef, env)
            // Ein Chat kann an Tickets mehrerer Workspaces hängen oder gehangen haben.
            let workspaces = env.config().knownWorkspaces
            guard !workspaces.isEmpty else { throw TicketSourceError.notConfigured }
            var tickets: [Ticket] = []
            for workspace in workspaces {
                tickets += try await access.source(in: workspace).tickets(linkedTo: chat.id)
            }
            return TicketsCLIFormatter.mine(tickets, chat: chat, json: json)

        case .link(let key, let chatRef, let keepStatus):
            let chat = try callerChat(chatRef, env)
            let source = try access.source(forKey: key)
            try access.guardChat(chat, key: key)
            let context = try await source.ticket(key: key)
            try await source.saveLink(ticketID: context.ticket.id, chat: chat, active: true, at: env.now())
            var statusName = context.ticket.status.name
            let notStarted: Set<TicketStatusKind> = [.backlog, .unstarted, .triage]
            if !keepStatus, notStarted.contains(context.ticket.status.kind), let started = context.firstStatus(of: .started) {
                try await source.setStatus(ticketID: context.ticket.id, statusID: started.id)
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

        case .done(let key, let chatRef, let status, let note, let force, let summary):
            let chat = try callerChat(chatRef, env)
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            // Erst alles prüfen, dann schreiben: Ein falscher Statusname oder ein
            // leerer Text soll nichts halb ändern.
            let target = try status.map { try resolveStatus($0, in: context) }
            if let target { try guardCompletion(target, key: key, force: force, env) }
            let noteText = try note.map { try text($0, env) }
            // Wer nach dem Merge auf „erledigt“ setzt, gibt nicht ab: Die Zusammenfassung
            // hat der bauende Chat geschrieben.
            let closing = target?.kind == .completed && !summary.hasContent
            var completion = closing ? nil : try completionRecord(summary, chat: chat, key: key, env)
            let image = try summary.image.map { try imageFile($0, env) }
            if let record = completion {
                // Mit einer Platzhalter-Adresse geprüft, bevor irgendetwas hochgeht.
                var probe = record
                if image != nil { probe.imageURL = String(repeating: "x", count: 300) }
                guard TicketRecordText.completion(probe, at: env.now()).utf8.count <= TicketsText.maxBytes else {
                    throw Failure(exitCode: TicketsCLIExit.usage,
                                  message: "Abschluss zu lang (mehr als \(TicketsText.maxBytes / 1024) KB). Nichts gesendet.")
                }
            }
            // Der Abschluss zuerst: Scheitert er, ist am Ticket noch nichts umgestellt.
            if var record = completion {
                if let image {
                    record.imageURL = try await source.uploadImage(image.data, fileName: image.name, contentType: image.type)
                }
                completion = record
                try await source.addComment(ticketID: context.ticket.id, body: TicketRecordText.completion(record, at: env.now()))
            }
            do {
                // Nur eine laufende Verknüpfung beenden; eine schon beendete behält ihre Zeit.
                let wasActive = context.ticket.activeLinks.contains { $0.chatID == chat.id }
                if wasActive {
                    try await source.saveLink(ticketID: context.ticket.id, chat: chat, active: false, at: env.now())
                }
                if let noteText {
                    try await source.setDescription(
                        ticketID: context.ticket.id,
                        description: TicketStandLine.apply(noteText, to: context.ticket.description, on: env.now()))
                }
                if let target, target.id != context.ticket.status.id {
                    try await source.setStatus(ticketID: context.ticket.id, statusID: target.id)
                }
            } catch let error as TicketSourceError where completion != nil {
                // Ein zweiter Versuch mit Zusammenfassung schriebe den Abschluss doppelt.
                throw Failure(exitCode: exitCode(for: error), message: error.message + """

                Der Abschluss steht schon am Ticket, Verknüpfung oder Status sind noch nicht umgestellt.
                Nachholen ohne zweiten Abschluss: dieselbe Zeile mit --no-summary statt der Zusammenfassung.
                """)
            }
            let wasActive = context.ticket.activeLinks.contains { $0.chatID == chat.id }
            let linked = wasActive ? "Verknüpfung mit „\(chat.shortName)“ beendet."
                : "„\(chat.shortName)“ war nicht (mehr) verknüpft."
            let recorded = completion == nil ? "" : " Abschluss steht am Ticket."
            return "\(key): \(linked)\(recorded) Status: \((target ?? context.ticket.status).name)"

        case .decide(let key, let options):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            // Wer festhält, steht immer dabei, getrennt von dem, der entschieden hat.
            let recorder = env.callerChatID().flatMap { id in env.chats().chats.first { $0.id == id } }
            let by: String
            if let named = options.by?.trimmingCharacters(in: .whitespaces), !named.isEmpty {
                by = named
            } else if recorder != nil {
                // Ein Chat schreibt nicht ungefragt im Namen dessen, dem der Zugang gehört.
                throw Failure(exitCode: TicketsCLIExit.usage, message: """
                Aus einem Chat braucht `decide` --by: wer entschieden hat. Der Name wird nicht aus dem Zugang geraten.
                Hat der Nutzer entschieden: --by "<sein Name>". War es deine eigene Entscheidung: dein Rufname.
                """)
            } else {
                by = try await source.person(matching: "me").name
            }
            let body = TicketRecordText.decision(
                TicketRecordText.Decision(question: options.question, options: options.options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                                          chosen: options.chosen, by: by, recordedBy: recorder?.shortName ?? "im Terminal",
                                          note: options.note),
                at: env.now())
            guard body.utf8.count <= TicketsText.maxBytes else {
                throw Failure(exitCode: TicketsCLIExit.usage, message: "Text zu lang (mehr als \(TicketsText.maxBytes / 1024) KB). Nichts gesendet.")
            }
            try await source.addComment(ticketID: context.ticket.id, body: body)
            return "\(key): Entscheidung festgehalten (\(by))."

        case .check(let key, let references, let uncheck, let json):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            let items = TicketChecklist.items(in: context.ticket.description)
            if references.isEmpty {
                if json {
                    return TicketsCLIFormatter.jsonString([
                        "key": key,
                        "items": items.map { ["number": $0.number, "done": $0.isDone, "text": $0.text] as [String: Any] },
                    ] as [String: Any])
                }
                guard !items.isEmpty else { return "\(key) hat keine Kästchen." }
                return items.map { "\(String($0.number).padding(toLength: 3, withPad: " ", startingAt: 0))[\($0.isDone ? "x" : " ")] \($0.text)" }
                    .joined(separator: "\n")
            }
            let result: (description: String, changed: [TicketChecklistItem])
            do {
                result = try TicketChecklist.setting(references, done: !uncheck, in: context.ticket.description)
            } catch TicketChecklist.Failure.noItems {
                throw Failure(exitCode: TicketsCLIExit.notFound, message: "\(key) hat keine Kästchen.")
            } catch TicketChecklist.Failure.notFound(let reference) {
                throw Failure(exitCode: TicketsCLIExit.notFound,
                              message: "Kein Kästchen passt auf „\(reference)“. Anzeigen: whisperm8 tickets check \(key)")
            } catch TicketChecklist.Failure.ambiguous(let reference, let hits) {
                throw Failure(exitCode: TicketsCLIExit.conflict,
                              message: "„\(reference)“ passt auf mehrere Kästchen: " + hits.map { "\($0.number)" }.joined(separator: ", ")
                                + ". Nummer angeben.")
            }
            let word = uncheck ? "wieder offen" : "abgehakt"
            guard !result.changed.isEmpty else {
                return "\(key): war schon \(uncheck ? "offen" : "abgehakt"), nichts geändert."
            }
            try await source.setDescription(ticketID: context.ticket.id, description: result.description)
            let progress = TicketChecklist.progress(in: result.description)
            return "\(key): \(result.changed.count) Kästchen \(word) (\(progress?.done ?? 0) von \(progress?.total ?? 0) erledigt)."

        case .unlink(let key, let chatRef):
            let chat = try callerChat(chatRef, env)
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            let mine = context.ticket.links.filter { $0.chatID == chat.id }
            for link in mine { try await source.removeLink(id: link.id) }
            return mine.isEmpty ? "\(key): „\(chat.shortName)“ war nicht verknüpft." : "\(key): Verknüpfung mit „\(chat.shortName)“ entfernt."

        case .status(let key, let name, let force):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            let target = try resolveStatus(name, in: context)
            try guardCompletion(target, key: key, force: force, env)
            if target.id == context.ticket.status.id { return "\(key) steht schon auf \(target.name)." }
            try await source.setStatus(ticketID: context.ticket.id, statusID: target.id)
            return "\(key): \(context.ticket.status.name) → \(target.name)"

        case .note(let key, let raw):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            let note = try text(raw, env)
            try await source.setDescription(
                ticketID: context.ticket.id,
                description: TicketStandLine.apply(note, to: context.ticket.description, on: env.now()))
            return "\(key): Stand-Zeile aktualisiert."

        case .comment(let key, let raw):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            try await source.addComment(ticketID: context.ticket.id, body: try text(raw, env))
            return "\(key): Kommentar angelegt."

        case .new(let options):
            let team = try resolveTeam(options.team, env, forWrite: true)
            let source = try access.source(forTeam: team)
            let assignee = try await options.assignee.asyncMap { try await source.person(matching: $0).id }
            let created = try await source.create(TicketDraft(
                team: team, title: options.title,
                description: try options.description.map { try text($0, env) } ?? "",
                project: options.project, statusName: options.status, priority: options.priority,
                labels: options.labels, assigneeID: assignee))
            return "\(created.key) angelegt: \(created.title)" + (created.url.map { "\n\($0)" } ?? "")

        case .assign(let key, let query):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            if query == "none" {
                try await source.assign(ticketID: context.ticket.id, personID: nil)
                return "\(key): niemandem zugewiesen."
            }
            let person = try await source.person(matching: query)
            try await source.assign(ticketID: context.ticket.id, personID: person.id)
            return "\(key): \(person.name) zugewiesen."

        case .label(let key, let add, let remove):
            let source = try access.source(forKey: key)
            let context = try await source.ticket(key: key)
            try await source.changeLabels(ticketID: context.ticket.id, team: context.team, add: add, remove: remove)
            var parts: [String] = []
            if !add.isEmpty { parts.append("+" + add.joined(separator: ", ")) }
            if !remove.isEmpty { parts.append("−" + remove.joined(separator: ", ")) }
            return "\(key): Labels \(parts.joined(separator: " "))"

        case .setup(let keyFromStdin, let project, let team, let workspace, let reassign, let areas):
            return try await setup(keyFromStdin: keyFromStdin, project: project, team: team, workspace: workspace,
                                   reassign: reassign, areas: areas, env)

        case .removeTeam(let team, let withProjects):
            return try removeTeam(team, withProjects: withProjects, env)

        case .doctor(let json):
            // Wird in `execute` behandelt (Bericht immer nach stdout).
            return TicketsCLIFormatter.doctor(await doctor(env), json: json)
        }
    }

    // MARK: Bausteine

    private static func board(team: String?, _ env: TicketsCLIEnvironment, _ access: Access) async throws
        -> (TicketBoardModel, TicketBoardSnapshot, Bool, TicketSource) {
        let resolved = try resolveTeam(team, env)
        let source = try access.source(forTeam: resolved)
        let snapshot = try await source.board(team: resolved)
        let (chats, reachable) = env.chats()
        let config = env.config()
        // „Ohne Ticket“ meint Chats dieses Projekts, nicht alle Chats des Rechners.
        // Wer ausdrücklich ein Team nennt, meint dessen Projekt, nicht den Ordner, in dem er steht.
        let projectPath = team == nil
            ? config.projectPath(forDirectory: env.currentDirectory()) ?? config.projectPaths(forTeam: resolved).first
            : config.projectPaths(forTeam: resolved).first
        let model = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: projectPath)
        return (model, snapshot, reachable, source)
    }

    /// Team eines Befehls ohne Ticket-Nummer (`board`, `list`, `new`): `--team`,
    /// sonst das Projekt des aktuellen Ordners (auch eines Ordners darunter).
    ///
    /// Aus einem Ordner ohne Projekt rät nur das Lesen, und nur solange es eine
    /// einzige Firma gibt: dann zeigt es das einzige Team mit Ordner. Ein
    /// Schreibbefehl rät nie. Sonst landete ein `tickets new` aus irgendeinem
    /// Ordner still bei dem Team, das zufällig als einziges einen Ordner hat,
    /// und für einen Ordner ohne Projekt hält ihn auch die Schreibsperre nicht auf.
    static func resolveTeam(_ explicit: String?, _ env: TicketsCLIEnvironment, forWrite: Bool = false) throws -> String {
        if let explicit { return explicit.uppercased() }
        let config = env.config()
        let directory = TicketConfig.normalized(env.currentDirectory())
        if let team = config.team(forDirectory: directory) { return team }
        if !forWrite, let team = config.teamForReadingAnywhere { return team }
        let known = config.knownTeams
        let teams = known.isEmpty ? "" : " Eingerichtet: \(known.joined(separator: ", "))."
        let assign = "Oder den Ordner einmal zuordnen: whisperm8 tickets setup --team <Kürzel> --project \(directory)"
        guard forWrite else {
            throw Failure(exitCode: TicketsCLIExit.usage, message: """
            Team unklar: \(directory) ist keinem Team zugeordnet.\(teams)
            Das Team nennen: --team <Kürzel>
            \(assign)
            """)
        }
        // Ist der Aufrufer ein Chat, steht sein Projekt als Vorschlag da; genommen wird es nicht von selbst.
        let chat = env.callerChatID().flatMap { id in env.chats().chats.first { $0.id == id } }
        let hint = chat.flatMap { chat in
            config.team(forDirectory: chat.projectPath).map { " Dein Chat gehört zum Projekt \(chat.projectName), Team \($0)." }
        } ?? ""
        throw Failure(exitCode: TicketsCLIExit.usage, message: """
        Nichts angelegt: \(directory) ist keinem Team zugeordnet, und ein Schreibbefehl rät das Team nicht.\(teams)\(hint)
        Das Team nennen: --team <Kürzel>
        \(assign)
        """)
    }

    private static func resolveStatus(_ name: String, in context: TicketContext) throws -> TicketStatus {
        if let status = context.status(named: name) { return status }
        throw Failure(exitCode: TicketsCLIExit.notFound,
                      message: "Status „\(name)“ gibt es im Team \(context.team) nicht. Möglich: "
                        + context.statuses.map(\.name).joined(separator: ", "))
    }

    /// Eine Regel für „fertig“: Der arbeitende Chat gibt ab, auf „erledigt“ setzt
    /// der Supervisor nach Prüfung und Merge. Die Kommandozeile hält das ein,
    /// wenn der Aufrufer ein Chat ist, der kein Supervisor ist. Ein Mensch im
    /// Terminal und der Supervisor (auch mit `--chat` für andere) dürfen.
    private static func guardCompletion(_ target: TicketStatus, key: String, force: Bool, _ env: TicketsCLIEnvironment) throws {
        guard target.kind == .completed, !force, let id = env.callerChatID() else { return }
        let (chats, _) = env.chats()
        guard let caller = chats.first(where: { $0.id == id }), !TicketBoardBuilder.isSupervisor(caller) else { return }
        throw Failure(exitCode: TicketsCLIExit.conflict, message: """
        Auf „\(target.name)“ setzt der Supervisor nach Prüfung und Merge. Als Chat das Ticket abgeben \
        (whisperm8 tickets done \(key) --built "was gebaut wurde" --status <Status vor „\(target.name)“>) und dem Supervisor melden.
        Nur wenn der Nutzer es ausdrücklich von dir verlangt: --force
        """)
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
        // Der Text geht an einen fremden Dienst. Eine Grenze fängt die versehentlich
        // genannte große Datei (Log, Export, Verlauf) ab, bevor sie dort landet.
        guard value.utf8.count <= TicketsText.maxBytes else {
            throw Failure(exitCode: TicketsCLIExit.usage,
                          message: "Text zu lang (mehr als \(TicketsText.maxBytes / 1024) KB). Nichts gesendet.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(exitCode: TicketsCLIExit.usage, message: "Leerer Text.") }
        return trimmed
    }

    // MARK: Einrichten und prüfen

    private static func setup(keyFromStdin: Bool, project: String?, team: String?, workspace: String?,
                              reassign: Bool, areas: String?, _ env: TicketsCLIEnvironment) async throws -> String {
        var lines: [String] = []
        var config = env.config()
        var changed = false
        let wanted = workspace?.lowercased()
        if let wanted, !TicketConfig.isWorkspaceName(wanted) {
            throw Failure(exitCode: TicketsCLIExit.usage,
                          message: "„\(wanted)“ ist kein Workspace-Kürzel (erwartet: der Teil aus linear.app/<Kürzel>).")
        }
        if keyFromStdin {
            let key = env.readStdin().trimmingCharacters(in: .whitespacesAndNewlines)
            guard TicketCredentialStore.isStorable(key) else {
                throw Failure(exitCode: TicketsCLIExit.usage, message: "Kein gültiger Key auf stdin (erwartet: der kopierte Linear-API-Key).")
            }
            switch await env.validateKey(key) {
            case .failure(let error):
                throw Failure(exitCode: exitCode(for: error), message: "Key nicht gespeichert. " + error.message)
            case .success(let account):
                // Der Workspace ergibt sich aus dem Key selbst: Er lässt sich nicht falsch ablegen.
                guard TicketConfig.isWorkspaceName(account.workspaceKey) else {
                    throw Failure(exitCode: TicketsCLIExit.unavailable, message: "Key nicht gespeichert. Linear nennt zu diesem Key keinen Workspace.")
                }
                if let wanted, wanted != account.workspaceKey {
                    throw Failure(exitCode: TicketsCLIExit.conflict,
                                  message: "Key nicht gespeichert. Er gehört zu „\(account.workspaceKey)“, nicht zu „\(wanted)“.")
                }
                guard env.credential.write(account.workspaceKey, key) else {
                    throw Failure(exitCode: TicketsCLIExit.unavailable, message: "Der Schlüsselbund-Eintrag ließ sich nicht schreiben.")
                }
                config.add(workspace: account.workspaceKey)
                changed = true
                lines.append("Key für „\(account.workspaceKey)“ im Schlüsselbund. Gehört zu \(account.workspace) als \(account.userName)\(account.isAdmin ? ", Admin" : "").")
            }
        } else if let wanted, !config.knownWorkspaces.contains(wanted) {
            // Ein Key, der schon im Schlüsselbund liegt (von einem anderen Werkzeug abgelegt), wird übernommen.
            guard env.credential.read(wanted) != nil else {
                throw Failure(exitCode: TicketsCLIExit.unavailable,
                              message: "Für „\(wanted)“ liegt kein Key im Schlüsselbund. Ablegen: pbpaste | whisperm8 tickets setup --key-stdin")
            }
            let account = try await named(wanted) { try await env.source(wanted).account() }
            guard account.workspaceKey == wanted else {
                throw Failure(exitCode: TicketsCLIExit.conflict,
                              message: "Der Key unter „\(wanted)“ gehört zu \(account.workspace). Nichts übernommen.")
            }
            config.add(workspace: wanted)
            changed = true
            lines.append("Workspace „\(wanted)“ übernommen: \(account.workspace) als \(account.userName)\(account.isAdmin ? ", Admin" : "").")
        }
        if let team {
            let target: String
            if let wanted {
                let teams = try await named(wanted) { try await env.source(wanted).teams() }
                guard teams.contains(team) else {
                    throw Failure(exitCode: TicketsCLIExit.notFound,
                                  message: "Team \(team) gibt es im Workspace „\(wanted)“ nicht. Dort: \(teams.joined(separator: ", "))")
                }
                target = wanted
            } else {
                // Ohne Angabe: nachsehen, in welchem eingerichteten Workspace es das Team gibt.
                let known = config.knownWorkspaces
                guard !known.isEmpty else { throw TicketSourceError.notConfigured }
                var hits: [String] = []
                for candidate in known where try await named(candidate, { try await env.source(candidate).teams() }).contains(team) {
                    hits.append(candidate)
                }
                switch hits.count {
                case 1:
                    target = hits[0]
                case 0:
                    throw Failure(exitCode: TicketsCLIExit.notFound,
                                  message: "Team \(team) gibt es in keinem eingerichteten Workspace (\(known.joined(separator: ", "))).")
                default:
                    throw Failure(exitCode: TicketsCLIExit.conflict,
                                  message: "Team \(team) gibt es in \(hits.joined(separator: " und ")). Mit --workspace sagen, welches gemeint ist.")
                }
            }
            // Ein Kürzel kennt genau einen Workspace. Stilles Umhängen ließe jeden Ordner
            // dieses Teams in den anderen Workspace schreiben, ohne dass die Sperre es merkt.
            if let current = config.workspacesByTeam[team], current != target, !reassign {
                throw Failure(exitCode: TicketsCLIExit.conflict, message: """
                Team \(team) ist schon dem Workspace „\(current)“ zugeordnet. Nichts geändert.
                Die Kommandozeile kennt je Kürzel einen Workspace; gibt es \(team) in beiden, ist nur einer erreichbar.
                Wirklich umhängen: --reassign
                """)
            }
            config.set(workspace: target, forTeam: team)
            if let project {
                let path = (project as NSString).isAbsolutePath ? project
                    : ((env.currentDirectory() as NSString).appendingPathComponent(project) as NSString).standardizingPath
                config.set(team: team, forProject: path)
                lines.append("\(TicketConfig.normalized(path)) gehört zum Team \(team) im Workspace „\(target)“.")
                if let areas {
                    let root = TicketConfig.normalized(path)
                    switch areasTable(in: (root as NSString).appendingPathComponent(areas), env) {
                    case .success:
                        break
                    case .failure(let problem):
                        throw Failure(exitCode: TicketsCLIExit.notFound, message: "\(areas): \(problem.text) Nichts geändert.")
                    }
                    config.areasFileByProjectPath[root] = areas
                    lines.append("Tabelle der Bereiche: \(areas)")
                }
            } else {
                lines.append("Team \(team) liegt im Workspace „\(target)“.")
            }
            changed = true
        }
        if changed { try env.saveConfig(config) }
        if lines.isEmpty {
            if config.knownWorkspaces.isEmpty {
                lines.append("Linear-Key: fehlt (whisperm8 tickets setup --key-stdin)")
            }
            for name in config.knownWorkspaces {
                lines.append("Workspace: \(name), Key " + (env.credential.read(name) == nil ? "fehlt (whisperm8 tickets setup --key-stdin)" : "hinterlegt"))
            }
            if config.teamsByProjectPath.isEmpty {
                lines.append("Zuordnung: keine (whisperm8 tickets setup --project <Ordner> --team <Kürzel>)")
            }
            for (path, team) in config.teamsByProjectPath.sorted(by: { $0.key < $1.key }) {
                lines.append("Zuordnung: \(path) → \(team) (\(config.workspace(forTeam: team) ?? "kein Workspace"))")
                if let areas = config.areasFileByProjectPath[path] { lines.append("  Tabelle der Bereiche: \(areas)") }
            }
            let mapped = Set(config.teamsByProjectPath.values)
            for (team, name) in config.workspacesByTeam.sorted(by: { $0.key < $1.key }) where !mapped.contains(team) {
                lines.append("Team ohne Projektordner: \(team) (\(name))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Nimmt ein Team aus der Einrichtung. Linear wird nicht gefragt: Der Befehl
    /// ist gerade für ein Team da, das es dort nicht mehr gibt, und er soll auch
    /// ohne Netz und ohne Zugang gehen. Ein Ordner, der noch an dem Team hängt,
    /// wird nur auf ausdrücklichen Wunsch mit gelöst.
    private static func removeTeam(_ team: String, withProjects: Bool, _ env: TicketsCLIEnvironment) throws -> String {
        var config = env.config()
        guard config.knows(team: team) else {
            let known = config.knownTeams
            throw Failure(exitCode: TicketsCLIExit.notFound,
                          message: "Team \(team) steht nicht in der Einrichtung. Nichts geändert."
                              + (known.isEmpty ? "" : " Dort stehen: \(known.joined(separator: ", "))"))
        }
        let folders = config.projectPaths(forTeam: team)
        let workspace = config.workspacesByTeam.first { $0.key.caseInsensitiveCompare(team) == .orderedSame }?.value
        var after = config
        after.removeTeam(team)
        let consequences = folders.map { foldersFate($0, in: after) }
        if !folders.isEmpty, !withProjects {
            throw Failure(exitCode: TicketsCLIExit.conflict, message: """
            An Team \(team) \(folders.count == 1 ? "hängt noch ein Ordner" : "hängen noch \(folders.count) Ordner"): \(folders.joined(separator: ", "))
            Nichts geändert. Ohne das Team:
            \(consequences.map { "  " + $0 }.joined(separator: "\n"))
            Samt Ordner-Zuordnung entfernen: whisperm8 tickets setup --remove-team \(team) --with-projects
            Oder den Ordner erst einem anderen Team geben: whisperm8 tickets setup --team <Kürzel> --project <Ordner>
            """)
        }
        try env.saveConfig(after)
        var lines = ["Team \(team) ist aus der Einrichtung genommen" + (workspace.map { " (lag im Workspace „\($0)“)." } ?? ".")]
        lines += consequences
        if !folders.isEmpty {
            lines.append("Neu zuordnen: whisperm8 tickets setup --team <Kürzel> --project <Ordner>")
        }
        return lines.joined(separator: "\n")
    }

    /// Was für einen Ordner gilt, dessen Team aus der Einrichtung ging. „Ohne
    /// Team“ stimmt nicht immer: Liegt er in einem anderen Projektordner, erbt
    /// er dessen Team. Gibt es nur eine Firma und nur noch ein Team mit Ordner,
    /// zeigen lesende Befehle ohne `--team` dieses. Die Sperre gegen das
    /// Schreiben in einen fremden Workspace hängt am Projekt des Ordners und
    /// fällt mit ihm weg.
    static func foldersFate(_ folder: String, in config: TicketConfig) -> String {
        if let inherited = config.team(forDirectory: folder), let parent = config.projectPath(forDirectory: folder) {
            return "\(folder) gehört dann über \(parent) zum Team \(inherited)."
        }
        // Schreiben ohne --team bricht dort ab. Mit Ticket-Nummer oder --team geht es weiter,
        // und die Sperre über die Projektgrenze greift für einen Ordner ohne Projekt nicht.
        let writing = "Anlegen ohne --team bricht dort ab; mit Ticket-Nummer oder --team gilt die Sperre "
            + "gegen das Schreiben in einen fremden Workspace dort nicht mehr."
        if let only = config.teamForReadingAnywhere {
            return "\(folder) hat kein eigenes Team mehr; board und list ohne --team zeigen dort \(only), das einzige Team mit Ordner. \(writing)"
        }
        return "\(folder) hat kein Team mehr. \(writing)"
    }

    // MARK: Abschluss

    /// Die Zusammenfassung beim Abgeben. Sie ist Pflicht, damit am Ticket steht,
    /// was gebaut wurde, ohne dass jemand den Chat-Verlauf lesen muss.
    private static func completionRecord(_ summary: TicketsDoneSummary, chat: TicketChat, key: String,
                                         _ env: TicketsCLIEnvironment) throws -> TicketRecordText.Completion? {
        if summary.skip { return nil }
        guard let built = summary.built else {
            throw Failure(exitCode: TicketsCLIExit.usage, message: """
            Zum Abgeben gehört eine kurze Zusammenfassung:
              whisperm8 tickets done \(key) --built "was gebaut wurde" [--commit abc1234] [--not "was nicht dazugehört"] \
            [--test "Schritt für den Handtest"]… [--image bild.png]
            Arbeit ohne Bau (Analyse, Entscheidung): --no-summary
            """)
        }
        return TicketRecordText.Completion(
            chat: chat.shortName, built: try text(built, env), commit: summary.commit,
            notIncluded: try summary.notIncluded.map { try text($0, env) },
            testSteps: summary.testSteps.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private static func imageFile(_ path: String, _ env: TicketsCLIEnvironment) throws -> (data: Data, name: String, type: String) {
        guard let type = TicketImage.contentType(forPath: path) else {
            throw Failure(exitCode: TicketsCLIExit.usage, message: "--image nimmt nur Bilder (png, jpg, gif, webp): \(path)")
        }
        guard let data = env.readData(path, TicketImage.maxBytes), !data.isEmpty else {
            throw Failure(exitCode: TicketsCLIExit.usage,
                          message: "Bild nicht lesbar oder größer als \(TicketImage.maxBytes / 1024 / 1024) MB: \(path)")
        }
        guard TicketImage.looksLike(type, data) else {
            throw Failure(exitCode: TicketsCLIExit.usage, message: "Die Datei ist kein \(type.replacingOccurrences(of: "image/", with: "").uppercased())-Bild: \(path)")
        }
        return (data, (path as NSString).lastPathComponent, type)
    }

    // MARK: Ordnung

    /// Hinweise zur Ordnung eines Teams. Kein Fehler: Der Bericht bleibt grün.
    static func hygiene(team: String, tickets: [Ticket], now: Date) -> [Check] {
        TicketHygiene.findings(in: tickets, now: now).map { finding in
            let what: String
            switch finding.kind {
            case .noProject: what = "ohne Projekt"
            case .noCriteria: what = "eingeplant oder in Arbeit, aber ohne „Fertig, wenn“"
            case .startedWithoutChat: what = "in Arbeit, aber nie hing ein Chat daran"
            case .stale: what = "seit über \(TicketHygiene.staleAfterDays / 7) Wochen unberührt"
            }
            let shown = finding.keys.prefix(8).joined(separator: ", ") + (finding.keys.count > 8 ? " und \(finding.keys.count - 8) weitere" : "")
            return Check(name: "Ordnung \(team)", ok: true, warning: true, detail: "\(finding.keys.count) \(what): \(shown)")
        }
    }

    private struct AreasProblem: Error {
        var text: String
    }

    /// Liest die Tabelle der Bereiche aus einer Doku-Datei. Die Datei darf groß
    /// sein (Feature-Doku); gelesen wird bis zu einem Megabyte.
    private static func areasTable(in path: String, _ env: TicketsCLIEnvironment) -> Result<[TicketArea], AreasProblem> {
        guard env.fileExists(path) else { return .failure(AreasProblem(text: "Die Datei gibt es nicht.")) }
        guard let data = env.readData(path, 1_048_576), let text = String(data: data, encoding: .utf8) else {
            return .failure(AreasProblem(text: "Die Datei ist nicht lesbar oder größer als 1 MB."))
        }
        guard let areas = TicketAreasTable.parse(text) else {
            return .failure(AreasProblem(text: "Darin steht keine Tabelle mit den Spalten Bereich, Ordner und Projekt."))
        }
        return .success(areas)
    }

    /// Prüft die Tabelle Bereich, Ordner, Projekt aus der Doku des Projekts
    /// gegen das Ticket-Werkzeug und das Dateisystem.
    private static func areas(team: String, workspace: String, config: TicketConfig, _ env: TicketsCLIEnvironment) async -> [Check] {
        var checks: [Check] = []
        for root in config.projectPaths(forTeam: team) {
            guard let file = config.areasFileByProjectPath[root] else { continue }
            let name = "Bereiche \(team)"
            let areas: [TicketArea]
            switch areasTable(in: (root as NSString).appendingPathComponent(file), env) {
            case .success(let found):
                areas = found
            case .failure(let problem):
                checks.append(Check(name: name, ok: true, warning: true, detail: "\(file): \(problem.text)"))
                continue
            }
            let projects: [String]
            do {
                projects = try await env.source(workspace).projects(team: team)
            } catch {
                checks.append(Check(name: name, ok: false, detail: (error as? TicketSourceError)?.message ?? "\(error)"))
                continue
            }
            let findings = TicketAreasTable.findings(areas: areas, projects: projects) { path in
                env.fileExists((root as NSString).appendingPathComponent(path))
            }
            if findings.isEmpty {
                checks.append(Check(name: name, ok: true, detail: "\(areas.count) Bereiche stimmen mit \(file) überein"))
            }
            checks += findings.map { Check(name: name, ok: true, warning: true, detail: $0) }
        }
        return checks
    }

    /// Fehler der Quelle mit dem Namen des Workspaces, wenn mehrere im Spiel sind.
    private static func named<T>(_ workspace: String, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as TicketSourceError {
            throw Failure(exitCode: exitCode(for: error), message: "Workspace „\(workspace)“: " + error.message)
        }
    }

    struct Check: Equatable {
        var name: String
        var ok: Bool
        /// Kein Fehler, aber etwas, das der Nutzer wissen muss.
        var warning = false
        var detail: String
    }

    /// Was bei einem Team zu tun ist, das die Einrichtung kennt, das der Zugang
    /// seines Workspaces aber nicht (mehr) sieht: gelöscht, umbenannt, oder der
    /// Key hat keinen Zugriff darauf. Mehr als „nicht zu sehen“ weiß die
    /// Kommandozeile nicht.
    ///
    /// Gibt es das Kürzel in einem anderen eingerichteten Workspace, ist das
    /// meist ein fremdes Team gleichen Namens. Umhängen ließe jeden Ordner des
    /// Teams dorthin schreiben; deshalb stehen beide Wege da, mit der Folge.
    static func missingTeamAdvice(_ team: String, workspace: String, elsewhere: [String], folders: [String]) -> String {
        // Ohne --with-projects, auch wenn ein Ordner am Team hängt: Wer die Zeile kopiert, sieht
        // so erst den Abbruch mit den Folgen für den Ordner und entscheidet dann.
        let remove = "whisperm8 tickets setup --remove-team \(team)" + (folders.isEmpty ? "" : " (nennt erst die Folgen für den Ordner)")
        let attached = folders.joined(separator: ", ")
        if let other = elsewhere.first {
            let effect = folders.isEmpty ? "" : " (dann \(folders.count == 1 ? "schreibt" : "schreiben") auch \(attached) nach „\(other)“)"
            return "in „\(workspace)“ nicht zu sehen; ein Team \(team) gibt es in „\(other)“. "
                + "Ist es dasselbe Team, umhängen: whisperm8 tickets setup --team \(team) --workspace \(other) --reassign\(effect). "
                + "Ist es ein anderes, aus der Einrichtung nehmen: \(remove)"
        }
        let gone = "in „\(workspace)“ nicht mehr zu sehen: gelöscht, umbenannt oder kein Zugriff mit diesem Key. "
        guard !folders.isEmpty else { return gone + "Aus der Einrichtung nehmen: \(remove)" }
        return gone + "Daran \(folders.count == 1 ? "hängt" : "hängen") noch \(attached). "
            + "Aus der Einrichtung nehmen: \(remove)"
            + "; bei neuem Kürzel vorher: whisperm8 tickets setup --team <Kürzel> --project <Ordner>"
    }

    static func doctor(_ env: TicketsCLIEnvironment) async -> [Check] {
        var checks: [Check] = []
        let config = env.config()
        guard !config.knownWorkspaces.isEmpty else {
            return [Check(name: "Linear-Key", ok: false, detail: "fehlt. Einrichten: whisperm8 tickets setup --key-stdin")]
        }
        var usable = Set<String>()
        var teamsByWorkspace: [String: [String]] = [:]
        for workspace in config.knownWorkspaces {
            guard env.credential.read(workspace) != nil else {
                checks.append(Check(name: "Linear-Key", ok: false,
                                    detail: "\(workspace): fehlt. Einrichten: whisperm8 tickets setup --key-stdin"))
                continue
            }
            do {
                let account = try await env.source(workspace).account()
                // Ein Key, der unter dem falschen Workspace liegt, würde in der falschen Firma schreiben.
                guard account.workspaceKey == workspace else {
                    checks.append(Check(name: "Linear-Zugang", ok: false,
                                        detail: "\(workspace): der hinterlegte Key gehört zu \(account.workspace)"))
                    continue
                }
                usable.insert(workspace)
                // Ohne Antwort kein Eintrag: Eine leere Liste hieße, der Workspace habe keine Teams.
                if let teams = try? await env.source(workspace).teams() { teamsByWorkspace[workspace] = teams }
                checks.append(Check(name: "Linear-Zugang", ok: true,
                                    detail: "\(account.workspace) als \(account.userName)\(account.isAdmin ? ", Admin" : "")"))
            } catch {
                checks.append(Check(name: "Linear-Zugang", ok: false,
                                    detail: "\(workspace): " + ((error as? TicketSourceError)?.message ?? "\(error)")))
            }
        }
        if config.teamsByProjectPath.isEmpty {
            checks.append(Check(name: "Zuordnung", ok: false,
                                detail: "kein Projekt zugeordnet. whisperm8 tickets setup --project <Ordner> --team <Kürzel>"))
        }
        // Dasselbe Kürzel in zwei Workspaces: Die Nummer ABC-12 ist dann nicht eindeutig,
        // und erreichbar ist nur das Team im zugeordneten Workspace.
        for team in Set(teamsByWorkspace.values.joined()).sorted() {
            let holders = teamsByWorkspace.filter { $0.value.contains(team) }.keys.sorted()
            guard holders.count > 1 else { continue }
            let reach = config.workspacesByTeam[team].map { "erreichbar ist nur „\($0)“" } ?? "keinem zugeordnet, also nicht erreichbar"
            checks.append(Check(name: "Kürzel \(team)", ok: true, warning: true,
                                detail: "gibt es in \(holders.joined(separator: " und ")); \(reach)"))
        }
        for team in config.knownTeams {
            guard let workspace = config.workspace(forTeam: team) else {
                checks.append(Check(name: "Team \(team)", ok: false,
                                    detail: "keinem Workspace zugeordnet. whisperm8 tickets setup --team \(team)"))
                continue
            }
            // Ohne Zugang steht der Fehler schon oben.
            guard usable.contains(workspace) else { continue }
            do {
                let costBefore = LinearCostMeter.shared.snapshot
                let snapshot = try await env.source(workspace).board(team: team)
                let open = snapshot.tickets.filter { !$0.status.kind.isClosed }
                checks.append(Check(name: "Team \(team)", ok: true,
                                    detail: "\(open.count) offene Tickets, \(open.filter { !$0.activeLinks.isEmpty }.count) mit Agent (\(workspace))"))
                // Was ein Abruf des Boards kostet: Die Ansicht in der App holt ihn im Takt.
                if let cost = LinearCostMeter.describe(from: costBefore, to: LinearCostMeter.shared.snapshot) {
                    checks.append(Check(name: "Budget \(team)", ok: true, detail: cost))
                }
                checks += hygiene(team: team, tickets: snapshot.tickets, now: env.now())
                checks += await areas(team: team, workspace: workspace, config: config, env)
            } catch TicketSourceError.notFound {
                // Das Board fragt nur nach dem Team: Der Zugang sieht es dort nicht (mehr).
                let elsewhere = teamsByWorkspace.filter { $0.key != workspace && $0.value.contains(team) }.keys.sorted()
                checks.append(Check(name: "Team \(team)", ok: false,
                                    detail: missingTeamAdvice(team, workspace: workspace, elsewhere: elsewhere,
                                                              folders: config.projectPaths(forTeam: team))))
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
        if let criteria = ticket.criteria { object["criteria"] = ["done": criteria.done, "total": criteria.total] }
        if let updatedAt = ticket.updatedAt { object["updatedAt"] = ISO8601DateFormatter().string(from: updatedAt) }
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
                if let criteria = ticket.criteria { marks += " \(criteria.done)/\(criteria.total)" }
                lines.append("  \(pad(ticket.key, 8))\(pad(ticket.title, 50)) | \(pad(marks, 30)) | \(pad(ticket.assignee?.name.components(separatedBy: " ").first ?? "–", 9)) | \(agentText(entry))")
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
        if let criteria = ticket.criteria { lines.append("Fertig, wenn: \(criteria.done) von \(criteria.total) abgehakt") }
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
        if json {
            return jsonString(checks.map { ["name": $0.name, "ok": $0.ok, "warning": $0.warning, "detail": $0.detail] as [String: Any] })
        }
        return checks.map { check in
            let mark = !check.ok ? "FEHLER" : check.warning ? "ACHTE " : "ok    "
            return "\(mark) \(pad(check.name, 14)) \(check.detail)"
        }.joined(separator: "\n")
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
