import XCTest
@testable import WhisperM8

/// Liste nach der Ansicht aus Linear (WM8-125): Gruppen, Reihenfolge,
/// Unteraufgaben und Auf- und Zuklappen.
@MainActor
final class TicketListGroupingTests: XCTestCase {
    private func entry(_ ticket: Ticket) -> TicketBoardEntry { TicketBoardEntry(ticket: ticket, agents: []) }

    private func keys(_ groups: [TicketListGroup]) -> [[String]] { groups.map { $0.rows.map(\.id) } }

    func testStatusGroupsFollowTheBoardOrderAndSortByPriority() {
        let entries = [
            entry(TicketFixtures.ticket(1, status: "Todo", priority: 3)),
            entry(TicketFixtures.ticket(2, status: "In Progress", priority: 4)),
            entry(TicketFixtures.ticket(3, status: "Todo", priority: 1)),
            entry(TicketFixtures.ticket(4, status: "Merge-bereit", priority: 2)),
            entry(TicketFixtures.ticket(5, status: "Backlog", priority: 0)),
            entry(TicketFixtures.ticket(6, status: "Backlog", priority: 2)),
        ]
        let rule = TicketTeamRule(statusMeanings: ["Merge-bereit": .waitsForMe])
        let groups = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("v"), rule: rule)
        XCTAssertEqual(groups.map(\.title), ["Merge-bereit", "In Progress", "Todo", "Backlog"],
                       "wartet auf mich zuerst, dann wie die Spalten des Boards")
        XCTAssertEqual(keys(groups), [["WM8-4"], ["WM8-2"], ["WM8-3", "WM8-1"], ["WM8-6", "WM8-5"]],
                       "nach Priorität, „keine“ zuletzt")
        XCTAssertTrue(groups[0].waitsForMe)
        XCTAssertFalse(groups[1].waitsForMe)
    }

    func testProjectPriorityAndUnsupportedGrouping() {
        let entries = [
            entry(TicketFixtures.ticket(1, priority: 2, project: "Tickets")),
            entry(TicketFixtures.ticket(2, priority: 0, project: nil)),
            entry(TicketFixtures.ticket(3, priority: 1, project: "Agent Chats")),
        ]
        let byProject = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("p", grouping: .project),
                                                rule: TicketTeamRule())
        XCTAssertEqual(byProject.map(\.title), ["Agent Chats", "Tickets", TicketBoardText.project("")],
                       "alphabetisch, ohne Projekt am Ende")

        let byPriority = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("q", grouping: .priority),
                                                 rule: TicketTeamRule())
        XCTAssertEqual(keys(byPriority), [["WM8-3"], ["WM8-1"], ["WM8-2"]], "dringend zuerst, ohne Priorität zuletzt")

        let byCycle = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("c", grouping: .unsupported("cycle")),
                                              rule: TicketTeamRule())
        XCTAssertEqual(byCycle.map(\.title), ["Todo"], "unbekannte Gruppierung: nach Status")
    }

    func testSubIssuesSitUnderTheirParentAndOrphansNameTheirParent() {
        let entries = [
            entry(TicketFixtures.ticket(10, status: "In Progress", priority: 2)),
            entry(TicketFixtures.ticket(11, status: "Todo", priority: 3, parent: 10)),
            entry(TicketFixtures.ticket(12, status: "Backlog", priority: 1, parent: 10)),
            entry(TicketFixtures.ticket(13, status: "Todo", priority: 2, parent: 99)),
            entry(TicketFixtures.ticket(14, status: "Todo", priority: 4, parent: 11)),
        ]
        let groups = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("v"), rule: TicketTeamRule())
        XCTAssertEqual(keys(groups), [["WM8-10", "WM8-12", "WM8-11", "WM8-14"], ["WM8-13"]],
                       "Unteraufgaben in der Gruppe des Eltern-Tickets, nach Priorität")
        let rows = groups[0].rows
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2])
        XCTAssertEqual(rows[0].children, TicketChildProgress(done: 0, total: 2))
        XCTAssertEqual(groups[1].rows[0].parentKeyOutsideView, "WM8-99", "Eltern-Ticket nicht in der Ansicht")
        XCTAssertNil(rows[1].parentKeyOutsideView)

        let withoutSubIssues = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("s", subIssues: false),
                                                       rule: TicketTeamRule())
        XCTAssertEqual(keys(withoutSubIssues), [["WM8-10"]], "Unteraufgaben aus: nur Tickets ohne Eltern")
    }

    func testParentCycleDoesNotLoop() {
        let entries = [
            entry(TicketFixtures.ticket(1, parent: 2)),
            entry(TicketFixtures.ticket(2, parent: 1)),
            entry(TicketFixtures.ticket(3, parent: 3)),
        ]
        let groups = TicketListGrouping.make(entries: entries, view: TicketFixtures.view("v"), rule: TicketTeamRule())
        XCTAssertEqual(Set(groups.flatMap(\.rows).map(\.id)), ["WM8-1", "WM8-2", "WM8-3"], "ein Ring bleibt flach, keiner verschwindet")
        XCTAssertEqual(groups.flatMap(\.rows).map(\.depth), [0, 0, 0])
    }

    func testWithoutViewEverythingIsGroupedByStatus() {
        let model = TicketBoardModel(entries: [entry(TicketFixtures.ticket(1)), entry(TicketFixtures.ticket(2, status: "In Progress"))],
                                     looseChats: [], supervisors: [])
        let presentation = TicketBoardPresentation.make(model: model, filter: .all)
        XCTAssertNil(presentation.view)
        XCTAssertEqual(presentation.groups.map(\.title), ["In Progress", "Todo"])
        XCTAssertEqual(presentation.entry(key: "WM8-1")?.ticket.key, "WM8-1")
    }

    // MARK: Ansicht im ViewModel

    private func viewModel(groups: TicketViewGrouping = .status) -> TicketBoardViewModel {
        var model = TicketBoardModel(entries: [
            entry(TicketFixtures.ticket(1, status: "Todo")),
            entry(TicketFixtures.ticket(2, status: "In Progress")),
            entry(TicketFixtures.ticket(3, status: "Todo", priority: 1)),
        ], looseChats: [], supervisors: [])
        model.view = TicketFixtures.view("n", grouping: groups)
        let vm = TicketBoardViewModel(model: model, documents: .immediate)
        vm.setViews(TicketViewCatalog(views: [TicketFixtures.view("n"), TicketFixtures.view("a")], defaultID: "n"),
                    active: "n", isLoading: false)
        return vm
    }

    func testListIsTheDefaultMode() {
        XCTAssertEqual(TicketBoardViewModel().mode, .list)
    }

    func testCollapsedGroupsAreSkippedByTriageAndKeys() {
        let vm = viewModel()
        XCTAssertEqual(vm.listKeys, ["WM8-2", "WM8-3", "WM8-1"])
        vm.selectedKey = "WM8-1"
        vm.toggleGroup("status:todo")
        XCTAssertTrue(vm.isCollapsed("status:todo"))
        XCTAssertEqual(vm.listKeys, ["WM8-2"])
        XCTAssertNil(vm.selectedKey, "das gewählte Ticket ist zugeklappt")
        XCTAssertEqual(vm.selectedGroupID, "status:todo", "die Auswahl bleibt auf dem Kopf der Gruppe")

        vm.toggleGroup("status:todo")
        XCTAssertEqual(vm.listKeys, ["WM8-2", "WM8-3", "WM8-1"])
    }

    func testChoosingAViewClosesTheTriageAndAsksForTickets() {
        let vm = viewModel()
        var asked: [String] = []
        vm.onSelectView = { asked.append($0) }
        vm.openFromList("WM8-3")
        XCTAssertNotNil(vm.triage)
        XCTAssertEqual(vm.triage?.title, "Ansicht n")

        vm.selectView("a")
        XCTAssertNil(vm.triage)
        XCTAssertNil(vm.selectedKey)
        XCTAssertEqual(vm.activeViewID, "a")
        XCTAssertEqual(asked, ["a"])

        vm.selectView("a")
        vm.selectView("gibt-es-nicht")
        XCTAssertEqual(asked, ["a"], "derselbe oder ein unbekannter Reiter fragt nicht")
    }

    func testCollapsingIsPerView() {
        let vm = viewModel()
        vm.toggleGroup("status:todo")
        vm.setViews(vm.catalog, active: "a", isLoading: false)
        XCTAssertFalse(vm.isCollapsed("status:todo"), "andere Ansicht, eigene Gruppen")
        vm.setViews(vm.catalog, active: "n", isLoading: false)
        XCTAssertTrue(vm.isCollapsed("status:todo"))
    }

    // MARK: Abgleich mit Ansicht

    func testBuilderTakesTheTicketsOfTheView() {
        let chat = UUID()
        let snapshot = TicketFixtures.snapshot([TicketFixtures.ticket(1), TicketFixtures.ticket(2)])
        let viewTickets = TicketViewTickets(tickets: [TicketFixtures.ticket(2, links: [TicketFixtures.link(chat)])],
                                            fetchedAt: Date(timeIntervalSince1970: 5))
        let chats = [TicketChat(id: chat, title: "Ena", projectName: "w", projectPath: "/w", state: .working, isRunning: true)]
        let model = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: "/w", rule: TicketTeamRule(),
                                             view: TicketFixtures.view("n"), viewTickets: viewTickets)
        XCTAssertEqual(model.entries.map(\.ticket.key), ["WM8-2"])
        XCTAssertEqual(model.entries.first?.agents.first?.chat?.id, chat)
        XCTAssertEqual(model.view?.id, "n")

        let loading = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: "/w", rule: TicketTeamRule(),
                                               view: TicketFixtures.view("n"), viewTickets: nil)
        XCTAssertTrue(loading.entries.isEmpty, "noch nicht geladen: nicht kurz die falschen Tickets zeigen")

        let plain = TicketBoardBuilder.build(snapshot: snapshot, chats: chats, projectPath: "/w", rule: TicketTeamRule(),
                                             view: nil, viewTickets: nil)
        XCTAssertEqual(plain.entries.count, 2)
    }
}
