import XCTest
@testable import WhisperM8

/// WM8-102: Arbeitsordner neben dem Projekt gehören zum Haupt-Repo, wenn ihr
/// Name mit dem Namen des Repos beginnt.
final class SiblingWorktreeProjectTests: XCTestCase {
    private func location(root: String, gitDir: String) -> GitLocation {
        GitLocation(root: root, gitDir: gitDir, branch: "feat/x")
    }

    private func mainRepo(_ path: String, root: String, gitDir: String, existing: Set<String> = ["/r/akquise-ai", "/r/ListM8", "/r/sindy-deluxe"]) -> String? {
        AgentProjectPath.siblingWorktreeMainRepo(
            path: path,
            git: location(root: root, gitDir: gitDir),
            directoryExists: existing.contains
        )
    }

    func testSiblingWithRepoNamePrefixBelongsToMainRepo() {
        XCTAssertEqual(
            mainRepo("/r/akquise-ai-kurse", root: "/r/akquise-ai-kurse",
                     gitDir: "/r/akquise-ai/.git/worktrees/akquise-ai-kurse"),
            "/r/akquise-ai")
        XCTAssertEqual(
            mainRepo("/r/ListM8-ds190", root: "/r/ListM8-ds190",
                     gitDir: "/r/ListM8/.git/worktrees/ListM8-ds190"),
            "/r/ListM8")
    }

    func testNameRuleIgnoresCase() {
        XCTAssertEqual(
            mainRepo("/r/listm8-slot", root: "/r/listm8-slot", gitDir: "/r/ListM8/.git/worktrees/listm8-slot"),
            "/r/ListM8")
    }

    func testWorktreeWithOwnNameStaysOwnProject() {
        XCTAssertNil(
            mainRepo("/r/kunden/podomedica", root: "/r/kunden/podomedica",
                     gitDir: "/r/sindy-deluxe/.git/worktrees/podomedica"))
    }

    func testNormalRepoIsNoWorktree() {
        XCTAssertNil(mainRepo("/r/akquise-ai", root: "/r/akquise-ai", gitDir: "/r/akquise-ai/.git"))
        XCTAssertNil(AgentProjectPath.siblingWorktreeMainRepo(path: "/r/x", git: nil, directoryExists: { _ in true }))
    }

    func testSubfolderOfWorktreeIsNotRegrouped() {
        XCTAssertNil(
            mainRepo("/r/akquise-ai-kurse/app", root: "/r/akquise-ai-kurse",
                     gitDir: "/r/akquise-ai/.git/worktrees/akquise-ai-kurse"))
    }

    func testNestedWorktreeInsideMainRepoFollowsNameRule() {
        XCTAssertNil(
            mainRepo("/r/akquise-ai/wt/feature", root: "/r/akquise-ai/wt/feature",
                     gitDir: "/r/akquise-ai/.git/worktrees/feature"))
        XCTAssertEqual(
            mainRepo("/r/akquise-ai/wt/akquise-ai-feature", root: "/r/akquise-ai/wt/akquise-ai-feature",
                     gitDir: "/r/akquise-ai/.git/worktrees/akquise-ai-feature"),
            "/r/akquise-ai")
    }

    func testDeletedMainRepoKeepsOwnProject() {
        XCTAssertNil(
            mainRepo("/r/akquise-ai-kurse", root: "/r/akquise-ai-kurse",
                     gitDir: "/r/akquise-ai/.git/worktrees/akquise-ai-kurse", existing: []))
    }

    func testSameNameAsRepoIsNotASibling() {
        XCTAssertNil(
            mainRepo("/other/akquise-ai", root: "/other/akquise-ai",
                     gitDir: "/r/akquise-ai/.git/worktrees/akquise-ai"))
    }

    func testClaudeWorktreeMarkerStillWins() {
        XCTAssertEqual(
            AgentProjectPath.owningProjectPath("/nowhere/akquise-ai/.claude/worktrees/x"),
            "/nowhere/akquise-ai")
    }

    /// Echte Ordner mit `.git`-Datei, wie `git worktree add` sie anlegt.
    func testReadsGitFileFromDisk() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-102-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("akquise-ai")
        let sibling = base.appendingPathComponent("akquise-ai-tim")
        let gitDir = main.appendingPathComponent(".git/worktrees/akquise-ai-tim")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: main.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/tim\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: sibling.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let resolved = AgentProjectPath.owningProjectPath(sibling.path)
        XCTAssertEqual(URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path,
                       main.resolvingSymlinksInPath().path)
        XCTAssertEqual(AgentProjectPath.owningProjectPath(main.path), main.standardizedFileURL.path)
    }
}

/// Verweis-Pflege und Anzeige unter dem Haupt-Projekt (WM8-102).
final class WorktreeProjectDisplayTests: XCTestCase {
    private func session(_ project: AgentProject, _ title: String) -> AgentChatSession {
        AgentChatSession(provider: .claude, projectID: project.id, title: title, createdManually: true)
    }

