import XCTest
@testable import WhisperM8

/// Regel je Team (was ein Status bedeutet, wann ein Ticket auf mich wartet)
/// und die Spalten nach echtem Status.
@MainActor
final class TicketTeamRuleTests: XCTestCase {
    private let me = TicketPerson(id: "me", name: "Giuliano Costa")
    private let other = TicketPerson(id: "u2", name: "Erfundene Person")
    private let jon = UUID(uuidString: "7493E390-EDEB-4CC0-AEBE-68EF61F356EE")!

    private let rule = TicketTeamRule(statusMeanings: ["merge-bereit": .waitsForMe, "Wartet aufs Ausliefern": .done],
                                      waitingLabels: ["Entscheidung", "Handtest"])

    // MARK: Bedeutung und „wartet auf mich“

    func testMeaningFollowsRuleCaseInsensitivelyAndFallsBackToKind() {
        XCTAssertEqual(rule.meaning(of: TicketFixtures.status("Merge-bereit")), .waitsForMe)
        XCTAssertEqual(rule.meaning(of: TicketFixtures.status("In Progress")), .inProgress, "begonnen ohne Eintrag: in Arbeit")
        XCTAssertNil(rule.meaning(of: TicketFixtures.status("Todo")))
        XCTAssertEqual(TicketTeamRule().meaning(of: TicketFixtures.status("Merge-bereit")), .inProgress, "ohne Regel kein fester Name")
    }

    func testWaitsForMe() {
        let viewer = me.id
        XCTAssertTrue(rule.waitsForMe(TicketFixtures.ticket(1, status: "Merge-bereit"), viewerID: viewer), "Status bedeutet „wartet“")
        XCTAssertTrue(rule.waitsForMe(TicketFixtures.ticket(2, assignee: me, labels: ["handtest"]), viewerID: viewer))
        XCTAssertFalse(rule.waitsForMe(TicketFixtures.ticket(3, assignee: me, labels: ["Feature"]), viewerID: viewer),
                       "Regel nennt Labels: ohne eines davon wartet es nicht")
        XCTAssertFalse(rule.waitsForMe(TicketFixtures.ticket(4, assignee: other, labels: ["Entscheidung"]), viewerID: viewer))
        XCTAssertFalse(rule.waitsForMe(TicketFixtures.ticket(5, assignee: me, labels: ["Entscheidung"]), viewerID: nil),
                       "ohne bekannten Nutzer zählt nur der Status")
        XCTAssertFalse(rule.waitsForMe(TicketFixtures.ticket(6, status: "Done", assignee: me, labels: ["Entscheidung"]), viewerID: viewer))
        XCTAssertTrue(TicketTeamRule().waitsForMe(TicketFixtures.ticket(7, status: "Backlog", assignee: me), viewerID: viewer),
                      "leere Regel: alles, was mir zugewiesen ist")
    }

