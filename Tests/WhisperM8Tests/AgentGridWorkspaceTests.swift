import Foundation
import XCTest
@testable import WhisperM8

/// Entity-, Invarianten- und Migrations-Tests für die Grid-Workspaces
/// (Schema v4) — Testmatrix aus der Robustheits-Spezifikation
/// (Codex-Job 14d92786, docs/plans/grid-workspace-plan.html Abschnitt 06).
final class AgentGridWorkspaceTests: XCTestCase {
    // MARK: - Fixtures

    private func makeWorkspace(sessions: [AgentChatSession]) -> AgentWorkspace {
        AgentWorkspace(
            projects: [AgentProject(id: projectID, name: "P", path: "/tmp/p")],
            sessions: sessions
        )
    }

    private let projectID = UUID()

    private func makeSession(
        id: UUID = UUID(),
        status: AgentChatStatus = .closed
    ) -> AgentChatSession {
        var session = AgentChatSession(
            id: id,
            provider: .claude,
            projectID: projectID,
            title: "Chat",
            lastActivityAt: Date(timeIntervalSince1970: 1_000),
            createdManually: true
        )
        session.status = status
        return session
    }

    // MARK: - Codable

    func testWorkspaceRoundTripsViaJSON() throws {
        let a = UUID(); let b = UUID()
        let original = AgentGridWorkspace(
            name: "Release-Woche",
            colorHex: "#3E8E63",
            slots: [a, nil, b, nil],
            capacity: 4,
            columnFractions: [0.3, 0.7],
            rowFractions: [0.6, 0.4]
        )
        let decoded = try JSONDecoder().decode(
            AgentGridWorkspace.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.slots, [a, nil, b, nil], "Slot-Positionen exakt erhalten")
        XCTAssertEqual(decoded.columnFractions, [0.3, 0.7])
    }

    func testWorkspaceMissingKeysDecodeWithSafeDefaults() throws {
        let decoded = try JSONDecoder().decode(
            AgentGridWorkspace.self, from: Data("{}".utf8)
        )
        XCTAssertEqual(decoded.name, AgentGridWorkspace.defaultName)
        XCTAssertEqual(decoded.colorHex, AgentGridWorkspace.defaultColorHex)
        XCTAssertEqual(decoded.capacity, 2)
        XCTAssertEqual(decoded.slots, [nil, nil])
        XCTAssertEqual(decoded.columnFractions, [0.5, 0.5])
        XCTAssertEqual(decoded.rowFractions, [1.0])
    }

