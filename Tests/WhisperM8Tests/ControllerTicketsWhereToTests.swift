import Foundation
import XCTest
@testable import WhisperM8

/// Weg zum Board mit dem Controller (WM8-91, Paket 1): Reiter „Tickets“ in
/// „Wohin“, Rückweg mit L2 getippt, Einträge im Options-Menü, Leiste und Kopf
/// der Insel.
@MainActor
final class ControllerTicketsWhereToTests: XCTestCase {
    private let here = UUID()
    private let worktree = UUID()
    private let other = UUID()
    private let abc = UUID()

    private var teams: [ControllerTicketTeam] {
        [
            ControllerTicketTeam(team: "WM8", projectID: here, projectName: "whisperm8", colorHex: "#5e6ad2"),
            ControllerTicketTeam(team: "KUN", projectID: other, projectName: "kundenportal", colorHex: "#3fa873"),
            ControllerTicketTeam(team: "ABC", projectID: abc, projectName: "beispiel", colorHex: "#c9962a"),
        ]
    }

    private func boards(
        hereProject: UUID?, hereTeam: String?, inTickets: Bool = false, last: UUID? = nil, waiting: [String: Int] = [:]
    ) -> ControllerTicketBoards {
        let teamOf: [UUID: String] = [here: "WM8", worktree: "WM8", other: "KUN"]
        return ControllerTicketBoards.make(
            teams: teams, hereProjectID: hereProject, hereProjectName: "Projekt", hereTeam: hereTeam,
            inTickets: inTickets, lastProjectID: last, teamOfProject: { teamOf[$0] }, waiting: { waiting[$0] })
    }

    // MARK: - Zeilen

    func testRowsPutHereFirstThenPreviousThenByTeam() {
        let result = boards(hereProject: worktree, hereTeam: "WM8", last: other, waiting: ["WM8": 6])
        XCTAssertEqual(result.rows.map(\.team), ["WM8", "KUN", "ABC"])
        XCTAssertTrue(result.rows[0].isHere)
        XCTAssertEqual(result.rows[0].id, worktree, "„hier“ öffnet das Board des aktuellen Projekts selbst")
        XCTAssertEqual(result.rows[0].waitingCount, 6)
        XCTAssertTrue(result.rows[1].isPrevious)
        XCTAssertNil(result.rows[1].waitingCount, "ohne geladenen Stand keine Zahl")
        XCTAssertNil(result.hereWithoutTeam)
    }

    func testProjectWithoutTeamGetsAHint() {
        let result = boards(hereProject: UUID(), hereTeam: nil)
        XCTAssertEqual(result.hereWithoutTeam, "Projekt")
        XCTAssertFalse(result.rows.contains(where: \.isHere))
    }

    func testInTheBoardHereIsNow() {
        let result = boards(hereProject: here, hereTeam: "WM8", inTickets: true, last: here)
        XCTAssertTrue(result.rows[0].isCurrent)
        XCTAssertFalse(result.rows.contains(where: \.isPrevious), "das offene Board ist nicht „vorher“")
    }

    // MARK: - Reiter und Ziel

    private func state(_ boards: ControllerTicketBoards?, grid: Bool = false,
                       previous: ControllerWhereToState.Destination = .stay) -> ControllerWhereToState {
        let chat = UUID()
        return ControllerWhereToState(
            chats: [ControllerIslandChatRow(id: chat, title: "Jarvis", project: nil, status: .idle, detail: "", isCurrent: true)],
            currentChatID: chat,
            workspaces: [ControllerWorkspaceChoice(id: UUID(), name: "WM8 Aktiv", colorHex: "#5e6ad2", chatCount: 3,
                                                   hasWaitingChat: false, isCurrent: grid)],
            gridActive: grid, previous: previous, tickets: boards)
    }

    func testTicketsTabOnlyWithTheTicketView() {
        XCTAssertEqual(state(nil).tabs, [.chats, .workspaces])
        XCTAssertEqual(state(boards(hereProject: here, hereTeam: "WM8")).tabs, [.chats, .workspaces, .tickets])
    }

    /// Aus „Chats“ sind es zwei Schritte bis „Tickets“, kein Umlauf.
    func testTabsMoveOneStepWithoutWrapping() {
        var whereTo = state(boards(hereProject: here, hereTeam: "WM8"))
        XCTAssertEqual(whereTo.tab, .chats)
        XCTAssertFalse(whereTo.switchTab(-1))
        XCTAssertTrue(whereTo.switchTab(1))
        XCTAssertEqual(whereTo.tab, .workspaces)
        XCTAssertTrue(whereTo.switchTab(1))
        XCTAssertEqual(whereTo.tab, .tickets)
        XCTAssertFalse(whereTo.switchTab(1))
        XCTAssertTrue(whereTo.switchTab(-1))
        XCTAssertEqual(whereTo.tab, .workspaces)
    }

