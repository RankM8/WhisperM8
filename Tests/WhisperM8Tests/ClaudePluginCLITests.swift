import XCTest
@testable import WhisperM8

/// Tests fuer die `claude plugin`-Wrapper-Schicht: JSON-Parser (beide
/// Top-Level-Formen), Details-Text-Parser (degradierend) und die
/// Argv-/Env-Konstruktion des CLI-Wrappers (Fake-Runner, Muster
/// `CodexGlobalConfigReaderTests`/`BackgroundAgentSpawnerTests`).
final class ClaudePluginCLITests: XCTestCase {
    // MARK: - List-Parser (Fixtures = echte CLI-Outputs, 2026-07-19)

    func testParseTopLevelArrayForm() throws {
        let json = """
        [
          {
            "id": "apollo@claude-plugins-official",
            "version": "0.1.1",
            "scope": "user",
            "enabled": true,
            "installPath": "/Users/x/.claude/plugins/cache/claude-plugins-official/apollo/0.1.1",
            "installedAt": "2026-05-15T19:20:07.925Z",
            "lastUpdated": "2026-05-15T19:20:07.925Z",
            "mcpServers": {
              "apollo": { "type": "http", "url": "https://mcp.apollo.io/mcp" }
            }
          },
          {
            "id": "agent-sdk-dev@claude-plugins-official",
            "version": "unknown",
            "scope": "user",
            "enabled": false,
            "installPath": "/Users/x/.claude-profiles/PowerUser/plugins/cache/a",
            "unknownFutureKey": {"nested": true}
          }
        ]
        """
        let list = try ClaudePluginListParser.parse(Data(json.utf8))
        XCTAssertEqual(list.installed.count, 2)
        XCTAssertTrue(list.available.isEmpty)
        XCTAssertEqual(list.installed[0].displayName, "apollo")
        XCTAssertEqual(list.installed[0].marketplaceName, "claude-plugins-official")
        XCTAssertEqual(list.installed[0].mcpServers?.keys.sorted(), ["apollo"])
        XCTAssertEqual(list.installed[1].version, "unknown")
        XCTAssertFalse(list.installed[1].enabled)
        XCTAssertNil(list.installed[1].installedAt)
    }

    func testParseCombinedDictForm() throws {
        let json = """
        {
          "installed": [
            {
              "id": "doc-system@360-plugins",
              "version": "5.0.0",
              "scope": "user",
              "enabled": true,
              "installPath": "/Users/x/.claude/plugins/cache/360-plugins/doc-system/5.0.0"
            }
          ],
          "available": [
            {
              "pluginId": "agent-sdk-dev@claude-code-plugins",
              "name": "agent-sdk-dev",
              "description": "Development kit for working with the Claude Agent SDK",
              "marketplaceName": "claude-code-plugins",
              "source": "./plugins/agent-sdk-dev"
            }
          ]
        }
        """
        let list = try ClaudePluginListParser.parse(Data(json.utf8))
        XCTAssertEqual(list.installed.map(\.id), ["doc-system@360-plugins"])
        XCTAssertEqual(list.available.map(\.pluginId), ["agent-sdk-dev@claude-code-plugins"])
        XCTAssertEqual(list.available[0].marketplaceName, "claude-code-plugins")
    }

    func testParseMarketplaceVariants() throws {
        let json = """
        [
          { "name": "360-marketplace", "source": "git",
            "url": "https://github.com/RankM8/360-marketplace.git",
            "installLocation": "/Users/x/.claude/plugins/marketplaces/360-marketplace" },
          { "name": "360-plugins", "source": "github", "repo": "RankM8/360-plugins",
            "installLocation": "/Users/x/.claude/plugins/marketplaces/360-plugins" },
          { "name": "360webmanager", "source": "directory",
            "path": "/Users/x/repos/marketing-engine",
            "installLocation": "/Users/x/repos/marketing-engine" }
        ]
        """
        let marketplaces = try ClaudePluginListParser.parseMarketplaces(Data(json.utf8))
        XCTAssertEqual(marketplaces.count, 3)
        XCTAssertEqual(marketplaces[0].sourceDetail, "https://github.com/RankM8/360-marketplace.git")
        XCTAssertEqual(marketplaces[1].sourceDetail, "RankM8/360-plugins")
        XCTAssertEqual(marketplaces[2].sourceDetail, "/Users/x/repos/marketing-engine")
    }

