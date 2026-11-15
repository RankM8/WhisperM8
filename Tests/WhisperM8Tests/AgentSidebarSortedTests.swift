import XCTest
@testable import WhisperM8

/// Seitenleiste A (WM8-80): laufende Chats vor gestoppten, Workspace-Chats
/// nur als Hinweis, Projekte mit Laufendem zuerst. Die ersten Tests halten
/// fest, was der Umbau nicht ändern darf.
final class AgentSidebarSortedTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func project(_ name: String, sortIndex: Int? = nil) -> AgentProject {
        AgentProject(name: name, path: "/tmp/\(name)", createdManually: true, sortIndex: sortIndex)
    }

    private func chat(
        _ title: String,
        in project: AgentProject,
        sortIndex: Int? = nil,
        lastActivity: TimeInterval = 999_000
    ) -> AgentChatSession {
        AgentChatSession(
            provider: .claude,
            projectID: project.id,
            title: title,
            status: .closed,
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: 500),
            lastActivityAt: Date(timeIntervalSince1970: lastActivity),
            createdManually: true
        )
    }

    private func filter(
        _ scope: SidebarScope = .all,
        running: Set<UUID> = [],
        openTabs: Set<UUID> = []
    ) -> SidebarScopeFilter {
        SidebarScopeFilter(
            scope: scope,
            runningSessionIDs: running,
            openTabIDs: openTabs,
            now: now,
            recentWindow: SidebarScopeFilter.defaultRecentWindow
        )
    }

    private func snapshot(
        _ workspace: AgentWorkspace,
        scope: SidebarScopeFilter,
        pinned: [UUID] = [],
        query: String = "",
        selected: UUID? = nil
    ) -> AgentSidebarSnapshot {
        AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: pinned,
            scope: scope,
            layout: .grouped,
            query: query,
            flatVisibleLimit: 50,
            selectedSessionID: selected
        )
    }

    // MARK: - Bestand, der bleiben muss

    func testManualChatOrderHoldsWhenNothingRuns() {
        let repo = project("repo")
        let c = chat("C", in: repo, sortIndex: 2)
        let a = chat("A", in: repo, sortIndex: 0)
        let b = chat("B", in: repo, sortIndex: 1)
        let result = snapshot(AgentWorkspace(projects: [repo], sessions: [c, a, b]), scope: filter())
        XCTAssertEqual(result.sessionsByProject[repo.id]?.map(\.title), ["A", "B", "C"])
    }

    func testManualProjectOrderHoldsWhenNothingRuns() {
        let second = project("zwei", sortIndex: 1)
        let first = project("eins", sortIndex: 0)
        let third = project("drei", sortIndex: 2)
        let sessions = [chat("x", in: second), chat("y", in: first), chat("z", in: third)]
        let result = snapshot(AgentWorkspace(projects: [second, first, third], sessions: sessions), scope: filter())
        XCTAssertEqual(result.visibleProjects.map(\.name), ["eins", "zwei", "drei"])
    }

    func testPinnedAndArchivedChatsStayOutOfProjectGroups() {
        let repo = project("repo")
        let pinned = chat("Pin", in: repo)
        var archived = chat("Archiv", in: repo)
        archived.status = .archived
        let normal = chat("Normal", in: repo)
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [pinned, archived, normal]),
            scope: filter(running: [pinned.id]),
            pinned: [pinned.id]
        )
        XCTAssertEqual(result.sessionsByProject[repo.id]?.map(\.title), ["Normal"])
        XCTAssertEqual(result.visiblePinned.map(\.title), ["Pin"])
    }

    func testRunningParentOfSubagentStaysInItsProject() {
        let repo = project("repo")
        var parent = chat("Eltern", in: repo)
        parent.externalSessionID = "ext-parent"
        var child = AgentChatSession(provider: .codex, projectID: repo.id, title: "Kind", createdManually: true)
        child.subagentParentSessionID = "ext-parent"
        child.kind = .subagentJob
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [parent, child]),
            scope: filter(.active, running: [child.id])
        )
        XCTAssertEqual(result.sessionsByProject[repo.id]?.map(\.title), ["Eltern"])
        XCTAssertEqual(result.subagentChildrenByParent[parent.id]?.map(\.title), ["Kind"])
    }
}
