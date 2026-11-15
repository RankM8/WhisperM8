import XCTest
@testable import WhisperM8

/// Reihenfolge, Sichtbarkeit und Ziehen-Umfang der Tab-Leiste. Hält das
/// Verhalten fest, bevor die Leiste für WM8-80 umgebaut wird.
final class AgentTabOrderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
    private let ws = UUID(), projectX = UUID(), projectY = UUID()

    private var items: [AgentTabGroupingItem] {
        [.single(a), .group(key: .workspace(ws), sessionIDs: [b, c]), .single(d)]
    }

    func testOrderFlattensGroupsInPlace() {
        XCTAssertEqual(AgentTabOrder.orderIDs(of: items), [a, b, c, d])
        XCTAssertEqual(AgentTabOrder.orderIDs(of: []), [])
    }

    func testExpandedGroupShowsAllMembers() {
        XCTAssertEqual(
            AgentTabOrder.visibleOrderIDs(items: items, collapsedKeys: [], selectedID: a),
            [a, b, c, d]
        )
    }

    func testCollapsedGroupShowsOnlyTheActiveMember() {
        XCTAssertEqual(
            AgentTabOrder.visibleOrderIDs(items: items, collapsedKeys: [.workspace(ws)], selectedID: c),
            [a, c, d]
        )
    }

    func testCollapsedGroupWithoutActiveMemberShowsNothing() {
        XCTAssertEqual(
            AgentTabOrder.visibleOrderIDs(items: items, collapsedKeys: [.workspace(ws)], selectedID: a),
            [a, d]
        )
        XCTAssertEqual(
            AgentTabOrder.visibleMemberIDs([b, c], collapsed: true, selectedID: nil),
            []
        )
    }

    // MARK: - Ziehen

    private func key(_ id: UUID) -> AgentTabGroupingKey? {
        switch id {
        case a, b: return .project(projectX)
        case c, d: return .project(projectY)
        default: return nil
        }
    }

    func testGroupChipDragTakesWholeGroupInVisibleOrder() {
        let result = AgentTabOrder.dragGroup(
            droppedID: c, groupMemberIDs: [c, b], sourceOrder: [a, b, c, d],
            sourceSelection: [], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [b, c])
    }

    func testGroupChipDragKeepsMembersWhenNoneAreOpen() {
        let result = AgentTabOrder.dragGroup(
            droppedID: c, groupMemberIDs: [c, b], sourceOrder: [a, d],
            sourceSelection: [], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [c, b])
    }

    func testSingleDragWithoutSelection() {
        let result = AgentTabOrder.dragGroup(
            droppedID: b, groupMemberIDs: nil, sourceOrder: [a, b, c],
            sourceSelection: [], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [b])
    }

    func testDraggedTabOutsideSelectionMovesAlone() {
        let result = AgentTabOrder.dragGroup(
            droppedID: c, groupMemberIDs: nil, sourceOrder: [a, b, c],
            sourceSelection: [a, b], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [c])
    }

    func testSelectionOfSameOriginMovesTogetherInVisibleOrder() {
        let result = AgentTabOrder.dragGroup(
            droppedID: a, groupMemberIDs: nil, sourceOrder: [b, d, a],
            sourceSelection: [a, b], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [b, a])
    }

    func testMixedOriginSelectionMovesOnlyDraggedTabWhenGrouped() {
        let result = AgentTabOrder.dragGroup(
            droppedID: a, groupMemberIDs: nil, sourceOrder: [a, b, c],
            sourceSelection: [a, c], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [a])
    }

    func testMixedOriginSelectionMovesTogetherWhenGroupingOff() {
        let result = AgentTabOrder.dragGroup(
            droppedID: a, groupMemberIDs: nil, sourceOrder: [a, b, c],
            sourceSelection: [a, c], groupingEnabled: false, keyOf: key)
        XCTAssertEqual(result, [a, c])
    }

    func testSidebarSelectionNotYetOpenStaysInDragGroup() {
        let result = AgentTabOrder.dragGroup(
            droppedID: b, groupMemberIDs: nil, sourceOrder: [a],
            sourceSelection: [a, b], groupingEnabled: true, keyOf: key)
        XCTAssertEqual(result, [a, b])
    }
}

