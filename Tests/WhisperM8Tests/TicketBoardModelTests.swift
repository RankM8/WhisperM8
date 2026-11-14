import XCTest
@testable import WhisperM8

final class TicketBoardModelTests: XCTestCase {
    // MARK: Bausteine

    private let project = "/repos/whisperm8"
    private let jon = UUID(uuidString: "7493E390-EDEB-4CC0-AEBE-68EF61F356EE")!
    private let dex = UUID(uuidString: "840BFE4C-0000-4000-8000-000000000001")!
    private let ole = UUID(uuidString: "B0096DCA-0000-4000-8000-000000000002")!
    private let jarvis = UUID(uuidString: "A37D241B-0000-4000-8000-000000000003")!
    private let giuliano = TicketPerson(id: "u1", name: "Giuliano Costa")
    private let xeno = TicketPerson(id: "u2", name: "Xeno Suter")

    private func status(_ kind: TicketStatusKind, _ name: String? = nil) -> TicketStatus {
        TicketStatus(id: "s-\(kind.rawValue)", name: name ?? kind.rawValue, kind: kind, position: Double(kind.boardOrder))
    }

    private func link(_ chat: UUID, active: Bool = true) -> TicketChatLink {
        TicketChatLink(id: "a-\(chat.uuidString.prefix(4))", chatID: chat, isActive: active, title: "Chat",
                       subtitle: active ? "arbeitet seit 14.11. 00:51" : "beendet am 14.11. 01:10", creatorName: "Giuliano Costa")
    }

    private func ticket(_ number: Int, _ kind: TicketStatusKind, priority: Int = 3, assignee: TicketPerson? = nil,
                        project: String? = "Neustart", links: [TicketChatLink] = [], statusName: String? = nil) -> Ticket {
        Ticket(id: "id-\(number)", key: "WM8-\(number)", title: "Ticket \(number)", description: "", priority: priority,
               status: status(kind, statusName), project: project, milestone: nil, assignee: assignee, labels: [],
               links: links, isBlocked: false, url: nil)
    }

    private func chat(_ id: UUID, _ title: String, state: TicketChatState? = .idle, running: Bool = true,
                      path: String? = nil) -> TicketChat {
        TicketChat(id: id, title: title, projectName: "whisperm8", projectPath: path ?? project, state: state, isRunning: running)
    }

    private func snapshot(_ tickets: [Ticket]) -> TicketBoardSnapshot {
        TicketBoardSnapshot(team: "WM8", statuses: [], tickets: tickets, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: Zuordnung Chat ↔ Ticket

    func testActiveLinkResolvesToLocalChat() {
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([ticket(10, .started, links: [link(dex)])]),
            chats: [chat(dex, "3 Dex · WM8-10 Abnahme", state: .working)], projectPath: project)
        XCTAssertEqual(model.entries.first?.agents.first?.chat?.shortName, "3 Dex")
        XCTAssertEqual(model.entries.first?.agents.first?.chat?.state, .working)
        XCTAssertTrue(model.looseChats.isEmpty)
    }

    func testEndedLinkDoesNotCountAsAgent() {
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([ticket(10, .started, links: [link(dex, active: false)])]),
            chats: [chat(dex, "3 Dex")], projectPath: project)
        XCTAssertFalse(model.entries[0].hasAgent)
        XCTAssertEqual(model.looseChats.map(\.chat.id), [dex], "beendete Verknüpfung: Chat ist wieder ohne Ticket")
    }