    // MARK: - Details-Parser

    private let detailsFixture = """
    leadgenjay 1.0.0
      Lead Gen Jay Skill-Paket: 98 Skills fuer Cold Email und mehr.
      Source: leadgenjay@360-plugins

    Component inventory
      Skills (103)  LGJ-graphics, ab-testing-suite, brainstorming
      Agents (1)  code-reviewer
      Hooks (0)
      MCP servers (0)
      LSP servers (0)

    Projected token cost
      Always-on:   ~15,070 tok   added to every session

    Per-component (rounded)
      component                        always-on  on-invoke
      youtube-thumbnail                     ~120      ~8.3k
      brand-voice                           ~130     ~12.8k
      openai-ads-pack                       ~130       ~460
    """

    func testDetailsParserExtractsCoreFields() {
        let details = ClaudePluginDetailsParser.parse(detailsFixture)
        XCTAssertEqual(details.name, "leadgenjay")
        XCTAssertEqual(details.version, "1.0.0")
        XCTAssertEqual(details.sourceID, "leadgenjay@360-plugins")
        XCTAssertEqual(details.skillCount, 103)
        XCTAssertEqual(details.agentCount, 1)
        XCTAssertEqual(details.hookCount, 0)
        XCTAssertEqual(details.mcpServerCount, 0)
        XCTAssertEqual(details.lspServerCount, 0)
        XCTAssertEqual(details.alwaysOnTokens, 15070)
        XCTAssertEqual(details.components.count, 3)
        XCTAssertEqual(details.components[0].name, "youtube-thumbnail")
        XCTAssertEqual(details.components[0].alwaysOnTokens, 120)
        XCTAssertEqual(details.components[0].onInvokeTokens, 8300)
        XCTAssertEqual(details.components[2].onInvokeTokens, 460)
    }

    func testDetailsParserDegradesOnMissingSections() {
        // Nur Kopfzeile — Parser darf nie werfen, Felder bleiben nil.
        let details = ClaudePluginDetailsParser.parse("mini 0.1\n")
        XCTAssertEqual(details.name, "mini")
        XCTAssertNil(details.alwaysOnTokens)
        XCTAssertTrue(details.components.isEmpty)

        let empty = ClaudePluginDetailsParser.parse("")
        XCTAssertNil(empty.name)
    }

    func testTokenValueVariants() {
        XCTAssertEqual(ClaudePluginDetailsParser.tokenValue("~1,625"), 1625)
        XCTAssertEqual(ClaudePluginDetailsParser.tokenValue("~15,070 tok"), 15070)
        XCTAssertEqual(ClaudePluginDetailsParser.tokenValue("~2k"), 2000)
        XCTAssertEqual(ClaudePluginDetailsParser.tokenValue("~8.3k"), 8300)
        XCTAssertEqual(ClaudePluginDetailsParser.tokenValue("120"), 120)
        XCTAssertNil(ClaudePluginDetailsParser.tokenValue("—"))
        XCTAssertNil(ClaudePluginDetailsParser.tokenValue(""))
        XCTAssertNil(ClaudePluginDetailsParser.tokenValue("tok"))
    }

    // MARK: - CLI-Wrapper: Argv + Env (Fake-Runner)

    private final class RunnerRecorder: @unchecked Sendable {
        var calls: [(executable: String, arguments: [String], environment: [String: String])] = []
        var stubbedOutput = "[]"
    }

