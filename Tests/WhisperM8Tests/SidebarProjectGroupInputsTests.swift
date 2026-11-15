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
                sidebarScope: .all, isSearching: false, stoppedFoldOverride: nil)
        }
        XCTAssertEqual(key(selected: UUID()), key(selected: UUID()))
        XCTAssertNotEqual(key(selected: nil), key(selected: blocks.rows[0].id))
    }
}
