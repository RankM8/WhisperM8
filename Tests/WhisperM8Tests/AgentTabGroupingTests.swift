import XCTest
@testable import WhisperM8

final class AgentTabGroupingTests: XCTestCase {
    func testWorkspaceWinsBeforeProjectAndKeepsManualOrder() {
        let project = UUID()
        let workspace = UUID()
        let first = UUID()
        let second = UUID()
        let projectOnly = UUID()
        let entries = [
            AgentTabGroupingEntry(sessionID: first, projectID: project),
            AgentTabGroupingEntry(sessionID: projectOnly, projectID: project),
            AgentTabGroupingEntry(sessionID: second, projectID: project)
        ]

        let items = AgentTabGrouping.items(
            entries: entries,
            workspaceBySession: [first: workspace, second: workspace],
            enabled: true
        )

        XCTAssertEqual(items, [
            .group(key: .workspace(workspace), sessionIDs: [first, second]),
            .single(projectOnly)
        ])
    }

    func testProjectCreatesGroupOnlyFromTwoTabs() {
        let project = UUID()
        let otherProject = UUID()
        let first = UUID()
        let singleton = UUID()
        let second = UUID()
        let entries = [
            AgentTabGroupingEntry(sessionID: first, projectID: project),
            AgentTabGroupingEntry(sessionID: singleton, projectID: otherProject),
            AgentTabGroupingEntry(sessionID: second, projectID: project)
        ]

        XCTAssertEqual(
            AgentTabGrouping.items(entries: entries, workspaceBySession: [:], enabled: true),
            [
                .group(key: .project(project), sessionIDs: [first, second]),
                .single(singleton)
            ]
        )
    }

    func testDisabledGroupingReturnsExactManualOrder() {
        let project = UUID()
        let ids = [UUID(), UUID(), UUID()]
        let entries = ids.map { AgentTabGroupingEntry(sessionID: $0, projectID: project) }

        XCTAssertEqual(
            AgentTabGrouping.items(entries: entries, workspaceBySession: [:], enabled: false),
            ids.map(AgentTabGroupingItem.single)
        )
    }

    func testForeignTabSnapsBeforeWholeTargetGroup() {
        let project = UUID()
        let otherProject = UUID()
        let first = UUID()
        let second = UUID()
        let foreign = UUID()
        let items: [AgentTabGroupingItem] = [
            .group(key: .project(project), sessionIDs: [first, second]),
            .single(foreign)
        ]

        XCTAssertEqual(
            AgentTabGrouping.adjustedDropTarget(
                before: second,
                movingIDs: [foreign],
                movingKeys: [.project(otherProject)],
                items: items
            ),
            first
        )
    }

    func testSameOriginFromOtherWindowCanDropInsideGroup() {
        let project = UUID()
        let first = UUID()
        let second = UUID()
        let incoming = UUID()
        let items: [AgentTabGroupingItem] = [
            .group(key: .project(project), sessionIDs: [first, second])
        ]

        XCTAssertEqual(
            AgentTabGrouping.adjustedDropTarget(
                before: second,
                movingIDs: [incoming],
                movingKeys: [.project(project)],
                items: items
            ),
            second
        )
    }

    func testMixedSelectionNeverReturnsMovingGroupMemberAsTarget() {
        let project = UUID()
        let otherProject = UUID()
        let first = UUID()
        let second = UUID()
        let foreign = UUID()
        let after = UUID()
        let items: [AgentTabGroupingItem] = [
            .group(key: .project(project), sessionIDs: [first, second]),
            .single(after)
        ]

        XCTAssertEqual(
            AgentTabGrouping.adjustedDropTarget(
                before: second,
                movingIDs: [first, second, foreign],
                movingKeys: [.project(project), .project(otherProject)],
                items: items
            ),
            after
        )
    }

    func testMemberCanStillReorderInsideOwnGroup() {
        let project = UUID()
        let first = UUID()
        let second = UUID()
        let items: [AgentTabGroupingItem] = [
            .group(key: .project(project), sessionIDs: [first, second])
        ]

        XCTAssertEqual(
            AgentTabGrouping.adjustedDropTarget(
                before: first,
                movingIDs: [second],
                movingKeys: [.project(project)],
                items: items
            ),
            first
        )
    }
}
