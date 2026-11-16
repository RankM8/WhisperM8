import XCTest
@testable import WhisperM8

@MainActor
final class TicketBoardPresentationTests: XCTestCase {
    private let jon = UUID(uuidString: "7493E390-EDEB-4CC0-AEBE-68EF61F356EE")!
    private let ole = UUID(uuidString: "B0096DCA-0000-4000-8000-000000000002")!
    private let giuliano = TicketPerson(id: "u1", name: "Giuliano Costa")
    private let project = "/Users/g/repos/whisperm8"

    private func chat(_ id: UUID, _ title: String, _ state: TicketChatState) -> TicketChat {
        TicketChat(id: id, title: title, projectName: "whisperm8", projectPath: project, state: state, isRunning: true)
    }

    private func model() -> TicketBoardModel {
        let tickets = [
            TicketFixtures.ticket(1, status: "In Progress", priority: 2, assignee: giuliano, project: "Tickets", links: [TicketFixtures.link(jon)]),
            TicketFixtures.ticket(2, status: "Todo", priority: 1, project: "Agent Chats"),
            TicketFixtures.ticket(3, status: "Backlog", project: nil),
            TicketFixtures.ticket(4, status: "Todo", assignee: giuliano, project: "Tickets"),
            TicketFixtures.ticket(5, status: "Done", project: "Tickets", links: [TicketFixtures.link(ole, active: false)]),
        ]
        return TicketBoardBuilder.build(snapshot: TicketFixtures.snapshot(tickets),
                                        chats: [chat(jon, "Jon · Board", .working), chat(ole, "Ole · Terminal", .idle)], projectPath: project)
    }

    // MARK: Inhalt

    func testColumnsGroupsAndProjects() {
        let presentation = TicketBoardPresentation.make(model: model(), filter: .all)
        XCTAssertEqual(presentation.lanes.map(\.status.name), ["In Progress", "Todo", "Backlog"], "nur Status mit offenen Tickets")
        XCTAssertEqual(presentation.lanes.map { $0.entries.map(\.ticket.key) }, [["WM8-1"], ["WM8-2", "WM8-4"], ["WM8-3"]])
        // Ohne Ansicht aus Linear: Liste nach Status wie die Spalten (WM8-125).
        XCTAssertEqual(presentation.groups.map(\.title), ["In Progress", "Todo", "Backlog"])
        XCTAssertEqual(presentation.groups[1].entries.map(\.ticket.key), ["WM8-2", "WM8-4"])
        XCTAssertEqual(presentation.groups[0].agentCount, 1)
        XCTAssertEqual(presentation.projects, ["Agent Chats", "Tickets", ""])
        XCTAssertEqual(presentation.visibleCount, 4, "das erledigte Ticket steht nur für die Spur im Abzug")
        XCTAssertNil(presentation.entry(key: "WM8-5"))
        XCTAssertEqual(presentation.looseChats.map(\.chat.shortName), ["Ole"])
        XCTAssertEqual(presentation.looseChats.first?.earlier, ["WM8-5 (Done)"])
    }

    func testFilterNarrowsContentButCountsStayHonest() {
        var filter = TicketBoardFilter()
        filter.project = "Tickets"
        let presentation = TicketBoardPresentation.make(model: model(), filter: filter)
        XCTAssertEqual(presentation.groups.map { $0.entries.map(\.ticket.key) }, [["WM8-1"], ["WM8-4"]])
        XCTAssertEqual(presentation.projects, ["Agent Chats", "Tickets", ""], "die Auswahl zeigt weiter alle Projekte")
        XCTAssertEqual(presentation.counts.all, 2)
        XCTAssertEqual(presentation.counts.withAgent, 1)
        XCTAssertEqual(presentation.counts.withoutAgent, 1)
        XCTAssertEqual(presentation.counts.people.map(\.count), [2])
        XCTAssertEqual(TicketBoardPresentation.make(model: TicketBoardModel(entries: [], looseChats: [], supervisors: []), filter: .all),
                       .empty)
    }

    // MARK: Zustand der Ansicht

    func testViewModelKeepsSelectionAcrossANewSnapshot() {
        let viewModel = TicketBoardViewModel(model: model())
        viewModel.selectedKey = "WM8-1"
        XCTAssertEqual(viewModel.selected?.ticket.key, "WM8-1")
        viewModel.update(model())
        XCTAssertEqual(viewModel.selected?.ticket.key, "WM8-1")
    }