    private func makeCLI(recorder: RunnerRecorder) -> ClaudePluginCLI {
        var cli = ClaudePluginCLI()
        cli.commandResolver = { _ in "/usr/local/bin/claude" }
        cli.environmentBuilder = { profile in
            var env = ["PATH": "/usr/bin", "NO_COLOR": "1"]
            if let profile {
                env["CLAUDE_CONFIG_DIR"] = "/profiles/\(profile)"
            }
            return env
        }
        cli.runner = { executable, arguments, environment in
            recorder.calls.append((executable.path, arguments, environment))
            return recorder.stubbedOutput
        }
        return cli
    }

    func testInstallBuildsScopeAndConfigArguments() async throws {
        let recorder = RunnerRecorder()
        let cli = makeCLI(recorder: recorder)

        try await cli.install(
            "grilling@skills",
            scope: .project,
            config: ["b": "2", "a": "1"],
            accountProfile: "PowerUser"
        )

        let call = try XCTUnwrap(recorder.calls.first)
        XCTAssertEqual(call.arguments, [
            "plugin", "install", "grilling@skills", "--scope", "project",
            "--config", "a=1", "--config", "b=2"
        ])
        XCTAssertEqual(call.environment["CLAUDE_CONFIG_DIR"], "/profiles/PowerUser")
    }

    func testEnableDisableAndScopelessUninstall() async throws {
        let recorder = RunnerRecorder()
        let cli = makeCLI(recorder: recorder)

        try await cli.setEnabled(false, pluginID: "leadgenjay@360-plugins", scope: .user, accountProfile: nil)
        try await cli.setEnabled(true, pluginID: "leadgenjay@360-plugins", scope: nil, accountProfile: nil)
        try await cli.uninstall("x@y", scope: nil, accountProfile: nil)

        XCTAssertEqual(recorder.calls[0].arguments, ["plugin", "disable", "leadgenjay@360-plugins", "--scope", "user"])
        XCTAssertEqual(recorder.calls[1].arguments, ["plugin", "enable", "leadgenjay@360-plugins"])
        XCTAssertEqual(recorder.calls[2].arguments, ["plugin", "uninstall", "x@y"])
        XCTAssertNil(recorder.calls[0].environment["CLAUDE_CONFIG_DIR"])
    }

    func testListAndMarketplaceCommands() async throws {
        let recorder = RunnerRecorder()
        let cli = makeCLI(recorder: recorder)

        recorder.stubbedOutput = #"{"installed": [], "available": []}"#
        _ = try await cli.listPlugins(accountProfile: nil)
        recorder.stubbedOutput = "[]"
        _ = try await cli.marketplaces(accountProfile: nil)
        try await cli.updateMarketplaces(name: nil, accountProfile: nil)
        try await cli.updateMarketplaces(name: "360-plugins", accountProfile: nil)
        try await cli.addMarketplace(source: "owner/repo", accountProfile: nil)

        XCTAssertEqual(recorder.calls[0].arguments, ["plugin", "list", "--available", "--json"])
        XCTAssertEqual(recorder.calls[1].arguments, ["plugin", "marketplace", "list", "--json"])
        XCTAssertEqual(recorder.calls[2].arguments, ["plugin", "marketplace", "update"])
        XCTAssertEqual(recorder.calls[3].arguments, ["plugin", "marketplace", "update", "360-plugins"])
        XCTAssertEqual(recorder.calls[4].arguments, ["plugin", "marketplace", "add", "owner/repo"])
    }

    func testMissingClaudeBinaryThrows() async {
        var cli = ClaudePluginCLI()
        cli.commandResolver = { _ in nil }
        do {
            _ = try await cli.listPlugins(accountProfile: nil)
            XCTFail("Expected claudeNotFound")
        } catch {
            XCTAssertTrue(error is ClaudePluginCLI.CLIError)
        }
    }
}