/// Herkunft eines Tabs (Vic zu WM8-80/WM8-102): Gruppe, Workspace-Vorrang,
/// Einrasten bei gemischter Herkunft, Umschalter-Umfang.
final class AgentTabOriginTests: XCTestCase {
    private let main = UUID(), kurse = UUID(), other = UUID()
    private let mainTab = UUID(), kurseTab = UUID(), otherTab = UUID()
    private var parents: [UUID: UUID] { [kurse: main] }

    func testWorktreeTabJoinsMainProjectGroup() {
        let entries = [
            AgentTabOrder.groupingEntry(sessionID: mainTab, projectID: main, projectParents: parents),
            AgentTabOrder.groupingEntry(sessionID: kurseTab, projectID: kurse, projectParents: parents),
            AgentTabOrder.groupingEntry(sessionID: otherTab, projectID: other, projectParents: parents),
        ]
        let items = AgentTabGrouping.items(entries: entries, workspaceBySession: [:], enabled: true)
        XCTAssertEqual(items, [.group(key: .project(main), sessionIDs: [mainTab, kurseTab]), .single(otherTab)])
    }

    func testWorkspaceStillWinsOverProject() {
        let ws = UUID()
        let entry = AgentTabOrder.groupingEntry(sessionID: kurseTab, projectID: kurse, projectParents: parents)
        XCTAssertEqual(AgentTabGrouping.key(for: entry, workspaceBySession: [kurseTab: ws]), .workspace(ws))
        XCTAssertEqual(AgentTabGrouping.key(for: entry, workspaceBySession: [:]), .project(main))
    }

    func testFirstCuratedWorkspaceWinsAndProjectViewsDoNotCount() {
        let projectView = AgentGridWorkspace(name: "P", slots: [mainTab, kurseTab], sourceProjectID: main)
        let first = AgentGridWorkspace(name: "A", slots: [kurseTab, nil])
        let second = AgentGridWorkspace(name: "B", slots: [kurseTab, otherTab])
        let map = AgentTabOrder.workspaceBySession(gridWorkspaces: [projectView, first, second])
        XCTAssertEqual(map[kurseTab], first.id, "erster Raster-Workspace in gespeicherter Reihenfolge")
        XCTAssertEqual(map[otherTab], second.id)
        XCTAssertNil(map[mainTab], "Projekt-Ansicht zählt nicht")
    }

    func testMixedOriginHasNoTargetCluster() {
        let keys: [UUID: AgentTabGroupingKey] = [mainTab: .project(main), kurseTab: .project(main), otherTab: .project(other)]
        XCTAssertEqual(AgentTabOrder.movingOrigin([mainTab, kurseTab], keyOf: { keys[$0] }), .project(main))
        XCTAssertNil(AgentTabOrder.movingOrigin([mainTab, otherTab], keyOf: { keys[$0] }))
        XCTAssertNil(AgentTabOrder.movingOrigin([UUID()], keyOf: { keys[$0] }), "ohne Herkunft kein Cluster")
    }

    func testSwitcherProjectScopeSpansWorktrees() {
        let sessions = [
            AgentChatSession(id: mainTab, provider: .claude, projectID: main, title: "a"),
            AgentChatSession(id: kurseTab, provider: .claude, projectID: kurse, title: "b"),
            AgentChatSession(id: otherTab, provider: .claude, projectID: other, title: "c"),
        ]
        let scope = TabSwitcherScope.resolve(
            showsGrid: false, activeWorkspace: nil, selectedSessionID: kurseTab,
            openTabs: TabSwitcherScope.tabs(from: sessions, projectParents: parents))
        XCTAssertEqual(scope, .project(order: [mainTab, kurseTab]))
    }

    func testPickerListsWorktreesUnderTheirMainProject() {
        let a = AgentProject(id: main, name: "akquise-ai", path: "/r/akquise-ai", createdManually: true)
        let tim = AgentProject(name: "akquise-ai-tim", path: "/r/akquise-ai-tim", createdManually: true)
        let k = AgentProject(id: kurse, name: "akquise-ai-kurse", path: "/r/akquise-ai-kurse", createdManually: true)
        let b = AgentProject(id: other, name: "buchhaltung", path: "/r/buchhaltung", createdManually: true)
        let order = AgentProjectDisplay.pickerOrder(
            mainProjects: [a, b], allProjects: [tim, a, b, k], parents: [kurse: main, tim.id: main])
        XCTAssertEqual(order.map(\.name), ["akquise-ai", "akquise-ai-kurse", "akquise-ai-tim", "buchhaltung"])
    }
}
