import XCTest
@testable import WhisperM8

final class AgentWorktreeManagerTests: XCTestCase {
    // MARK: - Pure (Fake-Runner)

    func testNotARepoThrows() {
        let manager = AgentWorktreeManager(gitRunner: { args in
            if args.contains("rev-parse") {
                return .init(exitCode: 128, stdout: "", stderr: "fatal: not a git repository")
            }
            return .init(exitCode: 0, stdout: "", stderr: "")
        })
        XCTAssertThrowsError(
            try manager.createWorktree(repoPath: "/tmp/x", shortId: "abc12345", at: URL(fileURLWithPath: "/tmp/wt"))
        ) { error in
            XCTAssertEqual(error as? AgentWorktreeManager.WorktreeError, .notARepo("/tmp/x"))
        }
    }

    func testCreateBuildsExpectedBranchName() throws {
        var seenArgs: [[String]] = []
        let manager = AgentWorktreeManager(gitRunner: { args in
            seenArgs.append(args)
            if args.contains("rev-parse") { return .init(exitCode: 0, stdout: "true\n", stderr: "") }
            return .init(exitCode: 0, stdout: "", stderr: "")
        })
        let worktree = try manager.createWorktree(
            repoPath: "/repo", shortId: "a3f81c2e", at: URL(fileURLWithPath: "/jobs/a3f81c2e/worktree")
        )
        XCTAssertEqual(worktree.branch, "subagent/a3f81c2e")
        XCTAssertEqual(worktree.path, "/jobs/a3f81c2e/worktree")
        XCTAssertTrue(seenArgs.contains { $0.contains("worktree") && $0.contains("add") && $0.contains("-b") })
    }

    func testRemoveRefusesDirtyWorktree() {
        let manager = AgentWorktreeManager(gitRunner: { args in
            if args.contains("status") { return .init(exitCode: 0, stdout: " M file.swift\n", stderr: "") }
            return .init(exitCode: 0, stdout: "", stderr: "")
        })
        XCTAssertThrowsError(try manager.removeWorktree(repoPath: "/repo", worktreePath: "/wt")) { error in
            XCTAssertEqual(error as? AgentWorktreeManager.WorktreeError, .dirty("/wt"))
        }
    }

    // MARK: - Integration (echtes Temp-Git-Repo)

    private func makeGitRepo() throws -> URL {
        let dir = try makeTempProjectDirectory()
        let run = { (args: [String]) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-q"])
        try run(["config", "user.email", "test@test.local"])
        try run(["config", "user.name", "Test"])
        try "hello".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."])
        try run(["commit", "-q", "-m", "init"])
        return dir
    }

    func testCreateAndRemoveWorktreeEndToEnd() throws {
        let repo = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let destination = repo.appendingPathComponent("wt-test", isDirectory: true)
        let manager = AgentWorktreeManager()

        let worktree = try manager.createWorktree(repoPath: repo.path, shortId: "deadbeef", at: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
        XCTAssertTrue(manager.isClean(worktreePath: worktree.path))

        // Dirty machen → remove verweigert.
        try "dirty".write(to: destination.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(manager.isClean(worktreePath: worktree.path))
        XCTAssertThrowsError(try manager.removeWorktree(repoPath: repo.path, worktreePath: worktree.path))

        // Sauber machen → remove klappt.
        try FileManager.default.removeItem(at: destination.appendingPathComponent("b.txt"))
        try manager.removeWorktree(repoPath: repo.path, worktreePath: worktree.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
