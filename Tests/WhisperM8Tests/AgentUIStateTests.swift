import Foundation
import XCTest
@testable import WhisperM8

final class AgentUIStateTests: XCTestCase {
    // MARK: - Fixtures

    private func makeWorkspace(
        projects: [AgentProject],
        sessions: [AgentChatSession]
    ) -> AgentWorkspace {
        AgentWorkspace(projects: projects, sessions: sessions)
    }

    private func makeSession(
        id: UUID = UUID(),
        projectID: UUID,
        title: String = "Chat",
        createdManually: Bool? = true,
        status: AgentChatStatus = .closed,
        lastActivityAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> AgentChatSession {
        var session = AgentChatSession(
            id: id,
            provider: .claude,
            projectID: projectID,
            title: title,
            lastActivityAt: lastActivityAt,
            createdManually: createdManually
        )
        session.status = status
        return session
    }

    // MARK: - Codable (v2)

    func testAgentUIStateRoundTripsViaJSON() throws {
        let original = AgentUIState(
            openTabIDs: [UUID(), UUID()],
            pinnedSessionIDs: [UUID()],
            selectedSessionID: UUID(),
            selectedProjectID: UUID(),
            expandedProjectIDs: [UUID(), UUID()]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, AgentUIState.currentSchemaVersion)
    }

    func testAgentUIStateLegacyJSONUsesDefaults() throws {
        // Pre-Schema-Version-File ohne explizite Felder — alle decodeIfPresent
        let json = "{}"
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.openTabIDs.isEmpty)
        XCTAssertTrue(decoded.pinnedSessionIDs.isEmpty)
        XCTAssertNil(decoded.selectedSessionID)
        XCTAssertNil(decoded.selectedProjectID)
        XCTAssertTrue(decoded.expandedProjectIDs.isEmpty)
    }