    func testRuleSurvivesConfigRoundTripAndOldFiles() throws {
        var config = TicketConfig()
        config.set(rule: rule, forTeam: "wm8")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TicketConfig.self, from: data)
        XCTAssertEqual(decoded.rule(forTeam: "WM8"), rule)
        let old = try JSONDecoder().decode(TicketConfig.self, from: Data(#"{"version":1,"teamsByProjectPath":{}}"#.utf8))
        XCTAssertEqual(old.rule(forTeam: "WM8"), TicketTeamRule())
        let future = try JSONDecoder().decode(TicketTeamRule.self, from: Data(#"{"statusMeanings":{"A":"waitsForMe","B":"neu"}}"#.utf8))
        XCTAssertEqual(future.statusMeanings, ["A": .waitsForMe], "unbekannte Bedeutung fällt weg, statt die Datei unlesbar zu machen")
        config.set(rule: TicketTeamRule(), forTeam: "WM8")
        XCTAssertTrue(config.rulesByTeam.isEmpty, "leere Regel wird nicht gespeichert")
    }

    // MARK: Spalten

    private func model(rule: TicketTeamRule? = nil) -> TicketBoardModel {
        var snapshot = TicketFixtures.snapshot([
            TicketFixtures.ticket(1, status: "In Progress", priority: 2, links: [TicketFixtures.link(jon)]),
            TicketFixtures.ticket(2, status: "Merge-bereit"),
            TicketFixtures.ticket(3, status: "Todo", assignee: me, labels: ["Entscheidung"]),
            TicketFixtures.ticket(4, status: "Todo", priority: 1),
            TicketFixtures.ticket(5, status: "Backlog"),
            TicketFixtures.ticket(6, status: "Done"),
        ])
        snapshot.viewerID = me.id
        return TicketBoardBuilder.build(
            snapshot: snapshot,
            chats: [TicketChat(id: jon, title: "Jon · Board", projectName: "w", projectPath: "/p", state: .working, isRunning: true)],
            projectPath: "/p", rule: rule ?? self.rule)
    }

    func testLanesFollowRealStatusMostAdvancedFirst() {
        let lanes = TicketBoardPresentation.make(model: model()).lanes
        XCTAssertEqual(lanes.map(\.status.name), ["Merge-bereit", "In Progress", "Todo", "Backlog"],
                       "wartet auf mich zuerst, dann begonnen, als Nächstes, Backlog; erledigt nie")
        XCTAssertEqual(lanes.map(\.meaning), [.waitsForMe, .inProgress, nil, nil])
        XCTAssertEqual(lanes[2].entries.map(\.ticket.key), ["WM8-4", "WM8-3"], "nach Priorität")
        XCTAssertEqual(lanes.map(\.waitingCount), [1, 0, 1, 0])
    }

    /// Seit WM8-125 filtert das Board nicht mehr selbst: Keine Spalte klappt ein,
    /// und die Zahl „wartet“ gilt für das ganze Team.
    func testBoardNoLongerFiltersAndCountsTheWholeTeam() {
        let presentation = TicketBoardPresentation.make(model: model())
        XCTAssertEqual(presentation.lanes.count, 4)
        XCTAssertEqual(presentation.lanes.map(\.isFolded), [false, false, false, false])
        XCTAssertFalse(TicketBoardLanes.isFolded(entries: [], filterActive: false), "ohne Filter bleibt eine leere Spalte breit")
        XCTAssertEqual(presentation.teamWaitingCount, 2)
    }

    func testWaitingLanesFirstAndDoneBehindWork() {
        let statuses = [
            TicketStatus(id: "b", name: "Backlog", kind: .backlog, position: 0),
            TicketStatus(id: "t", name: "Todo", kind: .unstarted, position: 1),
            TicketStatus(id: "p", name: "In Progress", kind: .started, position: 2),
            TicketStatus(id: "r", name: "Im Review", kind: .started, position: 3),
            TicketStatus(id: "s", name: "Beim Kunden", kind: .started, position: 4),
            TicketStatus(id: "q", name: "Rückfrage", kind: .unstarted, position: 1.5),
        ]
        let rule = TicketTeamRule(statusMeanings: ["Beim Kunden": .done, "Rückfrage": .waitsForMe])
        let sorted = statuses.sorted { TicketBoardLanes.laneOrder($0, $1, rule: rule) }.map(\.name)
        XCTAssertEqual(sorted, ["Rückfrage", "Im Review", "In Progress", "Beim Kunden", "Todo", "Backlog"])
    }

    func testShownCardsAreCutAtTheLimitUnlessExpanded() {
        let status = TicketFixtures.status("Backlog")
        let entries = (1...11).map { TicketBoardEntry(ticket: TicketFixtures.ticket($0, status: "Backlog"), agents: []) }
        let lane = TicketBoardLane(status: status, meaning: nil, entries: entries)
        let cut = TicketBoardLanes.shown(lane, expanded: false)
        XCTAssertEqual(cut.entries.map(\.ticket.key), entries.prefix(TicketBoardLanes.cardLimit).map(\.ticket.key))
        XCTAssertEqual(cut.hidden, 3)
        let all = TicketBoardLanes.shown(lane, expanded: true)
        XCTAssertEqual(all.entries.count, 11)
        XCTAssertEqual(all.hidden, 0)
        let short = TicketBoardLanes.shown(TicketBoardLane(status: status, meaning: nil, entries: Array(entries.prefix(3))), expanded: false)
        XCTAssertEqual(short.entries.count, 3)
        XCTAssertEqual(short.hidden, 0)
    }

    func testUnknownStatusStillGetsALane() {
        var snapshot = TicketFixtures.snapshot([TicketFixtures.ticket(1, status: "Todo")])
        snapshot.tickets[0].status = TicketStatus(id: "neu", name: "Beim Kunden", kind: .started, position: 2.7)
        snapshot.statuses = TicketFixtures.statuses
        let model = TicketBoardBuilder.build(snapshot: snapshot, chats: [], projectPath: nil)
        XCTAssertEqual(TicketBoardPresentation.make(model: model).lanes.map(\.status.name), ["Beim Kunden"])
    }

    func testDoneAndWaitingStatusesDoNotCountAsMissingAgent() {
        var filter = TicketBoardFilter()
        filter.agent = .withoutAgent
        // Filter der Kommandozeile (`tickets list --no-agent`).
        let keys = Set(filter.apply(to: model().entries).map(\.ticket.key))
        XCTAssertEqual(keys, ["WM8-4", "WM8-3"], "Merge-bereit wartet auf mich, nicht auf einen Chat")
        let plain = Set(filter.apply(to: model(rule: TicketTeamRule()).entries).map(\.ticket.key))
        XCTAssertEqual(plain, ["WM8-2", "WM8-4", "WM8-3"])
    }

    // MARK: Kommandozeile

    func testRuleChangeFromCommandLine() throws {
        let arguments = try TicketsCLIArguments.parse(["setup", "--team", "wm8", "--status", "Merge-bereit=wartet",
                                                       "--status", "Beim Kunden=fertig", "--waiting-labels", "Entscheidung, Handtest"])
        guard case .rule(let request) = arguments else { return XCTFail("\(arguments)") }
        XCTAssertEqual(request.team, "WM8")
        XCTAssertTrue(arguments.isWrite)
        var result = try TicketTeamRuleChange.apply(request, to: TicketConfig())
        XCTAssertEqual(result.config.rule(forTeam: "WM8"),
                       TicketTeamRule(statusMeanings: ["Merge-bereit": .waitsForMe, "Beim Kunden": .done],
                                      waitingLabels: ["Entscheidung", "Handtest"]))
        XCTAssertTrue(result.message.contains("Merge-bereit = wartet"), result.message)

        // Gleicher Name anders geschrieben ersetzt; `NAME=` nimmt weg.
        result = try TicketTeamRuleChange.apply(.init(team: "WM8", statuses: ["merge-bereit=arbeit", "Beim Kunden="]), to: result.config)
        XCTAssertEqual(result.config.rule(forTeam: "WM8").statusMeanings, ["merge-bereit": .inProgress])

        XCTAssertThrowsError(try TicketTeamRuleChange.apply(.init(team: "WM8", statuses: ["Todo=bald"]), to: TicketConfig()))
        XCTAssertThrowsError(try TicketTeamRuleChange.apply(.init(team: "WM8", statuses: ["Todo"]), to: TicketConfig()))
        XCTAssertThrowsError(try TicketsCLIArguments.parse(["setup", "--status", "A=wartet"]), "ohne --team")
        XCTAssertThrowsError(try TicketsCLIArguments.parse(["setup", "--team", "WM8", "--status", "A=wartet", "--project", "/x"]))

        let show = try TicketsCLIArguments.parse(["setup", "--team", "WM8", "--show-rule"])
        guard case .rule(let showRequest) = show else { return XCTFail("\(show)") }
        XCTAssertTrue(showRequest.isShowOnly)
        XCTAssertFalse(show.isWrite)
        let cleared = try TicketTeamRuleChange.apply(.init(team: "WM8", clear: true), to: result.config)
        XCTAssertTrue(cleared.config.rulesByTeam.isEmpty)
    }
}
