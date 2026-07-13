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

    // MARK: - Grid-Mitgliedschaft (visibleMembers / membershipAdding)

    func testEmptyMembershipFallsBackToFirstFourTabs() {
        let ids = [UUID(), UUID(), UUID(), UUID(), UUID()]
        XCTAssertEqual(
            AgentGridLayout.visibleMembers(orderedTabIDs: ids, membership: []),
            Array(ids.prefix(4)),
            "leere Mitgliedschaft = Default „alle offenen Tabs, max. 4\""
        )
    }

    func testMembershipShowsOnlyMembersInTabOrder() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID()
        XCTAssertEqual(
            AgentGridLayout.visibleMembers(orderedTabIDs: [a, b, c, d], membership: [d, b]),
            [b, d],
            "Mitglieder erscheinen in TAB-Reihenfolge, nicht in Aufnahme-Reihenfolge"
        )
    }

    func testDegenerateMembershipFallsBackToDefault() {
        let a = UUID(); let b = UUID(); let c = UUID()
        // Nur noch ein Mitglied übrig (z. B. weil die anderen Tabs
        // geschlossen wurden) → Default statt 1-Pane-Grid.
        XCTAssertEqual(
            AgentGridLayout.visibleMembers(orderedTabIDs: [a, b, c], membership: [b]),
            [a, b, c]
        )
        // Mitglieder zeigen auf lauter geschlossene Tabs → Default.
        XCTAssertEqual(
            AgentGridLayout.visibleMembers(orderedTabIDs: [a, b], membership: [UUID(), UUID()]),
            [a, b]
        )
    }

    func testMembershipAddingAppendsAndDeduplicates() {
        let a = UUID(); let b = UUID(); let c = UUID()
        XCTAssertEqual(
            AgentGridLayout.membershipAdding(c, membership: [a, b], focused: a),
            [a, b, c]
        )
        XCTAssertEqual(
            AgentGridLayout.membershipAdding(b, membership: [a, b], focused: a),
            [a, b],
            "erneutes Hinzufügen erzeugt kein Duplikat"
        )
    }

    func testMembershipAddingEvictsOldestNonFocusedWhenFull() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID(); let e = UUID()
        let result = AgentGridLayout.membershipAdding(e, membership: [a, b, c, d], focused: b)
        XCTAssertEqual(result, [b, c, d, e],
                       "a (ältestes, nicht fokussiert) weicht; Fokus b und Neuzugang e bleiben")
        XCTAssertEqual(result.count, AgentGridLayout.maxPanes)
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

    func testGridSessionIDsDecodeDefaultAndRoundTrip() throws {
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
    func testStoreCloseTabRemovesGridMember() {
        let persistence = AgentSessionStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("wm8-gridm-ws-\(UUID().uuidString).json"),
            uiStateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("wm8-gridm-ui-\(UUID().uuidString).json")
        )
        let store = AgentWindowStore(persistence: persistence)
        let w = store.primaryWindowID
        let a = UUID(); let b = UUID(); let c = UUID()
        store.openTab(a, in: w); store.openTab(b, in: w); store.openTab(c, in: w)
        store.setGridSessionIDs([a, b, c], in: w)
        store.closeTab(b, in: w)
        XCTAssertEqual(store.gridSessionIDs(in: w), [a, c],
                       "Tab-Schließen entfernt das Grid-Mitglied automatisch")
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