    func testMissingFractionKeysUseLayoutDefaults() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "name": "X", "capacity": 6, "slots": []}
        """
        let decoded = try JSONDecoder().decode(AgentGridWorkspace.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.columnFractions.count, 3)
        XCTAssertEqual(decoded.rowFractions.count, 2)
        XCTAssertEqual(decoded.columnFractions[0], 1.0 / 3.0, accuracy: 0.0001)
    }

    // MARK: - Intrinsische Normalisierung

    func testInvalidFractionVectorsAreRepairedPerAxis() {
        let workspace = AgentGridWorkspace(
            capacity: 4,
            columnFractions: [0.2, -1.0],       // nichtpositiv → Reparatur
            rowFractions: [0.25, 0.75]           // gültig → bleibt
        )
        XCTAssertEqual(workspace.columnFractions, [0.5, 0.5])
        XCTAssertEqual(workspace.rowFractions, [0.25, 0.75])
    }

    func testFractionsAreRenormalizedToSumOne() {
        let workspace = AgentGridWorkspace(
            capacity: 2,
            columnFractions: [1.0, 3.0],
            rowFractions: []
        )
        XCTAssertEqual(workspace.columnFractions[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(workspace.columnFractions[1], 0.75, accuracy: 0.0001)
        XCTAssertEqual(workspace.rowFractions, [1.0])
    }

    func testInvalidCapacityIsInferredFromHighestOccupiedSlot() {
        let a = UUID()
        var slots: [UUID?] = Array(repeating: nil, count: 5)
        slots[4] = a // höchster belegter Index 4 → Stufe 6
        let workspace = AgentGridWorkspace(slots: slots, capacity: 5)
        XCTAssertEqual(workspace.capacity, 6)
        XCTAssertEqual(workspace.slots[4], a, "Position bleibt erhalten")
        XCTAssertEqual(workspace.slots.count, 6)
    }

    func testSlotsArePaddedToCapacity() {
        let a = UUID()
        let workspace = AgentGridWorkspace(slots: [a], capacity: 4)
        XCTAssertEqual(workspace.slots, [a, nil, nil, nil])
    }

    func testSlotsBeyondCapacityGrowToNextAllowedStage() {
        let ids = (0 ..< 5).map { _ in UUID() }
        let workspace = AgentGridWorkspace(slots: ids.map { $0 }, capacity: 4)
        XCTAssertEqual(workspace.capacity, 6, "kleinste passende erlaubte Stufe")
        XCTAssertEqual(workspace.slots.prefix(5).compactMap { $0 }, ids)
        XCTAssertNil(workspace.slots[5])
    }

    func testSlotsBeyondNineAreDeterministicallyTruncated() {
        let ids = (0 ..< 11).map { _ in UUID() }
        let workspace = AgentGridWorkspace(slots: ids.map { $0 }, capacity: 9)
        XCTAssertEqual(workspace.capacity, 9)
        XCTAssertEqual(workspace.slots.compactMap { $0 }, Array(ids.prefix(9)),
                       "stabiler Prefix, Rest verworfen")
    }

    func testDuplicateSessionInWorkspaceBecomesNilAtLaterIndex() {
        let a = UUID()
        let workspace = AgentGridWorkspace(slots: [a, nil, a], capacity: 3)
        XCTAssertEqual(workspace.slots, [a, nil, nil], "kein Kompaktieren")
    }

    func testInvalidColorFallsBackToDefault() {
        XCTAssertEqual(AgentGridWorkspace(colorHex: "rot").colorHex, AgentGridWorkspace.defaultColorHex)
        XCTAssertEqual(AgentGridWorkspace(colorHex: "#12345").colorHex, AgentGridWorkspace.defaultColorHex)
        XCTAssertEqual(AgentGridWorkspace(colorHex: "#a1b2c3").colorHex, "#A1B2C3", "kanonisch Großbuchstaben")
    }

    func testEmptyNameFallsBackToDefault() {
        XCTAssertEqual(AgentGridWorkspace(name: "   ").name, AgentGridWorkspace.defaultName)
        XCTAssertEqual(AgentGridWorkspace(name: "  Recherche ").name, "Recherche", "getrimmt")
    }

    // MARK: - UI-State-Invarianten

    func testSameSessionMayExistInDifferentWorkspaces() {
        let a = UUID()
        let w1 = AgentGridWorkspace(slots: [a, nil], capacity: 2)
        let w2 = AgentGridWorkspace(slots: [nil, a], capacity: 2)
        let normalized = AgentUIState.normalizedGridWorkspaces([w1, w2])
        XCTAssertEqual(normalized[0].slots[0], a)
        XCTAssertEqual(normalized[1].slots[1], a, "Mehrfach-Mitgliedschaft bleibt")
    }

    func testDuplicateWorkspaceIDsKeepFirstEntry() {
        let id = UUID()
        let first = AgentGridWorkspace(id: id, name: "Erster")
        let second = AgentGridWorkspace(id: id, name: "Zweiter")
        let normalized = AgentUIState.normalizedGridWorkspaces([first, second])
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].name, "Erster")
    }

    func testInvalidActiveWorkspaceReferenceIsCleared() {
        let window = AgentChatWindowState(
            openTabIDs: [UUID()],
            isPrimary: true,
            showsGrid: true,
            activeWorkspaceID: UUID() // zeigt ins Leere
        )
        let state = AgentUIState(windows: [window], primaryWindowID: window.id)
        XCTAssertNil(state.windowState(for: window.id).activeWorkspaceID)
        XCTAssertFalse(state.windowState(for: window.id).showsGrid,
                       "kaputte Referenz nimmt das Grid mit runter")
    }

    func testDuplicateWorkspaceOwnershipKeepsPrimaryWindow() {
        let entity = AgentGridWorkspace(name: "Geteilt")
        let a = UUID(); let b = UUID()
        let primary = AgentChatWindowState(
            openTabIDs: [a], isPrimary: true, showsGrid: true, activeWorkspaceID: entity.id
        )
        let secondary = AgentChatWindowState(
            openTabIDs: [b], showsGrid: true, activeWorkspaceID: entity.id
        )
        let state = AgentUIState(
            windows: [secondary, primary],
            primaryWindowID: primary.id,
            gridWorkspaces: [entity]
        )
        XCTAssertEqual(state.windowState(for: primary.id).activeWorkspaceID, entity.id)
        XCTAssertNil(state.windowState(for: secondary.id).activeWorkspaceID,
                     "Single-Owner: Verlierer wird deaktiviert")
        XCTAssertFalse(state.windowState(for: secondary.id).showsGrid)
    }

    func testValidActiveWorkspaceSurvivesSingleMode() {
        let entity = AgentGridWorkspace(name: "Rücksprung")
        let window = AgentChatWindowState(
            openTabIDs: [UUID()],
            isPrimary: true,
            showsGrid: false,
            activeWorkspaceID: entity.id
        )
        let state = AgentUIState(
            windows: [window], primaryWindowID: window.id, gridWorkspaces: [entity]
        )
        XCTAssertEqual(state.windowState(for: window.id).activeWorkspaceID, entity.id,
                       "Referenz bleibt auch bei verborgenem Grid (Zurück-zum-Workspace)")
    }

    // MARK: - Prune (Slots gegen den Domain-Workspace)

    func testPruneClearsMissingSessionAtOriginalIndex() {
        let live1 = makeSession(); let live2 = makeSession()
        let dead = UUID()
        let entity = AgentGridWorkspace(slots: [live1.id, dead, live2.id], capacity: 3)
        var state = AgentUIState(gridWorkspaces: [entity])
        state.prune(workspace: makeWorkspace(sessions: [live1, live2]))
        XCTAssertEqual(state.gridWorkspaces[0].slots, [live1.id, nil, live2.id])
    }

    func testPruneClearsArchivedSessionAtOriginalIndex() {
        let live = makeSession()
        let archived = makeSession(status: .archived)
        let entity = AgentGridWorkspace(slots: [archived.id, live.id], capacity: 2)
        var state = AgentUIState(gridWorkspaces: [entity])
        state.prune(workspace: makeWorkspace(sessions: [live, archived]))
        XCTAssertEqual(state.gridWorkspaces[0].slots, [nil, live.id],
                       "archiviert → Slot nil, Kapazität unverändert")
    }

    func testPruneKeepsClosedSessionsInSlots() {
        let closed = makeSession(status: .closed)
        let running = makeSession(status: .running)
        let entity = AgentGridWorkspace(slots: [closed.id, running.id], capacity: 2)
        var state = AgentUIState(gridWorkspaces: [entity])
        state.prune(workspace: makeWorkspace(sessions: [closed, running]))
        XCTAssertEqual(state.gridWorkspaces[0].slots, [closed.id, running.id],
                       ".closed ist eine normale, resumierbare Session")
    }

    func testPruneNeverCompactsOrShrinksWorkspace() {
        let live = makeSession()
        var slots: [UUID?] = Array(repeating: nil, count: 9)
        slots[0] = UUID(); slots[4] = live.id; slots[8] = UUID()
        let entity = AgentGridWorkspace(slots: slots, capacity: 9)
        var state = AgentUIState(gridWorkspaces: [entity])
        state.prune(workspace: makeWorkspace(sessions: [live]))
        XCTAssertEqual(state.gridWorkspaces[0].slots.count, 9)
        XCTAssertEqual(state.gridWorkspaces[0].capacity, 9)
        XCTAssertEqual(state.gridWorkspaces[0].slots[4], live.id)
        XCTAssertNil(state.gridWorkspaces[0].slots[0])
        XCTAssertNil(state.gridWorkspaces[0].slots[8])
    }

    // MARK: - Migration v3 → v4

    /// v3-Fenster-JSON mit Grid-Zustand bauen.
    private func v3JSON(
        windowID: UUID,
        tabIDs: [UUID],
        showsGrid: Bool,
        gridSessionIDs: [UUID],
        extraWindows: String = ""
    ) -> String {
        """
        {"schemaVersion": 3,
         "primaryWindowID": "\(windowID.uuidString)",
         "windows": [
           {"id": "\(windowID.uuidString)",
            "openTabIDs": [\(tabIDs.map { "\"\($0.uuidString)\"" }.joined(separator: ","))],
            "isPrimary": true,
            "showsGrid": \(showsGrid),
            "gridSessionIDs": [\(gridSessionIDs.map { "\"\($0.uuidString)\"" }.joined(separator: ","))]}
           \(extraWindows)]}
        """
    }

    func testV3ExplicitGridMembershipMigratesInTabOrder() throws {
        let s = (0 ..< 4).map { _ in makeSession() }
        let windowID = UUID()
        // Mitgliedschaft bewusst verdreht — die sichtbare Reihenfolge folgte
        // den TABS, nicht der Membership-Liste.
        let json = v3JSON(
            windowID: windowID,
            tabIDs: s.map(\.id),
            showsGrid: true,
            gridSessionIDs: [s[2].id, s[0].id]
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))

        XCTAssertEqual(state.schemaVersion, 4)
        XCTAssertEqual(state.gridWorkspaces.count, 1)
        XCTAssertEqual(state.gridWorkspaces[0].name, "Grid")
        XCTAssertEqual(state.gridWorkspaces[0].capacity, 2)
        XCTAssertEqual(state.gridWorkspaces[0].slots, [s[0].id, s[2].id], "Tab-Reihenfolge")
        XCTAssertEqual(state.windowState(for: windowID).activeWorkspaceID, state.gridWorkspaces[0].id)
        XCTAssertTrue(state.windowState(for: windowID).legacyGridSessionIDs.isEmpty)
        XCTAssertTrue(state.windowState(for: windowID).showsGrid, "showsGrid unverändert")
    }

    func testV3EmptyMembershipMigratesFirstFourLiveTabs() throws {
        let s = (0 ..< 6).map { _ in makeSession() }
        let windowID = UUID()
        let json = v3JSON(
            windowID: windowID, tabIDs: s.map(\.id), showsGrid: true, gridSessionIDs: []
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))

        XCTAssertEqual(state.gridWorkspaces.count, 1)
        XCTAssertEqual(state.gridWorkspaces[0].slots, s.prefix(4).map(\.id),
                       "alter Default (erste 4 Tabs) exakt materialisiert")
        XCTAssertEqual(state.gridWorkspaces[0].capacity, 4)
    }

    func testV3DegenerateMembershipUsesLegacyFallback() throws {
        let s = (0 ..< 3).map { _ in makeSession() }
        let windowID = UUID()
        // Nur EIN gültiges Mitglied = degeneriert → Default statt 1er-Grid.
        let json = v3JSON(
            windowID: windowID, tabIDs: s.map(\.id), showsGrid: true,
            gridSessionIDs: [s[1].id]
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))

        XCTAssertEqual(state.gridWorkspaces[0].slots, s.map(\.id))
        XCTAssertEqual(state.gridWorkspaces[0].capacity, 3)
    }

    func testV3HiddenConfiguredGridKeepsWorkspaceReference() throws {
        let s = (0 ..< 2).map { _ in makeSession() }
        let windowID = UUID()
        let json = v3JSON(
            windowID: windowID, tabIDs: s.map(\.id), showsGrid: false,
            gridSessionIDs: s.map(\.id)
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))

        XCTAssertEqual(state.gridWorkspaces.count, 1, "konfiguriertes Grid bleibt als Rücksprungziel")
        XCTAssertEqual(state.windowState(for: windowID).activeWorkspaceID, state.gridWorkspaces[0].id)
        XCTAssertFalse(state.windowState(for: windowID).showsGrid)
    }

    func testV3WindowWithoutGridStateCreatesNoWorkspace() throws {
        let s = makeSession()
        let windowID = UUID()
        let json = v3JSON(windowID: windowID, tabIDs: [s.id], showsGrid: false, gridSessionIDs: [])
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: [s]))
        XCTAssertTrue(state.gridWorkspaces.isEmpty)
        XCTAssertNil(state.windowState(for: windowID).activeWorkspaceID)
    }

    func testV3MultiWindowMigrationCreatesOneWorkspacePerLegacyWindow() throws {
        let s = (0 ..< 4).map { _ in makeSession() }
        let primaryID = UUID()
        let secondaryID = UUID()
        let extra = """
        ,{"id": "\(secondaryID.uuidString)",
          "openTabIDs": ["\(s[2].id.uuidString)", "\(s[3].id.uuidString)"],
          "isPrimary": false,
          "showsGrid": true,
          "gridSessionIDs": ["\(s[2].id.uuidString)", "\(s[3].id.uuidString)"]}
        """
        let json = v3JSON(
            windowID: primaryID,
            tabIDs: [s[0].id, s[1].id],
            showsGrid: true,
            gridSessionIDs: [s[0].id, s[1].id],
            extraWindows: extra
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))

        XCTAssertEqual(state.gridWorkspaces.count, 2, "je Legacy-Fenster eine Entity (verlustfrei)")
        XCTAssertEqual(state.gridWorkspaces.map(\.name), ["Grid", "Grid 2"])
        XCTAssertEqual(state.windowState(for: primaryID).activeWorkspaceID, state.gridWorkspaces[0].id)
        XCTAssertEqual(state.windowState(for: secondaryID).activeWorkspaceID, state.gridWorkspaces[1].id)
    }

    func testV3MigrationFiltersArchivedMissingAndDuplicateMembers() throws {
        let live1 = makeSession(); let live2 = makeSession()
        let archived = makeSession(status: .archived)
        let missing = UUID()
        let windowID = UUID()
        let json = v3JSON(
            windowID: windowID,
            tabIDs: [live1.id, archived.id, missing, live2.id, live1.id],
            showsGrid: true,
            gridSessionIDs: [live1.id, archived.id, missing, live2.id]
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: [live1, live2, archived]))

        XCTAssertEqual(state.gridWorkspaces[0].slots.compactMap { $0 }, [live1.id, live2.id],
                       "nur live, eindeutige Sessions")
    }

    func testV3MigrationSelectsCapacityStages() throws {
        for (memberCount, expectedCapacity) in [(2, 2), (3, 3), (4, 4)] {
            let s = (0 ..< memberCount).map { _ in makeSession() }
            let windowID = UUID()
            let json = v3JSON(
                windowID: windowID, tabIDs: s.map(\.id), showsGrid: true,
                gridSessionIDs: s.map(\.id)
            )
            var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
            state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))
            XCTAssertEqual(state.gridWorkspaces[0].capacity, expectedCapacity,
                           "\(memberCount) Mitglieder → Stufe \(expectedCapacity)")
        }
    }

    func testV3MigrationAdoptsLegacySplitFractions() throws {
        let s = (0 ..< 4).map { _ in makeSession() }
        let windowID = UUID()
        let json = v3JSON(
            windowID: windowID, tabIDs: s.map(\.id), showsGrid: true,
            gridSessionIDs: s.map(\.id)
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(
            workspace: makeWorkspace(sessions: s),
            legacySplits: (column: 0.3, row: 0.7)
        )
        XCTAssertEqual(state.gridWorkspaces[0].columnFractions[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(state.gridWorkspaces[0].columnFractions[1], 0.7, accuracy: 0.0001)
        XCTAssertEqual(state.gridWorkspaces[0].rowFractions[0], 0.7, accuracy: 0.0001)
        XCTAssertEqual(state.gridWorkspaces[0].rowFractions[1], 0.3, accuracy: 0.0001)
    }

    func testV4MigrationIsIdempotent() throws {
        let s = (0 ..< 2).map { _ in makeSession() }
        let windowID = UUID()
        let json = v3JSON(
            windowID: windowID, tabIDs: s.map(\.id), showsGrid: true,
            gridSessionIDs: s.map(\.id)
        )
        var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))
        let afterFirst = state
        state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))
        XCTAssertEqual(state, afterFirst, "zweiter Lauf ist ein No-op")
        XCTAssertEqual(state.gridWorkspaces.count, 1)
    }

    func testV4EncodingRoundTripsWorkspaces() throws {
        let entity = AgentGridWorkspace(name: "Recherche", slots: [UUID(), nil], capacity: 2)
        let original = AgentUIState(gridWorkspaces: [entity])
        let decoded = try JSONDecoder().decode(
            AgentUIState.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.gridWorkspaces, original.gridWorkspaces)
        XCTAssertEqual(decoded, original)
    }

    func testLegacyV3StateWithoutGridDataDecodesToEmptyWorkspaces() throws {
        let json = """
        {"schemaVersion": 3, "openTabIDs": []}
        """
        let decoded = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.gridWorkspaces.isEmpty)
    }

    func testV3MigrationSelectsHigherCapacityStages() throws {
        for (memberCount, expectedCapacity) in [(5, 6), (7, 9)] {
            let s = (0 ..< memberCount).map { _ in makeSession() }
            let windowID = UUID()
            let json = v3JSON(
                windowID: windowID, tabIDs: s.map(\.id), showsGrid: true,
                gridSessionIDs: s.map(\.id)
            )
            var state = try JSONDecoder().decode(AgentUIState.self, from: Data(json.utf8))
            state.migrateIfNeeded(workspace: makeWorkspace(sessions: s))
            XCTAssertEqual(state.gridWorkspaces[0].capacity, expectedCapacity,
                           "\(memberCount) Mitglieder → Stufe \(expectedCapacity)")
            XCTAssertEqual(state.gridWorkspaces[0].occupiedSessionIDs, s.map(\.id))
        }
    }

    // MARK: - Kaskaden (Archiv/Delete → alle UI-Referenzen)

    func testLoadPruneUsesNonArchivedSessionsForAllUIReferences() {
        let live = makeSession()
        let archived = makeSession(status: .archived)
        let entity = AgentGridWorkspace(slots: [archived.id, live.id], capacity: 2)
        var state = AgentUIState(
            openTabIDs: [archived.id, live.id],
            pinnedSessionIDs: [archived.id],
            selectedSessionID: archived.id,
            unreadSubagentSessionIDs: [archived.id],
            gridWorkspaces: [entity]
        )
        state.prune(workspace: makeWorkspace(sessions: [live, archived]))

        XCTAssertEqual(state.openTabIDs, [live.id], "archivierte Tabs werden geräumt")
        XCTAssertTrue(state.pinnedSessionIDs.isEmpty, "archivierte Pins werden geräumt")
        XCTAssertTrue(state.unreadSubagentSessionIDs.isEmpty)
        XCTAssertEqual(state.gridWorkspaces[0].slots, [nil, live.id])
        XCTAssertNotEqual(state.selectedSessionID, archived.id)
    }

    func testRestoreArchivedSessionDoesNotResurrectOldSlots() {
        var session = makeSession(status: .archived)
        let entity = AgentGridWorkspace(slots: [session.id, nil], capacity: 2)
        var state = AgentUIState(gridWorkspaces: [entity])
        state.prune(workspace: makeWorkspace(sessions: [session]))
        XCTAssertEqual(state.gridWorkspaces[0].slots, [nil, nil], "Archiv leert den Slot")

        // Restore (Status wieder .closed) fügt NICHT automatisch wieder ein.
        session.status = .closed
        state.prune(workspace: makeWorkspace(sessions: [session]))
        XCTAssertEqual(state.gridWorkspaces[0].slots, [nil, nil],
                       "Wiederaufnahme nur über explizites Hinzufügen")
    }

    func testDeleteWorkspaceNeverDeletesSessionsOrTabs() {
        let live = makeSession()
        let entity = AgentGridWorkspace(slots: [live.id, nil], capacity: 2)
        let window = AgentChatWindowState(
            openTabIDs: [live.id],
            isPrimary: true,
            showsGrid: true,
            activeWorkspaceID: entity.id
        )
        var state = AgentUIState(
            windows: [window], primaryWindowID: window.id, gridWorkspaces: [entity]
        )
        state.gridWorkspaces.removeAll { $0.id == entity.id }
        state.prune(workspace: makeWorkspace(sessions: [live]))
        XCTAssertEqual(state.windowState(for: window.id).openTabIDs, [live.id],
                       "Tabs überleben das Entity-Löschen")
        XCTAssertNil(state.windowState(for: window.id).activeWorkspaceID)
        XCTAssertFalse(state.windowState(for: window.id).showsGrid)
    }

    func testPruneFocusFallsBackToNextThenPreviousSlot() {
        // Regel „nächster belegter Slot, sonst vorheriger" (Review-Finding:
        // pauschal „erster" war falsch). [A, B, C], Fokus B, B archiviert →
        // Fokus C (nicht A).
        let a = makeSession(); let b = makeSession(status: .archived); let c = makeSession()
        let entity = AgentGridWorkspace(slots: [a.id, b.id, c.id], capacity: 3)
        let window = AgentChatWindowState(
            openTabIDs: [a.id, b.id, c.id],
            selectedSessionID: b.id,
            isPrimary: true,
            showsGrid: true,
            activeWorkspaceID: entity.id,
            gridFocusSessionID: b.id
        )
        var state = AgentUIState(
            windows: [window], primaryWindowID: window.id, gridWorkspaces: [entity]
        )
        state.prune(workspace: makeWorkspace(sessions: [a, b, c]))
        XCTAssertEqual(state.gridWorkspaces[0].slots, [a.id, nil, c.id])
        XCTAssertEqual(state.windowState(for: window.id).selectedSessionID, c.id,
                       "nächster belegter Slot gewinnt")

        // Letzter Slot fokussiert + archiviert → vorheriger.
        let d = makeSession(); let e = makeSession(status: .archived)
        let entity2 = AgentGridWorkspace(slots: [d.id, e.id], capacity: 2)
        let window2 = AgentChatWindowState(
            openTabIDs: [d.id, e.id],
            selectedSessionID: e.id,
            isPrimary: true,
            showsGrid: true,
            activeWorkspaceID: entity2.id,
            gridFocusSessionID: e.id
        )
        var state2 = AgentUIState(
            windows: [window2], primaryWindowID: window2.id, gridWorkspaces: [entity2]
        )
        state2.prune(workspace: makeWorkspace(sessions: [d, e]))
        XCTAssertEqual(state2.windowState(for: window2.id).selectedSessionID, d.id,
                       "kein nächster → vorheriger belegter Slot")
    }

    // MARK: - Gemerkter Pane-Fokus (gridFocusSessionID)

    func testGridFocusSurvivesHiddenGridAndInvalidatesWithSlot() {
        let a = makeSession(); let b = makeSession()
        let entity = AgentGridWorkspace(slots: [a.id, b.id], capacity: 2)
        var window = AgentChatWindowState(
            openTabIDs: [a.id, b.id],
            selectedSessionID: b.id,
            isPrimary: true,
            showsGrid: false, // Einzelansicht — Referenz + Fokus bleiben
            activeWorkspaceID: entity.id,
            gridFocusSessionID: b.id
        )
        var state = AgentUIState(
            windows: [window], primaryWindowID: window.id, gridWorkspaces: [entity]
        )
        XCTAssertEqual(state.windowState(for: window.id).gridFocusSessionID, b.id)

        // Slot von b wird geleert → der gemerkte Fokus ist ungültig.
        var emptied = entity
        emptied.slots[1] = nil
        window = state.windowState(for: window.id)
        state = AgentUIState(
            windows: [window], primaryWindowID: window.id, gridWorkspaces: [emptied]
        )
        XCTAssertNil(state.windowState(for: window.id).gridFocusSessionID)
    }
}