    func testAStatusChangeDoesNotRebuildAnything() {
        let viewModel = TicketBoardViewModel(model: model())
        let builds = viewModel.rebuilds
        // Derselbe Abzug, nur ein Chat arbeitet nicht mehr.
        let changed = TicketBoardBuilder.build(
            snapshot: TicketFixtures.snapshot(model().entries.map(\.ticket) + [TicketFixtures.ticket(5, status: "Done", project: "Tickets",
                                                                                                  links: [TicketFixtures.link(ole, active: false)])]),
            chats: [chat(jon, "Jon · Board", .needsYou), chat(ole, "Ole · Terminal", .working)], projectPath: project)
        XCTAssertNotEqual(changed, model(), "mit Zustand sind die Modelle verschieden")
        viewModel.update(changed)
        viewModel.update(model())
        XCTAssertEqual(viewModel.rebuilds, builds, "der Zustand der Chats zählt für den Inhalt nicht")
        XCTAssertEqual(changed.chatStates[jon], .needsYou, "er geht getrennt an die Status-Punkte")

        let source = TicketChatStatusSource.fixed(changed.chatStates)
        XCTAssertEqual(source.current(ole), .working)
        XCTAssertNil(source.current(UUID()), "ein Chat, den die Quelle nicht kennt, hat keinen Zustand")
    }

    func testDetailContentIsDerivedOnce() {
        var first = TicketFixtures.link(jon)
        first.since = Date(timeIntervalSince1970: 1_794_626_460)
        var ticket = TicketFixtures.ticket(1, status: "In Progress", links: [first, TicketFixtures.link(ole)])
        ticket.url = "https://linear.app/x/issue/WM8-1"
        let entry = TicketBoardEntry(ticket: ticket, agents: [
            TicketAgent(link: first, chat: nil),   // läuft auf einem anderen Rechner
            TicketAgent(link: TicketFixtures.link(ole), chat: chat(ole, "Ole · Terminal", .idle)),
        ])
        let content = TicketDetailContent.make(entry)
        XCTAssertEqual(content.localChatID, ole, "„Zum Chat“ nimmt den ersten Chat auf diesem Rechner")
        XCTAssertEqual(content.agents.map(\.since), [first.since, nil])
        XCTAssertEqual(content.agents.map { $0.entry.agents.count }, [1, 1])
        XCTAssertEqual(content.url?.absoluteString, "https://linear.app/x/issue/WM8-1")

        for bad in ["http://linear.app/x", "file:///Applications/Calculator.app", "whisperm8://chat/1", "kein link"] {
            ticket.url = bad
            XCTAssertNil(TicketDetailContent.make(TicketBoardEntry(ticket: ticket, agents: [])).url,
                         "„In Linear öffnen“ nur mit https: \(bad)")
        }
    }

    func testChosenPersonStaysVisibleWithZeroHits() {
        var filter = TicketBoardFilter()
        filter.person = .person(id: "u1")
        filter.agent = .withoutAgent
        // Giuliano hat hier nur ein Ticket mit Agent und eines ohne: Erst mit „Mit Agent“ auf null bringen.
        var only = TicketBoardFilter()
        only.person = .person(id: "u1")
        only.project = "Agent Chats"
        let presentation = TicketBoardPresentation.make(model: model(), filter: only)
        XCTAssertEqual(presentation.visibleCount, 0)
        XCTAssertEqual(presentation.counts.people.map(\.person.id), ["u1"], "der aktive Filter bleibt als Knopf sichtbar")
        XCTAssertEqual(presentation.counts.people.map(\.count), [0])
    }

    func testResetGoesBackToTheList() {
        let viewModel = TicketBoardViewModel(model: model())
        viewModel.setViews(TicketViewCatalog(views: [TicketFixtures.view("n")], defaultID: "n"), active: "n", isLoading: false)
        viewModel.toggleGroup("status:todo")
        viewModel.selectedKey = "WM8-1"
        viewModel.mode = .board
        viewModel.reset()
        XCTAssertEqual(viewModel.mode, .list, "Liste ist der Standard (WM8-125)")
        XCTAssertNil(viewModel.activeViewID)
        XCTAssertTrue(viewModel.collapsedGroups.isEmpty)
        XCTAssertEqual(viewModel.presentation, .empty)
    }

    func testCardHelpers() {
        XCTAssertEqual(TicketBoardText.cardLabels(["Feature", "Improvement", "Handtest"]), ["Handtest", "Feature", "Improvement"],
                       "die Art des Tickets zuletzt, damit ein Hinweis wie Handtest nicht hinter „+1“ verschwindet")
        XCTAssertTrue(TicketBoardText.repeatsColumn(TicketFixtures.status("In Progress")))
        XCTAssertFalse(TicketBoardText.repeatsColumn(TicketFixtures.status("Merge-bereit")))
        let people = [TicketPerson(id: "a", name: "Anna Roth"), TicketPerson(id: "b", name: "Anna Weiss"), TicketPerson(id: "c", name: "Tom Kern")]
        XCTAssertEqual(TicketBoardText.chipNames(people), ["a": "Anna Roth", "b": "Anna Weiss", "c": "Tom"])
        let entry = TicketBoardEntry(ticket: TicketFixtures.ticket(1, status: "Merge-bereit", description: "- [x] a\n- [ ] b",
                                                                 links: [TicketFixtures.link(jon, active: false)]), agents: [])
        XCTAssertEqual(entry.criteria, TicketChecklistProgress(done: 1, total: 2), "einmal gerechnet, nicht bei jedem Zeichnen")
        XCTAssertEqual(entry.handedOverBy, ["Chat"])
        XCTAssertTrue(TicketBoardText.spoken(entry).hasPrefix("WM8-1, Ticket 1, Merge-bereit"))
    }

