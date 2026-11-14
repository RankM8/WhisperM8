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

    func testTicketsModeIsNotPersisted() {
        let files = (tempURL("ws"), tempURL("ui"))
        let store = AgentWindowStore(persistence: AgentSessionStore(fileURL: files.0, uiStateFileURL: files.1))
        store.setTicketsMode(true, in: store.primaryWindowID)
        store.setOpenTabIDs([UUID()], in: store.primaryWindowID)   // erzwingt ein Schreiben

        let reloaded = AgentWindowStore(persistence: AgentSessionStore(fileURL: files.0, uiStateFileURL: files.1))
        XCTAssertFalse(reloaded.isTicketsMode(in: reloaded.primaryWindowID))
    }
}
