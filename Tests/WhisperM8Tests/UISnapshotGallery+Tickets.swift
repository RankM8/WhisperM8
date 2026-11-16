import SwiftUI
@testable import WhisperM8

/// Fixtures der Tickets: Einstellungsseite in ihren Zuständen.
extension UISnapshotGallery {
    @MainActor
    static func ticketSettingsFixtures() -> [Fixture] {
        typealias Model = TicketsSettingsModel
        let home = NSHomeDirectory()
        let projects = [
            TicketProjectChoice(name: "whisperm8", path: home + "/repos/whisperm8"),
            TicketProjectChoice(name: "ListM8", path: home + "/repos/ListM8"),
            TicketProjectChoice(name: "akquise-ai", path: home + "/repos/akquise-ai"),
        ]
        /// Abhängigkeiten, die genau den gezeigten Zustand zurückgeben: Der
        /// Lauf von `load()` beim Erscheinen ändert das Bild nicht.
        func page(workspaces: [Model.Workspace], mappings: [Model.Mapping], staleTeams: [Model.StaleTeam] = []) -> AnyView {
            var config = TicketConfig()
            for workspace in workspaces { config.add(workspace: workspace.name) }
            for stale in staleTeams { config.set(workspace: stale.workspace, forTeam: stale.team) }
            for mapping in mappings {
                if let workspace = mapping.workspace { config.set(workspace: workspace, forTeam: mapping.team) }
                config.set(team: mapping.team, forProject: mapping.path)
            }
            let withKey = Set(workspaces.filter(\.hasKey).map(\.name))
            let teams = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.name, $0) })
            let dependencies = TicketsSettingsDependencies(
                loadConfig: { config }, loadConfigForChange: { config }, saveConfig: { _ in },
                hasKey: { withKey.contains($0) }, storeKey: { _, _ in false }, deleteKey: { _ in false },
                account: { _ in .failure(.unauthorized) },
                teams: { name in teams[name]?.problem == nil ? .success(teams[name]?.teams ?? []) : .failure(.unauthorized) },
                projects: { projects }, chooseFolder: { nil })
            let model = Model(dependencies: dependencies, workspaces: workspaces, mappings: mappings, staleTeams: staleTeams,
                              projects: projects)
            return AnyView(TicketsSettingsPage(dependencies: dependencies, model: model))
        }
        let size = CGSize(width: 760, height: 900)
        let on: [String: Any] = [PreferenceKeys.ticketBoardEnabled: true]
        return [
            Fixture(name: "tickets-einstellungen-aus", size: CGSize(width: 760, height: 420)) {
                page(workspaces: [], mappings: [])
            },
            Fixture(name: "tickets-einstellungen-leer", size: CGSize(width: 760, height: 640), storage: on) {
                page(workspaces: [], mappings: [])
            },
            Fixture(name: "tickets-einstellungen-eingerichtet", size: size, storage: on) {
                page(
                    workspaces: [
                        Model.Workspace(name: "dealsupply", hasKey: true, teams: ["DEA", "DS", "PRB"]),
                        Model.Workspace(name: "whisperm8", hasKey: true, teams: ["WM8"]),
                    ],
                    mappings: [
                        Model.Mapping(path: home + "/repos/ListM8", team: "DS", workspace: "dealsupply"),
                        Model.Mapping(path: home + "/repos/whisperm8", team: "WM8", workspace: "whisperm8"),
                    ])
            },
            Fixture(name: "tickets-einstellungen-stoerung", size: size, storage: on) {
                page(
                    workspaces: [
                        Model.Workspace(name: "dealsupply", hasKey: false),
                        Model.Workspace(name: "whisperm8", hasKey: true, problem: TicketSourceError.unauthorized.userText),
                    ],
                    mappings: [
                        Model.Mapping(path: home + "/repos/ListM8", team: "DS", workspace: "dealsupply"),
                        Model.Mapping(path: home + "/repos/alt", team: "ALT", workspace: nil),
                    ])
            },
            // Ein Team wurde in Linear gelöscht oder umbenannt: einmal mit Ordner, einmal ohne.
            Fixture(name: "tickets-einstellungen-team-fehlt", size: CGSize(width: 760, height: 1040), storage: on) {
                page(
                    workspaces: [
                        Model.Workspace(name: "dealsupply", hasKey: true, teams: ["DEA", "DS"]),
                        Model.Workspace(name: "whisperm8", hasKey: true, teams: ["WM8"]),
                    ],
                    mappings: [
                        Model.Mapping(path: home + "/repos/ListM8", team: "DS", workspace: "dealsupply"),
                        Model.Mapping(path: home + "/repos/probe", team: "ALT", workspace: "dealsupply", teamMissing: true),
                        Model.Mapping(path: home + "/repos/whisperm8", team: "WM8", workspace: "whisperm8"),
                    ],
                    staleTeams: [Model.StaleTeam(team: "PRB", workspace: "dealsupply")])
            },
        ]
    }

    // MARK: Board

    /// Board, Backlog und Detail mit einem festen Abzug.
    @MainActor
    static func ticketBoardFixtures() -> [Fixture] {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
        let project = "/Users/demo/repos/whisperm8"
        func chat(_ n: Int, _ title: String, _ state: TicketChatState) -> TicketChat {
            TicketChat(id: id(n), title: title, projectName: "whisperm8", projectPath: project, state: state, isRunning: true)
        }
        let chats = [
            chat(1, "WM8-81 Jon · Ticket-Board: Ansicht", .working), chat(2, "WM8-69 Gus · Chat am Limit", .needsYou),
            chat(3, "WM8-12 Vic · Neustart: Gegenlesen", .idle), chat(4, "WM8-16 Fin · Insel: Tastatur", .errored),
            chat(5, "Ole · Terminal-Tab", .idle), chat(6, "Noa · Chats sprechen miteinander", .working),
            chat(9, "Jarvis: Supervisor", .idle),
        ]
        let me = TicketPerson(id: "u1", name: "Giuliano Costa"), erika = TicketPerson(id: "u2", name: "Erika Beispiel")
        let statuses = [
            TicketStatus(id: "s0", name: "Backlog", kind: .backlog, position: 0), TicketStatus(id: "s1", name: "Todo", kind: .unstarted, position: 1),
            TicketStatus(id: "s2", name: "In Progress", kind: .started, position: 2), TicketStatus(id: "s3", name: "Merge-bereit", kind: .started, position: 2.5),
            TicketStatus(id: "s4", name: "Done", kind: .completed, position: 3),
            TicketStatus(id: "s5", name: "Wartet aufs Ausliefern", kind: .started, position: 3.5),
        ]
        func link(_ n: Int, active: Bool = true) -> TicketChatLink {
            TicketChatLink(id: "att-\(n)", chatID: id(n), isActive: active, title: "Chat: " + (chats.first { $0.id == id(n) }?.title ?? "Kai · Umzug"),
                           subtitle: active ? "arbeitet seit 14.11. 04:21 · WhisperM8" : "beendet am 14.11. 05:35 · WhisperM8", creatorName: me.name,
                           since: Date(timeIntervalSince1970: 1_794_626_460))
        }
        let criteria = "**Stand 14.11.2026:** Paket A ist in main.\n\n## Ziel\n\nIn WhisperM8 gibt es je Projekt eine Ansicht „Tickets“: Board und Backlog aus Linear, je Ticket der zuständige Chat mit seinem Live-Zustand.\n\n## Fertig, wenn\n\n- [x] die Ansicht hinter einem Schalter in den Labs-Einstellungen liegt\n- [ ] Board mit drei Spalten und Backlog-Liste stehen\n- [ ] jede Karte den verknüpften Chat mit Status-Punkt zeigt\n- [ ] das Detail „Zum Chat“ und „In Linear öffnen“ anbietet\n\n## Hinweise\n\nPlan: docs/plans/ticket-board.md"
        func ticket(_ n: Int, _ status: String, _ title: String, priority: Int = 3, person: TicketPerson? = nil, area: String? = "Tickets",
                    milestone: String? = nil, labels: [String] = [], links: [TicketChatLink] = [], blocked: Bool = false,
                    text: String = "", parent: Int? = nil) -> Ticket {
            Ticket(id: "id-\(n)", key: "WM8-\(n)", title: title, description: text, priority: priority,
                   status: statuses.first { $0.name == status }!, project: area, milestone: milestone, assignee: person, labels: labels,
                   links: links, isBlocked: blocked, url: "https://linear.app/whisperm8/issue/WM8-\(n)",
                   updatedAt: Date(timeIntervalSince1970: 1_794_600_000 - Double(n) * 3600), parentKey: parent.map { "WM8-\($0)" })
        }
        let tickets = [
            // Eltern-Ticket mit Unteraufgaben (WM8-125); die Beziehungen sind für das Bild angenommen.
            ticket(111, "In Progress", "Ticket-Board für den Alltag", priority: 2, person: me, labels: ["Feature"]),
            ticket(81, "In Progress", "Ticket-Board in der App, Stufe 1: Board und Backlog lesen, Chat je Ticket mit Live-Status", priority: 2,
                   person: me, milestone: "Ticket-Board in der App", labels: ["Feature"], links: [link(1)], text: criteria, parent: 111),
            ticket(69, "In Progress", "Chats am Nutzungslimit erkennen, anzeigen, sauber umziehen", priority: 1, area: "Agent Chats",
                   labels: ["Feature", "Handtest"], links: [link(2)]),
            ticket(16, "In Progress", "Insel auch für die Tastatur: Entwurf fertigstellen", area: "Insel und Pille", links: [link(4)], blocked: true),
            ticket(12, "In Progress", "Neustart ohne Chatverlust: Gesamtabnahme", priority: 2, person: erika, area: "App-Hülle und Neustart", links: [link(3)]),
            ticket(30, "In Progress", "Tastenkürzel für den Workspace-Wechsel", priority: 4, area: "Agent Chats"),
            ticket(86, "Merge-bereit", "Ticket-Werkzeug: Entscheidung festhalten, Abschluss beim Abgeben", priority: 2, links: [link(1, active: false)],
                   text: "## Fertig, wenn\n- [x] a\n- [x] b\n- [x] c", parent: 111),
            ticket(37, "Wartet aufs Ausliefern", "Tickets an Chats zuweisen", person: me, links: [link(1, active: false)]),
            ticket(84, "Todo", "Linears eigene Agent-Funktion prüfen", priority: 2, person: me, labels: ["Entscheidung"]),
            ticket(57, "Todo", "Linear-Keys ersetzen", priority: 1, person: me, area: "Konten und Zugänge", labels: ["Handtest", "Entscheidung"],
                   parent: 120),
            ticket(80, "Todo", "Seitenleiste sortiert und ohne Doppelungen, Tabs schrumpfen", area: "Agent Chats", milestone: "Seitenleiste und Tabs"),
            ticket(83, "Backlog", "Chat-Verlauf am Ticket: nachlesen und auf einem anderen Rechner fortsetzen"),
            ticket(45, "Backlog", "Chats sehen, die in WhisperM8 auf anderen Rechnern laufen", priority: 4),
            ticket(58, "Backlog", "Jarvis-Skill: Titel ohne Nummer", priority: 0, area: nil),
            ticket(29, "Done", "Terminal-Tab bleibt nach Neustart", area: "Agent Chats", links: [link(5, active: false)]),
        ] + (90...96).map { n in
            // Erfundene Backlog-Tickets, damit eine Spalte „N weitere“ zeigt.
            ticket(n, "Backlog", "Beispiel-Ticket \(n): erfundener Eintrag im Backlog", priority: 4, area: "Beispiel")
        }
        let snapshot = TicketBoardSnapshot(team: "WM8", statuses: statuses, tickets: tickets, fetchedAt: Date(timeIntervalSince1970: 1_794_630_000),
                                           viewerID: me.id)
        // Regel wie für WM8 gedacht: Merge-bereit heißt Abnahme bei dir, Entscheidungen und Handtests warten auf dich.
        let rule = TicketTeamRule(statusMeanings: ["Merge-bereit": .waitsForMe, "Wartet aufs Ausliefern": .done],
                                  waitingLabels: ["Entscheidung", "Handtest"])
        // Reiter wie im Team WM8 (WM8-125): Namen echt, Gruppierung wie in Linear.
        func linearView(_ id: String, _ name: String, _ grouping: TicketViewGrouping = .status) -> TicketView {
            TicketView(id: id, name: name, teamKey: "WM8", grouping: grouping, ordering: .priority, showsSubIssues: true,
                       url: "https://linear.app/whisperm8/view/\(id)")
        }
        let views = [
            linearView("next", "Als Nächstes: Giuliano"), linearView("all", "All issues"),
            linearView("without", "Ohne Agent", .project), linearView("with", "Mit Agent", .project),
            linearView("blocked", "Blockiert", .project), linearView("ready", "Als Nächstes", .priority),
            linearView("work", "Gerade in Arbeit", .project), linearView("decisions", "Entscheidungen", .project),
            linearView("tests", "Handtests", .project), linearView("waiting", "Wartet auf mich", .project),
        ]
        let catalog = TicketViewCatalog(views: views, defaultID: "next")
        var board = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: project, rule: rule)
        board.view = views[0]
        var boardByProject = board
        boardByProject.view = views[6]
        // Verlauf am Ticket: Abschluss und Entscheidung im festen Aufbau, dazu
        // ein gewöhnlicher Kommentar. Personen und Zeiten sind erfunden.
        func at(_ hour: Int, _ minute: Int) -> Date { Date(timeIntervalSince1970: 1_794_614_400 + Double(hour * 3600 + minute * 60)) }
        let comments = TicketComments(items: [
            TicketComment(id: "c3", author: "Giuliano Costa", createdAt: at(17, 33), body: """
            **Abschluss · 15.11.2026, 17:33 Uhr · Jon**

            **Gebaut:** Board und Backlog lesen, Chat je Ticket mit Live-Status, Detail mit „Zum Chat“.

            **Commit:** 12f485bc

            **Handtest:**
            - [ ] Board öffnen, Spalten und Karten stimmen mit Linear überein
            - [ ] „Zum Chat“ springt in den richtigen Tab
            - [ ] Bild: ![Bildschirmfoto](https://uploads.linear.app/beispiel.png)
            """, isReply: false),
            TicketComment(id: "c2", author: "Erika Beispiel", createdAt: at(17, 23),
                          body: "Paket A ist merge-bereit. Volle Suite grün. Prüfer bitte gegenlesen: [Plan](https://example.com/plan).",
                          isReply: false),
            TicketComment(id: "c1", author: "Giuliano Costa", createdAt: at(15, 55), body: """
            **Entscheidung · 15.11.2026, 15:55 Uhr**

            **Frage:** Wie viele Spalten zeigt das Board?

            **Gewählt:** Drei Gruppen nach Art des Status

            **Entschieden von:** Giuliano
            """, isReply: false),
        ], hasMore: false)
        let paragraph = "Ein langer Kommentar mit Begründung, Zwischenstand und offenen Fragen. Er läuft über mehrere Zeilen, damit man sieht, wie der Verlauf liest, wenn Kollegen und Chats ausführlich schreiben."
        let longComments = TicketComments(items: (1...12).reversed().map { n in
            TicketComment(id: "l\(n)", author: n.isMultiple(of: 2) ? "Erika Beispiel" : "Jon (Chat)", createdAt: at(8 + n, 5),
                          body: "**Zwischenstand \(n)**\n\n" + Array(repeating: paragraph, count: 3).joined(separator: "\n\n")
                              + "\n\n- Punkt eins\n- Punkt zwei mit `Code`", isReply: n == 5)
        }, hasMore: true)
        let source = TicketChatStatusSource.fixed(Dictionary(uniqueKeysWithValues: chats.compactMap { chat in chat.state.map { (chat.id, $0) } }))
        func view(_ configure: (TicketBoardViewModel) -> Void = { _ in }, problem: String? = nil,
                  byProject: Bool = false) -> AnyView {
            let model = TicketBoardViewModel(model: byProject ? boardByProject : board, documents: .immediate)
            model.setViews(catalog, active: byProject ? "work" : "next", isLoading: false)
            configure(model)
            let load = TicketBoardLoad(fetchedAt: snapshot.fetchedAt, problem: problem)
            return AnyView(TicketBoardView(title: "Tickets · whisperm8", model: model, load: load, source: source,
                                           actions: snapshotTicketActions))
        }
        let size = CGSize(width: 1340, height: 860)
        return [
            // Liste als Standard mit Reitern aus Linear (WM8-125).
            Fixture(name: "tickets-liste", size: size) { view() },
            Fixture(name: "tickets-liste-mittel", size: CGSize(width: 860, height: 760)) { view() },
            Fixture(name: "tickets-liste-schmal", size: CGSize(width: 620, height: 760)) { view() },
            Fixture(name: "tickets-liste-vorhaben", size: size) { view(byProject: true) },
            Fixture(name: "tickets-liste-zugeklappt", size: size) {
                view { $0.toggleGroup("status:backlog"); $0.setListStop(TicketListStop.group("status:todo")) }
            },
            Fixture(name: "tickets-liste-auswahl", size: size) { view { $0.setListStop("WM8-81") } },
            Fixture(name: "tickets-board", size: size) { view { $0.mode = .board } },
            Fixture(name: "tickets-chats-ohne-ticket-offen", size: CGSize(width: 900, height: 120)) {
                AnyView(TicketLooseChatsBar(chats: board.looseChats, supervisors: board.supervisors, source: source, openChat: { _ in },
                                            isExpanded: true)
                    .padding(14).background(AgentTheme.background))
            },
            Fixture(name: "tickets-board-stoerung", size: size) {
                view(problem: TicketSourceError.network("-1009").userText)
            },
            // Triage: Liste links (die Spalte), Ticket mit Verlauf, Eigenschaften rechts.
            Fixture(name: "tickets-triage", size: size) {
                view { $0.mode = .board; $0.openFromLane("WM8-81"); $0.setComments(.loaded(comments), ticketID: "id-81") }
            },
            Fixture(name: "tickets-triage-lange-kommentare", size: size) {
                view { $0.mode = .board; $0.openFromLane("WM8-86"); $0.setComments(.loaded(longComments), ticketID: "id-86") }
            },
            Fixture(name: "tickets-triage-laedt", size: size) { view { $0.mode = .board; $0.openFromLane("WM8-57") } },
            Fixture(name: "tickets-triage-fehler", size: size) {
                view { $0.mode = .board; $0.openFromLane("WM8-57"); $0.setComments(.failed(TicketSourceError.network("-1009").userText), ticketID: "id-57") }
            },
            // Triage aus der Liste (WM8-125): links dieselbe Liste mit Gruppen, das Ticket markiert.
            Fixture(name: "tickets-triage-liste", size: size) {
                view { $0.openFromList("WM8-81"); $0.setComments(.loaded(comments), ticketID: "id-81") }
            },
            Fixture(name: "tickets-triage-liste-schmal", size: CGSize(width: 820, height: 700)) {
                view { $0.openFromList("WM8-57"); $0.setComments(.loaded(TicketComments(items: [], hasMore: false)), ticketID: "id-57") }
            },
            // Grundlage für die Bilder des Board-Chats (WM8-113): Triage mit Fenster, damit „→ Jarvis“ erscheint.
            Fixture(name: "tickets-triage-mit-fenster", size: size) {
                view { $0.mode = .board; $0.windowID = boardChatSnapshotWindowID; $0.openFromLane("WM8-81"); $0.setComments(.loaded(comments), ticketID: "id-81") }
            },
            Fixture(name: "tickets-triage-schmal", size: CGSize(width: 760, height: 640)) {
                view { $0.mode = .board; $0.openFromLane("WM8-81"); $0.setComments(.loaded(comments), ticketID: "id-81") }
            },
        ] + ticketEmptyStateFixtures() + ticketsControllerBoardFixtures(
            view: { configure in view(configure) }, comments: comments)
    }

    /// Wie in der App: „← Chats · WM8 Aktiv“ links im Kopf (WM8-124).
    static var snapshotTicketActions: TicketBoardActions {
        var actions = TicketBoardActions.none
        actions.back = TicketsBackLinkModel(destination: .init(name: "WM8 Aktiv", route: .previousPlace)) {}
        return actions
    }

    /// Was die Ansicht zeigt, solange es kein Board gibt.
    @MainActor
    private static func ticketEmptyStateFixtures() -> [Fixture] {
        let size = CGSize(width: 900, height: 520)
        func state(_ name: String, _ kind: TicketBoardEmptyState.Kind) -> Fixture {
            Fixture(name: "tickets-leer-\(name)", size: size) {
                AnyView(TicketBoardEmptyState(kind: kind, actions: snapshotTicketActions).background(AgentTheme.background))
            }
        }
        return [
            state("aus", .disabled),
            state("kein-projekt", .noProject),
            state("keine-zuordnung", .notMapped(project: "whisperm8")),
            state("kein-schluessel", .noKey(workspace: "whisperm8")),
            state("nicht-erreichbar", .unreachable(TicketSourceError.network("-1009").userText)),
            state("laedt", .loading),
        ]
    }
}
