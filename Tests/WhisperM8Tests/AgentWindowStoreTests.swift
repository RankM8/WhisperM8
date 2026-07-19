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

    func testWindowIDContainingTabFindsPrimaryAndSecondary() {
        let store = makeStore()
        let primary = store.primaryWindowID
        let inPrimary = UUID()
        let inSecondary = UUID()
        let unknown = UUID()
        store.openTab(inPrimary, in: primary)
        store.openTab(inSecondary, in: primary)
        // Sekundaerfenster entstehen ausschliesslich per Tear-off.
        let secondary = store.detachToNewWindow(inSecondary, from: primary)

        XCTAssertEqual(store.windowID(containingTab: inPrimary), primary)
        XCTAssertEqual(store.windowID(containingTab: inSecondary), secondary)
        XCTAssertNil(store.windowID(containingTab: unknown), "unbekannte Session gehoert keinem Fenster")
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

    // MARK: - closeTabInHostingWindow (CLI-`chats close`-Kern)

    func testCloseTabInHostingWindowFindsPrimaryAndSecondary() {
        let store = makeStore()
        let primary = store.primaryWindowID
        let inPrimary = UUID(); let inSecondary = UUID()
        store.openTab(inPrimary, in: primary)
        store.openTab(inSecondary, in: primary)
        let secondary = store.detachToNewWindow(inSecondary, from: primary)

        XCTAssertEqual(store.closeTabInHostingWindow(inSecondary), secondary)
        XCTAssertTrue(store.openTabIDs(in: secondary).isEmpty)
        XCTAssertEqual(store.closeTabInHostingWindow(inPrimary), primary)
        XCTAssertTrue(store.openTabIDs(in: primary).isEmpty)
    }

    func testCloseTabInHostingWindowIsIdempotentForClosedTabs() {
        let store = makeStore()
        let s = UUID()
        XCTAssertNil(store.closeTabInHostingWindow(s), "nie offener Tab → nil, kein Fehler")
        store.openTab(s, in: store.primaryWindowID)
        XCTAssertNotNil(store.closeTabInHostingWindow(s))
        XCTAssertNil(store.closeTabInHostingWindow(s), "zweiter Close ist ein No-op")
    }

    func testCloseTabInHostingWindowRepairsSelectionAndMultiSelection() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID(); let c = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w); store.openTab(c, in: w)
        store.selectTab(b, in: w)
        store.setMultiSelection([a, b], in: w)

        store.closeTabInHostingWindow(b)
        XCTAssertEqual(store.selectedSession(in: w), a, "Selektion rueckt auf den vorherigen Tab")
        XCTAssertEqual(store.multiSelection(in: w), [a], "geschlossener Tab verlaesst die Multi-Auswahl")

        store.closeTabInHostingWindow(a)
        XCTAssertTrue(store.multiSelection(in: w).isEmpty, "leere Auswahl wird aufgeraeumt")
    }

    /// Der zentrale Unterschied zu archive/stop: Close fasst ausschliesslich
    /// den UI-State an — Session-Status im Workspace und Pin bleiben.
    func testCloseTabInHostingWindowTouchesOnlyUIState() throws {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        let store = AgentWindowStore(persistence: persistence)
        let project = try persistence.upsertProject(path: "/tmp/close-test", name: "close-test")
        let session = try persistence.upsertSession(AgentChatSession(
            id: UUID(), provider: .claude, projectID: project.id, title: "Opfer",
            status: .running, groupName: nil, lastActivityAt: Date(),
            titleIsAutoGenerated: nil, lastTurnAt: nil, kind: nil))

        store.openTab(session.id, in: store.primaryWindowID)
        store.togglePin(session.id)
        XCTAssertNotNil(store.closeTabInHostingWindow(session.id))

        let reloaded = persistence.loadWorkspace().sessions.first { $0.id == session.id }
        XCTAssertEqual(reloaded?.status, .running, "Close archiviert/stoppt die Session NICHT")
        XCTAssertTrue(store.pinnedSessionIDs.contains(session.id), "Pin ueberlebt den Tab-Close")
        XCTAssertTrue(store.openTabIDs(in: store.primaryWindowID).isEmpty)
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

    // MARK: - Fenster-Lifecycle (Close-Tracking)

    func testRemoveWindowRemovesSecondaryWithTabs() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w)
        let newW = store.detachToNewWindow(b, from: w)

        XCTAssertTrue(store.removeWindow(newW), "Sekundaerfenster MIT Tabs wird entfernt")
        XCTAssertNil(store.state.windows.first { $0.id == newW })
        XCTAssertEqual(store.openTabIDs(in: w), [a], "Primaerfenster bleibt unberuehrt")
    }

    func testRemoveWindowProtectsPrimaryAndUnknownIDs() {
        let store = makeStore()
        let a = UUID()
        store.openTab(a, in: store.primaryWindowID)
        XCTAssertFalse(store.removeWindow(store.primaryWindowID), "Primaerfenster ist geschuetzt")
        XCTAssertEqual(store.openTabIDs(in: store.primaryWindowID), [a])
        XCTAssertFalse(store.removeWindow(UUID()), "unbekannte ID ist ein No-op")
    }

    func testHandleWindowWillCloseRemovesSecondaryWindow() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID()
        store.openTab(a, in: w)
        let newW = store.detachToNewWindow(a, from: w)
        store.handleWindowWillClose(newW)
        XCTAssertNil(store.state.windows.first { $0.id == newW },
                     "User-Close raeumt Fenster + Tabs aus dem State")
    }

    func testHandleWindowWillCloseKeepsPrimary() {
        let store = makeStore()
        let a = UUID()
        store.openTab(a, in: store.primaryWindowID)
        store.handleWindowWillClose(store.primaryWindowID)
        XCTAssertEqual(store.openTabIDs(in: store.primaryWindowID), [a],
                       "Primaer-Close laesst die Tabs fuer den Dock-Reopen stehen")
    }

    func testSuspendedCloseTrackingKeepsWindowForRestore() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID()
        store.openTab(a, in: w)
        let newW = store.detachToNewWindow(a, from: w)

        store.suspendCloseTracking()
        store.handleWindowWillClose(newW)
        XCTAssertNotNil(store.state.windows.first { $0.id == newW },
                        "Quit-/Profilwechsel-Close entfernt nichts — der Launch-Restore braucht den Eintrag")

        store.resumeCloseTracking()
        store.handleWindowWillClose(newW)
        XCTAssertNil(store.state.windows.first { $0.id == newW },
                     "nach Resume zaehlt ein Close wieder als User-Aktion")
    }

    /// Kern-Repro des Doppelfenster-Bugs: X-Close → Quit → Relaunch darf das
    /// geschlossene Fenster NICHT wiederherstellen.
    func testRemovedWindowDoesNotSurviveReload() throws {
        let uiURL = tempURL("ui")
        let wsURL = tempURL("ws")
        let pid = UUID(); let a = UUID(); let b = UUID()
        let persistence = AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        var sessionA = AgentChatSession(
            id: a, provider: .claude, projectID: pid, title: "A",
            lastActivityAt: Date(timeIntervalSince1970: 1), createdManually: true
        )
        sessionA.status = .closed
        var sessionB = AgentChatSession(
            id: b, provider: .claude, projectID: pid, title: "B",
            lastActivityAt: Date(timeIntervalSince1970: 2), createdManually: true
        )
        sessionB.status = .closed
        try persistence.saveWorkspace(
            AgentWorkspace(
                projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
                sessions: [sessionA, sessionB]
            )
        )

        let store = AgentWindowStore(persistence: persistence)
        store.openTab(a, in: store.primaryWindowID)
        store.openTab(b, in: store.primaryWindowID)
        let newW = store.detachToNewWindow(b, from: store.primaryWindowID)
        store.handleWindowWillClose(newW) // User schliesst das Sekundaerfenster
        store.flush()

        let reloaded = AgentWindowStore(
            persistence: AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        )
        XCTAssertTrue(reloaded.secondaryWindowIDs.isEmpty,
                      "per X geschlossenes Fenster wird beim Launch NICHT wiederhergestellt")
        XCTAssertEqual(reloaded.openTabIDs(in: reloaded.primaryWindowID), [a],
                       "Primaer-Tabs ueberleben; die Tabs des geschlossenen Fensters sind zu")
    }

    // MARK: - Kein Create-on-mutate

    func testMutationsOnUnknownWindowAreNoOps() {
        let store = makeStore()
        let ghost = UUID()
        store.openTab(UUID(), in: ghost)
        store.setSelectedProject(UUID(), in: ghost)
        store.setOpenTabIDs([UUID()], in: ghost)
        XCTAssertFalse(store.hasWindow(ghost),
                       "Nachzuegler-Mutationen wiederbeleben kein entferntes/unbekanntes Fenster")
        XCTAssertEqual(store.state.windows.count, 1, "nur das Primaerfenster existiert")
    }

    func testMoveTabToUnknownTargetIsNoOp() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID()
        store.openTab(a, in: w)
        store.moveTab(a, from: w, to: UUID(), before: nil)
        XCTAssertEqual(store.openTabIDs(in: w), [a], "kein Tab-Verlust in ein Geisterfenster")
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

    // MARK: - Diff-Gate (C14): No-op-Mutationen publizieren und speichern nicht

    func testNoOpMutationsDoNotDirtyStore() {
        let store = makeStore()
        let w = store.primaryWindowID
        let s = UUID()
        store.openTab(s, in: w)
        let revision = store.dirtyRevision

        // Identische Wiederholungen der typischen Hot-Caller: alles No-ops.
        store.openTab(s, in: w)
        store.selectTab(s, in: w)
        store.setSelectedSession(s, in: w)
        store.setOpenTabIDs([s], in: w)
        store.reorderTab(s, before: nil, in: w)
        store.setSelectedProject(nil, in: w)

        XCTAssertEqual(store.dirtyRevision, revision,
                       "No-op-Mutationen duerfen weder Revision noch Save ausloesen")
    }

    func testRealMutationBumpsRevisionExactlyOnce() {
        let store = makeStore()
        let w = store.primaryWindowID
        let a = UUID(), b = UUID()
        store.openTab(a, in: w)
        let revision = store.dirtyRevision

        store.openTab(b, in: w)
        XCTAssertEqual(store.dirtyRevision, revision + 1,
                       "echte Aenderung erhoeht die Revision genau einmal")

        store.selectTab(a, in: w)
        XCTAssertEqual(store.dirtyRevision, revision + 2,
                       "Selektionswechsel ist eine echte Aenderung")
    }

    func testNoOpGridWorkspaceMutationDoesNotDirtyStore() {
        let store = makeStore()
        let id = store.createGridWorkspace(name: "Test")
        guard let fractions = store.gridWorkspace(id: id)?.columnFractions else {
            XCTFail("frisch angelegter Workspace muss auffindbar sein")
            return
        }
        let revision = store.dirtyRevision

        // Kein Caller-Guard auf diesem Pfad — prueft das zentrale Gate in
        // `mutate` fuer identische Werte.
        store.setGridColumnFractions(ofGridWorkspace: id, fractions)

        XCTAssertEqual(store.dirtyRevision, revision,
                       "identische Fractions sind ein No-op ohne Revision/Save")
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
