import Foundation
import XCTest
@testable import WhisperM8

/// Auto-Layout + Grid-bezogene Fenster-State-Persistenz. Die frühere
/// Mitgliedschafts-/Verdrängungs-Logik (`AgentGridLayout`) ist mit den
/// Workspace-Entities (Schema v4) ersatzlos entfallen — deren Semantik
/// testen `WorkspaceSlotOpsTests` und `AgentGridWorkspaceTests`.
final class AgentGridLayoutTests: XCTestCase {
    // MARK: - AgentGridAutoLayout

    func testAutoLayoutForTabCount() {
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(0), .single)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(1), .single)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(2), .cols2)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(3), .twoPlusOne)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(4), .grid2x2)
    }

    func testAutoLayoutPaneCounts() {
        XCTAssertEqual(AgentGridAutoLayout.single.paneCount, 1)
        XCTAssertEqual(AgentGridAutoLayout.cols2.paneCount, 2)
        XCTAssertEqual(AgentGridAutoLayout.twoPlusOne.paneCount, 3)
        XCTAssertEqual(AgentGridAutoLayout.grid2x2.paneCount, 4)
    }

    // MARK: - Persistenz (AgentChatWindowState.showsGrid)

    func testWindowStateWithoutShowsGridDecodesAsFalse() throws {
        // Bestandsdatei ohne das Feld darf NICHT keyNotFound werfen — der
        // loadUIState-Fallback würde sonst den kompletten Tab-State verwerfen.
        let windowID = UUID()
        let tabID = UUID()
        let json = """
        {"schemaVersion": 3,
         "primaryWindowID": "\(windowID.uuidString)",
         "windows": [{"id": "\(windowID.uuidString)",
                      "openTabIDs": ["\(tabID.uuidString)"],
                      "isPrimary": true}]}
        """
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.windowState(for: windowID).showsGrid)
        XCTAssertEqual(decoded.windowState(for: windowID).openTabIDs, [tabID])
    }

    func testLegacyGridPresetMigratesToShowsGrid() throws {
        // Preset-Ära (V1, 2026-07-12): "single" → Einzelansicht, jedes
        // andere Raster → Grid.
        let gridWindowID = UUID()
        let singleWindowID = UUID()
        let json = """
        {"schemaVersion": 3,
         "primaryWindowID": "\(gridWindowID.uuidString)",
         "windows": [
           {"id": "\(gridWindowID.uuidString)", "openTabIDs": [],
            "isPrimary": true, "gridPreset": "grid2x2"},
           {"id": "\(singleWindowID.uuidString)",
            "openTabIDs": ["\(UUID().uuidString)"], "gridPreset": "single"}
         ]}
        """
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.windowState(for: gridWindowID).showsGrid, "Raster-Preset → Grid")
        XCTAssertFalse(decoded.windowState(for: singleWindowID).showsGrid, "single → Einzelansicht")
    }

    func testShowsGridRoundTripsAndDropsLegacyKey() throws {
        let window = AgentChatWindowState(
            openTabIDs: [UUID(), UUID()],
            isPrimary: true,
            showsGrid: true
        )
        let original = AgentUIState(windows: [window], primaryWindowID: window.id)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: encoded)
        XCTAssertTrue(decoded.windowState(for: window.id).showsGrid)
        XCTAssertEqual(decoded, original)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        XCTAssertNil(windows.first?["gridPreset"], "Legacy-Key wird nicht mehr geschrieben")
    }

    func testGridSessionIDsDecodeDefaultAndAreNeverEncoded() throws {
        // Bestandsdatei ohne das Feld → leere Auswahl (Default-Verhalten).
        let windowID = UUID()
        let json = """
        {"schemaVersion": 3,
         "primaryWindowID": "\(windowID.uuidString)",
         "windows": [{"id": "\(windowID.uuidString)", "openTabIDs": [], "isPrimary": true}]}
        """
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.windowState(for: windowID).legacyGridSessionIDs.isEmpty)

        // v3-Key `gridSessionIDs` wird noch DEKODIERT (Migrations-Input),
        // aber nie mehr encodiert — v4 persistiert die Mitgliedschaft in den
        // globalen Workspace-Entities.
        let a = UUID(); let b = UUID()
        let window = AgentChatWindowState(
            openTabIDs: [a, b],
            isPrimary: true,
            showsGrid: true,
            legacyGridSessionIDs: [a, b]
        )
        let original = AgentUIState(windows: [window], primaryWindowID: window.id)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self).contains("gridSessionIDs"),
            "Legacy-Key darf nicht mehr geschrieben werden"
        )
        let redecoded = try JSONDecoder().decode(AgentUIState.self, from: encoded)
        XCTAssertTrue(redecoded.windowState(for: window.id).legacyGridSessionIDs.isEmpty)
    }

    func testNormalizationDropsGridMembersWithoutTab() {
        let a = UUID(); let b = UUID(); let stale = UUID()
        let window = AgentChatWindowState(
            openTabIDs: [a, b],
            isPrimary: true,
            legacyGridSessionIDs: [a, stale, a] // Duplikat + toter Verweis
        )
        // init → normalizedWindows räumt auf.
        let state = AgentUIState(windows: [window], primaryWindowID: window.id)
        XCTAssertEqual(state.windowState(for: window.id).legacyGridSessionIDs, [a],
                       "Mitglieder ⊆ Tabs, dedupliziert")
    }

    @MainActor
    func testStoreShowsGridSurvivesTabMutations() {
        let persistence = AgentSessionStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("wm8-grid-ws-\(UUID().uuidString).json"),
            uiStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("wm8-grid-ui-\(UUID().uuidString).json")
        )
        let store = AgentWindowStore(persistence: persistence)
        let w = store.primaryWindowID
        store.setShowsGrid(true, in: w)
        store.openTab(UUID(), in: w)
        store.openTab(UUID(), in: w)
        XCTAssertTrue(store.showsGrid(in: w),
                      "Tab-Mutationen (normalizedWindows) verlieren den Grid-Zustand nicht")
    }
}
