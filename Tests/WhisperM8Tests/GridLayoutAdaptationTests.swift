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

    /// Ein Chat aus der Mitte fällt weg: die übrigen rücken nach, aus 2×2
    /// wird 2+1 (Nutzerbefund 11.11.2026: „3 Chats → Raster bleibt 2×2").
    func testProjectViewChatLeavingFromTheMiddleCompactsToTwoPlusOne() throws {
        let (store, persistence) = makeStore()
        let s = try seed(persistence, count: 4)
        let view = try openProjectView(store, active: s)
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.capacity, 4)

        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [
            view.projectID: [s[0], s[2], s[3]]
        ])
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.slots, [s[0], s[2], s[3]], "Reihenfolge bleibt, Loch schließt sich")
        XCTAssertEqual(entity.capacity, 3)
    }

    /// Schalter „Close gaps…" aus: altes Verhalten — Loch bleibt, nur leere
    /// Kacheln am Ende fallen weg.
    func testProjectViewKeepsHoleWhenClosingGapsIsOff() throws {
        let (store, persistence) = makeStore()
        store.isGridAutoCompactEnabled = { false }
        let s = try seed(persistence, count: 4)
        let view = try openProjectView(store, active: s)

        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [
            view.projectID: [s[0], s[2], s[3]]
        ])
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.slots, [s[0], nil, s[2], s[3]])
        XCTAssertEqual(entity.capacity, 4)
    }

    /// Neue Chats hängen sich hinten an — nach dem Verdichten gibt es keine
    /// Löcher mehr, in die sie fallen könnten.
    func testProjectViewNewChatAppendsAfterCompaction() throws {
        let (store, persistence) = makeStore()
        let s = try seed(persistence, count: 4)
        let view = try openProjectView(store, active: Array(s.prefix(3)))
        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [view.projectID: [s[0], s[2]]])
        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [view.projectID: [s[0], s[2], s[3]]])
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.slots, [s[0], s[2], s[3]])
        XCTAssertEqual(entity.capacity, 3)
    }

    /// Ein einziger aktiver Chat nimmt die volle Fläche (Stufe 1).
    func testProjectViewWithSingleChatUsesFullArea() throws {
        let (store, persistence) = makeStore()
        let s = try seed(persistence, count: 1)
        let view = try openProjectView(store, active: s)
        let entity = try XCTUnwrap(store.gridWorkspace(id: view.entityID))
        XCTAssertEqual(entity.capacity, 1)
        XCTAssertEqual(entity.slots, [s[0]])
        XCTAssertEqual(AgentGridAutoLayout.forCapacity(entity.capacity), .single)
    }

    /// Tab eines laufenden Chats zu: Er verlässt die Ansicht, obwohl er
    /// weiterläuft — und kommt mit seinem Tab zurück.
    func testProjectViewRunningChatLeavesWithItsTabAndReturnsWithIt() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let view = try openProjectView(store, active: s)
        XCTAssertTrue(store.openTabIDs(in: w).contains(s[1]))

        store.closeTab(s[1], in: w)
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.slots, [s[0], s[2]],
                       "sofort raus, die übrigen rücken nach")
        // Läuft weiter → bleibt in der Aktiv-Menge, kommt aber nicht zurück.
        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [view.projectID: Set(s)])
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.slots, [s[0], s[2]])

        // Tab wieder auf (egal wo) → wieder Mitglied, hinten angehängt.
        store.openTab(s[1], in: w, select: false)
        XCTAssertEqual(store.dismissedProjectViewSessionIDs, [:])
        store.syncActiveProjectGridWorkspaces(activeSessionIDsByProject: [view.projectID: Set(s)])
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.slots, [s[0], s[2], s[1]])
    }

    /// ⊞ erneut heißt „alle aktiven zeigen" — auch weggeschlossene laufende.
    func testProjectViewReactivationShowsDismissedRunningChatAgain() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 2)
        let view = try openProjectView(store, active: s)
        store.closeTab(s[1], in: w)
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.occupiedSessionIDs, [s[0]])

        _ = store.activateProjectGridWorkspace(
            projectID: view.projectID, name: "P", colorHex: "#3E8E63",
            activeSessionIDs: Set(s), in: w
        )
        XCTAssertEqual(store.gridWorkspace(id: view.entityID)?.occupiedSessionIDs, [s[0], s[1]])
    }

    // MARK: - Eigene Workspaces

    /// Archivieren schließt die Lücke wie ⊖.
    func testArchivingMemberCompactsCuratedWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)
        store.setGridFocusedSession(s[1], in: w)

        try archive(s[1], in: persistence)
        store.prune(workspace: persistence.loadWorkspace())
        let entity = try XCTUnwrap(store.gridWorkspace(id: id))
        XCTAssertEqual(entity.slots, [s[0], s[2]])
        XCTAssertEqual(entity.capacity, 2)
        XCTAssertEqual(store.selectedSession(in: w), s[2], "Fokus geht an die nächste Pane")
    }

    /// Schalter aus: Archivieren lässt den Platz leer stehen.
    func testArchivingMemberLeavesHoleWhenClosingGapsIsOff() throws {
        let (store, persistence) = makeStore()
        store.isGridAutoCompactEnabled = { false }
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        try archive(s[1], in: persistence)
        store.prune(workspace: persistence.loadWorkspace())
        let entity = try XCTUnwrap(store.gridWorkspace(id: id))
        XCTAssertEqual(entity.slots, [s[0], nil, s[2]])
        XCTAssertEqual(entity.capacity, 3)
    }

    /// Tab eines Mitglieds schließen nimmt den Chat aus dem offenen
    /// Workspace; der Fokus bleibt im Raster und geht an die nächste Pane.
    func testClosingTabOfVisibleMemberRemovesItAndKeepsGridFocus() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)
        store.setGridFocusedSession(s[1], in: w)

        store.closeTab(s[1], in: w)
        let entity = try XCTUnwrap(store.gridWorkspace(id: id))
        XCTAssertEqual(entity.slots, [s[0], s[2]])
        XCTAssertEqual(entity.capacity, 2)
        XCTAssertTrue(store.showsGrid(in: w))
        XCTAssertEqual(store.selectedSession(in: w), s[2])
    }

    /// Dasselbe über die View-Bridge (✕, ⌘W, Sammel-Schließen).
    func testClosingTabsViaBridgeRemovesThemFromOpenWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 4)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        store.setOpenTabIDs(store.openTabIDs(in: w).filter { $0 != s[0] && $0 != s[3] }, in: w)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[1], s[2]])
    }

    /// Wiederöffnen (⌘⇧T) macht das Schließen rückgängig: Tab und Kachel.
    func testReopeningClosedTabReturnsItToTheWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        store.closeTab(s[1], in: w)
        XCTAssertEqual(store.reopenLastClosedTab()?.sessionID, s[1])
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], s[2], s[1]])
        XCTAssertTrue(store.openTabIDs(in: w).contains(s[1]))
    }

    /// Auch wenn der Workspace gerade nur Rücksprungziel ist (Einzelansicht).
    func testClosingTabWhileWorkspaceIsReturnTargetRemovesIt() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)
        store.showSingleSession(s[2], in: w)
        XCTAssertFalse(store.showsGrid(in: w))

        store.closeTab(s[2], in: w)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], s[1]])
    }

    /// Letzten Chat schließen: zwei leere Ablageflächen bleiben.
    func testClosingLastMemberLeavesEmptyTwoSlotWorkspace() throws {
        let (store, persistence) = makeStore()
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 1)
        let id = store.createGridWorkspace(name: "G", capacity: 1, slots: s.map { $0 }, activateIn: w)
        XCTAssertEqual(store.gridWorkspace(id: id)?.capacity, 1, "ein Chat = volle Fläche")

        store.closeTab(s[0], in: w)
        let entity = try XCTUnwrap(store.gridWorkspace(id: id))
        XCTAssertEqual(entity.slots, [nil, nil])
        XCTAssertEqual(entity.capacity, AgentGridWorkspace.emptyCapacity)
    }

    /// Schalter aus: Tab schließen nimmt den Chat raus, der Platz bleibt leer.
    func testClosingTabLeavesHoleWhenClosingGapsIsOff() throws {
        let (store, persistence) = makeStore()
        store.isGridAutoCompactEnabled = { false }
        let w = store.primaryWindowID
        let s = try seed(persistence, count: 3)
        let id = store.createGridWorkspace(name: "G", slots: s.map { $0 }, activateIn: w)

        store.closeTab(s[1], in: w)
        XCTAssertEqual(store.gridWorkspace(id: id)?.slots, [s[0], nil, s[2]])
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

    // MARK: - Aktiv-Menge ohne Sidebar

    /// Der Sync-Ersatz bei ausgeblendeter Sidebar rechnet dieselbe
    /// Aktiv-Menge wie der Sidebar-Snapshot — inklusive Subagent-Parents,
    /// gepinnter und fensterübergreifender Tabs.
    func testStandaloneActiveSetMatchesSidebarSnapshot() {
        let projectA = UUID(); let projectB = UUID()
        func chat(_ project: UUID, external: String? = nil, status: AgentChatStatus = .closed,
                  manual: Bool = true) -> AgentChatSession {
            var session = AgentChatSession(
                id: UUID(), provider: .claude, projectID: project, title: "c",
                lastActivityAt: Date(timeIntervalSince1970: 100), createdManually: manual
            )
            session.status = status
            session.externalSessionID = external
            return session
        }
        let parent = chat(projectA, external: "ext-parent")
        let child = AgentChatSession(
            provider: .codex, projectID: projectA, title: "Kind",
            createdAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 100), createdManually: true,
            kind: .subagentJob, subagentParentSessionID: "ext-parent"
        )
        let running = chat(projectA)
        let tabElsewhere = chat(projectB)
        let pinnedTab = chat(projectB)
        let archivedRunning = chat(projectB, status: .archived)
        let imported = chat(projectA, manual: false)
        let idle = chat(projectA)
        let sessions = [parent, child, running, tabElsewhere, pinnedTab, archivedRunning, imported, idle]
        let workspace = AgentWorkspace(projects: [], sessions: sessions)
        let runningIDs: Set<UUID> = [child.id, running.id, archivedRunning.id, imported.id]
        let globalTabs: Set<UUID> = [tabElsewhere.id, pinnedTab.id]

        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: [pinnedTab.id],
            scope: SidebarScopeFilter(
                scope: .active, runningSessionIDs: runningIDs, openTabIDs: [],
                now: Date(timeIntervalSince1970: 200), recentWindow: 3600
            ),
            layout: .grouped, query: "", flatVisibleLimit: 50, selectedSessionID: nil,
            globalOpenTabIDs: globalTabs
        )
        let standalone = AgentSidebarModelBuilder.activeSessionIDsByProject(
            sessions: sessions, runningSessionIDs: runningIDs, globalOpenTabIDs: globalTabs
        )
        XCTAssertEqual(standalone, snapshot.activeSessionIDsByProject)
        XCTAssertEqual(standalone[projectA], [parent.id, running.id])
        XCTAssertEqual(standalone[projectB], [tabElsewhere.id, pinnedTab.id])
    }
}
