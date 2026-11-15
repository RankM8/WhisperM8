import XCTest
@testable import WhisperM8

/// WM8-101: Eine Projektgruppe sieht nur die Teile der fensterweiten Mengen,
/// die ihre eigenen Chats betreffen. Sonst gilt jede der vielen Gruppen bei
/// jedem Auswahlwechsel als geändert und wird neu ausgewertet.
final class SidebarProjectGroupInputsTests: XCTestCase {
    private let project = AgentProject(name: "whisperm8", path: "/Users/demo/repos/whisperm8", color: "#3D6DF2",
                                       lastBranch: "main", createdManually: true)

    private func chat(_ title: String) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: project.id, title: title)
    }

    private func narrowed(
        _ blocks: SidebarProjectBlocks,
        selected: UUID? = nil,
        openTabs: Set<UUID> = [],
        children: [UUID: [AgentChatSession]] = [:],
        unread: Set<UUID> = []
    ) -> SidebarProjectGroupInputs {
        SidebarProjectGroupInputs.narrowed(
            blocks: blocks, selectedSessionID: selected, multiSelection: openTabs, openTabIDs: openTabs,
            autoRenamingSessionIDs: [], missingTranscriptSessionIDs: [], subagentChildrenByParent: children,
            workingSubagentSessionIDs: [], erroredSubagentSessionIDs: [], unreadSubagentSessionIDs: unread,
            expandedSubagentParentIDs: [])
    }

    func testSelectionOutsideTheGroupIsDropped() {
        let own = chat("eigener")
        let blocks = SidebarProjectBlocks(stopped: [own])
        XCTAssertNil(narrowed(blocks, selected: UUID()).selectedSessionID)
        XCTAssertEqual(narrowed(blocks, selected: own.id).selectedSessionID, own.id)
    }

    func testSelectionInAWorkspaceHintStays() {
        let inWorkspace = UUID()
        let blocks = SidebarProjectBlocks(
            workspaceHints: [SidebarWorkspaceHint(workspaceID: UUID(), name: "WM8 Aktiv", sessionIDs: [inWorkspace])])
        XCTAssertEqual(narrowed(blocks, selected: inWorkspace).selectedSessionID, inWorkspace)
    }

    func testSubagentChildOfARowStays() {
        let parent = chat("Eltern")
        let child = chat("Kind")
        let foreignParent = UUID()
        let blocks = SidebarProjectBlocks(running: [parent])
        let inputs = narrowed(blocks, selected: child.id,
                              children: [parent.id: [child], foreignParent: [chat("fremd")]],
                              unread: [child.id, UUID()])
        XCTAssertEqual(inputs.selectedSessionID, child.id)
        XCTAssertEqual(Array(inputs.subagentChildrenByParent.keys), [parent.id], "Kinder fremder Zeilen fallen weg")
        XCTAssertEqual(inputs.unreadSubagentSessionIDs, [child.id])
    }

    func testSetsAreCutToTheGroup() {
        let own = chat("eigener")
        let blocks = SidebarProjectBlocks(running: [own])
        let inputs = narrowed(blocks, openTabs: [own.id, UUID(), UUID()])
        XCTAssertEqual(inputs.openTabIDs, [own.id])
        XCTAssertEqual(inputs.multiSelection, [own.id])
    }

    /// Der eigentliche Zweck: Ein Wechsel zwischen zwei Chats anderer Projekte
    /// lässt den Schlüssel dieser Gruppe gleich, sie wird übersprungen.
    func testUnrelatedSelectionChangeKeepsTheKey() {
        let blocks = SidebarProjectBlocks(stopped: [chat("eigener")])
        func key(selected: UUID?) -> SidebarProjectGroupKey {
            SidebarProjectGroupKey(
                project: project, blocks: blocks, inputs: narrowed(blocks, selected: selected), isExpanded: true,
                worktreeProjects: [], activeSessionIDs: [], isWorkspaceOpen: false, workspaceOccupancyLabel: nil,
                sidebarScope: .all, isSearching: false, stoppedFoldOverride: nil, menu: Self.menu())
        }
        XCTAssertEqual(key(selected: UUID()), key(selected: UUID()))
        XCTAssertNotEqual(key(selected: nil), key(selected: blocks.rows[0].id))
    }

    // MARK: - Kontextmenü (Auflage aus dem Gegenlesen)

    private static let groupSession = UUID()

    static func menu(
        multiSelection: Set<UUID> = [],
        pinned: [UUID] = [],
        workspaces: [AgentGridWorkspace] = [],
        visibleGrid: AgentGridWorkspace? = nil,
        claude: [ClaudeAccountProfile] = [],
        gpt: [GPTAccountProfile] = [],
        bulkMove: Bool = true,
        gptMenu: Bool = true,
        pendingSwitches: [UUID: String] = [:],
        undoable: Bool = false,
        pendingLifecycle: Set<UUID> = [],
        takenOver: Set<UUID> = [],
        stoppable: Set<UUID> = []
    ) -> SidebarGroupMenuState {
        SidebarGroupMenuState.make(
            groupSessionIDs: [groupSession], multiSelection: multiSelection, pinnedSessionIDs: pinned,
            gridWorkspaces: workspaces, visibleGrid: visibleGrid, claudeProfiles: claude, gptProfiles: gpt,
            accountBulkMoveEnabled: bulkMove, gptAccountMenuEnabled: gptMenu, pendingAccountSwitches: pendingSwitches,
            hasUndoableAccountMove: undoable, pendingLifecycle: pendingLifecycle,
            takenOverJobs: takenOver, stoppableJobs: stoppable)
    }

    private func assertChanges(_ changed: SidebarGroupMenuState, _ what: String, line: UInt = #line) {
        XCTAssertNotEqual(Self.menu(), changed, "\(what) muss den Schlüssel ändern", line: line)
    }

    func testMultiSelectionCountChangesTheKey() {
        // Auswahl in anderen Gruppen: „N Tabs schließen“ zählt sie mit.
        let a = UUID(), b = UUID()
        XCTAssertNotEqual(Self.menu(multiSelection: [Self.groupSession, a]),
                          Self.menu(multiSelection: [Self.groupSession, a, b]))
    }

    func testPinStateOfTheSelectionChangesTheKey() {
        let other = UUID()
        let selection: Set<UUID> = [Self.groupSession, other]
        XCTAssertNotEqual(Self.menu(multiSelection: selection),
                          Self.menu(multiSelection: selection, pinned: [other]))
        XCTAssertEqual(Self.menu(), Self.menu(pinned: [other]), "ohne Auswahl zählt der Pin anderer Chats nicht")
    }

    func testWorkspaceListChangesTheKey() {
        let workspace = AgentGridWorkspace(name: "WM8 Aktiv", slots: [nil, nil], capacity: 2)
        assertChanges(Self.menu(workspaces: [workspace]), "neuer Workspace")
        var renamed = workspace
        renamed.name = "WM8 Wartet"
        XCTAssertNotEqual(Self.menu(workspaces: [workspace]), Self.menu(workspaces: [renamed]), "umbenannt")
        var filled = workspace
        filled.slots = [Self.groupSession, nil]
        XCTAssertNotEqual(Self.menu(workspaces: [workspace]), Self.menu(workspaces: [filled]), "Belegung (Haken)")
    }

    func testVisibleGridChangesTheKey() {
        assertChanges(Self.menu(visibleGrid: AgentGridWorkspace(name: "Raster", slots: [nil], capacity: 1)),
                      "sichtbares Raster")
    }

    func testAccountsChangeTheKey() {
        let dir = URL(fileURLWithPath: "/tmp/demo")
        assertChanges(Self.menu(claude: [ClaudeAccountProfile(name: "zweit", configDir: dir)]), "Claude-Konto")
        assertChanges(Self.menu(gpt: [GPTAccountProfile(name: "zweit", configDir: dir)]), "GPT-Konto")
        assertChanges(Self.menu(bulkMove: false), "Sammel-Umzug")
        assertChanges(Self.menu(gptMenu: false), "GPT-Backend oder GPT-Konto-Profile aus")
        assertChanges(Self.menu(pendingSwitches: [Self.groupSession: "zweit"]), "vorgemerkter Kontowechsel")
        assertChanges(Self.menu(undoable: true), "Rückgängig")
    }

    func testRuntimeStateOfGroupChatsChangesTheKey() {
        assertChanges(Self.menu(pendingLifecycle: [Self.groupSession]), "Hintergrund-Aktion läuft")
        assertChanges(Self.menu(takenOver: [Self.groupSession]), "Job übernommen")
        assertChanges(Self.menu(stoppable: [Self.groupSession]), "Job stoppbar")
        XCTAssertEqual(Self.menu(), Self.menu(pendingLifecycle: [UUID()], takenOver: [UUID()], stoppable: [UUID()]),
                       "Zustand fremder Chats lässt die Gruppe in Ruhe")
    }
}