    func testLinkToUnknownChatKeepsAgentWithoutChat() {
        // Chat läuft auf einem anderen Rechner oder wurde gelöscht.
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([ticket(10, .started, links: [link(dex)])]), chats: [], projectPath: project)
        XCTAssertTrue(model.entries[0].hasAgent)
        XCTAssertNil(model.entries[0].agents[0].chat)
    }

    func testHandedOverTicketKeepsTheTrail() {
        // Chat hat „Merge-bereit“ gesetzt und seine Verknüpfung beendet.
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([
                ticket(12, .started, links: [link(ole, active: false)], statusName: "Merge-bereit"),
                ticket(13, .unstarted, links: [link(dex, active: false)], statusName: "Todo"),
            ]),
            chats: [chat(ole, "2 Ole"), chat(dex, "3 Dex")], projectPath: project)
        XCTAssertTrue(model.entries[0].isHandedOver)
        XCTAssertFalse(model.entries[1].isHandedOver, "noch nicht begonnen und verlassen: das Ticket braucht wieder jemanden")
        XCTAssertEqual(model.looseChats.first { $0.chat.id == ole }?.earlier, ["WM8-12 (Merge-bereit)"])
        XCTAssertEqual(TicketBoardFilter(agent: .withoutAgent).apply(to: model.entries).map(\.ticket.key), ["WM8-13"])
    }

    func testClosedTicketLeavesTrailInsteadOfAgent() {
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([
                ticket(29, .completed, links: [link(ole)], statusName: "Done"),
                ticket(9, .completed, links: [link(ole, active: false)], statusName: "Done"),
            ]),
            chats: [chat(ole, "2 Ole · WM8-29 Terminal-Tab")], projectPath: project)
        XCTAssertTrue(model.entries.isEmpty, "erledigte Tickets erscheinen nicht im Board")
        XCTAssertEqual(model.looseChats.first?.earlier, ["WM8-9 (Done)", "WM8-29 (Done)"])
    }

    func testLooseChatsOnlyRunningAndOnlyThisProject() {
        let other = UUID()
        let stopped = UUID()
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([]),
            chats: [
                chat(ole, "2 Ole"),
                chat(other, "1 Ana", path: "/repos/ListM8"),
                chat(stopped, "9 Alt", state: .stopped, running: false),
            ], projectPath: project)
        XCTAssertEqual(model.looseChats.map(\.chat.id), [ole])
        XCTAssertEqual(model.looseChats.first?.earlier, [])
    }

    func testSupervisorIsListedSeparately() {
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([]),
            chats: [chat(jarvis, "Jarvis: Supervisor WhisperM8"), chat(ole, "2 Ole")], projectPath: project)
        XCTAssertEqual(model.supervisors.map(\.id), [jarvis])
        XCTAssertEqual(model.looseChats.map(\.chat.id), [ole])
    }

    func testSupervisorWithTicketIsNotListedTwice() {
        let model = TicketBoardBuilder.build(
            snapshot: snapshot([ticket(1, .started, links: [link(jarvis)])]),
            chats: [chat(jarvis, "Jarvis: Supervisor WhisperM8")], projectPath: project)
        XCTAssertTrue(model.supervisors.isEmpty)
        XCTAssertTrue(model.entries[0].hasAgent)
    }

    // MARK: Filter

    private func entries() -> [TicketBoardEntry] {
        TicketBoardBuilder.build(
            snapshot: snapshot([
                ticket(1, .started, assignee: giuliano, links: [link(jon)]),
                ticket(2, .started, assignee: xeno),
                ticket(3, .unstarted),
                ticket(4, .backlog, assignee: giuliano, project: nil),
                ticket(5, .backlog),
            ]),
            chats: [chat(jon, "6 Jon")], projectPath: project).entries
    }

    func testAgentFilter() {
        let all = entries()
        XCTAssertEqual(TicketBoardFilter(agent: .withAgent).apply(to: all).map(\.ticket.key), ["WM8-1"])
        XCTAssertEqual(TicketBoardFilter(agent: .withoutAgent).apply(to: all).map(\.ticket.key), ["WM8-2", "WM8-3"],
                       "Backlog ohne Agent ist kein Befund")
    }

    func testPersonFilter() {
        let all = entries()
        XCTAssertEqual(TicketBoardFilter(person: .unassigned).apply(to: all).map(\.ticket.key), ["WM8-3", "WM8-5"])
        XCTAssertEqual(TicketBoardFilter(person: .person(id: "u1")).apply(to: all).map(\.ticket.key), ["WM8-1", "WM8-4"])
    }

    func testFiltersCombine() {
        let all = entries()
        let mineWithoutAgent = TicketBoardFilter(agent: .withoutAgent, person: .person(id: "u2"))
        XCTAssertEqual(mineWithoutAgent.apply(to: all).map(\.ticket.key), ["WM8-2"])
        XCTAssertEqual(TicketBoardFilter(project: "").apply(to: all).map(\.ticket.key), ["WM8-4"], "leerer Name = ohne Vorhaben")
        XCTAssertEqual(TicketBoardFilter(agent: .withAgent, project: "").apply(to: all).count, 0)
    }

    func testCountsFollowTheOtherGroup() {
        let all = entries()
        let open = TicketFilterCounts.make(entries: all, filter: .all)
        XCTAssertEqual(open.all, 5)
        XCTAssertEqual(open.withAgent, 1)
        XCTAssertEqual(open.withoutAgent, 2)
        XCTAssertEqual(open.unassigned, 2)
        XCTAssertEqual(open.people.map(\.person.name), ["Giuliano Costa", "Xeno Suter"])
        XCTAssertEqual(open.people.map(\.count), [2, 1])

        // Person gewählt: Die Agent-Zahlen gelten nur noch für ihre Tickets.
        let mine = TicketFilterCounts.make(entries: all, filter: TicketBoardFilter(person: .person(id: "u1")))
        XCTAssertEqual(mine.all, 2)
        XCTAssertEqual(mine.withAgent, 1)
        XCTAssertEqual(mine.withoutAgent, 0)
        // Die Personen-Zahlen bleiben dabei vollständig, sonst ließe sich nicht wechseln.
        XCTAssertEqual(mine.unassigned, 2)
        XCTAssertEqual(mine.people.map(\.count), [2, 1])
    }

    // MARK: Spalten

    func testColumnsGroupByKindAndSort() {
        let built = TicketBoardBuilder.build(
            snapshot: snapshot([
                ticket(7, .unstarted, priority: 2),
                ticket(12, .triage, priority: 0),
                ticket(10, .started, priority: 3, links: [link(dex)]),
                ticket(9, .started, priority: 3),
                ticket(23, .started, priority: 2),
                ticket(13, .backlog, priority: 2),
            ]),
            chats: [chat(dex, "3 Dex")], projectPath: project).entries
        let columns = TicketBoardLayout.columns(built)
        XCTAssertEqual(columns.map(\.kind), [.started, .unstarted, .backlog])
        XCTAssertEqual(columns[0].entries.map(\.ticket.key), ["WM8-23", "WM8-10", "WM8-9"],
                       "erst Priorität, bei Gleichstand das Ticket mit Agent")
        XCTAssertEqual(columns[1].entries.map(\.ticket.key), ["WM8-7", "WM8-12"], "Triage steht bei „als Nächstes“, ohne Priorität zuletzt")
        XCTAssertEqual(columns[0].agentCount, 1)
    }

    // MARK: Format der Verknüpfung

    func testLinkFormatRoundTrip() {
        let url = TicketChatLinkFormat.url(for: jon)
        XCTAssertEqual(url, "whisperm8://chat/7493E390-EDEB-4CC0-AEBE-68EF61F356EE")
        XCTAssertEqual(TicketChatLinkFormat.chatID(fromURL: url), jon)
        XCTAssertNil(TicketChatLinkFormat.chatID(fromURL: "https://github.com/x/y/pull/1"))
        XCTAssertNil(TicketChatLinkFormat.chatID(fromURL: "whisperm8://chat/kein-uuid"))
    }

    func testSubtitlesMatchTheScriptFormat() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 0, minute: 51))!
        let active = TicketChatLinkFormat.activeSubtitle(for: chat(jon, "6 Jon · WM8-23 Linear"), at: date, calendar: calendar)
        XCTAssertEqual(active, "arbeitet seit 14.11. 00:51 · WhisperM8 · whisperm8")
        XCTAssertTrue(TicketChatLinkFormat.isActive(subtitle: active))
        let ended = TicketChatLinkFormat.endedSubtitle(at: date, calendar: calendar)
        XCTAssertEqual(ended, "beendet am 14.11. 00:51 · WhisperM8")
        XCTAssertFalse(TicketChatLinkFormat.isActive(subtitle: ended))
    }

    func testChatStateFromRuntimeStatus() {
        XCTAssertEqual(TicketChatState(.working), .working)
        XCTAssertEqual(TicketChatState(.awaitingInput), .needsYou)
        XCTAssertEqual(TicketChatState(.idle), .idle)
        XCTAssertEqual(TicketChatState(.errored), .errored)
        XCTAssertEqual(TicketChatState(.stopped), .stopped)
        XCTAssertEqual(TicketChatState(nil), .stopped)
    }
}
