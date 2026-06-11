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
        XCTAssertNil(state.selectedSessionID)
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
}
