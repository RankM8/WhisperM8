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
        guard case .check(true, let one) = blocks[3], case .check(false, _) = blocks[4], case .bullet = blocks[5] else {
            return XCTFail("\(blocks)")
        }
        XCTAssertEqual(String(one.characters), "eins")
        XCTAssertEqual(blocks[6], .code("# kein Titel"), "im Codeblock bleibt die Zeile, wie sie ist")
        XCTAssertEqual(blocks[7], .heading("Agent notes"))
        XCTAssertTrue(TicketDescriptionBlocks.make("").isEmpty)
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
