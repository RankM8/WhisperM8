import XCTest
@testable import WhisperM8

/// Fixtures aus dem Prototyp (Plan claude-account-switch-ohne-stopp.md, P2) und
/// Referenzwerte aus Claude Codes eigener JS-Funktion (Node, 2.1.296).
final class ClaudeSharedMemoryPathTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // realpath, damit `/var` → `/private/var` die Erwartungen nicht verfälscht
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: ClaudeSharedMemoryPath.realPath(raw.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Kodierung

    func testEncodingReplacesEveryNonAlphanumericUTF16Unit() {
        XCTAssertEqual(
            ClaudeSharedMemoryPath.encodedProjectName("/Users/x/Projekte/Bücher & Co"),
            "-Users-x-Projekte-B-cher---Co")
        // Emoji = zwei UTF-16-Einheiten → zwei Striche
        XCTAssertEqual(ClaudeSharedMemoryPath.encodedProjectName("/a/😀"), "-a---")
    }

    func testEncodingMatchesPrototypePath() {
        XCTAssertEqual(
            ClaudeSharedMemoryPath.encodedProjectName(
                "/private/tmp/claude-501/-Users-giulianocosta-repos-whisperm8/6dbc0ed5-3cf9-4451-9638-92822d78309f/scratchpad/proto/repo"),
            "-private-tmp-claude-501--Users-giulianocosta-repos-whisperm8-6dbc0ed5-3cf9-4451-9638-92822d78309f-scratchpad-proto-repo")
    }

    func testLongPathIsTruncatedWithHashSuffix() {
        let long = "/Users/test/" + String(repeating: "sehr-langer-ordnername/", count: 10) + "projekt"
        XCTAssertEqual(
            ClaudeSharedMemoryPath.encodedProjectName(long),
            "-Users-test-sehr-langer-ordnername-sehr-langer-ordnername-sehr-langer-ordnername-sehr-langer-ordnername-sehr-langer-ordnername-sehr-langer-ordnername-sehr-langer-ordnername-sehr-langer-ordnername-sehr-mmgdka")
    }

    func testHashMatchesClaudeIncludingOverflowAndSurrogates() {
        XCTAssertEqual(ClaudeSharedMemoryPath.claudeHash("/Users/x/Projekte/Bücher & Co"), 550420620)
        XCTAssertEqual(ClaudeSharedMemoryPath.claudeHash("/Users/test/a"), -832770598)
        XCTAssertEqual(ClaudeSharedMemoryPath.claudeHash("/Users/test/ü😀"), -1426705768)
    }

    // MARK: Projekt-Root

    func testSubdirectoryUsesRepoRoot() throws {
        let repo = try makeRepo("repo")
        let deeper = repo.appendingPathComponent("sub/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeSharedMemoryPath.projectRoot(forWorkingDirectory: deeper.path), repo.path)
    }

    func testWorktreeUsesMainRepoRoot() throws {
        let repo = try makeRepo("repo")
        let worktree = try makeWorktree(named: "repo-wt", of: repo)
        XCTAssertEqual(ClaudeSharedMemoryPath.projectRoot(forWorkingDirectory: worktree.path), repo.path)
    }

    func testWorktreeWithRelativeGitdirUsesMainRepoRoot() throws {
        let repo = try makeRepo("repo")
        let worktree = try makeWorktree(named: "repo-wt", of: repo, relativeGitdir: true)
        XCTAssertEqual(ClaudeSharedMemoryPath.projectRoot(forWorkingDirectory: worktree.path), repo.path)
    }

    func testSubmoduleKeepsItsOwnRoot() throws {
        let repo = try makeRepo("super")
        let modules = repo.appendingPathComponent(".git/modules/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let sub = repo.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/lib\n".write(
            to: sub.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSharedMemoryPath.projectRoot(forWorkingDirectory: sub.path), sub.path)
    }

    func testDirectoryWithoutGitUsesItself() throws {
        let plain = root.appendingPathComponent("nogit/x", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeSharedMemoryPath.projectRoot(forWorkingDirectory: plain.path), plain.path)
    }

    func testSymlinkedWorkingDirectoryIsResolved() throws {
        let repo = try makeRepo("repo")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        XCTAssertEqual(ClaudeSharedMemoryPath.projectRoot(forWorkingDirectory: link.path), repo.path)
    }

    func testPrivateTmpIsKept() {
        // Der Grund für realpath(3): Foundation würde `/private/tmp` zu `/tmp` kürzen.
        XCTAssertEqual(ClaudeSharedMemoryPath.realPath("/tmp"), "/private/tmp")
        XCTAssertEqual(
            ClaudeSharedMemoryPath.absolutePath("../../x", relativeTo: "/private/var/a/b/c"),
            "/private/var/a/x")
    }

    func testMemoryDirectoryLivesUnderMainProjects() throws {
        let repo = try makeRepo("repo")
        let main = URL(fileURLWithPath: "/Users/x/.claude", isDirectory: true)
        let url = ClaudeSharedMemoryPath.memoryDirectory(
            forWorkingDirectory: repo.path, mainConfigDirectory: main)
        XCTAssertEqual(
            url.path,
            "/Users/x/.claude/projects/\(ClaudeSharedMemoryPath.encodedProjectName(repo.path))/memory")
    }

    // MARK: Settings-Fragment

    func testFragmentOnlyForExistingAdditionalClaudeProfiles() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude-profiles/ai2"), withIntermediateDirectories: true)
        let profiles = ClaudeAccountProfiles(homeDirectory: home)
        let repo = try makeRepo("repo")
        func fragment(_ profile: String?, provider: AgentProvider = .claude, enabled: Bool = true) -> [String: Any]? {
            ClaudeSharedMemoryPath.settingsFragment(
                provider: provider, profileName: profile, workingDirectory: repo.path,
                profiles: profiles, isEnabled: enabled)
        }

        let expected = home.path + "/.claude/projects/"
            + ClaudeSharedMemoryPath.encodedProjectName(repo.path) + "/memory"
        XCTAssertEqual(fragment("ai2")?["autoMemoryDirectory"] as? String, expected)
        XCTAssertNil(fragment(nil), "main (ungestempelt) bleibt ohne Fragment")
        XCTAssertNil(fragment("main"))
        XCTAssertNil(fragment("geloescht"), "fehlendes Profil fällt beim Launch auf main zurück")
        XCTAssertNil(fragment("ai2", provider: .codex))
        XCTAssertNil(fragment("ai2", enabled: false))
    }

    // MARK: Helfer

    private func makeRepo(_ name: String) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        return repo
    }

    /// Nachbau dessen, was `git worktree add` anlegt.
    private func makeWorktree(named name: String, of repo: URL, relativeGitdir: Bool = false) throws -> URL {
        let worktree = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let adminDir = repo.appendingPathComponent(".git/worktrees/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: adminDir, withIntermediateDirectories: true)
        try "../..\n".write(to: adminDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "\(worktree.path)/.git\n".write(
            to: adminDir.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        let gitdir = relativeGitdir ? "../\(repo.lastPathComponent)/.git/worktrees/\(name)" : adminDir.path
        try "gitdir: \(gitdir)\n".write(
            to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return worktree
    }
}