    /// „hier“ ist außerhalb des Boards ein Ziel: L2 halten, ▶ ▶, loslassen.
    func testHereIsATargetOutsideTheBoard() {
        var whereTo = state(boards(hereProject: here, hereTeam: "WM8"))
        whereTo.switchTab(1)
        whereTo.switchTab(1)
        XCTAssertEqual(whereTo.destination, .tickets(here))
        whereTo.move(1)
        XCTAssertEqual(whereTo.destination, .tickets(abc), "unter „hier“ die übrigen Teams nach Kürzel")
    }

    /// Im Board beginnt „Wohin“ auf „Tickets“; Loslassen ohne Bewegung tut nichts.
    func testInTheBoardStartsOnTicketsAndStays() {
        let whereTo = state(boards(hereProject: here, hereTeam: "WM8", inTickets: true))
        XCTAssertEqual(whereTo.tab, .tickets)
        XCTAssertEqual(whereTo.destination, .stay)
    }

    /// Ohne Team im aktuellen Projekt: keine Markierung, Loslassen tut nichts;
    /// der erste Schritt markiert die erste Zeile.
    func testWithoutTeamNothingIsMarked() {
        var whereTo = state(boards(hereProject: UUID(), hereTeam: nil))
        whereTo.switchTab(1)
        whereTo.switchTab(1)
        XCTAssertEqual(whereTo.destination, .stay)
        whereTo.move(1)
        XCTAssertEqual(whereTo.destination, .tickets(abc), "ABC steht nach Kürzel zuerst")
    }

    /// Der vorige Ort ist ein Board: Er steht in „Tickets“, und die Tastatur
    /// (⌥Tab kurz) markiert ihn dort.
    func testPreviousBoardIsMarkedForTheKeyboard() {
        var whereTo = state(boards(hereProject: here, hereTeam: "WM8", last: other), previous: .tickets(other))
        XCTAssertEqual(whereTo.previous, .tickets(other))
        whereTo.markPreviousForKeyboard()
        XCTAssertEqual(whereTo.tab, .tickets)
        XCTAssertEqual(whereTo.destination, .tickets(other))
    }

    func testBackTargetOfABoardBecomesATicketsDestination() {
        let target = ControllerBackTarget(kind: .tickets, title: "WM8", id: here)
        XCTAssertEqual(ControllerActionDispatcher.whereToPrevious(target), .tickets(here))
    }

    // MARK: - Options-Menü

    func testMenuOffersTheBoardOnlyFromAChat() {
        let board = ControllerTicketBoardTarget(projectID: here, team: "WM8")
        var setup = ControllerMenuSetup()
        XCTAssertFalse(ControllerMenuModel.isVisible(.ticketBoard, setup: setup), "ohne Team kein Eintrag")
        setup.ticketBoard = board
        XCTAssertTrue(ControllerMenuModel.isVisible(.ticketBoard, setup: setup))
        XCTAssertTrue(ControllerMenuModel.isEnabled(.ticketBoard, setup: setup))
        XCTAssertFalse(ControllerMenuModel.isVisible(.backToChats, setup: setup))
        XCTAssertEqual(ControllerMenuItem.ticketBoard.group, .controller, "Gruppe „Steuerung“")

        setup.ticketsShown = true
        XCTAssertFalse(ControllerMenuModel.isVisible(.ticketBoard, setup: setup))
        XCTAssertTrue(ControllerMenuModel.isVisible(.backToChats, setup: setup))
        XCTAssertTrue(ControllerMenuModel.isEnabled(.backToChats, setup: setup))
    }

    /// Menü-Karte am Ticket: Gruppen Ticket, Board, Steuerung; das Archiv der
    /// Seitenleiste fehlt im Board.
    func testTicketMenuCard() {
        let vic = ControllerTicketMenuInfo.Chat(id: UUID(), title: "Vic")
        var setup = ControllerMenuSetup()
        setup.ticketsShown = true
        setup.ticket = ControllerTicketMenuInfo(key: "WM8-112", chats: [vic], hasURL: true)
        var model = ControllerMenuModel(setup: setup)
        XCTAssertEqual(model.top.entries.map(\.id), [
            .ticketChat, .ticketCopyLink, .ticketOpenInLinear,
            .boardCopyList, .boardRefresh,
            .backToChats, .clipboardHistory, .showBindings, .pause,
        ])
        XCTAssertTrue(model.top.entries.allSatisfy(\.enabled))
        XCTAssertEqual(model.groupStart(.ticketChat), .ticket)
        XCTAssertEqual(model.groupStart(.boardCopyList), .board)
        model.select(.ticketChat)
        XCTAssertTrue(model.openSubmenu(), "„Zum Chat ›“ zeigt die Chats am Ticket")
        guard case let .ticketChats(list)? = model.submenu else { return XCTFail("keine Chat-Ebene") }
        XCTAssertEqual(list.selected, vic.id.uuidString)

        // Ohne Chat auf diesem Rechner und ohne Adresse: aus, aber sichtbar.
        setup.ticket = ControllerTicketMenuInfo(key: "WM8-112", chats: [], hasURL: false)
        let bare = ControllerMenuModel(setup: setup)
        XCTAssertFalse(bare.top.entries.first { $0.id == .ticketChat }!.enabled)
        XCTAssertFalse(bare.top.entries.first { $0.id == .ticketOpenInLinear }!.enabled)
        // Ohne gewähltes Ticket nur das Board.
        setup.ticket = ControllerTicketMenuInfo(key: nil)
        XCTAssertFalse(ControllerMenuModel(setup: setup).top.entries.contains { $0.id == .ticketCopyLink })
    }

