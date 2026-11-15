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
        selected: UUID? = nil,
        workspaces: [AgentGridWorkspace] = []
    ) -> AgentSidebarSnapshot {
        AgentSidebarModelBuilder.snapshot(
            workspace: workspace,
            pinnedSessionIDs: pinned,
            scope: scope,
            layout: .grouped,
            query: query,
            flatVisibleLimit: 50,
            selectedSessionID: selected,
            gridWorkspaces: workspaces
        )
    }

    private func gridWorkspace(_ name: String, slots: [UUID?], sourceProjectID: UUID? = nil) -> AgentGridWorkspace {
        var entity = AgentGridWorkspace(name: name, slots: slots, capacity: 4)
        entity.sourceProjectID = sourceProjectID
        return entity
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

    // MARK: - Seitenleiste A

    func testRunningChatsComeBeforeStoppedAndKeepManualOrderInBothBlocks() {
        let repo = project("repo")
        let s1 = chat("S1", in: repo, sortIndex: 0)
        let r1 = chat("R1", in: repo, sortIndex: 1)
        let s2 = chat("S2", in: repo, sortIndex: 2)
        let r2 = chat("R2", in: repo, sortIndex: 3)
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [s1, r1, s2, r2]),
            scope: filter(running: [r1.id, r2.id])
        )
        let blocks = result.projectBlocks[repo.id]
        XCTAssertEqual(blocks?.running.map(\.title), ["R1", "R2"])
        XCTAssertEqual(blocks?.stopped.map(\.title), ["S1", "S2"])
        XCTAssertEqual(result.sessionsByProject[repo.id]?.map(\.title), ["R1", "R2", "S1", "S2"])
        XCTAssertEqual(blocks?.hasRunning, true)
    }

    func testRunningSubagentMakesItsParentRun() {
        let repo = project("repo")
        let stopped = chat("Gestoppt", in: repo, sortIndex: 0)
        var parent = chat("Eltern", in: repo, sortIndex: 1)
        parent.externalSessionID = "ext-parent"
        var child = AgentChatSession(provider: .codex, projectID: repo.id, title: "Kind", createdManually: true)
        child.subagentParentSessionID = "ext-parent"
        child.kind = .subagentJob
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [stopped, parent, child]),
            scope: filter(running: [child.id])
        )
        XCTAssertEqual(result.projectBlocks[repo.id]?.running.map(\.title), ["Eltern"])
    }

    func testWorkspaceChatsBecomeOneHintInSlotOrder() {
        let repo = project("repo")
        let a = chat("A", in: repo, sortIndex: 0)
        let b = chat("B", in: repo, sortIndex: 1)
        let solo = chat("Solo", in: repo, sortIndex: 2)
        let entity = gridWorkspace("WM8 Aktiv", slots: [b.id, nil, a.id])
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [a, b, solo]),
            scope: filter(running: [a.id]),
            workspaces: [entity]
        )
        let blocks = result.projectBlocks[repo.id]
        XCTAssertEqual(blocks?.workspaceHints, [
            SidebarWorkspaceHint(workspaceID: entity.id, name: "WM8 Aktiv", sessionIDs: [b.id, a.id])
        ])
        XCTAssertEqual(result.sessionsByProject[repo.id]?.map(\.title), ["Solo"], "keine Doppelung")
        XCTAssertEqual(result.chatCount, 1)
        XCTAssertEqual(blocks?.hasRunning, true, "ein laufender Workspace-Chat zählt fürs Projekt")
    }

    func testChatInTwoWorkspacesPointsToTheFirstAndProjectViewsDoNotCount() {
        let repo = project("repo")
        let a = chat("A", in: repo)
        let projectView = gridWorkspace("Projekt-Ansicht", slots: [a.id], sourceProjectID: repo.id)
        let first = gridWorkspace("Erster", slots: [a.id])
        let second = gridWorkspace("Zweiter", slots: [a.id])
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [a]),
            scope: filter(),
            workspaces: [projectView, first, second]
        )
        XCTAssertEqual(result.projectBlocks[repo.id]?.workspaceHints.map(\.name), ["Erster"])
    }

    func testProjectWhoseChatsAllSitInAWorkspaceStaysVisibleInActiveScope() {
        let repo = project("repo")
        let a = chat("A", in: repo)
        let entity = gridWorkspace("W", slots: [a.id])
        let result = snapshot(
            AgentWorkspace(projects: [repo], sessions: [a]),
            scope: filter(.active, running: [a.id]),
            workspaces: [entity]
        )
        XCTAssertEqual(result.visibleProjects, [repo])
        XCTAssertEqual(result.sessionsByProject[repo.id], [])
        XCTAssertEqual(result.projectBlocks[repo.id]?.workspaceHints.count, 1)
    }

    func testProjectsWithRunningChatsComeFirstAndKeepManualOrder() {
        let calmFirst = project("ruhig-1", sortIndex: 0)
        let liveSecond = project("läuft-2", sortIndex: 1)
        let calmThird = project("ruhig-3", sortIndex: 2)
        let liveFourth = project("läuft-4", sortIndex: 3)
        let r2 = chat("r2", in: liveSecond)
        let r4 = chat("r4", in: liveFourth)
        let sessions = [chat("x", in: calmFirst), r2, chat("y", in: calmThird), r4]
        let result = snapshot(
            AgentWorkspace(projects: [calmFirst, liveSecond, calmThird, liveFourth], sessions: sessions),
            scope: filter(running: [r2.id, r4.id])
        )
        XCTAssertEqual(result.visibleProjects.map(\.name), ["läuft-2", "läuft-4", "ruhig-1", "ruhig-3"])
        XCTAssertEqual(result.firstCalmProjectIndex, 2)
    }

    func testNoSeparatorWhenOnlyOneProjectBlockExists() {
        let a = project("a", sortIndex: 0)
        let b = project("b", sortIndex: 1)
        let result = snapshot(
            AgentWorkspace(projects: [a, b], sessions: [chat("x", in: a), chat("y", in: b)]),
            scope: filter()
        )
        XCTAssertNil(result.firstCalmProjectIndex)
    }

    func testSearchStillFindsProjectThroughAChatThatSitsInAWorkspace() {
        let repo = project("repo")
        let other = project("anders")
        let hit = chat("Treffer", in: repo)
        let entity = gridWorkspace("W", slots: [hit.id])
        let result = snapshot(
            AgentWorkspace(projects: [repo, other], sessions: [hit, chat("x", in: other)]),
            scope: filter(),
            query: "Treffer",
            workspaces: [entity]
        )
        XCTAssertEqual(result.visibleProjects, [repo])
    }

    func testWorktreeChatsSortIntoTheMainProjectBlocks() {
        let main = project("akquise-ai")
        var worktree = AgentProject(name: "akquise-ai-kurse", path: "/tmp/akquise-ai-kurse", createdManually: true)
        worktree.parentProjectID = main.id
        let mainChat = chat("Haupt", in: main, sortIndex: 0)
        let worktreeChat = chat("Kurse", in: worktree, sortIndex: 1)
        let result = snapshot(
            AgentWorkspace(projects: [main, worktree], sessions: [mainChat, worktreeChat]),
            scope: filter(running: [worktreeChat.id])
        )
        XCTAssertEqual(result.visibleProjects, [main])
        XCTAssertEqual(result.sessionsByProject[main.id]?.map(\.title), ["Kurse", "Haupt"])
    }

    func testStoppedFoldIsClosedOnlyUnderActiveUntilClicked() {
        func open(_ scope: SidebarScope, _ override: Bool? = nil, search: Bool = false, selection: Bool = false) -> Bool {
            AgentSidebarSorting.isStoppedFoldOpen(
                scope: scope, override: override, isSearching: search, containsSelection: selection)
        }
        XCTAssertFalse(open(.active))
        XCTAssertTrue(open(.recent))
        XCTAssertTrue(open(.all))
        XCTAssertTrue(open(.active, true))
        XCTAssertFalse(open(.all, false))
        XCTAssertTrue(open(.active, false, search: true), "Suche überstimmt das Zuklappen")
        XCTAssertTrue(open(.active, false, selection: true), "gewählter Chat bleibt sichtbar")
    }

    func testControllerListFollowsRunningThenStoppedAndRespectsTheFold() {
        let repo = project("repo")
        let s1 = chat("S1", in: repo, sortIndex: 0)
        let r1 = chat("R1", in: repo, sortIndex: 1)
        let s2 = chat("S2", in: repo, sortIndex: 2)
        let blocks = AgentSidebarSorting.blocks(
            sortedSessions: [s1, r1, s2], runningSessionIDs: [r1.id], workspaceBySession: [:], workspaces: [])
        func ids(_ scope: SidebarScope, selected: UUID? = nil) -> [UUID] {
            ProjectChatGroup.defaultVisibleRowIDs(
                blocks: blocks, scope: scope, isSearching: false, selectedSessionID: selected)
        }
        XCTAssertEqual(ids(.active), [r1.id], "unter Aktiv ist „N gestoppt“ zu")
        XCTAssertEqual(ids(.recent), [r1.id, s1.id, s2.id])
        XCTAssertEqual(ids(.active, selected: s2.id), [r1.id, s1.id, s2.id], "Auswahl öffnet die Faltzeile")
    }

    /// Ablegeregel: Ein laufender Chat, der zwischen gestoppte gezogen wird,
    /// bleibt im Block der laufenden. Die Handreihenfolge ändert sich, die
    /// Blöcke nicht.
    func testDroppingARunningChatAmongStoppedKeepsItInTheRunningBlock() {
        let repo = project("repo")
        let r1 = chat("R1", in: repo, sortIndex: 0)
        let r2 = chat("R2", in: repo, sortIndex: 1)
        let s1 = chat("S1", in: repo, sortIndex: 2)
        let s2 = chat("S2", in: repo, sortIndex: 3)
        let workspace = AgentWorkspace(projects: [repo], sessions: [r1, r2, s1, s2])
        let plan = AgentDragDropPlanner.sessionDropPlan(
            dropped: DraggableSession(sessionID: r1.id, sourceProjectID: repo.id),
            targetProjectID: repo.id,
            beforeSessionID: s2.id,
            workspace: workspace
        )
        guard case .reorder(_, let orderedIDs) = plan else { return XCTFail("erwartet: Umsortieren") }
        let byID = Dictionary(uniqueKeysWithValues: workspace.sessions.map { ($0.id, $0) })
        let reordered = orderedIDs.enumerated().map { index, id -> AgentChatSession in
            var session = byID[id]!
            session.sortIndex = index
            return session
        }
        let blocks = AgentSidebarSorting.blocks(
            sortedSessions: AgentSessionStore.sortedSessions(reordered),
            runningSessionIDs: [r1.id, r2.id], workspaceBySession: [:], workspaces: [])
        XCTAssertEqual(blocks.running.map(\.title), ["R2", "R1"])
        XCTAssertEqual(blocks.stopped.map(\.title), ["S1", "S2"])
    }
}

