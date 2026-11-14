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
        XCTAssertEqual(presentation.columns.map { $0.entries.map(\.ticket.key) }, [["WM8-1"], ["WM8-2", "WM8-4"], ["WM8-3"]])
        XCTAssertEqual(presentation.groups.map(\.project), ["Agent Chats", "Tickets", ""], "alphabetisch, ohne Projekt am Ende")
        XCTAssertEqual(presentation.groups[1].entries.map(\.ticket.key), ["WM8-1", "WM8-4"])
        XCTAssertEqual(presentation.groups[1].agentCount, 1)
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
        XCTAssertEqual(presentation.groups.map(\.project), ["Tickets"])
        XCTAssertEqual(presentation.projects, ["Agent Chats", "Tickets", ""], "die Auswahl zeigt weiter alle Projekte")
        XCTAssertEqual(presentation.counts.all, 2)
        XCTAssertEqual(presentation.counts.withAgent, 1)
        XCTAssertEqual(presentation.counts.withoutAgent, 1)
        XCTAssertEqual(presentation.counts.people.map(\.count), [2])
        XCTAssertEqual(TicketBoardPresentation.make(model: TicketBoardModel(entries: [], looseChats: [], supervisors: []), filter: .all),
                       .empty)
    }

    // MARK: Zustand der Ansicht

    func testViewModelRebuildsOnFilterAndKeepsSelection() {
        let viewModel = TicketBoardViewModel(model: model())
        viewModel.toggle("WM8-1")
        XCTAssertEqual(viewModel.selected?.ticket.key, "WM8-1")

        viewModel.filter.agent = .withoutAgent
        XCTAssertEqual(viewModel.presentation.visibleCount, 2)
        XCTAssertNil(viewModel.selected, "das gewählte Ticket ist ausgeblendet")
        XCTAssertEqual(viewModel.selectedKey, "WM8-1", "die Auswahl selbst bleibt, bis der Filter zurückgeht")
        viewModel.filter.agent = .all
        XCTAssertEqual(viewModel.selected?.ticket.key, "WM8-1")

        viewModel.toggle("WM8-1")
        XCTAssertNil(viewModel.selectedKey, "ein zweiter Klick schließt das Detail")
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

        let source = TicketChatStatusSource()
        source.set(changed.chatStates)
        XCTAssertEqual(source.states[ole], .working)
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

    func testResetAndVanishedPerson() {
        let viewModel = TicketBoardViewModel(model: model())
        viewModel.filter.person = .person(id: "u1")
        viewModel.selectedKey = "WM8-1"
        viewModel.mode = .backlog
        // Neuer Abzug ohne Tickets dieser Person: Der Filter blendete sonst alles aus.
        viewModel.update(TicketBoardModel(entries: model().entries.filter { $0.ticket.assignee == nil }, looseChats: [], supervisors: []))
        XCTAssertEqual(viewModel.filter.person, .all)
        viewModel.filter.agent = .withAgent
        viewModel.reset()
        XCTAssertEqual(viewModel.filter, TicketBoardFilter())
        XCTAssertEqual(viewModel.mode, .board)
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
        viewModel.filter.project = "Agent Chats"
        // Neuer Abzug: Das Ticket und sein Projekt gibt es nicht mehr.
        let remaining = model().entries.filter { $0.ticket.key != "WM8-2" }
        viewModel.update(TicketBoardModel(entries: remaining, looseChats: [], supervisors: []))
        XCTAssertNil(viewModel.selectedKey)
        XCTAssertNil(viewModel.filter.project, "ein Filter auf ein verschwundenes Projekt blendete sonst alles aus")
        XCTAssertEqual(viewModel.presentation.visibleCount, 3)
    }

    func testDescriptionIsParsedWhenSelectingNotWhenDrawing() {
        var tickets = model().entries
        tickets[0].ticket.description = "## Ziel\nText mit **Fett**.\n\n- [x] fertig\n- [ ] offen\n* Punkt"
        let viewModel = TicketBoardViewModel(model: TicketBoardModel(entries: tickets, looseChats: [], supervisors: []))
        XCTAssertTrue(viewModel.selectedDescription.isEmpty)
        viewModel.selectedKey = tickets[0].ticket.key
        XCTAssertEqual(viewModel.selectedDescription.count, 6)
        XCTAssertEqual(viewModel.selectedDescription.first, .heading("Ziel"))
        viewModel.selectedKey = nil
        XCTAssertTrue(viewModel.selectedDescription.isEmpty)
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
