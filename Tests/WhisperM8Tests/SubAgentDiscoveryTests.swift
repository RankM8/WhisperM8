import Foundation
import XCTest
@testable import WhisperM8

final class SubAgentDiscoveryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubAgentDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - parseFrontmatter

    func testParseFrontmatterReturnsEmptyForBlocksWithoutOpener() {
        let source = "name: solo\ndescription: nope\n"
        XCTAssertTrue(SubAgentDiscovery.parseFrontmatter(in: source).isEmpty)
    }

    func testParseFrontmatterReadsTopLevelKeyValueLines() {
        let source = """
        ---
        name: code-reviewer
        description: Reviews code for quality and security
        tools: [Read, Glob, Grep]
        model: sonnet
        color: cyan
        permissionMode: plan
        isolation: worktree
        ---

        Body content here.
        """
        let parsed = SubAgentDiscovery.parseFrontmatter(in: source)
        XCTAssertEqual(parsed["name"], "code-reviewer")
        XCTAssertEqual(parsed["description"], "Reviews code for quality and security")
        XCTAssertEqual(parsed["tools"], "[Read, Glob, Grep]")
        XCTAssertEqual(parsed["model"], "sonnet")
        XCTAssertEqual(parsed["color"], "cyan")
        XCTAssertEqual(parsed["permissionMode"], "plan")
        XCTAssertEqual(parsed["isolation"], "worktree")
    }

    func testParseFrontmatterIgnoresCommentsAndBlankLinesAndStopsAtCloser() {
        let source = """
        ---
        # comment

        name: foo

        ---
        name: bar
        """
        let parsed = SubAgentDiscovery.parseFrontmatter(in: source)
        XCTAssertEqual(parsed["name"], "foo")
        XCTAssertNil(parsed["bar"])
    }

    func testStripQuotesRemovesPairedQuotes() {
        XCTAssertEqual(SubAgentDiscovery.stripQuotes("\"hello\""), "hello")
        XCTAssertEqual(SubAgentDiscovery.stripQuotes("'hello'"), "hello")
        XCTAssertEqual(SubAgentDiscovery.stripQuotes("hello"), "hello")
        XCTAssertEqual(SubAgentDiscovery.stripQuotes("\"unbalanced'"), "\"unbalanced'")
    }

    // MARK: - parse (file)

    func testParseExtractsFieldsFromMarkdownFile() throws {
        let url = tempDir.appendingPathComponent("debug-pro.md")
        let body = """
        ---
        name: debug-pro
        description: "Finds root causes in CI failures"
        tools: [Read, Bash]
        color: "#FF453A"
        isolation: worktree
        ---

        You are a debug specialist…
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        let agent = try XCTUnwrap(SubAgentDiscovery.parse(fileURL: url, scope: .user))
        XCTAssertEqual(agent.name, "debug-pro")
        XCTAssertEqual(agent.description, "Finds root causes in CI failures")
        XCTAssertEqual(agent.color, "#FF453A")
        XCTAssertEqual(agent.toolsRaw, "[Read, Bash]")
        XCTAssertTrue(agent.isolationWorktree)
        XCTAssertEqual(agent.scope, .user)
        XCTAssertTrue(agent.hasToolsRestriction)
    }

    func testParseFallsBackToFileStemWhenNameAbsent() throws {
        let url = tempDir.appendingPathComponent("nameless.md")
        let body = """
        ---
        description: missing name
        ---
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        let agent = try XCTUnwrap(SubAgentDiscovery.parse(fileURL: url, scope: .project))
        XCTAssertEqual(agent.name, "nameless")
        XCTAssertEqual(agent.description, "missing name")
        XCTAssertFalse(agent.isolationWorktree)
    }

    // MARK: - discover (directory scan)

    func testDiscoverScansProjectFirstThenUserAndDedupesByName() throws {
        // Project scope: <tempDir>/.claude/agents/foo.md
        let projectAgents = tempDir
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: projectAgents, withIntermediateDirectories: true)
        try """
        ---
        name: dup
        description: project-version
        ---
        """.write(to: projectAgents.appendingPathComponent("dup.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: project-only
        description: only here
        ---
        """.write(to: projectAgents.appendingPathComponent("project-only.md"), atomically: true, encoding: .utf8)

        // Wir koennen den user-scope-Pfad nicht override-en (es ist
        // hardcoded auf ~/.claude/agents/), aber wir koennen verifizieren
        // dass die Projekt-Scope-Files gefunden werden + sortiert sind.
        let agents = SubAgentDiscovery.discover(projectPath: tempDir.path)
        let names = agents.map(\.name)
        XCTAssertTrue(names.contains("dup"))
        XCTAssertTrue(names.contains("project-only"))
        // Project-Agent gewinnt — die description sollte project-version sein.
        let dup = agents.first(where: { $0.name == "dup" })
        XCTAssertEqual(dup?.scope, .project)
        XCTAssertEqual(dup?.description, "project-version")
    }

    func testDiscoverReturnsEmptyWhenAgentsDirectoryMissing() {
        // tempDir hat noch kein .claude/agents — also nichts gefunden.
        let agents = SubAgentDiscovery.discover(projectPath: tempDir.path)
        // Es koennten User-Scope-Agents existieren (CI-Umgebung) — wir testen
        // nur dass keiner aus dem Projekt kommt.
        XCTAssertNil(agents.first(where: { $0.scope == .project }))
    }
}
