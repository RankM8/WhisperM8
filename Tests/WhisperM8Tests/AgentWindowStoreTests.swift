import Foundation
import XCTest
@testable import WhisperM8

/// Tests fuer die Single-Source-of-Truth des Fenster-/Tab-States. Jeder Test
/// arbeitet auf isolierten Temp-Dateien (eigener Workspace + UI-State), damit
/// die echte App-Persistenz unberuehrt bleibt.
@MainActor
final class AgentWindowStoreTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-\(prefix)-\(UUID().uuidString).json")
    }

    private func makeStore() -> AgentWindowStore {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        return AgentWindowStore(persistence: persistence)
    }

    // MARK: - Tab-Lifecycle

    func testOpenTabAddsAndSelects() {
        let store = makeStore()
        let w = store.primaryWindowID
        let s = UUID()
        store.openTab(s, in: w)
        XCTAssertEqual(store.openTabIDs(in: w), [s])
        XCTAssertEqual(store.selectedSession(in: w), s)
    }

    func testOpenTabIsIdempotent() {
        let store = makeStore()
        let w = store.primaryWindowID
        let s = UUID()
        store.openTab(s, in: w)
        store.openTab(s, in: w)
        XCTAssertEqual(store.openTabIDs(in: w), [s], "kein Duplikat beim erneuten Oeffnen")
    }

    func testCloseTabMovesSelectionToPreviousTab() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID(); let c = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w); store.openTab(c, in: w)
        store.selectTab(b, in: w)
        store.closeTab(b, in: w)
        XCTAssertEqual(store.openTabIDs(in: w), [a, c])
        XCTAssertEqual(store.selectedSession(in: w), a, "Selektion rueckt auf den vorherigen Tab")
    }

    func testCloseLastSelectedTabFallsBackToNeighbor() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w) // b selektiert
        store.closeTab(b, in: w)
        XCTAssertEqual(store.selectedSession(in: w), a)
    }

    func testReorderTabBeforeTarget() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID(); let c = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w); store.openTab(c, in: w)
        store.reorderTab(c, before: a, in: w)
        XCTAssertEqual(store.openTabIDs(in: w), [c, a, b])
    }

    // MARK: - Multi-Window

    func testDetachToNewWindowMovesTabOut() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w)
        let newW = store.detachToNewWindow(b, from: w)
        XCTAssertNotEqual(newW, w)
        XCTAssertEqual(store.openTabIDs(in: w), [a])
        XCTAssertEqual(store.openTabIDs(in: newW), [b])
        XCTAssertEqual(store.selectedSession(in: newW), b)
    }

    func testMoveTabBetweenWindows() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w)
        let newW = store.detachToNewWindow(b, from: w)
        store.moveTab(a, from: w, to: newW, before: b)
        XCTAssertTrue(store.openTabIDs(in: w).isEmpty, "Primaer leer, bleibt aber bestehen")
        XCTAssertEqual(store.openTabIDs(in: newW), [a, b])
    }

    /// Kerninvariante gegen „Chat doppelt in zwei Fenstern".
    func testSameSessionNeverLivesInTwoWindows() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID()
        store.openTab(a, in: w)
        let newW = store.detachToNewWindow(a, from: w) // a -> newW, Primaer leer
        store.openTab(a, in: w)                        // a erneut im Primaer oeffnen
        let allTabs = store.state.windows.flatMap(\.openTabIDs)
        XCTAssertEqual(allTabs.count, Set(allTabs).count, "Session nie in zwei Fenstern gleichzeitig")
        XCTAssertNotNil(store.state.windows.first { $0.id == newW })
    }

    func testRemoveWindowIfEmpty() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID()
        store.openTab(a, in: w)
        let newW = store.detachToNewWindow(a, from: w)
        XCTAssertFalse(store.removeWindowIfEmpty(newW), "nicht-leeres Fenster bleibt")
        store.closeTab(a, in: newW)
        XCTAssertTrue(store.removeWindowIfEmpty(newW), "leeres Sekundaerfenster wird entfernt")
        XCTAssertNil(store.state.windows.first { $0.id == newW })
    }

    func testPrimaryWindowIsNeverRemoved() {
        let store = makeStore()
        let w = store.primaryWindowID
        XCTAssertFalse(store.removeWindowIfEmpty(w), "Primaerfenster bleibt immer bestehen")
        XCTAssertNotNil(store.state.windows.first { $0.id == w })
    }

    // MARK: - Globaler State

    func testTogglePin() {
        let store = makeStore()
        let s = UUID()
        store.togglePin(s)
        XCTAssertTrue(store.pinnedSessionIDs.contains(s))
        store.togglePin(s)
        XCTAssertFalse(store.pinnedSessionIDs.contains(s))
    }

    // MARK: - Persistenz

    func testMutationsPersistAndReload() throws {
        let uiURL = tempURL("ui")
        let wsURL = tempURL("ws")
        // Workspace mit der Session befuellen, damit prune beim Reload den Tab
        // nicht als „tot" entfernt.
        let pid = UUID(); let a = UUID()
        let persistence = AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        var session = AgentChatSession(
            id: a, provider: .claude, projectID: pid, title: "Chat",
            lastActivityAt: Date(timeIntervalSince1970: 1), createdManually: true
        )
        session.status = .closed
        try persistence.saveWorkspace(
            AgentWorkspace(
                projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
                sessions: [session]
            )
        )

        let store = AgentWindowStore(persistence: persistence)
        store.openTab(a, in: store.primaryWindowID)
        store.flush()

        let reloaded = AgentWindowStore(
            persistence: AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        )
        XCTAssertEqual(reloaded.openTabIDs(in: reloaded.primaryWindowID), [a],
                       "Tab ueberlebt Persistenz-Roundtrip")
    }

    // MARK: - Multi-Select (ephemer, pro Fenster)

    func testMultiSelectionIsPerWindowAndClearable() {
        let store = makeStore()
        let w1 = store.primaryWindowID
        let w2 = UUID()
        let a = UUID(), b = UUID()

        XCTAssertTrue(store.multiSelection(in: w1).isEmpty)

        store.setMultiSelection([a, b], in: w1)
        XCTAssertEqual(store.multiSelection(in: w1), [a, b])
        XCTAssertTrue(store.multiSelection(in: w2).isEmpty, "Auswahl ist pro Fenster isoliert")

        store.setMultiSelection([], in: w1)
        XCTAssertTrue(store.multiSelection(in: w1).isEmpty, "leere Menge raeumt den Eintrag auf")
    }

    func testMultiSelectionIsNotPersisted() {
        let wsURL = tempURL("ws")
        let uiURL = tempURL("ui")
        let store = AgentWindowStore(persistence: AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL))
        store.setMultiSelection([UUID(), UUID()], in: store.primaryWindowID)
        store.flush()

        let reloaded = AgentWindowStore(persistence: AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL))
        XCTAssertTrue(reloaded.multiSelection(in: reloaded.primaryWindowID).isEmpty,
                      "Multi-Auswahl ist ephemer und ueberlebt keinen Roundtrip")
    }
}