    func testEncodingDropsLegacyV1Fields() throws {
        var state = AgentUIState.empty
        state.legacyOpenTabIDsByProject = [UUID(): [UUID()]]
        state.legacySelectedSessionIDByProject = [UUID(): UUID()]
        let encoded = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["openTabIDsByProject"])
        XCTAssertNil(object["selectedSessionIDByProject"])
        XCTAssertEqual(object["schemaVersion"] as? Int, AgentUIState.currentSchemaVersion)
    }

    // MARK: - Migration v1 → v2

    func testMigrationFlattensV1TabsInProjectOrder() throws {
        let pid1 = UUID()
        let pid2 = UUID()
        let s1 = UUID(); let s2 = UUID(); let s3 = UUID()

        // Projekt-Reihenfolge über sortIndex festnageln (sortedProjects).
        var p1 = AgentProject(id: pid1, name: "Erstes", path: "/tmp/a")
        p1.sortIndex = 0
        var p2 = AgentProject(id: pid2, name: "Zweites", path: "/tmp/b")
        p2.sortIndex = 1
        let workspace = makeWorkspace(
            projects: [p2, p1], // bewusst verdreht — Migration muss sortieren
            sessions: [
                makeSession(id: s1, projectID: pid1),
                makeSession(id: s2, projectID: pid1),
                makeSession(id: s3, projectID: pid2)
            ]
        )

        // Reales v1-Disk-Format: Swift kodiert [UUID: …]-Maps als flaches
        // Array alternierender Key/Value-Paare (UUID ist kein String-Key).
        let v1JSON = """
        {
          "schemaVersion": 1,
          "openTabIDsByProject": [
            "\(pid2.uuidString)", ["\(s3.uuidString)"],
            "\(pid1.uuidString)", ["\(s1.uuidString)", "\(s2.uuidString)"]
          ],
          "selectedSessionIDByProject": ["\(pid1.uuidString)", "\(s2.uuidString)"],
          "selectedProjectID": "\(pid1.uuidString)",
          "expandedProjectIDs": ["\(pid1.uuidString)"]
        }
        """
        var state = try JSONDecoder().decode(AgentUIState.self, from: v1JSON.data(using: .utf8)!)
        state.migrateToV2IfNeeded(workspace: workspace)

        XCTAssertEqual(state.schemaVersion, AgentUIState.currentSchemaVersion)
        XCTAssertEqual(state.openTabIDs, [s1, s2, s3], "Projekt-Reihenfolge (sortIndex), innerhalb v1-Reihenfolge")
        XCTAssertEqual(state.selectedSessionID, s2, "Selektion aus der Pro-Projekt-Erinnerung des selektierten Projekts")
        XCTAssertTrue(state.legacyOpenTabIDsByProject.isEmpty)
        XCTAssertTrue(state.legacySelectedSessionIDByProject.isEmpty)
    }

    func testMigrationFallsBackToFirstTabWhenNoPerProjectSelection() throws {
        let pid = UUID()
        let s1 = UUID()
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: [makeSession(id: s1, projectID: pid)]
        )
        var state = AgentUIState(
            schemaVersion: 1,
            legacyOpenTabIDsByProject: [pid: [s1]]
        )
        state.migrateToV2IfNeeded(workspace: workspace)
        XCTAssertEqual(state.openTabIDs, [s1])
        XCTAssertEqual(state.selectedSessionID, s1)
    }

    func testMigrationIsNoOpForV2State() {
        let tab = UUID()
        var state = AgentUIState(openTabIDs: [tab], selectedSessionID: tab)
        state.legacyOpenTabIDsByProject = [UUID(): [UUID()]] // darf nichts bewirken
        state.migrateToV2IfNeeded(workspace: makeWorkspace(projects: [], sessions: []))
        XCTAssertEqual(state.openTabIDs, [tab])
        XCTAssertTrue(state.legacyOpenTabIDsByProject.isEmpty, "Legacy-Reste werden geleert")
    }

    // MARK: - Pruning

    func testPruneRemovesStaleIDsFromTabsPinsAndSelection() {
        let pid = UUID()
        let live = UUID()
        let stale = UUID()
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: [makeSession(id: live, projectID: pid)]
        )

        var state = AgentUIState(
            openTabIDs: [live, stale, live], // Duplikat wird mitbereinigt
            pinnedSessionIDs: [stale, live],
            selectedSessionID: stale,
            selectedProjectID: UUID(),
            expandedProjectIDs: [pid, UUID()]
        )
        state.prune(workspace: workspace)

        XCTAssertEqual(state.openTabIDs, [live])
        XCTAssertEqual(state.pinnedSessionIDs, [live])
        XCTAssertEqual(state.selectedSessionID, live)
        XCTAssertEqual(state.windows.first?.openTabIDs, [live])
        XCTAssertEqual(state.windows.first?.selectedSessionID, live)
        XCTAssertNil(state.selectedProjectID)
        XCTAssertEqual(state.expandedProjectIDs, [pid])
    }

    func testPruneCapsGlobalTabsAndPreservesSelected() {
        let pid = UUID()
        let ids = (0..<(AgentUIState.maxOpenTabs + 3)).map { _ in UUID() }
        let selected = ids.last!
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: ids.map { makeSession(id: $0, projectID: pid) }
        )

        var state = AgentUIState(openTabIDs: ids, selectedSessionID: selected)
        state.prune(workspace: workspace)

        XCTAssertEqual(state.openTabIDs.count, AgentUIState.maxOpenTabs)
        XCTAssertTrue(state.openTabIDs.contains(selected), "Selektierter Tab überlebt die Kappung")
        XCTAssertEqual(state.windows.first?.openTabIDs.count, AgentUIState.maxOpenTabs)
        XCTAssertTrue(state.windows.first?.openTabIDs.contains(selected) == true)
    }

    func testPruneWithoutCapKeepsAllLiveTabs() {
        let pid = UUID()
        let sessions = (0..<(AgentUIState.maxOpenTabs + 3)).map { _ in makeSession(projectID: pid) }
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: sessions
        )
        let base = AgentUIState(
            openTabIDs: sessions.map(\.id),
            selectedSessionID: sessions.last?.id
        )

        var runtime = base
        runtime.prune(workspace: workspace, capTabs: false)
        XCTAssertEqual(runtime.openTabIDs.count, sessions.count,
                       "Laufzeit-GC (capTabs: false) kappt die Bar nicht")

        var load = base
        load.prune(workspace: workspace) // Default = Load-Pfad
        XCTAssertEqual(load.openTabIDs.count, AgentUIState.maxOpenTabs,
                       "Load-Pfad kappt weiterhin auf maxOpenTabs")
    }

    func testMoveTabToNewWindowRemovesItFromSourceAndCreatesTarget() {
        let sourceWindowID = UUID()
        let targetWindowID = UUID()
        let first = UUID()
        let moved = UUID()
        var state = AgentUIState(
            openTabIDs: [first, moved],
            selectedSessionID: moved,
            windows: [
                AgentChatWindowState(
                    id: sourceWindowID,
                    openTabIDs: [first, moved],
                    selectedSessionID: moved,
                    isPrimary: true
                )
            ],
            primaryWindowID: sourceWindowID
        )

        state.moveTabToNewWindow(sessionID: moved, sourceWindowID: sourceWindowID, newWindowID: targetWindowID)

        XCTAssertEqual(state.windowState(for: sourceWindowID).openTabIDs, [first])
        XCTAssertEqual(state.windowState(for: sourceWindowID).selectedSessionID, first)
        XCTAssertEqual(state.windowState(for: targetWindowID).openTabIDs, [moved])
        XCTAssertEqual(state.windowState(for: targetWindowID).selectedSessionID, moved)
    }

    func testMovingLastTabOutOfSecondaryWindowRemovesSecondaryWindow() {
        let primaryWindowID = UUID()
        let secondaryWindowID = UUID()
        let targetWindowID = UUID()
        let primaryTab = UUID()
        let moved = UUID()
        var state = AgentUIState(
            windows: [
                AgentChatWindowState(id: primaryWindowID, openTabIDs: [primaryTab], selectedSessionID: primaryTab, isPrimary: true),
                AgentChatWindowState(id: secondaryWindowID, openTabIDs: [moved], selectedSessionID: moved)
            ],
            primaryWindowID: primaryWindowID
        )

        state.moveTab(sessionID: moved, from: secondaryWindowID, to: targetWindowID, before: nil)

        XCTAssertNotNil(state.windows.first { $0.id == primaryWindowID })
        XCTAssertNil(state.windows.first { $0.id == secondaryWindowID })
        XCTAssertEqual(state.windowState(for: targetWindowID).openTabIDs, [moved])
    }

    // MARK: - Multi-Window-Invarianten (Schema v3)

    /// Kerninvariante gegen „derselbe Chat in zwei Fenstern": Nach Normalisierung
    /// lebt jede Session in genau EINEM Fenster (Primaer hat Vorrang).
    func testSameSessionLivesInOnlyOneWindow() {
        let primaryID = UUID()
        let secondaryID = UUID()
        let shared = UUID()
        let primaryOnly = UUID()
        // Bewusst inkonsistent: `shared` in BEIDEN Fenstern. Der init ruft
        // normalizedWindows → muss das Duplikat aufloesen.
        let state = AgentUIState(
            windows: [
                AgentChatWindowState(id: primaryID, openTabIDs: [primaryOnly, shared], selectedSessionID: shared, isPrimary: true),
                AgentChatWindowState(id: secondaryID, openTabIDs: [shared], selectedSessionID: shared)
            ],
            primaryWindowID: primaryID
        )

        let allTabs = state.windows.flatMap(\.openTabIDs)
        XCTAssertEqual(allTabs.count, Set(allTabs).count, "Keine Session darf in zwei Fenstern liegen")
        XCTAssertTrue(state.windowState(for: primaryID).openTabIDs.contains(shared), "Primaer behaelt die geteilte Session")
        XCTAssertFalse(state.windowState(for: secondaryID).openTabIDs.contains(shared), "Sekundaer verliert das Duplikat")
        XCTAssertNil(state.windowState(for: secondaryID).selectedSessionID, "verwaiste Selektion faellt auf nil")
    }

    /// v2-Datei (globale openTabIDs, keine windows) wird verlustfrei in EIN
    /// Primaerfenster migriert.
    func testV2StateMigratesIntoSinglePrimaryWindow() throws {
        let pid = UUID()
        let t1 = UUID(); let t2 = UUID()
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: [makeSession(id: t1, projectID: pid), makeSession(id: t2, projectID: pid)]
        )
        let v2JSON = """
        {
          "schemaVersion": 2,
          "openTabIDs": ["\(t1.uuidString)", "\(t2.uuidString)"],
          "pinnedSessionIDs": [],
          "selectedSessionID": "\(t2.uuidString)",
          "expandedProjectIDs": []
        }
        """
        var state = try JSONDecoder().decode(AgentUIState.self, from: v2JSON.data(using: .utf8)!)
        state.migrateToV2IfNeeded(workspace: workspace)

        XCTAssertEqual(state.schemaVersion, AgentUIState.currentSchemaVersion)
        XCTAssertEqual(state.windows.count, 1, "genau ein Primaerfenster nach v2→v3")
        let primary = state.windowState(for: state.primaryWindowID)
        XCTAssertTrue(primary.isPrimary)
        XCTAssertEqual(primary.openTabIDs, [t1, t2])
        XCTAssertEqual(primary.selectedSessionID, t2)
    }

    /// Tab in ein BESTEHENDES anderes Fenster verschieben (nicht „neues").
    func testMoveTabIntoExistingWindowAppendsAndEmptiesSource() {
        let primaryID = UUID(); let secondaryID = UUID()
        let a = UUID(); let b = UUID(); let c = UUID()
        var state = AgentUIState(
            windows: [
                AgentChatWindowState(id: primaryID, openTabIDs: [a, b], selectedSessionID: a, isPrimary: true),
                AgentChatWindowState(id: secondaryID, openTabIDs: [c], selectedSessionID: c)
            ],
            primaryWindowID: primaryID
        )
        state.moveTab(sessionID: c, from: secondaryID, to: primaryID, before: nil)

        XCTAssertEqual(state.windowState(for: primaryID).openTabIDs, [a, b, c])
        XCTAssertEqual(state.windowState(for: primaryID).selectedSessionID, c)
        XCTAssertNil(state.windows.first { $0.id == secondaryID }, "leeres Quell-Sekundaerfenster wird entfernt")
    }

    /// Reorder innerhalb desselben Fensters über `before`.
    func testMoveTabReordersBeforeTargetWithinSameWindow() {
        let primaryID = UUID()
        let a = UUID(); let b = UUID(); let c = UUID()
        var state = AgentUIState(
            windows: [AgentChatWindowState(id: primaryID, openTabIDs: [a, b, c], selectedSessionID: a, isPrimary: true)],
            primaryWindowID: primaryID
        )
        state.moveTab(sessionID: c, from: primaryID, to: primaryID, before: a)
        XCTAssertEqual(state.windowState(for: primaryID).openTabIDs, [c, a, b])
    }

    /// prune entfernt leere/tote Sekundaerfenster, behaelt aber das Primaerfenster.
    func testPruneRemovesEmptyAndDeadSecondaryWindowsKeepsPrimary() {
        let pid = UUID()
        let live = UUID(); let dead = UUID()
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: [makeSession(id: live, projectID: pid)] // `dead` fehlt bewusst
        )
        let primaryID = UUID(); let emptySecID = UUID(); let deadSecID = UUID()
        var state = AgentUIState(
            windows: [
                AgentChatWindowState(id: primaryID, openTabIDs: [live], selectedSessionID: live, isPrimary: true),
                AgentChatWindowState(id: emptySecID, openTabIDs: [], selectedSessionID: nil),
                AgentChatWindowState(id: deadSecID, openTabIDs: [dead], selectedSessionID: dead)
            ],
            primaryWindowID: primaryID
        )
        state.prune(workspace: workspace)

        XCTAssertNotNil(state.windows.first { $0.id == primaryID }, "Primaerfenster bleibt")
        XCTAssertNil(state.windows.first { $0.id == emptySecID }, "leeres Sekundaerfenster gepruned")
        XCTAssertNil(state.windows.first { $0.id == deadSecID }, "Sekundaerfenster mit nur toten Tabs gepruned")
        XCTAssertEqual(state.windowState(for: primaryID).openTabIDs, [live])
    }

    /// Das Primaerfenster überlebt prune auch dann, wenn es leer ist (sonst
    /// haette die App nach dem Schliessen aller Tabs kein Fenster mehr).
    func testPruneKeepsEmptyPrimaryWindow() {
        let pid = UUID()
        let live = UUID()
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: [makeSession(id: live, projectID: pid)]
        )
        let primaryID = UUID()
        var state = AgentUIState(
            windows: [AgentChatWindowState(id: primaryID, openTabIDs: [], selectedSessionID: nil, isPrimary: true)],
            primaryWindowID: primaryID
        )
        state.prune(workspace: workspace)
        XCTAssertNotNil(state.windows.first { $0.id == primaryID })
        XCTAssertTrue(state.windowState(for: primaryID).isPrimary)
    }

    /// Genau ein Fenster ist isPrimary, und es entspricht primaryWindowID.
    func testExactlyOnePrimaryWindowMatchesPrimaryID() {
        let primaryID = UUID(); let secondaryID = UUID()
        let a = UUID(); let b = UUID()
        let state = AgentUIState(
            windows: [
                // bewusst falsch geflaggt — Normalisierung muss korrigieren
                AgentChatWindowState(id: primaryID, openTabIDs: [a], selectedSessionID: a, isPrimary: false),
                AgentChatWindowState(id: secondaryID, openTabIDs: [b], selectedSessionID: b, isPrimary: true)
            ],
            primaryWindowID: primaryID
        )
        XCTAssertEqual(state.windows.filter(\.isPrimary).count, 1, "genau ein Primaerfenster")
        XCTAssertTrue(state.windowState(for: primaryID).isPrimary)
        XCTAssertFalse(state.windowState(for: secondaryID).isPrimary)
    }

    func testRemoveWindowRemovesSecondaryWithTabsButProtectsPrimary() {
        let primaryID = UUID(); let secondaryID = UUID()
        let a = UUID(); let b = UUID()
        var state = AgentUIState(
            windows: [
                AgentChatWindowState(id: primaryID, openTabIDs: [a], isPrimary: true),
                AgentChatWindowState(id: secondaryID, openTabIDs: [b]),
            ],
            primaryWindowID: primaryID
        )

        state.removeWindow(secondaryID)
        XCTAssertNil(state.windows.first { $0.id == secondaryID },
                     "Sekundaerfenster verschwindet mitsamt Tabs")

        state.removeWindow(primaryID)
        XCTAssertEqual(state.windows.first { $0.id == primaryID }?.openTabIDs, [a],
                       "Primaerfenster ist geschuetzt, Tabs bleiben")
    }

    // MARK: - First-Load-Migration

    func testInitialMigrationPopulatesGlobalTabsAcrossProjects() {
        let pid1 = UUID()
        let pid2 = UUID()
        let manualNew = UUID()
        let manualOld = UUID()
        let other = UUID()
        let imported = UUID()
        let archived = UUID()

        var p1 = AgentProject(id: pid1, name: "A", path: "/tmp/a")
        p1.sortIndex = 0
        var p2 = AgentProject(id: pid2, name: "B", path: "/tmp/b")
        p2.sortIndex = 1
        let workspace = makeWorkspace(
            projects: [p1, p2],
            sessions: [
                makeSession(id: manualOld, projectID: pid1, lastActivityAt: Date(timeIntervalSince1970: 100)),
                makeSession(id: manualNew, projectID: pid1, lastActivityAt: Date(timeIntervalSince1970: 200)),
                makeSession(id: imported, projectID: pid1, createdManually: nil),
                makeSession(id: archived, projectID: pid1, status: .archived),
                makeSession(id: other, projectID: pid2)
            ]
        )

        let state = AgentUIState.initialMigration(from: workspace)
        XCTAssertEqual(state.openTabIDs, [manualNew, manualOld, other])
        // Importierte (createdManually=nil) und archivierte werden nicht migriert
    }

    // MARK: - Subagent-Unread (Slice 3)

    func testUnreadSubagentSessionIDsRoundTripViaJSON() throws {
        let unread = [UUID(), UUID()]
        let original = AgentUIState(unreadSubagentSessionIDs: unread)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: encoded)
        XCTAssertEqual(decoded.unreadSubagentSessionIDs, unread)
    }

    func testUnreadSubagentSessionIDsDefaultToEmptyForLegacyJSON() throws {
        // Bestehende Sidecar-Files ohne das Feld — decodeIfPresent, KEIN
        // schemaVersion-Bump.
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.unreadSubagentSessionIDs.isEmpty)
    }

    func testPruneRemovesStaleAndDuplicateUnreadIDs() {
        let pid = UUID()
        let live = UUID()
        let stale = UUID()
        let workspace = makeWorkspace(
            projects: [AgentProject(id: pid, name: "P", path: "/tmp/p")],
            sessions: [makeSession(id: live, projectID: pid)]
        )

        var state = AgentUIState(unreadSubagentSessionIDs: [stale, live, live])
        state.prune(workspace: workspace)

        XCTAssertEqual(state.unreadSubagentSessionIDs, [live])
    }
}