    func testLinksAreSetAndClearedOnlyForCheckedPaths() {
        let main = AgentProject(name: "akquise-ai", path: "/r/akquise-ai", createdManually: true)
        let kurse = AgentProject(name: "akquise-ai-kurse", path: "/r/akquise-ai-kurse", createdManually: true)
        var stale = AgentProject(name: "alt", path: "/r/alt", createdManually: true)
        stale.parentProjectID = main.id
        var untouched = AgentProject(name: "fremd", path: "/r/fremd", createdManually: true)
        untouched.parentProjectID = main.id
        var workspace = AgentWorkspace(projects: [main, kurse, stale, untouched], sessions: [])

        let changed = AgentSessionStore.applyWorktreeProjectLinks(
            to: &workspace,
            mainRepoByPath: ["/r/akquise-ai-kurse": "/r/akquise-ai"],
            checkedPaths: ["/r/akquise-ai", "/r/akquise-ai-kurse", "/r/alt"]
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(workspace.projects[1].parentProjectID, main.id)
        XCTAssertNil(workspace.projects[2].parentProjectID, "geprüft, kein Arbeitsordner mehr")
        XCTAssertEqual(workspace.projects[3].parentProjectID, main.id, "nicht geprüft, bleibt")
        XCTAssertNil(workspace.projects[0].parentProjectID)

        XCTAssertFalse(AgentSessionStore.applyWorktreeProjectLinks(
            to: &workspace,
            mainRepoByPath: ["/r/akquise-ai-kurse": "/r/akquise-ai"],
            checkedPaths: ["/r/akquise-ai-kurse"]
        ), "zweiter Lauf ändert nichts")
    }

    func testMissingMainProjectLeavesNoLink() {
        let kurse = AgentProject(name: "akquise-ai-kurse", path: "/r/akquise-ai-kurse", createdManually: true)
        var workspace = AgentWorkspace(projects: [kurse], sessions: [])
        AgentSessionStore.applyWorktreeProjectLinks(
            to: &workspace, mainRepoByPath: ["/r/akquise-ai-kurse": "/r/akquise-ai"],
            checkedPaths: ["/r/akquise-ai-kurse"])
        XCTAssertNil(workspace.projects[0].parentProjectID)
    }

    func testDisplayParentNeedsManualStandaloneParent() {
        let main = AgentProject(name: "main", path: "/r/main", createdManually: true)
        let hidden = AgentProject(name: "hidden", path: "/r/hidden")
        var child = AgentProject(name: "main-x", path: "/r/main-x", createdManually: true)
        child.parentProjectID = main.id
        var orphan = AgentProject(name: "o", path: "/r/o", createdManually: true)
        orphan.parentProjectID = UUID()
        var underHidden = AgentProject(name: "hidden-x", path: "/r/hidden-x", createdManually: true)
        underHidden.parentProjectID = hidden.id
        var chain = AgentProject(name: "main-x-y", path: "/r/main-x-y", createdManually: true)
        chain.parentProjectID = child.id

        let parents = AgentProjectDisplay.parentByProjectID(projects: [main, hidden, child, orphan, underHidden, chain])
        XCTAssertEqual(parents, [child.id: main.id])
        XCTAssertEqual(AgentProjectDisplay.displayProjectID(orphan.id, parents: parents), orphan.id)
    }

    func testSidebarGroupsWorktreeChatsUnderMainProject() {
        let main = AgentProject(name: "akquise-ai", path: "/r/akquise-ai", createdManually: true)
        var kurse = AgentProject(name: "akquise-ai-kurse", path: "/r/akquise-ai-kurse", createdManually: true)
        kurse.parentProjectID = main.id
        let a = session(main, "Haupt")
        let b = session(kurse, "Kurse")
        let workspace = AgentWorkspace(projects: [main, kurse], sessions: [a, b])
        let snapshot = AgentSidebarModelBuilder.snapshot(
            workspace: workspace, pinnedSessionIDs: [],
            scope: SidebarScopeFilter(scope: .all, runningSessionIDs: [b.id], openTabIDs: [],
                                      now: Date(), recentWindow: SidebarScopeFilter.defaultRecentWindow),
            layout: .grouped, query: "", flatVisibleLimit: 50, selectedSessionID: nil)

        XCTAssertEqual(snapshot.visibleProjects.map(\.id), [main.id])
        XCTAssertEqual(Set(snapshot.sessionsByProject[main.id]?.map(\.id) ?? []), [a.id, b.id])
        XCTAssertNil(snapshot.sessionsByProject[kurse.id])
        XCTAssertEqual(snapshot.activeSessionIDsByProject[main.id], [b.id])
        XCTAssertEqual(snapshot.projectByID[kurse.id]?.id, main.id, "Symbol des Haupt-Projekts")
    }

    func testTicketTeamFollowsMainRepoOfSiblingFolder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm8-102-team-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("akquise-ai")
        let sibling = base.appendingPathComponent("akquise-ai-kurse")
        let gitDir = main.appendingPathComponent(".git/worktrees/akquise-ai-kurse")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling.appendingPathComponent("app"), withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: sibling.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        var config = TicketConfig()
        config.set(team: "XYZ", forProject: main.path)
        XCTAssertEqual(config.team(forDirectory: sibling.path), "XYZ")
        XCTAssertEqual(config.team(forDirectory: sibling.appendingPathComponent("app").path), "XYZ")
        XCTAssertNotNil(config.projectPath(forDirectory: sibling.path))
        XCTAssertNil(config.team(forDirectory: base.appendingPathComponent("fremd").path))
    }
}
