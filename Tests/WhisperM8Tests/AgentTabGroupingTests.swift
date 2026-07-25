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

}