    func testViewModelDropsWhatNoLongerExists() {
        let viewModel = TicketBoardViewModel(model: model())
        viewModel.selectedKey = "WM8-2"
        // Neuer Abzug: Das Ticket gibt es nicht mehr.
        let remaining = model().entries.filter { $0.ticket.key != "WM8-2" }
        viewModel.update(TicketBoardModel(entries: remaining, looseChats: [], supervisors: []))
        XCTAssertNil(viewModel.selectedKey)
        XCTAssertEqual(viewModel.presentation.visibleCount, 3)
    }

    // MARK: Beschreibung

    func testDescriptionBlocks() {
        let blocks = TicketDescriptionBlocks.make("""
        **Stand 14.11.2026:** offen.


        ## Fertig, wenn
        - [x] eins
        * [ ] zwei
        1. Schritt
        ```sh
        # kein Titel
        ```
        +++ Agent notes
        Text
        +++

        """)
        XCTAssertEqual(blocks.count, 9)
        guard case .text(let first) = blocks[0] else { return XCTFail("\(blocks[0])") }
        XCTAssertEqual(String(first.characters), "Stand 14.11.2026: offen.", "Fettschrift wird gesetzt, nicht als Sterne gezeigt")
        XCTAssertEqual(blocks[1], .gap, "mehrere Leerzeilen sind ein Abstand")
        XCTAssertEqual(blocks[2], .heading("Fertig, wenn"))
        guard case .check(true, let one) = blocks[3], case .check(false, _) = blocks[4], case .numbered("1.", _) = blocks[5] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(String(one.characters), "eins")
        XCTAssertEqual(blocks[6], .code("# kein Titel"), "im Codeblock bleibt die Zeile, wie sie ist")
        XCTAssertEqual(blocks[7], .heading("Agent notes"))
        XCTAssertTrue(TicketDescriptionBlocks.make("").isEmpty)
        let long = TicketDescriptionBlocks.make(Array(repeating: "Zeile", count: 1_000).joined(separator: "\n"))
        XCTAssertEqual(long.count, TicketDescriptionBlocks.maxBlocks + 1)
        XCTAssertEqual(long.last, .truncated, "eine sehr lange Beschreibung wird nicht ganz gesetzt")
        XCTAssertEqual(TicketDescriptionBlocks.make("## Titel\r\n+++\r\nText"), [.heading("Titel"), .text(AttributedString("Text"))])
    }

    /// Tickets stammen auch von anderen. Ein Link darf nur ins Web führen.
    func testOnlyWebLinksStayClickable() {
        func links(_ markdown: String) -> [URL] {
            TicketDescriptionBlocks.inline(markdown).runs.compactMap(\.link)
        }
        XCTAssertEqual(links("[Ticket](https://linear.app/x/issue/WM8-1)").map(\.absoluteString), ["https://linear.app/x/issue/WM8-1"])
        for bad in ["[Bericht](file:///Applications/Calculator.app)", "[Freigabe](smb://server/share)", "[Shell](ssh://host)",
                    "[App](whisperm8://chat/1)", "[x](javascript:alert(1))", "[y](https:kein-host)"] {
            XCTAssertTrue(links(bad).isEmpty, bad)
            XCTAssertFalse(String(TicketDescriptionBlocks.inline(bad).characters).isEmpty, "der Text bleibt lesbar")
        }
        XCTAssertFalse(TicketDescriptionBlocks.isSafe(URL(string: "file:///etc/passwd")!))
        XCTAssertTrue(TicketDescriptionBlocks.isSafe(URL(string: "http://example.com")!))
    }

    func testTextsAndStateMapping() {
        XCTAssertEqual(TicketBoardText.initials("Giuliano Costa"), "GC")
        XCTAssertEqual(TicketBoardText.initials("richard"), "R")
        let ticket = TicketFixtures.ticket(1, project: "Tickets")
        XCTAssertEqual(TicketBoardText.placement(ticket), "Tickets")
        var withMilestone = ticket
        withMilestone.milestone = "Board"
        XCTAssertEqual(TicketBoardText.placement(withMilestone), "Tickets · Board")
        // Der Punkt nutzt die Zustände der App; Grün ist nur „arbeitet“.
        XCTAssertEqual(TicketChatState.working.runtimeStatus, .working)
        XCTAssertEqual(TicketChatState.needsYou.runtimeStatus, .awaitingInput)
        for state in [TicketChatState.working, .needsYou, .idle, .errored, .stopped] {
            XCTAssertEqual(TicketChatState(state.runtimeStatus), state, "hin und zurück ohne Verlust")
        }
    }
}
