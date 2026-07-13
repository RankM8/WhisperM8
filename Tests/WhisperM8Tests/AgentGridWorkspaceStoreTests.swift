import Foundation
import XCTest
@testable import WhisperM8

/// Store-Ebene der Grid-Workspaces: Entity-CRUD, Aktivierung mit
/// Single-Owner-Politik, Tab-Materialisierung, Fokus-Reparatur und
/// Key-Window-Routing (Testmatrix aus der Robustheits-Spez 14d92786).
/// Alle Slot-/Tab-Sessions sind im Domain-Workspace geseedet — Create/Add
/// validieren dagegen, und der Flush-Prune räumt unbekannte IDs weg.
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

    /// Session im Domain-Workspace anlegen (Create/Add validieren dagegen).
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

    private func seed(_ persistence: AgentSessionStore, count: Int) throws -> [UUID] {
        try (0 ..< count).map { _ in try seedSession(persistence) }
    }

    // MARK: - Entity-CRUD

    func testCreateGridWorkspaceAppendsInSidebarOrder() {
        let (store, _) = makeStore()
        let first = store.createGridWorkspace(name: "Alpha")
        let second = store.createGridWorkspace(name: "Beta")
        XCTAssertEqual(store.gridWorkspaces.map(\.id), [first, second])
    }

    func testCreateGridWorkspaceValidatesSlotsAgainstDomain() throws {
        let (store, persistence) = makeStore()
        let live = try seedSession(persistence)
        let archived = try seedSession(persistence, status: .archived)
        let unknown = UUID()
        let id = store.createGridWorkspace(name: "Validiert", slots: [live, archived, unknown])
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots,
                       [live, nil],
                       "unbekannt/archiviert → nil; leere Tail-Slots kappt die Kapazität")
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

    func testDeleteGridWorkspaceClearsAllWindowReferencesButKeepsTabs() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        store.openTab(s[0], in: w); store.openTab(s[1], in: w)
        let id = store.createGridWorkspace(name: "Weg", slots: [s[0], s[1]], activateIn: w)
        XCTAssertTrue(store.showsGrid(in: w))

        XCTAssertTrue(store.deleteGridWorkspace(id))
        XCTAssertNil(store.gridWorkspace(id: id))
        XCTAssertNil(store.window(for: w).activeWorkspaceID)
        XCTAssertFalse(store.showsGrid(in: w))
        XCTAssertEqual(store.openTabIDs(in: w), [s[0], s[1]], "Tabs bleiben unangetastet")
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

    func testActivateMaterializesMissingTabsInSlotOrder() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let existing = try seedSession(persistence)
        store.openTab(existing, in: w)
        let s = try seed(persistence, count: 2)
        let id = store.createGridWorkspace(name: "G", slots: [s[0], s[1]])

        XCTAssertEqual(store.activateGridWorkspace(id, in: w), .activated)
        XCTAssertEqual(store.openTabIDs(in: w), [existing, s[0], s[1]],
                       "bestehender Prefix bleibt, Slots hinten in Slot-Reihenfolge")
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[0], "Fokus auf ersten belegten Slot")
    }

    func testWorkspaceSwitchKeepsTabsFromPreviousWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        _ = store.createGridWorkspace(name: "A", slots: [s[0], s[1]], activateIn: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [s[2]])

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.openTabIDs(in: w), [s[0], s[1], s[2]], "A-Tabs bleiben offen")
        XCTAssertEqual(store.window(for: w).activeWorkspaceID, wsB)
        XCTAssertEqual(store.selectedSession(in: w), s[2])
    }

    func testActivateRetainsFocusedSessionWhenItIsInTargetSlots() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let shared = try seedSession(persistence)
        let other = try seedSession(persistence)
        _ = store.createGridWorkspace(name: "A", slots: [other, shared], activateIn: w)
        store.setGridFocusedSession(shared, in: w)
        let wsB = store.createGridWorkspace(name: "B", slots: [shared])

        XCTAssertEqual(store.activateGridWorkspace(wsB, in: w), .activated)
        XCTAssertEqual(store.selectedSession(in: w), shared, "gemeinsamer Fokus bleibt")
    }

    func testSameVisibleWorkspaceSecondWindowReturnsExistingOwner() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let tab = try seedSession(persistence)
        store.openTab(tab, in: primary)
        let second = store.detachToNewWindow(tab, from: primary)
        let anchor = try seedSession(persistence)
        store.openTab(anchor, in: primary)
        let id = store.createGridWorkspace(name: "Exklusiv", activateIn: primary)
        XCTAssertTrue(store.showsGrid(in: primary), "Owner zeigt das Grid")

        let before = (store.window(for: primary), store.window(for: second))
        XCTAssertEqual(
            store.activateGridWorkspace(id, in: second),
            .alreadyActive(ownerWindowID: primary)
        )
        XCTAssertEqual(store.window(for: primary), before.0, "keinerlei Mutation")
        XCTAssertEqual(store.window(for: second), before.1)
    }

    func testHiddenReferenceSecondWindowReturnsExistingOwnerWithoutMutation() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let tab = try seedSession(persistence)
        store.openTab(tab, in: primary)
        let second = store.detachToNewWindow(tab, from: primary)
        let id = store.createGridWorkspace(name: "Versteckt", activateIn: primary)
        // Owner verbirgt das Grid (nur Rücksprung-Referenz) …
        store.showSingleSession(try seedSession(persistence), in: primary)
        XCTAssertFalse(store.showsGrid(in: primary))

        // … Entscheidung A strikt: AUCH die verborgene Referenz zählt als
        // Besitz — kein stilles Übernehmen, keinerlei Mutation (das
        // Besitzerfenster wird über seine Fenster-ID fokussiert).
        let before = (store.window(for: primary), store.window(for: second))
        XCTAssertEqual(
            store.activateGridWorkspace(id, in: second),
            .alreadyActive(ownerWindowID: primary)
        )
        XCTAssertEqual(store.window(for: primary), before.0)
        XCTAssertEqual(store.window(for: second), before.1)
        XCTAssertEqual(store.window(for: primary).activeWorkspaceID, id,
                       "Rücksprungziel des Besitzers bleibt intakt")
    }

    func testDisjointWorkspacesCanBeActiveInDifferentWindows() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let tab = try seedSession(persistence)
        store.openTab(tab, in: primary)
        let second = store.detachToNewWindow(tab, from: primary)
        let wsA = store.createGridWorkspace(name: "A", slots: [try seedSession(persistence)])
        let wsB = store.createGridWorkspace(name: "B", slots: [try seedSession(persistence)])

        XCTAssertEqual(store.activateGridWorkspace(wsA, in: primary), .activated)
        XCTAssertEqual(store.activateGridWorkspace(wsB, in: second), .activated)
        XCTAssertTrue(store.showsGrid(in: primary))
        XCTAssertTrue(store.showsGrid(in: second))
    }

    func testActivationBlockedWhenSlotSessionBelongsToOtherWindow() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let hostage = try seedSession(persistence)
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

    func testReactivationWithForeignTabIsBlockedToo() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        store.openTab(s[0], in: primary)
        let id = store.createGridWorkspace(name: "G", slots: [s[0], s[1]], activateIn: primary)
        // Slot-Chat wandert als Tab in ein zweites Fenster …
        let second = store.detachToNewWindow(s[1], from: primary)
        store.showSingleSession(s[0], in: primary)

        // … der idempotente Re-Aktivierungs-Pfad darf ihn NICHT
        // zurückstehlen (Review-Blocker: alreadyActiveHere ohne Prüfung).
        XCTAssertEqual(
            store.activateGridWorkspace(id, in: primary),
            .blockedByWindowOwnership([s[1]: second])
        )
        XCTAssertFalse(store.showsGrid(in: primary))
    }

    func testActivateIsIdempotentForOwnerWindow() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seedSession(persistence)
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

    func testAddSessionWithForeignTabAddsMembershipWithoutStealing() throws {
        let (store, persistence) = makeStore()
        let primary = store.primaryWindowID
        let session = try seedSession(persistence)
        store.openTab(session, in: primary)
        let second = store.detachToNewWindow(session, from: primary) // Tab lebt in W2
        let anchor = try seedSession(persistence)
        store.openTab(anchor, in: primary)
        let id = store.createGridWorkspace(name: "G", activateIn: primary)
        let focusBefore = store.selectedSession(in: primary)

        // Mitgliedschaft wird aufgenommen (Render-Guard zeigt im Owner den
        // Übernahme-Platzhalter) — aber weder Tab noch Fokus werden
        // angefasst (kein Terminal-Stehlen).
        XCTAssertEqual(
            store.addSession(session, toGridWorkspace: id),
            .added(slotIndex: 0, grewTo: nil)
        )
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots.first ?? nil, session)
        XCTAssertTrue(store.openTabIDs(in: second).contains(session), "Tab bleibt in W2")
        XCTAssertFalse(store.openTabIDs(in: primary).contains(session), "kein Tab im Owner")
        XCTAssertEqual(store.selectedSession(in: primary), focusBefore, "Fokus unverändert")
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

    func testShowSingleExternalSessionPreservesWorkspaceSlotsAndReference() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s1 = try seedSession(persistence)
        let external = try seedSession(persistence)
        let id = store.createGridWorkspace(name: "G", slots: [s1], activateIn: w)
        let entityBefore = store.gridWorkspace(id: id)

        store.showSingleSession(external, in: w)
        XCTAssertFalse(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), external)
        XCTAssertEqual(store.window(for: w).activeWorkspaceID, id, "Referenz bleibt")
        XCTAssertEqual(store.gridWorkspace(id: id), entityBefore, "Slots unverändert")
    }

    func testReturnToWorkspaceRestoresExactPaneFocus() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let external = try seedSession(persistence)
        _ = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)
        // Pane 2 fokussieren, dann in die Einzelansicht wechseln …
        store.setGridFocusedSession(s[1], in: w)
        store.showSingleSession(external, in: w)

        // … „Zurück" stellt EXAKT diese Pane wieder her (nicht Slot 1).
        XCTAssertEqual(store.returnToActiveGrid(in: w), .alreadyActiveHere)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[1],
                       "gemerkter Pane-Fokus überlebt die Einzelansicht")
    }

    func testSetGridFocusedSessionAcceptsOnlyOccupiedSlots() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        let external = try seedSession(persistence)
        store.openTab(external, in: w)
        _ = store.createGridWorkspace(name: "G", slots: [s[0], s[1]], activateIn: w)

        store.setGridFocusedSession(s[1], in: w)
        XCTAssertEqual(store.selectedSession(in: w), s[1])
        store.setGridFocusedSession(external, in: w)
        XCTAssertEqual(store.selectedSession(in: w), s[1], "Nicht-Slot wird ignoriert")
    }

    func testRemoveFocusedSessionFallsBackToNextOccupiedSlot() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)
        store.setGridFocusedSession(s[1], in: w)

        XCTAssertTrue(store.removeSession(s[1], fromGridWorkspace: id))
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], nil, s[2]])
        XCTAssertEqual(store.selectedSession(in: w), s[2], "nächster belegter Slot")
        XCTAssertTrue(store.openTabIDs(in: w).contains(s[1]), "Tab bleibt offen")
    }

    func testRemoveLastSessionLeavesEmptyWorkspaceWithNilFocusFallback() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let only = try seedSession(persistence)
        let id = store.createGridWorkspace(name: "G", slots: [only], activateIn: w)

        XCTAssertTrue(store.removeSession(only, fromGridWorkspace: id))
        XCTAssertEqual(store.gridWorkspace(id: id)?.capacity, 2, "Workspace bleibt als 0/N")
        XCTAssertEqual(store.gridWorkspace(id: id)?.occupiedSessionIDs, [])
    }

    // MARK: - Kapazität (Store-Ebene)

    func testSetCapacityShrinkRequiresConfirmationAndRepairsFocus() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let ids = try seed(persistence, count: 4)
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
        // Deterministischer Fallback vom ALTEN Fokus (Slot 4) aus: nächster/
        // vorheriger belegter Slot innerhalb der neuen Kapazität → Slot 2.
        XCTAssertEqual(store.selectedSession(in: w), ids[1], "Fokus repariert (next/prev)")
    }

    // MARK: - Key-Window-/Dictation-Routing

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

    func testDictationWindowSurvivesResignButNotClose() {
        let (store, _) = makeStore()
        let w1 = UUID(); let w2 = UUID()
        store.windowDidBecomeKey(w1)
        store.windowDidResignKey(w1)
        XCTAssertEqual(store.dictationWindowID, w1,
                       "App-Wechsel (resign) behält das Dictation-Ziel")
        store.windowDidBecomeKey(w2)
        XCTAssertEqual(store.dictationWindowID, w2, "neues Key-Fenster übernimmt")
        store.windowDidCloseForDictation(w2)
        XCTAssertNil(store.dictationWindowID)
        store.windowDidCloseForDictation(w1)
        XCTAssertNil(store.dictationWindowID, "fremdes Close ist ein No-op")
    }

    // MARK: - Persistenz

    func testGridWorkspacesPersistAndReload() throws {
        let wsURL = tempURL("ws"); let uiURL = tempURL("ui")
        let persistence = AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        let store = AgentWindowStore(persistence: persistence)
        let w = store.primaryWindowID
        var session = AgentChatSession(
            id: UUID(), provider: .claude, projectID: UUID(), title: "Chat",
            lastActivityAt: Date(timeIntervalSince1970: 1_000), createdManually: true
        )
        session.status = .closed
        _ = try persistence.upsertSession(session)
        store.openTab(session.id, in: w)
        let id = store.createGridWorkspace(name: "Persistiert", slots: [session.id], activateIn: w)
        store.flush()

        let reloaded = AgentWindowStore(
            persistence: AgentSessionStore(fileURL: wsURL, uiStateFileURL: uiURL)
        )
        XCTAssertEqual(reloaded.gridWorkspaces.map(\.id), [id])
        XCTAssertEqual(reloaded.gridWorkspace(id: id)?.name, "Persistiert")
        XCTAssertEqual(reloaded.gridWorkspace(id: id)?.slots.first ?? nil, session.id)
        XCTAssertEqual(reloaded.window(for: w).activeWorkspaceID, id)
    }

    func testFlushPrunesStaleReferencesAgainstDomain() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let live = try seedSession(persistence)
        store.openTab(live, in: w)
        // Stale Tab (Session existiert nicht) landet über den rohen
        // Tab-Pfad im State …
        store.openTab(UUID(), in: w)
        // … der Flush reconciled gegen den Domain-Workspace.
        store.flush()
        XCTAssertEqual(store.openTabIDs(in: w), [live])
    }
}
