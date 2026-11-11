import Foundation
import XCTest
@testable import WhisperM8

/// Klick (oder Kreuz am Controller) auf eine Chat-Zeile im WORKSPACES-Abschnitt
/// (`AgentWindowStore.navigateToWorkspaceChat`, Controller Runde 3): Die Zeile
/// gehört zu genau einem Workspace. Ist er nicht sichtbar, wechselt das
/// Fenster hinein — sonst bliebe die alte Workspace-Referenz stehen, und
/// „Zurück zum Workspace“ führte in den falschen Workspace.
@MainActor
final class AgentGridWorkspaceChatClickTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-wschatclick-\(prefix)-\(UUID().uuidString).json")
    }

    private func makeStore() -> (store: AgentWindowStore, persistence: AgentSessionStore) {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        return (AgentWindowStore(persistence: persistence), persistence)
    }

    private func seed(_ persistence: AgentSessionStore, count: Int) throws -> [UUID] {
        try (0 ..< count).map { _ in
            let session = AgentChatSession(
                id: UUID(),
                provider: .claude,
                projectID: UUID(),
                title: "Chat",
                lastActivityAt: Date(timeIntervalSince1970: 1_000),
                createdManually: true
            )
            _ = try persistence.upsertSession(session)
            return session.id
        }
    }

    /// Der Fall aus dem Handtest: Fenster zeigt Workspace A, Klick auf einen
    /// Chat unter Workspace B → Grid von B mit genau diesem Chat als Fokus;
    /// L3 aus der Einzelansicht führt danach zurück nach B.
    func testChatOfOtherWorkspaceSwitchesWindowIntoThatWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[2], s[3]])

        XCTAssertEqual(store.navigateToWorkspaceChat(s[3], workspaceID: wsB, in: w), .activated)
        XCTAssertEqual(store.window(for: w).activeWorkspaceID, wsB)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[3], "genau dieser Chat hat den Pane-Fokus")
        XCTAssertNotEqual(store.window(for: w).activeWorkspaceID, wsA)

        // Kachel groß (L3), dann zurück (L3): wieder B mit demselben Chat.
        store.showSingleSession(s[3], in: w)
        XCTAssertEqual(store.returnToActiveGrid(in: w), .alreadyActiveHere)
        XCTAssertEqual(store.window(for: w).activeWorkspaceID, wsB)
        XCTAssertEqual(store.selectedSession(in: w), s[3])
    }

    /// Workspace sichtbar: wie bisher nur der Pane-Fokus, keine Aktivierung.
    func testChatOfVisibleWorkspaceOnlyMovesPaneFocus() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        let ws = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        let tabsBefore = store.openTabIDs(in: w)

        XCTAssertEqual(store.navigateToWorkspaceChat(s[1], workspaceID: ws, in: w), .alreadyActiveHere)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[1])
        XCTAssertEqual(store.openTabIDs(in: w), tabsBefore)
    }

    /// Einzelansicht mit diesem Workspace als Rücksprungziel: Der Klick auf
    /// eine seiner Zeilen zeigt das Grid wieder, mit dem Chat als Fokus.
    func testHiddenReferenceShowsGridAgainWithClickedChat() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let ws = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        store.showSingleSession(s[2], in: w)
        XCTAssertFalse(store.showsGrid(in: w))

        XCTAssertEqual(store.navigateToWorkspaceChat(s[1], workspaceID: ws, in: w), .alreadyActiveHere)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[1])
    }

    /// Ein anderes Fenster besitzt den Workspace: nichts mutieren, der
    /// Aufrufer holt das Besitzerfenster nach vorn.
    func testWorkspaceOwnedByOtherWindowMutatesNothing() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        store.openTab(s[2], in: primary)
        let second = store.detachToNewWindow(s[2], from: primary)
        let ws = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: primary)

        let before = (store.window(for: primary), store.window(for: second))
        XCTAssertEqual(store.navigateToWorkspaceChat(s[1], workspaceID: ws, in: second),
                       .alreadyActive(ownerWindowID: primary))
        XCTAssertEqual(store.window(for: primary), before.0)
        XCTAssertEqual(store.window(for: second), before.1)
    }

    /// Veraltete Zeile: Chat liegt nicht (mehr) im Workspace → abgelehnt,
    /// ohne Mutation (die Ansicht fällt auf die normale Klickregel zurück).
    func testChatNotInWorkspaceIsRejected() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        _ = store.createGridWorkspace(name: "A", slots: [s[0]], activateIn: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[1]])
        let before = store.window(for: w)

        XCTAssertEqual(store.navigateToWorkspaceChat(s[2], workspaceID: wsB, in: w), .rejected)
        XCTAssertEqual(store.navigateToWorkspaceChat(s[1], workspaceID: UUID(), in: w), .rejected)
        XCTAssertEqual(store.window(for: w), before)
    }
}
