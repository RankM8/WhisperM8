import Foundation
import XCTest
@testable import WhisperM8

final class AgentGridLayoutTests: XCTestCase {
    // MARK: - visibleIDs

    func testVisibleIDsTakesPrefix() {
        let ids = [UUID(), UUID(), UUID(), UUID(), UUID()]
        XCTAssertEqual(AgentGridLayout.visibleIDs(ids, paneCount: 2), Array(ids.prefix(2)))
        XCTAssertEqual(AgentGridLayout.visibleIDs(ids, paneCount: 4), Array(ids.prefix(4)))
    }

    func testVisibleIDsWithFewerTabsThanPanes() {
        let ids = [UUID()]
        XCTAssertEqual(AgentGridLayout.visibleIDs(ids, paneCount: 4), ids,
                       "weniger Tabs als Panes → alle sichtbar, Rest bleibt leer")
        XCTAssertTrue(AgentGridLayout.visibleIDs([], paneCount: 2).isEmpty)
    }

    // MARK: - orderBringingIntoView

    func testAlreadyVisibleSelectionNeedsNoReorder() {
        let a = UUID(); let b = UUID(); let c = UUID()
        XCTAssertNil(AgentGridLayout.orderBringingIntoView(
            selected: a,
            openTabIDs: [a, b, c],
            visibleIDs: [a, b],
            previousSelected: b
        ))
    }

    func testHiddenSelectionSwapsWithPreviousSelectedSlot() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID()
        // 1×2-Grid zeigt [a, b]; a war fokussiert, User selektiert d.
        let order = AgentGridLayout.orderBringingIntoView(
            selected: d,
            openTabIDs: [a, b, c, d],
            visibleIDs: [a, b],
            previousSelected: a
        )
        XCTAssertEqual(order, [d, b, c, a], "d übernimmt den Slot des zuvor fokussierten a")
    }

    func testHiddenSelectionFallsBackToLastVisibleSlot() {
        let a = UUID(); let b = UUID(); let c = UUID()
        // Kein (sichtbarer) vorheriger Fokus → letzter sichtbarer Slot weicht.
        let order = AgentGridLayout.orderBringingIntoView(
            selected: c,
            openTabIDs: [a, b, c],
            visibleIDs: [a, b],
            previousSelected: nil
        )
        XCTAssertEqual(order, [a, c, b])
    }

    func testPreviousSelectedOutsideVisibleFallsBackToLastSlot() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID()
        let order = AgentGridLayout.orderBringingIntoView(
            selected: d,
            openTabIDs: [a, b, c, d],
            visibleIDs: [a, b],
            previousSelected: c // nicht sichtbar → zählt nicht als Slot
        )
        XCTAssertEqual(order, [a, d, c, b])
    }

    func testUnknownSelectionOrEmptyGridIsNoOp() {
        let a = UUID(); let b = UUID()
        XCTAssertNil(AgentGridLayout.orderBringingIntoView(
            selected: UUID(), // nicht in openTabIDs
            openTabIDs: [a, b],
            visibleIDs: [a],
            previousSelected: nil
        ))
        XCTAssertNil(AgentGridLayout.orderBringingIntoView(
            selected: a,
            openTabIDs: [a, b],
            visibleIDs: [], // kein Grid sichtbar
            previousSelected: nil
        ))
    }

    func testSwapIsRobustAgainstFilteredVisibleList() {
        // openTabIDs enthält einen (z. B. archivierten) Tab, den die Anzeige
        // überspringt — der Identity-Swap darf davon nicht verrutschen.
        let archived = UUID()
        let a = UUID(); let b = UUID(); let c = UUID()
        let order = AgentGridLayout.orderBringingIntoView(
            selected: c,
            openTabIDs: [archived, a, b, c],
            visibleIDs: [a, b], // gefiltert: ohne archived
            previousSelected: a
        )
        XCTAssertEqual(order, [archived, c, b, a])
    }

    // MARK: - AgentGridAutoLayout

    func testAutoLayoutForTabCount() {
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(0), .single)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(1), .single)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(2), .cols2)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(3), .twoPlusOne)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(4), .grid2x2)
        XCTAssertEqual(AgentGridAutoLayout.forTabCount(9), .grid2x2,
                       "5+ Tabs bleiben 2×2 — Rest läuft über den Bring-into-View-Swap")
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
