import XCTest
@testable import WhisperM8

/// Tests für den subprozess-freien Branch-Lookup (`.git/HEAD`-Read statt
/// `git branch --show-current`-Spawn). Fixture-Verzeichnisse werden pro Test
/// unter einem Temp-Root angelegt — kein echtes `git`-Binary nötig.
final class GitBranchReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBranchReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// Legt `<root>/<name>/.git/HEAD` mit gegebenem Inhalt an und liefert den Projektpfad.
    private func makeRepo(named name: String, head: String) throws -> String {
        let project = root.appendingPathComponent(name)
        let gitDir = project.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try head.write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return project.path
    }

    // MARK: - HEAD-Parser (pur)

    func testBranchNameFromNormalRef() {
        XCTAssertEqual(GitBranchReader.branchName(fromHEADContents: "ref: refs/heads/main\n"), "main")
    }

    func testBranchNameKeepsSlashesInBranchName() {
        XCTAssertEqual(
            GitBranchReader.branchName(fromHEADContents: "ref: refs/heads/feature/agent-chats\n"),
            "feature/agent-chats"
        )
    }

    func testBranchNameDetachedHeadReturnsNil() {
        // Nackter SHA = detached HEAD — `git branch --show-current` liefert dann leer.
        XCTAssertNil(GitBranchReader.branchName(fromHEADContents: "add0d8c1f2e3a4b5c6d7e8f901234567890abcde\n"))
    }

    func testBranchNameNonHeadsRefReturnsNil() {
        XCTAssertNil(GitBranchReader.branchName(fromHEADContents: "ref: refs/tags/v1.0\n"))
    }

    func testBranchNameEmptyReturnsNil() {
        XCTAssertNil(GitBranchReader.branchName(fromHEADContents: ""))
        XCTAssertNil(GitBranchReader.branchName(fromHEADContents: "ref: refs/heads/"))
    }

    // MARK: - Verzeichnis-Auflösung

    func testCurrentBranchFromNormalRepo() throws {
        let path = try makeRepo(named: "repo", head: "ref: refs/heads/main\n")
        XCTAssertEqual(GitBranchReader.currentBranch(at: path), "main")
    }

    func testCurrentBranchDetachedHeadReturnsNil() throws {
        let path = try makeRepo(named: "detached", head: "0123456789abcdef0123456789abcdef01234567\n")
        XCTAssertNil(GitBranchReader.currentBranch(at: path))
    }

    func testCurrentBranchWithoutGitReturnsNil() throws {
        let project = root.appendingPathComponent("plain-folder")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertNil(GitBranchReader.currentBranch(at: project.path))
    }

    func testCurrentBranchMissingDirectoryReturnsNil() {
        XCTAssertNil(GitBranchReader.currentBranch(at: root.appendingPathComponent("does-not-exist").path))
    }

    func testCurrentBranchWorktreeWithAbsoluteGitdir() throws {
        // Haupt-Repo mit Worktree-Metadaten: .git/worktrees/<name>/HEAD trägt
        // den Branch des Worktrees.
        let mainRepo = root.appendingPathComponent("main-repo")
        let worktreeGitDir = mainRepo.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/fix/freeze\n".write(
            to: worktreeGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )

        // Worktree-Checkout: .git ist eine DATEI mit absolutem gitdir.
        let worktree = root.appendingPathComponent("wt-checkout")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGitDir.path)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(GitBranchReader.currentBranch(at: worktree.path), "fix/freeze")
    }

    func testCurrentBranchWorktreeWithRelativeGitdir() throws {
        // Submodule-Stil: `gitdir: ../.git/modules/sub` relativ zum Projekt.
        let modulesGitDir = root.appendingPathComponent(".git/modules/sub")
        try FileManager.default.createDirectory(at: modulesGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/develop\n".write(
            to: modulesGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )

        let submodule = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/sub\n".write(
            to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(GitBranchReader.currentBranch(at: submodule.path), "develop")
    }

    func testCurrentBranchFromRepoSubdirectoryWalksUpToEnclosingRepo() throws {
        // `git -C /repo/packages/app` findet das Repo in den Eltern —
        // der Reader muss das für Monorepo-Unterordner nachbilden.
        let repoPath = try makeRepo(named: "monorepo", head: "ref: refs/heads/main\n")
        let subdirectory = URL(fileURLWithPath: repoPath)
            .appendingPathComponent("packages/app")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        XCTAssertEqual(GitBranchReader.currentBranch(at: subdirectory.path), "main")
    }

    func testCurrentBranchNearerGitWinsOverEnclosingRepo() throws {
        // Verschachtelte Repos: das NÄCHSTE .git gewinnt (wie bei git).
        let outerPath = try makeRepo(named: "outer", head: "ref: refs/heads/outer-branch\n")
        let innerProject = URL(fileURLWithPath: outerPath).appendingPathComponent("inner")
        let innerGit = innerProject.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: innerGit, withIntermediateDirectories: true)
        try "ref: refs/heads/inner-branch\n".write(
            to: innerGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(GitBranchReader.currentBranch(at: innerProject.path), "inner-branch")
    }

    func testCurrentBranchGitFileWithoutGitdirPrefixReturnsNil() throws {
        let project = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "not a gitdir pointer\n".write(
            to: project.appendingPathComponent(".git"), atomically: true, encoding: .utf8
        )
        XCTAssertNil(GitBranchReader.currentBranch(at: project.path))
    }
}
