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
        func page(workspaces: [Model.Workspace], mappings: [Model.Mapping]) -> AnyView {
            var config = TicketConfig()
            for workspace in workspaces { config.add(workspace: workspace.name) }
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
            let model = Model(dependencies: dependencies, workspaces: workspaces, mappings: mappings, projects: projects)
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
        let me = TicketPerson(id: "u1", name: "Giuliano Costa"), richard = TicketPerson(id: "u2", name: "Richard Strittmatter")
        let statuses = [
            TicketStatus(id: "s0", name: "Backlog", kind: .backlog, position: 0), TicketStatus(id: "s1", name: "Todo", kind: .unstarted, position: 1),
            TicketStatus(id: "s2", name: "In Progress", kind: .started, position: 2), TicketStatus(id: "s3", name: "Merge-bereit", kind: .started, position: 2.5),
            TicketStatus(id: "s4", name: "Done", kind: .completed, position: 3),
            TicketStatus(id: "s5", name: "Wartet aufs Ausliefern", kind: .started, position: 3.5),
        ]
        func link(_ n: Int, active: Bool = true) -> TicketChatLink {
            TicketChatLink(id: "att-\(n)", chatID: id(n), isActive: active, title: "Chat: " + (chats.first { $0.id == id(n) }?.title ?? "Kai · Umzug"),
                           subtitle: active ? "arbeitet seit 14.11. 04:21 · WhisperM8" : "beendet am 14.11. 05:35 · WhisperM8", creatorName: me.name)
        }
        let criteria = "**Stand 14.11.2026:** Paket A ist in main.\n\n## Ziel\n\nIn WhisperM8 gibt es je Projekt eine Ansicht „Tickets“: Board und Backlog aus Linear, je Ticket der zuständige Chat mit seinem Live-Zustand.\n\n## Fertig, wenn\n\n- [x] die Ansicht hinter einem Schalter in den Labs-Einstellungen liegt\n- [ ] Board mit drei Spalten und Backlog-Liste stehen\n- [ ] jede Karte den verknüpften Chat mit Status-Punkt zeigt\n- [ ] das Detail „Zum Chat“ und „In Linear öffnen“ anbietet\n\n## Hinweise\n\nPlan: docs/plans/ticket-board.md"
        func ticket(_ n: Int, _ status: String, _ title: String, priority: Int = 3, person: TicketPerson? = nil, area: String? = "Tickets",
                    milestone: String? = nil, labels: [String] = [], links: [TicketChatLink] = [], blocked: Bool = false,
                    text: String = "") -> Ticket {
            Ticket(id: "id-\(n)", key: "WM8-\(n)", title: title, description: text, priority: priority,
                   status: statuses.first { $0.name == status }!, project: area, milestone: milestone, assignee: person, labels: labels,
                   links: links, isBlocked: blocked, url: "https://linear.app/whisperm8/issue/WM8-\(n)")
        }
        let tickets = [
            ticket(81, "In Progress", "Ticket-Board in der App, Stufe 1: Board und Backlog lesen, Chat je Ticket mit Live-Status", priority: 2,
                   person: me, milestone: "Ticket-Board in der App", labels: ["Feature"], links: [link(1)], text: criteria),
            ticket(69, "In Progress", "Chats am Nutzungslimit erkennen, anzeigen, sauber umziehen", priority: 1, area: "Agent Chats",
                   labels: ["Feature", "Handtest"], links: [link(2)]),
            ticket(16, "In Progress", "Insel auch für die Tastatur: Entwurf fertigstellen", area: "Insel und Pille", links: [link(4)], blocked: true),
            ticket(12, "In Progress", "Neustart ohne Chatverlust: Gesamtabnahme", priority: 2, person: richard, area: "App-Hülle und Neustart", links: [link(3)]),
            ticket(30, "In Progress", "Tastenkürzel für den Workspace-Wechsel", priority: 4, area: "Agent Chats"),
            ticket(86, "Merge-bereit", "Ticket-Werkzeug: Entscheidung festhalten, Abschluss beim Abgeben", priority: 2, links: [link(1, active: false)],
                   text: "## Fertig, wenn\n- [x] a\n- [x] b\n- [x] c"),
            ticket(37, "Wartet aufs Ausliefern", "Tickets an Chats zuweisen", person: me, links: [link(1, active: false)]),
            ticket(84, "Todo", "Linears eigene Agent-Funktion prüfen", priority: 2, person: me, labels: ["Entscheidung"]),
            ticket(57, "Todo", "Linear-Keys ersetzen", priority: 1, person: me, area: "Konten und Zugänge", labels: ["Handtest"]),
            ticket(80, "Todo", "Seitenleiste sortiert und ohne Doppelungen, Tabs schrumpfen", area: "Agent Chats", milestone: "Seitenleiste und Tabs"),
            ticket(83, "Backlog", "Chat-Verlauf am Ticket: nachlesen und auf einem anderen Rechner fortsetzen"),
            ticket(45, "Backlog", "Chats sehen, die in WhisperM8 auf anderen Rechnern laufen", priority: 4),
            ticket(58, "Backlog", "Jarvis-Skill: Titel ohne Nummer", priority: 0, area: nil),
            ticket(29, "Done", "Terminal-Tab bleibt nach Neustart", area: "Agent Chats", links: [link(5, active: false)]),
        ]
        let snapshot = TicketBoardSnapshot(team: "WM8", statuses: statuses, tickets: tickets, fetchedAt: Date(timeIntervalSince1970: 1_794_630_000))
        let board = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: project)
        let source = TicketChatStatusSource(states: Dictionary(uniqueKeysWithValues: chats.compactMap { chat in chat.state.map { (chat.id, $0) } }))
        let loaded = TicketBoardLoadState(fetchedAt: snapshot.fetchedAt)

        func view(_ configure: (TicketBoardViewModel) -> Void = { _ in }, load: TicketBoardLoadState = loaded) -> AnyView {
            let model = TicketBoardViewModel(model: board)
            configure(model)
            return AnyView(TicketBoardView(title: "Tickets · whisperm8", model: model, load: load, source: source, actions: .none))
        }
        let size = CGSize(width: 1340, height: 860)
        return [
            Fixture(name: "tickets-board", size: size) { view() },
            Fixture(name: "tickets-board-detail", size: size) { view { $0.selectedKey = "WM8-81" } },
            Fixture(name: "tickets-board-ohne-agent", size: size) { view { $0.filter.agent = .withoutAgent } },
            Fixture(name: "tickets-board-person", size: size) { view { $0.filter.person = .person(id: "u1") } },
            Fixture(name: "tickets-backlog", size: size) { view { $0.mode = .backlog } },
            Fixture(name: "tickets-backlog-detail", size: size) { view { $0.mode = .backlog; $0.selectedKey = "WM8-69" } },
            Fixture(name: "tickets-board-schmal-detail", size: CGSize(width: 760, height: 640)) { view { $0.selectedKey = "WM8-81" } },
            Fixture(name: "tickets-backlog-schmal", size: CGSize(width: 560, height: 640)) { view { $0.mode = .backlog } },
            Fixture(name: "tickets-board-stoerung", size: size) {
                view(load: TicketBoardLoadState(fetchedAt: snapshot.fetchedAt, problem: TicketSourceError.network("-1009").userText))
            },
        ]
    }
}
