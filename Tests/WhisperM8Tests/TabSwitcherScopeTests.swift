import Foundation
import XCTest
@testable import WhisperM8

/// Umfang und Reihenfolge des Ctrl+Tab-Switchers (Slice S1,
/// docs/plans/tab-switcher-workspace.md): Grid (A), maximierter Workspace-
/// Chat (B), Projekt-Liste (C) — und wann es keinen Switcher gibt.
final class TabSwitcherScopeTests: XCTestCase {
    private let projectX = UUID()
    private let projectY = UUID()
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()

    private func tab(_ id: UUID, _ project: UUID, archived: Bool = false) -> TabSwitcherScope.Tab {
        TabSwitcherScope.Tab(id: id, projectID: project, isArchived: archived)
    }

    private func workspace(_ slots: [UUID?], capacity: Int) -> AgentGridWorkspace {
        AgentGridWorkspace(slots: slots, capacity: capacity)
    }

    // MARK: - A: Grid sichtbar

    func testGridOrderFollowsSlotIndexNotTabOrder() {
        let entity = workspace([c, a, b, nil], capacity: 4)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectY), tab(c, projectX)]
        )
        XCTAssertEqual(scope, .grid(order: [c, a, b]))
    }

    func testGridSkipsEmptySlots() {
        let entity = workspace([nil, a, nil, b], capacity: 4)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX)]
        )
        XCTAssertEqual(scope?.order, [a, b])
    }

    func testGridSkipsTakeoverPlaceholders() {
        // c ist Slot-Mitglied, aber Tab eines anderen Fensters (bzw.
        // geschlossen) → Übernahme-Platzhalter, nicht fokussierbar.
        let entity = workspace([a, c, b], capacity: 3)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX)]
        )
        XCTAssertEqual(scope, .grid(order: [a, b]))
    }

    func testGridIgnoresTabsOutsideWorkspace() {
        let entity = workspace([a, b], capacity: 2)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(d, projectX), tab(a, projectX), tab(c, projectX), tab(b, projectX)]
        )
        XCTAssertEqual(scope, .grid(order: [a, b]))
    }

    func testGridWithoutSelectionStillResolves() {
        let entity = workspace([a, b], capacity: 2)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: nil,
            openTabs: [tab(a, projectX), tab(b, projectX)]
        )
        XCTAssertEqual(scope, .grid(order: [a, b]))
    }

    func testGridWithSingleFocusableSlotIsNil() {
        // Kein Rückfall auf die Projekt-Liste — weniger als 2 Ziele heißt
        // kein Switcher.
        let entity = workspace([a, nil, c], capacity: 3)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX)]
        )
        XCTAssertNil(scope)
    }

    func testGridSkipsArchivedSessions() {
        let entity = workspace([a, b, c], capacity: 3)
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX, archived: true), tab(c, projectX)]
        )
        XCTAssertEqual(scope, .grid(order: [a, c]))
    }

    func testShowsGridWithoutWorkspaceFallsBackToProject() {
        // `showsGrid` ohne gültige Referenz rendert kein Grid (isGridActive).
        let scope = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: nil,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX)]
        )
        XCTAssertEqual(scope, .project(order: [a, b]))
    }

    // MARK: - B: maximierter Chat im referenzierten Workspace

    func testMaximizedWorkspaceChatUsesSlotOrder() {
        let entity = workspace([b, nil, a, c], capacity: 4)
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectY), tab(c, projectX), tab(d, projectX)]
        )
        XCTAssertEqual(scope, .workspaceMap(workspaceID: entity.id, order: [b, a, c]))
    }

    func testMaximizedSkipsTakeoverPlaceholders() {
        let entity = workspace([a, b, c], capacity: 3)
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(c, projectX)]
        )
        XCTAssertEqual(scope, .workspaceMap(workspaceID: entity.id, order: [a, c]))
    }

    // MARK: - C: Einzelansicht ohne Workspace-Bezug

    func testProjectScopeKeepsTabOrderAndFiltersProject() {
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: c,
            openTabs: [tab(a, projectX), tab(b, projectY), tab(c, projectX), tab(d, projectX)]
        )
        XCTAssertEqual(scope, .project(order: [a, c, d]))
    }

    func testProjectWithSingleTabIsNil() {
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: b,
            openTabs: [tab(a, projectX), tab(b, projectY), tab(c, projectX)]
        )
        XCTAssertNil(scope)
    }

    func testProjectSkipsArchivedSessions() {
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX, archived: true), tab(c, projectX)]
        )
        XCTAssertEqual(scope, .project(order: [a, c]))
    }

    func testProjectOnlyArchivedSiblingIsNil() {
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX, archived: true)]
        )
        XCTAssertNil(scope)
    }

    func testArchivedSelectionHasNoProjectScope() {
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: a,
            openTabs: [tab(a, projectX, archived: true), tab(b, projectX), tab(c, projectX)]
        )
        XCTAssertNil(scope)
    }

    func testNoSelectionWithoutGridIsNil() {
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: nil,
            openTabs: [tab(a, projectX), tab(b, projectX)]
        )
        XCTAssertNil(scope)
    }

    func testSelectedChatOutsideReferencedWorkspaceUsesProject() {
        // Fenster referenziert einen Workspace, der selektierte Chat liegt
        // aber nicht darin → C, nicht B.
        let entity = workspace([b, d], capacity: 2)
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX), tab(c, projectX), tab(d, projectY)]
        )
        XCTAssertEqual(scope, .project(order: [a, b, c]))
    }

    // MARK: - Chat in zwei Workspaces

    func testChatInTwoWorkspacesFollowsReferencedWorkspace() {
        // a liegt in beiden Workspaces; maßgeblich ist nur der, den das
        // Fenster referenziert.
        let first = workspace([a, b], capacity: 2)
        let second = workspace([c, a], capacity: 2)
        let tabs = [tab(a, projectX), tab(b, projectY), tab(c, projectY)]

        XCTAssertEqual(
            TabSwitcherScope.resolve(
                showsGrid: false, activeWorkspace: first, selectedSessionID: a, openTabs: tabs
            ),
            .workspaceMap(workspaceID: first.id, order: [a, b])
        )
        XCTAssertEqual(
            TabSwitcherScope.resolve(
                showsGrid: false, activeWorkspace: second, selectedSessionID: a, openTabs: tabs
            ),
            .workspaceMap(workspaceID: second.id, order: [c, a])
        )
    }

    func testChatInWorkspaceButWindowReferencesNoneUsesProject() {
        // Workspace-Mitgliedschaft allein zählt nicht — ohne Referenz des
        // Fensters ist das Situation C.
        let scope = TabSwitcherScope.resolve(
            showsGrid: false,
            activeWorkspace: nil,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectY), tab(c, projectX)]
        )
        XCTAssertEqual(scope, .project(order: [a, c]))
    }

    // MARK: - Zusammenspiel mit TabSwitcherModel

    func testScopeOrderDrivesSwitcherModel() {
        let entity = workspace([c, a, b], capacity: 3)
        let order = TabSwitcherScope.resolve(
            showsGrid: true,
            activeWorkspace: entity,
            selectedSessionID: a,
            openTabs: [tab(a, projectX), tab(b, projectX), tab(c, projectX)]
        )?.order ?? []
        // Leserichtung: von a (Slot 1) vor → b (Slot 2), zurück → c (Slot 0).
        XCTAssertEqual(TabSwitcherModel.begin(order: order, current: a, direction: 1)?.highlightedID, b)
        XCTAssertEqual(TabSwitcherModel.begin(order: order, current: a, direction: -1)?.highlightedID, c)
    }
}
