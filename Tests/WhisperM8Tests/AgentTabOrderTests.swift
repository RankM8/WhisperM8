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
