import Foundation
import XCTest
@testable import WhisperM8

/// Ticket-Ansicht je Fenster: Umschalten, und zurück zu den Chats, sobald
/// zu einem Chat navigiert wird.
@MainActor
final class AgentWindowStoreTicketsModeTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-\(prefix)-\(UUID().uuidString).json")
    }

    private func makeStore() -> AgentWindowStore {
        AgentWindowStore(persistence: AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui")))
    }

    func testOffByDefaultAndPerWindow() {
        let store = makeStore()
        let first = store.primaryWindowID
        let second = UUID()
        XCTAssertFalse(store.isTicketsMode(in: first))

        store.setTicketsMode(true, in: first)
        XCTAssertTrue(store.isTicketsMode(in: first))
        XCTAssertFalse(store.isTicketsMode(in: second), "ein Fenster schaltet das andere nicht um")

        store.setTicketsMode(false, in: first)
        XCTAssertFalse(store.isTicketsMode(in: first))
    }

    func testNavigatingToAChatReturnsToChats() {
        let store = makeStore()
        let window = store.primaryWindowID
        let chat = UUID()
        store.setTicketsMode(true, in: window)

        store.navigateToSession(chat, in: window)
        XCTAssertFalse(store.isTicketsMode(in: window))
        XCTAssertEqual(store.selectedSession(in: window), chat)
    }

    func testNavigatingToTheSelectedChatAlsoReturnsToChats() {
        let store = makeStore()
        let window = store.primaryWindowID
        let chat = UUID()
        store.navigateToSession(chat, in: window)
        store.setTicketsMode(true, in: window)

        // „Zum Chat“ am Ticket für den Chat, der schon gewählt ist.
        store.navigateToSession(chat, in: window)
        XCTAssertFalse(store.isTicketsMode(in: window))
    }

    func testNavigationInAnotherWindowLeavesTicketsOpen() {
        let store = makeStore()
        let window = store.primaryWindowID
        let other = UUID()
        store.setTicketsMode(true, in: window)
        store.navigateToSession(UUID(), in: other)
        XCTAssertTrue(store.isTicketsMode(in: window))
    }

    func testEverythingThatShowsAChatReturnsToChats() {
        let store = makeStore()
        let window = store.primaryWindowID
        let actions: [(String, (UUID) -> Void)] = [
            ("openTab", { store.openTab($0, in: window) }),
            ("setSelectedSession", { store.setSelectedSession($0, in: window) }),
            ("showSingleSession", { store.showSingleSession($0, in: window) }),
            ("showSingleSessionFollowingGridFocus", { store.showSingleSessionFollowingGridFocus($0, in: window) }),
        ]
        for (name, action) in actions {
            store.setTicketsMode(true, in: window)
            action(UUID())
            XCTAssertFalse(store.isTicketsMode(in: window), name)
        }
    }

    func testOpeningAWorkspaceReturnsToChats() {
        let store = makeStore()
        let window = store.primaryWindowID
        let chats = [UUID(), UUID()]
        let workspace = store.createGridWorkspace(name: "Zwei", slots: chats)
        store.navigateToSession(chats[0], in: window)
        store.setTicketsMode(true, in: window)

        // Der gewählte Chat liegt im Workspace: Die Auswahl bleibt gleich,
        // trotzdem muss der Workspace erscheinen.
        XCTAssertEqual(store.activateGridWorkspace(workspace, in: window), .activated)
        XCTAssertFalse(store.isTicketsMode(in: window))

        store.showSingleSession(chats[0], in: window)
        store.setTicketsMode(true, in: window)
        _ = store.returnToActiveGrid(in: window)
        XCTAssertTrue(store.window(for: window).showsGrid)
        XCTAssertFalse(store.isTicketsMode(in: window))
    }

    func testControlChannelNavigationKeepsTickets() {
        let store = makeStore()
        let window = store.primaryWindowID
        let chats = [UUID(), UUID()]
        let workspace = store.createGridWorkspace(name: "Zwei", slots: chats)
        store.setTicketsMode(true, in: window)

        // `whisperm8 chats focus` und `workspace open`: Die Auswahl wechselt, die Tickets bleiben.
        store.keepingTicketsMode { store.navigateToSession(chats[0], in: window) }
        XCTAssertEqual(store.selectedSession(in: window), chats[0])
        XCTAssertTrue(store.isTicketsMode(in: window))
        _ = store.keepingTicketsMode { store.activateGridWorkspace(workspace, in: window) }
        XCTAssertTrue(store.isTicketsMode(in: window))

        // Danach gilt wieder die normale Regel.
        store.navigateToSession(chats[1], in: window)
        XCTAssertFalse(store.isTicketsMode(in: window))
    }

    func testUserToggleWorksWhileControlChannelHolds() {
        let store = makeStore()
        let window = store.primaryWindowID
        store.setTicketsMode(true, in: window)
        store.keepingTicketsMode { store.setTicketsMode(false, in: window) }
        XCTAssertFalse(store.isTicketsMode(in: window), "der Knopf schaltet immer")
    }

    func testSelectionThatOnlyMovesUpKeepsTickets() {
        let store = makeStore()
        let window = store.primaryWindowID
        let first = UUID(), second = UUID()
        store.openTab(first, in: window)
        store.openTab(second, in: window)
        store.setTicketsMode(true, in: window)

        // Tab im Hintergrund geöffnet, gewählter Tab geschlossen: Die Auswahl
        // rückt nach, niemand wollte einen Chat sehen.
        store.openTab(UUID(), in: window, select: false)
        store.closeTab(second, in: window)
        XCTAssertEqual(store.selectedSession(in: window), first)
        XCTAssertTrue(store.isTicketsMode(in: window))

        store.setSelectedSession(nil, in: window)
        XCTAssertTrue(store.isTicketsMode(in: window))
    }

    func testControllerSnapshotHidesTheChatBehindTickets() {
        let chat = UUID()
        let snapshot = AgentChatsWindowSnapshot(
            windowID: UUID(), isKeyWindow: true, selectedSessionID: chat, isGridActive: true,
            canReturnToWorkspace: true, isSwitcherOpen: false, hasSheet: false, isSidebarVisible: true,
            hasMultiSelection: false, isArchiveMode: false)
        let hidden = snapshot.withChatsHidden()
        // Kein Chat „vor mir“: Enter, Escape und Diktat finden kein Ziel.
        XCTAssertNil(hidden.selectedSessionID)
        XCTAssertFalse(hidden.isGridActive)
        XCTAssertFalse(hidden.canReturnToWorkspace)
        XCTAssertEqual(hidden.windowID, snapshot.windowID)
        XCTAssertTrue(hidden.isSidebarVisible)
    }

    func testTicketsModeIsNotPersisted() {
        let files = (tempURL("ws"), tempURL("ui"))
        let store = AgentWindowStore(persistence: AgentSessionStore(fileURL: files.0, uiStateFileURL: files.1))
        store.setTicketsMode(true, in: store.primaryWindowID)
        store.setOpenTabIDs([UUID()], in: store.primaryWindowID)   // erzwingt ein Schreiben

        let reloaded = AgentWindowStore(persistence: AgentSessionStore(fileURL: files.0, uiStateFileURL: files.1))
        XCTAssertFalse(reloaded.isTicketsMode(in: reloaded.primaryWindowID))
    }
}
