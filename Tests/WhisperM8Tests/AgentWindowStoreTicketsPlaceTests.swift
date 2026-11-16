import Foundation
import XCTest
@testable import WhisperM8

/// Das Ticket-Board als Ort für L2 (WM8-91): hin und zurück führt dorthin,
/// wo man vorher war, auch zwischen Board und Chat.
@MainActor
final class AgentWindowStoreTicketsPlaceTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-tickets-place-\(prefix)-\(UUID().uuidString).json")
    }

    private var store: AgentWindowStore!
    private var persistence: AgentSessionStore!
    private var boardEnabled = true
    private let project = UUID()
    private let otherProject = UUID()

    override func setUp() async throws {
        persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        store = AgentWindowStore(persistence: persistence)
        boardEnabled = true
        store.ticketPlaces.isBoardEnabled = { [unowned self] in boardEnabled }
    }

    private func seed(_ count: Int) throws -> [UUID] {
        try (0 ..< count).map { _ in
            let session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: project, title: "Chat",
                lastActivityAt: Date(timeIntervalSince1970: 1_000), createdManually: true)
            _ = try persistence.upsertSession(session)
            return session.id
        }
    }

    private var window: UUID { store.primaryWindowID }

    func testPlaceOfAWindowShowingTicketsIsTheBoard() {
        let state = AgentChatWindowState(selectedSessionID: UUID(), selectedProjectID: project, showsGrid: false)
        XCTAssertEqual(AgentWindowStore.place(of: state, in: AgentUIState(), ticketsMode: true),
                       .tickets(projectID: project))
        XCTAssertEqual(AgentWindowStore.place(of: state, in: AgentUIState(), ticketsMode: false),
                       .chat(state.selectedSessionID!))
    }

    /// Chat → Board: L2 führt in den Chat. Zurück im Chat führt L2 ins Board.
    func testChatAndBoardAreEachOthersTarget() throws {
        let s = try seed(1)
        store.openTab(s[0], in: window, select: true)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        XCTAssertEqual(store.previousPlace(in: window), .chat(s[0]))

        store.navigateToSession(s[0], in: window)
        XCTAssertFalse(store.isTicketsMode(in: window))
        XCTAssertEqual(store.previousPlace(in: window), .tickets(projectID: project),
                       "derselbe Chat, der hinter den Tickets stand: trotzdem zurück ins Board")

        // Zurück ins Board (wie L2 getippt): Ziel ist wieder der Chat.
        store.setTicketsMode(true, in: window)
        XCTAssertEqual(store.previousPlace(in: window), .chat(s[0]), "hin und zurück, beliebig oft")
        store.navigateToSession(s[0], in: window)
        XCTAssertEqual(store.previousPlace(in: window), .tickets(projectID: project))
    }

    /// Lesen schreibt nicht: Der Verlauf ändert sich beim Abfragen nicht.
    func testReadingThePreviousPlaceDoesNotWrite() throws {
        let s = try seed(1)
        store.openTab(s[0], in: window, select: true)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        store.navigateToSession(s[0], in: window)
        let before = store.placeHistories
        _ = store.previousPlace(in: window)
        _ = store.previousPlace(in: window)
        XCTAssertEqual(store.placeHistories, before)
    }

    /// Aus dem Board in einen anderen Chat: Ziel ist das Board, nicht der Chat,
    /// der hinter den Tickets gewählt war.
    func testLeavingTheBoardForAnotherChatTargetsTheBoard() throws {
        let s = try seed(2)
        store.openTab(s[0], in: window, select: true)
        store.openTab(s[1], in: window, select: false)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)

        store.navigateToSession(s[1], in: window)
        XCTAssertEqual(store.selectedSession(in: window), s[1])
        XCTAssertEqual(store.previousPlace(in: window), .tickets(projectID: project))
    }

    /// Der Knopf in der Titelzone (oder „Zu den Chats“) ist auch ein Ortswechsel.
    func testToggleBackToChatsTargetsTheBoard() throws {
        let s = try seed(1)
        store.openTab(s[0], in: window, select: true)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        store.setTicketsMode(false, in: window)
        XCTAssertEqual(store.previousPlace(in: window), .tickets(projectID: project))
    }

    /// Ein anderes Board (anderes Projekt) ist ein eigener Ort.
    func testAnotherBoardIsAnotherPlace() throws {
        _ = try seed(1)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        store.setSelectedProject(otherProject, in: window)
        XCTAssertEqual(store.previousPlace(in: window), .tickets(projectID: project))
        XCTAssertEqual(store.lastTicketsProjectID(in: window), otherProject)
    }

    /// Eine Auswahl aus dem Steuerkanal lässt die Tickets stehen und ist kein
    /// Ortswechsel.
    func testSelectionBehindTheTicketsIsNoPlaceChange() throws {
        let s = try seed(2)
        store.openTab(s[0], in: window, select: true)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        store.keepingTicketsMode { store.navigateToSession(s[1], in: window) }
        XCTAssertTrue(store.isTicketsMode(in: window))
        XCTAssertEqual(store.previousPlace(in: window), .chat(s[0]))
    }

    func testBoardIsNoTargetWhileTheTicketViewIsOff() throws {
        let s = try seed(1)
        store.openTab(s[0], in: window, select: true)
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        store.setTicketsMode(false, in: window)
        boardEnabled = false
        XCTAssertNil(store.previousPlace(in: window))
    }

    func testForgettingTheWindowDropsTheLastBoard() {
        store.setSelectedProject(project, in: window)
        store.setTicketsMode(true, in: window)
        XCTAssertEqual(store.lastTicketsProjectID(in: window), project)
        store.forgetTickets(of: window)
        XCTAssertNil(store.lastTicketsProjectID(in: window))
    }
}
