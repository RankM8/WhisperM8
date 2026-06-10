import Foundation
import XCTest
@testable import WhisperM8

final class AgentUIStateTests: XCTestCase {
    // MARK: - AgentUIState

    func testAgentUIStateRoundTripsViaJSON() throws {
        let pid1 = UUID()
        let pid2 = UUID()
        let sid1 = UUID()
        let sid2 = UUID()
        let original = AgentUIState(
            schemaVersion: 1,
            openTabIDsByProject: [pid1: [sid1, sid2], pid2: [sid2]],
            selectedSessionIDByProject: [pid1: sid2],
            selectedProjectID: pid1,
            expandedProjectIDs: [pid1, pid2]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testAgentUIStateLegacyJSONUsesDefaults() throws {
        // Pre-Schema-Version-File ohne explizite Felder — alle decodeIfPresent
        let json = "{}"
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.openTabIDsByProject.isEmpty)
        XCTAssertTrue(decoded.selectedSessionIDByProject.isEmpty)
        XCTAssertNil(decoded.selectedProjectID)
        XCTAssertTrue(decoded.expandedProjectIDs.isEmpty)
    }

    func testAgentUIStatePrunesStaleProjectAndSessionIDs() {
        let livePID = UUID()
        let staleProjectID = UUID()
        let liveSID = UUID()
        let staleSID = UUID()

        let workspace = AgentWorkspace(
            projects: [
                AgentProject(id: livePID, name: "P", path: "/tmp/p")
            ],
            sessions: [
                AgentChatSession(id: liveSID, provider: .claude, projectID: livePID, title: "X")
            ]
        )

        var state = AgentUIState(
            openTabIDsByProject: [
                livePID: [liveSID, staleSID],
                staleProjectID: [staleSID]
            ],
            selectedSessionIDByProject: [
                livePID: staleSID,
                staleProjectID: liveSID
            ],
            selectedProjectID: staleProjectID,
            expandedProjectIDs: [livePID, staleProjectID]
        )
        state.prune(workspace: workspace)

        XCTAssertEqual(state.openTabIDsByProject[livePID], [liveSID])
        XCTAssertNil(state.openTabIDsByProject[staleProjectID])
        XCTAssertNil(state.selectedSessionIDByProject[livePID]) // staleSID war ausgewaehlt
        XCTAssertNil(state.selectedSessionIDByProject[staleProjectID])
        XCTAssertNil(state.selectedProjectID)
        XCTAssertEqual(state.expandedProjectIDs, [livePID])
    }

    func testAgentUIStateInitialMigrationFromWorkspacePopulatesOpenTabs() {
        let pid = UUID()
        let sidManual = UUID()
        let sidImported = UUID()
        let sidArchived = UUID()

        let workspace = AgentWorkspace(
            projects: [
                AgentProject(id: pid, name: "P", path: "/tmp/p")
            ],
            sessions: [
                AgentChatSession(id: sidManual, provider: .claude, projectID: pid, title: "Manual", createdManually: true),
                AgentChatSession(id: sidImported, provider: .claude, projectID: pid, title: "Imported", createdManually: nil),
                AgentChatSession(id: sidArchived, provider: .claude, projectID: pid, title: "Archived", status: .archived, createdManually: true)
            ]
        )

        let state = AgentUIState.initialMigration(from: workspace)
        XCTAssertEqual(state.openTabIDsByProject[pid], [sidManual])
        // Importierte (createdManually=nil) und archivierte werden nicht migriert
    }
}
