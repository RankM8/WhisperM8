import Foundation
import XCTest
@testable import WhisperM8

/// Wie sich das Raster anpasst, wenn Chats wegfallen oder dazukommen —
/// über alle Wege: Projekt-Ansicht, eigene Workspaces, Archivieren, Tab
/// schließen, Tab in ein anderes Fenster ziehen.
///
/// Die Fälle beschreiben das Verhalten aus Sicht des Users („3 Chats → 2+1"),
/// nicht die Mechanik. Mechanik-Tests stehen in `WorkspaceSlotOpsTests` und
/// `AgentGridWorkspaceStoreTests`.
@MainActor
final class GridLayoutAdaptationTests: XCTestCase {
    private func tempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-gridadapt-\(prefix)-\(UUID().uuidString).json")
    }

    private func makeStore() -> (store: AgentWindowStore, persistence: AgentSessionStore) {
        let persistence = AgentSessionStore(fileURL: tempURL("ws"), uiStateFileURL: tempURL("ui"))
        return (AgentWindowStore(persistence: persistence), persistence)
    }

    /// Sessions mit absteigender Aktivität — die Projekt-Ansicht ordnet neue
    /// Mitglieder nach Sidebar-Reihenfolge, so landet `[0]` in Slot 1.
    private func seed(_ persistence: AgentSessionStore, count: Int) throws -> [UUID] {
        try (0 ..< count).map { index in
            var session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: UUID(), title: "Chat \(index)",
                lastActivityAt: Date(timeIntervalSince1970: Double(1_000 - index)),
                createdManually: true
            )
            session.status = .closed
            _ = try persistence.upsertSession(session)
            return session.id
        }
    }

    private func archive(_ sessionID: UUID, in persistence: AgentSessionStore) throws {
        try persistence.updateSession(id: sessionID) { $0.status = .archived }
    }

    private func openProjectView(
        _ store: AgentWindowStore, active: [UUID], projectID: UUID = UUID()
    ) throws -> (projectID: UUID, entityID: UUID) {
        _ = store.activateProjectGridWorkspace(
            projectID: projectID, name: "P", colorHex: "#3E8E63",
            activeSessionIDs: Set(active), in: store.primaryWindowID
        )
        let entityID = try XCTUnwrap(store.gridWorkspaces.first { $0.sourceProjectID == projectID }?.id)
        return (projectID, entityID)
    }

    // MARK: - Projekt-Ansicht

    /// Heute: Ein Chat aus der Mitte fällt weg — das Loch bleibt, die
    /// Stufe 2×2 auch (das ist der Ärger des Users).
    func testProjectViewChatLeavingFromTheMiddleLeavesHole() throws {
        let (store, persistence) = makeStore()
        let s = try seed(persistence, count: 4)
        let view = try openProjectView(store, active: s)
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.capacity, 4)

        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [
            view.projectID: [s[0], s[2], s[3]]
        ])
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.slots, [s[0], nil, s[2], s[3]])
        XCTAssertEqual(entity.capacity, 4)
    }

    /// Heute: Ein einziger aktiver Chat bekommt 1×2 mit einer leeren Kachel.
    func testProjectViewWithSingleChatUsesTwoSlotStage() throws {
        let (store, persistence) = makeStore()
        let s = try seed(persistence, count: 1)
        let view = try openProjectView(store, active: s)
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.capacity, 2)
        XCTAssertEqual(entity.slots, [s[0], nil])
    }

    /// Heute: Tab eines laufenden Chats zu — er bleibt aktiv (läuft) und
    /// damit Mitglied; die Kachel wird zum Platzhalter „Tab was closed".
    func testProjectViewRunningChatWithClosedTabStaysMember() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let view = try openProjectView(store, active: s)
        XCTAssertTrue(store.openTabIDs(in: w).contains(s[1]))

        store.closeTab(s[1], in: w)
        // Läuft weiter → bleibt in der Aktiv-Menge.
        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [view.projectID: Set(s)])
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.slots, [s[0], s[1], s[2]])
        XCTAssertFalse(store.openTabIDs(in: w).contains(s[1]))
    }

    // MARK: - Eigene Workspaces

    /// Heute: Archivieren lässt den Platz leer stehen — trotz „Close gaps".
    func testArchivingMemberLeavesHoleInCuratedWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        try archive(s[1], in: persistence)
        store.prune(workspace: persistence.loadWorkspace())
        let entity = try XCTUnwrap(store.gridWorkspace(id: id))
        XCTAssertEqual(entity.slots, [s[0], nil, s[2]])
        XCTAssertEqual(entity.capacity, 3)
    }

    /// Heute: Tab eines Mitglieds im Besitzerfenster schließen — die
    /// Mitgliedschaft bleibt, die Kachel zeigt „Tab was closed · Reopen".
    func testClosingTabOfVisibleMemberKeepsMembership() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        store.closeTab(s[1], in: w)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], s[1], s[2]])
    }

    /// Bleibt: Tab in ein anderes Fenster ziehen nimmt den Chat NICHT aus
    /// dem Workspace — die Kachel bietet „Move here" an.
    func testMovingTabToOtherWindowKeepsMembership() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        let second = store.detachToNewWindow(s[1], from: w)
        XCTAssertEqual(store.windowID(containingTab: s[1]), second)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], s[1], s[2]])
    }

    /// Bleibt: `--keep-slot` hält Loch und Stufe fest.
    func testKeepSlotRemovalKeepsHoleAndStage() throws {
        let (store, persistence) = makeStore()
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 })

        XCTAssertTrue(store.removeSession(s[1], fromGridWorkspace: id, compacting: false))
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], nil, s[2]])
        XCTAssertEqual(store.gridWorkspace(id: id)?.capacity, 3)
    }

    /// Bleibt: Workspaces, die in KEINEM Fenster offen sind, behalten ihre
    /// Mitglieder, wenn deren Tab zugeht (Playlist) — beim Öffnen kommen
    /// die Tabs wieder.
    func testClosingTabKeepsMembershipInWorkspaceOpenNowhere() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 })
        store.openTab(s[0], in: w)

        store.closeTab(s[0], in: w)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], s[1]])
        XCTAssertEqual(store.activateGridWorkspace(id, in: w), .activated)
        XCTAssertTrue(store.openTabIDs(in: w).contains(s[0]), "Öffnen materialisiert den Tab wieder")
    }
}
