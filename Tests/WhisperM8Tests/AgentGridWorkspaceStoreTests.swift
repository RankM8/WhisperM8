import Foundation
import XCTest
@testable import WhisperM8

/// Store-Ebene der Grid-Workspaces: Entity-CRUD, Aktivierung mit
/// Single-Owner-Politik, Tab-Materialisierung, Fokus-Reparatur und
/// Key-Window-Routing (Testmatrix aus der Robustheits-Spez 14d92786).
@MainActor
final class AgentGridWorkspaceStoreTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-gridws-\(prefix)-\(UUID().uuidString).json")
    }

    private func makeStore() -> (store: AgentWindowStore, persistence: AgentSessionStore) {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        return (AgentWindowStore(persistence: persistence), persistence)
    }

    /// Session im Domain-Workspace anlegen (addSession validiert dagegen).
    @discardableResult
    private func seedSession(
        _ persistence: AgentSessionStore,
        status: AgentChatStatus = .closed
    ) throws -> UUID {
        var session = AgentChatSession(
            id: UUID(),
            provider: .claude,
            projectID: UUID(),
            title: "Chat",
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            createdManually: true
        )
        session.status = status
        _ = try persistence.upsertSession(session)
        return session.id
    }

    // MARK: - Entity-CRUD

    func testCreateGridWorkspaceAppendsInSidebarOrder() {
        let (store, _) = makeStore()
        let first = store.createGridWorkspace(name: "Alpha")
        let second = store.createGridWorkspace(name: "Beta")
        XCTAssertEqual(store.gridWorkspaces.map(\.id), [first, second])
    }

    func testRenameGridWorkspaceTrimsAndRejectsEmptyName() {
        let (store, _) = makeStore()
        let id = store.createGridWorkspace(name: "Alt")
        XCTAssertTrue(store.renameGridWorkspace(id, to: "  Neu "))
        XCTAssertEqual(store.gridWorkspace(id: id)?.name, "Neu")
        XCTAssertFalse(store.renameGridWorkspace(id, to: "   "), "leer = No-op")
        XCTAssertEqual(store.gridWorkspace(id: id)?.name, "Neu")
        XCTAssertFalse(store.renameGridWorkspace(UUID(), to: "X"), "unbekannt = No-op")
    }

    func testSetColorAcceptsOnlyCanonicalHex() {
        let (store, _) = makeStore()
        let id = store.createGridWorkspace(name: "Farbig")
        XCTAssertTrue(store.setGridWorkspaceColor(id, colorHex: "#a1b2c3"))
        XCTAssertEqual(store.gridWorkspace(id: id)?.colorHex, "#A1B2C3")
        XCTAssertFalse(store.setGridWorkspaceColor(id, colorHex: "blau"))
    }

    func testDeleteGridWorkspaceClearsAllWindowReferencesButKeepsTabs() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w)
        let id = store.createGridWorkspace(name: "Weg", slots: [a, b], activateIn: w)
        XCTAssertTrue(store.showsGrid(in: w))

        XCTAssertTrue(store.deleteGridWorkspace(id))
        XCTAssertNil(store.gridWorkspace(id: id))
        XCTAssertNil(store.window(for: w).activeWorkspaceID)
        XCTAssertFalse(store.showsGrid(in: w))
        XCTAssertEqual(store.openTabIDs(in: w), [a, b], "Tabs bleiben unangetastet")
    }

    func testReorderGridWorkspacesCannotDropOmittedEntities() {
        let (store, _) = makeStore()
        let a = store.createGridWorkspace(name: "A")
        let b = store.createGridWorkspace(name: "B")
        let c = store.createGridWorkspace(name: "C")
        // Stale partielle Liste (nur c, a — b fehlt, plus unbekannte ID).
        store.reorderGridWorkspaces(orderedIDs: [c, UUID(), a])
        XCTAssertEqual(store.gridWorkspaces.map(\.id), [c, a, b],
                       "ausgelassene Entities bleiben stabil hinten")
    }

    // MARK: - Aktivierung (Single-Owner)

    func testActivateMaterializesMissingTabsInSlotOrder() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let existing = UUID()
        store.openTab(existing, in: w)
        let s1 = UUID(); let s2 = UUID()
        let id = store.createGridWorkspace(name: "G", slots: [s1, s2])

        XCTAssertEqual(store.activateGridWorkspace(id, in: w), .activated)
        XCTAssertEqual(store.openTabIDs(in: w), [existing, s1, s2],
                       "bestehender Prefix bleibt, Slots hinten in Slot-Reihenfolge")
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s1, "Fokus auf ersten belegten Slot")
    }

    func testWorkspaceSwitchKeepsTabsFromPreviousWorkspace() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let a1 = UUID(); let a2 = UUID(); let b1 = UUID()
        let wsA = store.createGridWorkspace(name: "A", slots: [a1, a2], activateIn: w)
        _ = wsA
        let wsB = store.createGridWorkspace(name: "B", slots: [b1])

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.openTabIDs(in: w), [a1, a2, b1], "A-Tabs bleiben offen")
        XCTAssertEqual(store.window(for: w).activeWorkspaceID, wsB)
        XCTAssertEqual(store.selectedSession(in: w), b1)
    }

    func testActivateRetainsFocusedSessionWhenItIsInTargetSlots() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let shared = UUID(); let other = UUID()
        let wsA = store.createGridWorkspace(name: "A", slots: [other, shared], activateIn: w)
        _ = wsA
        store.setGridFocusedSession(shared, in: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [shared])

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), shared, "gemeinsamer Fokus bleibt")
    }

    func testSameWorkspaceSecondWindowReturnsExistingOwner() {
        let (store, _) = makeStore()
        let primary = store.primaryWindowID
        let tab = UUID()
        store.openTab(tab, in: primary)
        let second = store.detachToNewWindow(tab, from: primary)
        let id = store.createGridWorkspace(name: "Exklusiv", activateIn: primary)

        let before = (store.window(for: primary), store.window(for: second))
        XCTAssertEqual(
            store.activateGridWorkspace(id, in: second),
            .alreadyActive(ownerWindowID: primary)
        )
        XCTAssertEqual(store.window(for: primary), before.0, "keinerlei Mutation")
        XCTAssertEqual(store.window(for: second), before.1)
    }

    func testDisjointWorkspacesCanBeActiveInDifferentWindows() {
        let (store, _) = makeStore()
        let primary = store.primaryWindowID
        let tab = UUID()
        store.openTab(tab, in: primary)
        let second = store.detachToNewWindow(tab, from: primary)
        let wsA = store.createGridWorkspace(name: "A", slots: [UUID()])
        let wsB = store.createGridWorkspace(name: "B", slots: [UUID()])

        XCTAssertEqual(store.activateGridWorkspace(wsA, in: primary), .activated)
        XCTAssertEqual(store.activateGridWorkspace(wsB, in: second), .activated)
        XCTAssertTrue(store.showsGrid(in: primary))
        XCTAssertTrue(store.showsGrid(in: second))
    }

    func testActivationBlockedWhenSlotSessionBelongsToOtherWindow() {
        let (store, _) = makeStore()
        let primary = store.primaryWindowID
        let hostage = UUID()
        store.openTab(hostage, in: primary)
        let second = store.detachToNewWindow(hostage, from: primary)
        // hostage ist jetzt Tab von `second`; Workspace soll in primary auf.
        let id = store.createGridWorkspace(name: "Blockiert", slots: [hostage])

        XCTAssertEqual(
            store.activateGridWorkspace(id, in: primary),
            .blockedByWindowOwnership([hostage: second]),
            "kein Terminal-Stehlen, keine Teilmutation"
        )
        XCTAssertNil(store.window(for: primary).activeWorkspaceID)
        XCTAssertFalse(store.showsGrid(in: primary))
    }

    func testActivateIsIdempotentForOwnerWindow() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let s = UUID()
        let id = store.createGridWorkspace(name: "Idem", slots: [s], activateIn: w)
        store.showSingleSession(s, in: w) // Grid verbergen, Referenz bleibt
        XCTAssertEqual(store.activateGridWorkspace(id, in: w), .alreadyActiveHere)
        XCTAssertTrue(store.showsGrid(in: w), "wieder sichtbar")
    }

    // MARK: - addSession (Validierung + Owner-Fenster)

    func testAddSessionMaterializesTabAndFocusInOwnerWindow() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let id = store.createGridWorkspace(name: "G", activateIn: w)
        let session = try seedSession(persistence)

        XCTAssertEqual(
            store.addSession(session, toGridWorkspace: id),
            .added(slotIndex: 0, grewTo: nil)
        )
        XCTAssertEqual(store.openTabIDs(in: w), [session], "Tab materialisiert")
        XCTAssertEqual(store.selectedSession(in: w), session, "fokussiert (Grid sichtbar)")
    }

    func testAddSessionRejectsUnknownAndArchived() throws {
        let (store, persistence) = makeStore()
        let id = store.createGridWorkspace(name: "G")
        let archived = try seedSession(persistence, status: .archived)

        XCTAssertEqual(store.addSession(UUID(), toGridWorkspace: id), .rejected)
        XCTAssertEqual(store.addSession(archived, toGridWorkspace: id), .rejected)
        XCTAssertEqual(store.gridWorkspace(id: id)?.occupiedSessionIDs, [])
    }

    func testAddToActiveWorkspaceBlockedByOtherWindowOwnership() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let session = try seedSession(persistence)
        store.openTab(session, in: primary)
        _ = store.detachToNewWindow(session, from: primary) // Tab lebt in W2
        let anchor = UUID()
        store.openTab(anchor, in: primary)
        let id = store.createGridWorkspace(name: "G", activateIn: primary)

        XCTAssertEqual(store.addSession(session, toGridWorkspace: id), .rejected,
                       "Slot-Chat als Tab eines anderen Fensters → kein Stehlen")
        XCTAssertEqual(store.gridWorkspace(id: id)?.occupiedSessionIDs, [])
    }

    func testTargetedReplaceKeepsDisplacedSessionAsTab() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let old = try seedSession(persistence)
        let new = try seedSession(persistence)
        let id = store.createGridWorkspace(name: "G", slots: [old], activateIn: w)

        XCTAssertEqual(
            store.addSession(new, toGridWorkspace: id, at: 0),
            .replaced(slotIndex: 0, displaced: old)
        )
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots[0], new)
        XCTAssertTrue(store.openTabIDs(in: w).contains(old), "ersetzter Chat bleibt Tab")
    }

    // MARK: - Einzelansicht / Rücksprung / Fokus

    func testShowSingleExternalSessionPreservesWorkspaceSlotsAndReference() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let s1 = UUID(); let external = UUID()
        let id = store.createGridWorkspace(name: "G", slots: [s1], activateIn: w)
        let entityBefore = store.gridWorkspace(id: id)

        store.showSingleSession(external, in: w)
        XCTAssertFalse(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), external)
        XCTAssertEqual(store.window(for: w).activeWorkspaceID, id, "Referenz bleibt")
        XCTAssertEqual(store.gridWorkspace(id: id), entityBefore, "Slots unverändert")
    }

    func testReturnToWorkspaceRestoresGridAndSlotFocus() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let s1 = UUID(); let external = UUID()
        let id = store.createGridWorkspace(name: "G", slots: [s1], activateIn: w)
        _ = id
        store.showSingleSession(external, in: w)

        XCTAssertEqual(store.returnToActiveGrid(in: w), .alreadyActiveHere)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s1,
                       "externe Selektion ist kein Slot → erster belegter Slot")
    }

    func testSetGridFocusedSessionAcceptsOnlyOccupiedSlots() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let s1 = UUID(); let s2 = UUID(); let external = UUID()
        store.openTab(external, in: w)
        _ = store.createGridWorkspace(name: "G", slots: [s1, s2], activateIn: w)

        store.setGridFocusedSession(s2, in: w)
        XCTAssertEqual(store.selectedSession(in: w), s2)
        store.setGridFocusedSession(external, in: w)
        XCTAssertEqual(store.selectedSession(in: w), s2, "Nicht-Slot wird ignoriert")
    }

    func testRemoveFocusedSessionFallsBackToNextOccupiedSlot() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()
        let id = store.createGridWorkspace(name: "G", slots: [s1, s2, s3], activateIn: w)
        store.setGridFocusedSession(s2, in: w)

        XCTAssertTrue(store.removeSession(s2, fromGridWorkspace: id))
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s1, nil, s3])
        XCTAssertEqual(store.selectedSession(in: w), s3, "nächster belegter Slot")
        XCTAssertTrue(store.openTabIDs(in: w).contains(s2), "Tab bleibt offen")
    }

    func testRemoveLastSessionLeavesEmptyWorkspaceWithNilFocusFallback() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let only = UUID()
        let id = store.createGridWorkspace(name: "G", slots: [only], activateIn: w)

        XCTAssertTrue(store.removeSession(only, fromGridWorkspace: id))
        XCTAssertEqual(store.gridWorkspace(id: id)?.capacity, 2, "Workspace bleibt als 0/N")
        XCTAssertEqual(store.gridWorkspace(id: id)?.occupiedSessionIDs, [])
        // Fokus fällt auf nil zurück; normalizedWindows hält die Selektion
        // danach in den offenen Tabs (der Tab von `only` ist noch offen).
    }

    // MARK: - Kapazität (Store-Ebene)

    func testSetCapacityShrinkRequiresConfirmationAndRepairsFocus() {
        let (store, _) = makeStore()
        let w = store.primaryWindowID
        let ids = (0 ..< 4).map { _ in UUID() }
        let id = store.createGridWorkspace(name: "G", slots: ids.map { $0 }, activateIn: w)
        store.setGridFocusedSession(ids[3], in: w)

        XCTAssertEqual(
            store.setCapacity(ofGridWorkspace: id, to: 2),
            .confirmationRequired([ids[2], ids[3]])
        )
        XCTAssertEqual(store.gridWorkspace(id: id)?.capacity, 4, "ohne Bestätigung keine Mutation")

        XCTAssertEqual(
            store.setCapacity(
                ofGridWorkspace: id, to: 2,
                expectedEvictedSessionIDs: [ids[2], ids[3]]
            ),
            .applied
        )
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [ids[0], ids[1]])
        XCTAssertEqual(store.selectedSession(in: w), ids[0], "Fokus repariert")
    }

    // MARK: - Key-Window-Routing

    func testKeyWindowRoutingFollowsBecomeAndGuardedResign() {
        let (store, _) = makeStore()
        let w1 = UUID(); let w2 = UUID()
        store.windowDidBecomeKey(w1)
        XCTAssertEqual(store.keyAgentChatWindowID, w1)
        store.windowDidBecomeKey(w2)
        // Verspätetes resign des ALTEN Fensters darf das neue nicht räumen.
        store.windowDidResignKey(w1)
        XCTAssertEqual(store.keyAgentChatWindowID, w2)
        store.windowDidResignKey(w2)
        XCTAssertNil(store.keyAgentChatWindowID)
    }

    // MARK: - Persistenz

    func testGridWorkspacesPersistAndReload() throws {
        let wsURL = tempURL("ws"); let uiURL = tempURL("ui")
        let persistence = AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        let store = AgentWindowStore(persistence: persistence)
        let w = store.primaryWindowID
        let s = UUID()
        store.openTab(s, in: w)
        let id = store.createGridWorkspace(name: "Persistiert", slots: [s], activateIn: w)
        store.flush()

        let reloaded = AgentWindowStore(
            persistence: AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        )
        XCTAssertEqual(reloaded.gridWorkspaces.map(\.id), [id])
        XCTAssertEqual(reloaded.gridWorkspace(id: id)?.name, "Persistiert")
        XCTAssertEqual(reloaded.window(for: w).activeWorkspaceID, id)
    }
}
