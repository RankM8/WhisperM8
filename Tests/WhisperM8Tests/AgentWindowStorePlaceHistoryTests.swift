import Foundation
import XCTest
@testable import WhisperM8

/// L2 getippt im Store: Welche Änderungen sind ein Ortswechsel, und wohin
/// führt „zurück“ (Chat oder Workspace im Raster)?
@MainActor
final class AgentWindowStorePlaceHistoryTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-places-\(prefix)-\(UUID().uuidString).json")
    }

    private func makeStore() -> (store: AgentWindowStore, persistence: AgentSessionStore) {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        return (AgentWindowStore(persistence: persistence), persistence)
    }

    private func seed(_ persistence: AgentSessionStore, count: Int) throws -> [UUID] {
        try (0 ..< count).map { _ in
            let session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: UUID(), title: "Chat",
                lastActivityAt: Date(timeIntervalSince1970: 1_000), createdManually: true)
            _ = try persistence.upsertSession(session)
            return session.id
        }
    }

    /// Kachelwechsel im selben Raster sind kein Ortswechsel; der Wechsel in
    /// einen anderen Workspace schon.
    func testTileFocusInsideGridIsNoPlaceChange() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        store.setGridFocusedSession(s[1], in: w)
        store.setGridFocusedSession(s[0], in: w)
        XCTAssertNil(store.previousPlace(in: w), "nur Kacheln gewechselt")

        let wsB = store.createGridWorkspace(name: "B", slots: [s[2]])
        store.activateGridWorkspace(wsB, in: w)
        XCTAssertEqual(store.previousPlace(in: w), .workspace(wsA))
    }

    /// Vom Raster in einen Chat und zurück: wieder als Raster, auf der Kachel
    /// von vorher. Ein zweites Zurück führt wieder in den Chat.
    func testBackFromChatRestoresGridAndTile() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        store.setGridFocusedSession(s[1], in: w)
        store.openTab(s[2], in: w, select: false)
        store.navigateToSession(s[2], in: w)
        XCTAssertFalse(store.showsGrid(in: w))
        XCTAssertEqual(store.previousPlace(in: w), .workspace(wsA))

        store.activateGridWorkspace(wsA, in: w)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[1], "Kachel von vorher")
        XCTAssertEqual(store.previousPlace(in: w), .chat(s[2]))
    }

    /// Zwischen zwei Rastern hin und her: Die Kachel je Workspace bleibt.
    func testBackBetweenWorkspacesKeepsTilePerWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        store.setGridFocusedSession(s[1], in: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[2], s[3]])
        store.activateGridWorkspace(wsB, in: w)
        store.setGridFocusedSession(s[3], in: w)

        store.activateGridWorkspace(wsA, in: w)
        XCTAssertEqual(store.selectedSession(in: w), s[1])
        XCTAssertEqual(store.previousPlace(in: w), .workspace(wsB))
        store.activateGridWorkspace(wsB, in: w)
        XCTAssertEqual(store.selectedSession(in: w), s[3])
        XCTAssertEqual(store.previousPlace(in: w), .workspace(wsA))
    }

    /// Kachel groß (L3) bleibt der Workspace: kein neues Ziel.
    func testMaximizedTileStaysInWorkspacePlace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        store.openTab(s[2], in: w)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]])
        store.activateGridWorkspace(wsA, in: w)
        XCTAssertEqual(store.previousPlace(in: w), .chat(s[2]))

        store.showSingleSession(s[1], in: w)
        XCTAssertEqual(store.previousPlace(in: w), .chat(s[2]), "Kachel groß ist kein Ortswechsel")
        store.activateGridWorkspace(wsA, in: w)
        XCTAssertEqual(store.previousPlace(in: w), .chat(s[2]))
    }

    /// Ein Chat in zwei Workspaces: Der Wechsel zählt, auch wenn die Auswahl
    /// gleich bleibt.
    func testWorkspaceSwitchWithSameSelectionCounts() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        store.setGridFocusedSession(s[0], in: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[0]])
        store.activateGridWorkspace(wsB, in: w)
        XCTAssertEqual(store.selectedSession(in: w), s[0])
        XCTAssertEqual(store.previousPlace(in: w), .workspace(wsA))
    }

    /// Workspace gelöscht: kein Ziel mehr (L2 vibriert „geht nicht“).
    func testDeletedWorkspaceIsNoTarget() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let wsA = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        store.openTab(s[2], in: w, select: false)
        store.navigateToSession(s[2], in: w)
        XCTAssertEqual(store.previousPlace(in: w), .workspace(wsA))
        store.deleteGridWorkspace(wsA)
        XCTAssertNil(store.previousPlace(in: w))
    }

    /// Voriger Chat geschlossen: kein Ziel. Den aktuellen Chat schließen:
    /// Er wird nicht zum Ziel, „zurück“ bleibt der Ort davor.
    func testClosedChatsAreNoTarget() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        store.openTab(s[0], in: w)
        store.openTab(s[1], in: w)
        XCTAssertEqual(store.previousPlace(in: w), .chat(s[0]))
        store.closeTab(s[0], in: w)
        XCTAssertNil(store.previousPlace(in: w))

        // Tabs jetzt s1, s2, s0. Von s1 nach s0, s0 schließen, die Auswahl
        // rückt auf s2: Zurück führt nach s1, nicht in den geschlossenen s0.
        store.openTab(s[2], in: w)
        store.openTab(s[0], in: w)
        store.navigateToSession(s[1], in: w)
        store.navigateToSession(s[0], in: w)
        store.closeTab(s[0], in: w)
        XCTAssertEqual(store.selectedSession(in: w), s[2])
        XCTAssertEqual(store.previousPlace(in: w), .chat(s[1]), "der geschlossene Chat ist kein Ziel")
    }

    /// Jedes Fenster hat seinen eigenen Verlauf.
    func testHistoryIsPerWindow() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        store.openTab(s[0], in: primary)
        store.openTab(s[1], in: primary)
        let second = store.detachToNewWindow(s[1], from: primary)
        store.openTab(s[2], in: second)
        store.openTab(s[3], in: second)
        XCTAssertEqual(store.previousPlace(in: second), .chat(s[2]))
        XCTAssertNotEqual(store.previousPlace(in: primary), .chat(s[2]))
        XCTAssertNotEqual(store.previousPlace(in: primary), .chat(s[3]))
    }
}