    // MARK: - Leiste

    func testLegendNamesTheWayBackAndNoDictation() {
        let back = ControllerBackTarget(kind: .chat, title: "Jarvis", id: UUID())
        let context = ControllerContext.tickets(
            ControllerTicketState(place: ControllerTicketsPlace(projectID: here, team: "WM8"), backTarget: back))
        let entries = ControllerLegend.entries(for: context)
        XCTAssertEqual(entries.first(where: { $0.label == .lastChat })?.backTarget, back)
        XCTAssertFalse(entries.contains(where: { $0.label == .dictate }), "R2 tut ohne Board-Chat nichts")
        XCTAssertTrue(entries.contains(where: { $0.label == .menu }))
        XCTAssertTrue(entries.contains(where: { $0.label == .layersHold }))
    }

    /// Board, Triage und Chat-Zeile zeigen ihre eigenen Tasten (Plan, „Die Leiste unten“).
    func testLegendPerView() {
        func labels(_ view: ControllerTicketView, chats: Bool = false, chatTitle: String? = nil) -> [ControllerLegendLabel] {
            var place = ControllerTicketsPlace(projectID: here, team: "WM8")
            place.view = view
            place.hasTicket = true
            place.ticketHasChats = chats
            place.chatLineTitle = chatTitle
            return ControllerLegend.entries(for: .tickets(ControllerTicketState(place: place))).map(\.label)
        }
        // Paket 3d: „▲ Filter“ gleich hinter „Öffnen“.
        XCTAssertEqual(Array(labels(.board).prefix(8)),
                       [.ticketSelection, .open, .boardViews, .copyLink, .ticketPreviousNext, .openInLinear, .refresh, .menu])
        XCTAssertTrue(labels(.triage).contains(.backToBoard))
        XCTAssertTrue(labels(.triage).contains(.read))
        XCTAssertFalse(labels(.triage).contains(.chatsOnTicket), "▶ nur, wenn das Ticket Chats hat")
        XCTAssertTrue(labels(.triage, chats: true).contains(.chatsOnTicket))
        XCTAssertEqual(labels(.chatLine, chatTitle: "Vic"), [.goToChat, .backToTicketList, .chooseChat])
        XCTAssertFalse(labels(.chatLine).contains(.goToChat), "Chat auf anderem Rechner: kein „Zum Chat“")
        for view in [ControllerTicketView.empty, .board, .list, .triage, .chatLine] {
            XCTAssertFalse(labels(view).contains(.dictate), "\(view): kein Diktat")
            XCTAssertFalse(labels(view).contains(.send), "\(view): nichts senden")
        }
    }

    // MARK: - Teams aus der Einrichtung

    func testDirectoryResolvesTeamsAndOneProjectPerTeam() {
        var config = TicketConfig()
        config.set(team: "WM8", forProject: "/tmp/wm8-fake/whisperm8")
        config.set(team: "KUN", forProject: "/tmp/wm8-fake/kundenportal")
        let projects = [
            TicketTeamDirectory.Project(id: worktree, path: "/tmp/wm8-fake/whisperm8/.claude/worktrees/x", name: "x", colorHex: "#111111"),
            TicketTeamDirectory.Project(id: here, path: "/tmp/wm8-fake/whisperm8", name: "whisperm8", colorHex: "#5e6ad2"),
            TicketTeamDirectory.Project(id: UUID(), path: "/tmp/wm8-fake/ohne-team", name: "ohne", colorHex: "#222222"),
        ]
        let resolved = TicketTeamDirectory.resolve(config: config, projects: projects)
        XCTAssertEqual(resolved.teamByProjectID[here], "WM8")
        XCTAssertEqual(resolved.teamByProjectID[worktree], "WM8", "Arbeitsordner unterhalb des Projekts")
        XCTAssertEqual(resolved.teams.map(\.team), ["WM8"], "KUN hat kein Projekt in der App")
        XCTAssertEqual(resolved.teams.first?.projectID, here, "das Projekt, dessen Ordner eingerichtet ist")
    }

    func testPlaceTitle() {
        XCTAssertEqual(ControllerTicketsPlace(projectID: nil, team: "WM8").label, "WM8")
        XCTAssertEqual(ControllerTicketsPlace(projectID: nil, team: nil, projectName: "whisperm8").label, "whisperm8")
    }
}
