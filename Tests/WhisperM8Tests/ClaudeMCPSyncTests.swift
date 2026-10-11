import XCTest
@testable import WhisperM8

/// MCP-Angleich über Konten (11.10.2026): nur ergänzen, Konflikte nie raten,
/// immer über `claude mcp add-json -s user`.
final class ClaudeMCPSyncTests: XCTestCase {
    private final class RunnerSpy: ProcessRunner, @unchecked Sendable {
        struct Call { var arguments: [String]; var environment: [String: String] }
        var calls: [Call] = []
        var exitCode: Int32 = 0
        func run(executable: String, arguments: [String], workingDirectory: String,
                 environmentOverrides: [String: String], timeout: TimeInterval) async throws -> ProcessRunResult {
            calls.append(Call(arguments: arguments, environment: environmentOverrides))
            return ProcessRunResult(exitCode: exitCode, stdout: "", stderr: exitCode == 0 ? "" : "boom\nmore")
        }
    }

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func writeClaudeJSON(_ profile: String, servers: [String: Any]) throws {
        let url: URL
        if profile == "main" {
            url = home.appendingPathComponent(".claude.json")
        } else {
            let dir = home.appendingPathComponent(".claude-profiles/\(profile)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent(".claude.json")
        }
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers, "oauthAccount": ["emailAddress": "x"]])
            .write(to: url)
    }

    func testSnapshotAndPlanAddOnlyMissingAndSkipConflictsAndExclusions() throws {
        try writeClaudeJSON("main", servers: ["atlassian": ["type": "http", "url": "https://a"],
                                               "pw": ["type": "stdio", "command": "x"]])
        try writeClaudeJSON("ai2", servers: ["figma": ["type": "http", "url": "https://f"],
                                              "pw": ["type": "stdio", "command": "y"],
                                              "secret": ["type": "http", "url": "https://s"]])
        let sync = ClaudeMCPSync(profiles: ClaudeAccountProfiles(homeDirectory: home))

        let snapshot = sync.snapshot()
        XCTAssertEqual(snapshot.profileNames, ["main", "ai2"])
        XCTAssertTrue(snapshot.hasConflict("pw"))

        let plan = ClaudeMCPSync.plan(snapshot, excluded: ["secret"])
        XCTAssertEqual(plan.additions.map { "\($0.server)→\($0.profile)" }, ["atlassian→ai2", "figma→main"])
        XCTAssertEqual(plan.conflicts, ["pw"])
        XCTAssertEqual(plan.excluded, ["secret"])
    }

    func testApplyUsesClaudeCommandWithConfigDirOnlyForProfiles() async throws {
        try writeClaudeJSON("ai2", servers: [:])
        let runner = RunnerSpy()
        let sync = ClaudeMCPSync(
            profiles: ClaudeAccountProfiles(homeDirectory: home),
            processRunner: runner,
            commandResolver: { _ in "/fake/claude" })
        let plan = ClaudeMCPSync.Plan(additions: [
            .init(profile: "main", server: "figma", definitionJSON: #"{"url":"https://f"}"#),
            .init(profile: "ai2", server: "atlassian", definitionJSON: #"{"url":"https://a"}"#),
        ])

        let outcome = await sync.apply(plan)

        XCTAssertEqual(outcome.added.count, 2)
        XCTAssertEqual(runner.calls[0].arguments, ["mcp", "add-json", "-s", "user", "figma", #"{"url":"https://f"}"#])
        XCTAssertNil(runner.calls[0].environment["CLAUDE_CONFIG_DIR"], "main ohne Variable")
        XCTAssertEqual(runner.calls[1].environment["CLAUDE_CONFIG_DIR"], home.path + "/.claude-profiles/ai2")
    }

    func testFailureReportsOnlyFirstLineOfStderr() async {
        let runner = RunnerSpy()
        runner.exitCode = 1
        let sync = ClaudeMCPSync(profiles: ClaudeAccountProfiles(homeDirectory: home),
                                 processRunner: runner, commandResolver: { _ in "/fake/claude" })
        let outcome = await sync.apply(.init(additions: [.init(profile: "main", server: "x", definitionJSON: "{}")]))
        XCTAssertEqual(outcome.failed.map(\.message), ["boom"])
    }

    func testAutoSyncIsOffByDefault() throws {
        let suite = "mcp-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(AppPreferences(defaults: defaults).isMCPAutoSyncEnabled)
    }
}
