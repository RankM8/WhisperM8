import Foundation
import XCTest
@testable import WhisperM8

/// Tab-Position für ⇧⌘T / `chats reopen` (E2E-Befund 12.11.2026): Der Tab
/// kommt an seine alte Stelle in der Tab-Leiste zurück, nicht ans Ende.
@MainActor
final class ClosedTabPositionTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testSingleCloseRecordsLeftNeighbourAndIndex() {
        let positions = ClosedTabPosition.positions(of: [c], in: [a, b, c, d])
        XCTAssertEqual(positions[c], ClosedTabPosition(index: 2, previousTabID: b))
        XCTAssertEqual(positions[c]?.insertionIndex(in: [a, b, d]), 2)
    }

    func testFirstTabGoesBackToTheFront() {
        let position = ClosedTabPosition.positions(of: [a], in: [a, b, c])[a]
        XCTAssertEqual(position?.insertionIndex(in: [b, c]), 0)
    }

    /// Sammel-Schließen B+C, dann LIFO C, B → wieder A, B, C, D.
    func testBulkCloseReopenedInReverseRestoresOrder() {
        let positions = ClosedTabPosition.positions(of: [b, c], in: [a, b, c, d])
        var tabs = [a, d]
        tabs.insert(c, at: positions[c]!.insertionIndex(in: tabs))
        tabs.insert(b, at: positions[b]!.insertionIndex(in: tabs))
        XCTAssertEqual(tabs, [a, b, c, d])
    }

    /// Linker Nachbar inzwischen zu: alter Index, geklemmt.
    func testMissingAnchorFallsBackToClampedIndex() {
        let position = ClosedTabPosition(index: 3, previousTabID: UUID())
        XCTAssertEqual(position.insertionIndex(in: [a, b, c, d, UUID()]), 3)
        XCTAssertEqual(position.insertionIndex(in: [a]), 1)
    }

    // MARK: - Store

    private func makeStore() -> (store: AgentWindowStore, persistence: AgentSessionStore) {
        let dir = FileManager.default.temporaryDirectory
        let persistence = AgentSessionStore(
            fileURL: dir.appendingPathComponent("wm8-tabpos-ws-\(UUID().uuidString).json"),
            uiStateFileURL: dir.appendingPathComponent("wm8-tabpos-ui-\(UUID().uuidString).json")
        )
        return (AgentWindowStore(persistence: persistence), persistence)
    }

    private func seed(_ persistence: AgentSessionStore, count: Int) throws -> [UUID] {
        try (0 ..< count).map { _ in
            let session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: UUID(), title: "Chat",
                lastActivityAt: Date(timeIntervalSince1970: 1_000), createdManually: true
            )
            _ = try persistence.upsertSession(session)
            return session.id
        }
    }

    func testReopenPutsTabBackAtItsOldPlaceAndSelectsIt() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        s.forEach { store.openTab($0, in: w) }

        store.closeTab(s[1], in: w)
        XCTAssertEqual(store.reopenLastClosedTab()?.sessionID, s[1])
        XCTAssertEqual(store.openTabIDs(in: w), s)
        XCTAssertEqual(store.selectedSession(in: w), s[1])
    }

    func testReopenAfterBridgeCloseRestoresOrder() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        s.forEach { store.openTab($0, in: w) }

        store.setOpenTabIDs([s[0], s[3]], in: w)
        store.reopenLastClosedTab()
        store.reopenLastClosedTab()
        XCTAssertEqual(store.openTabIDs(in: w), s)
    }

    /// Tab und Kachel kommen beide an die alte Stelle (grid.md).
    func testReopenRestoresTabAndWorkspacePlace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)
        XCTAssertEqual(store.openTabIDs(in: w), s)

        store.closeTab(s[0], in: w)
        store.reopenLastClosedTab()
        XCTAssertEqual(store.openTabIDs(in: w), s)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], s[1], s[2]])
    }
}
