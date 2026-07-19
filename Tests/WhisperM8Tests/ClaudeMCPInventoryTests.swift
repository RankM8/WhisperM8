import XCTest
@testable import WhisperM8

/// Tests des MCP-Inventars: Text-Parser (`claude mcp list`), Config-Reader
/// und Quellen-Merge mit Origin-Klassifikation. Fixtures = echte Outputs
/// (2026-07-19).
final class ClaudeMCPInventoryTests: XCTestCase {
    // MARK: - CLI-Text-Parser

    private let cliFixture = """
    Checking MCP server health…

    claude.ai Close: https://mcp.close.com/mcp - ✔ Connected
    claude.ai Apollo.io: https://mcp.apollo.io/mcp - ! Needs authentication
    plugin:apollo:apollo: https://mcp.apollo.io/mcp (HTTP) - ! Needs authentication
    plugin:slack:slack: https://mcp.slack.com/mcp (HTTP) - ✔ Connected
    imap-email: node /Users/x/repos/imap-mcp-server/dist/index.js - ⏸ Pending approval (run `claude` to approve)
    """

    func testParseMCPListOutput() {
        let servers = ClaudeMCPInventory.parseMCPListOutput(cliFixture)
        XCTAssertEqual(servers.count, 5)
        XCTAssertEqual(servers[0].name, "claude.ai Close")
        XCTAssertEqual(servers[0].detail, "https://mcp.close.com/mcp")
        XCTAssertEqual(servers[0].status, "✔ Connected")
        // Name mit Doppelpunkten (plugin:apollo:apollo) bleibt intakt.
        XCTAssertEqual(servers[2].name, "plugin:apollo:apollo")
        // Status mit " - "-freiem Detail und Klammer-Zusatz.
        XCTAssertEqual(servers[4].name, "imap-email")
        XCTAssertEqual(servers[4].detail, "node /Users/x/repos/imap-mcp-server/dist/index.js")
        XCTAssertEqual(servers[4].status, "⏸ Pending approval (run `claude` to approve)")
    }

    func testParseMCPListOutputDegradesOnGarbage() {
        XCTAssertTrue(ClaudeMCPInventory.parseMCPListOutput("").isEmpty)
        XCTAssertTrue(ClaudeMCPInventory.parseMCPListOutput("Checking MCP server health…\n\nkein-doppelpunkt-hier").isEmpty)
    }

    // MARK: - Config-Reader

    func testParseConfigJSONExtractsUserAndProjectServers() {
        let json = """
        {
          "mcpServers": {
            "atlassian": { "type": "sse", "url": "https://mcp.atlassian.com/v1/sse" },
            "gooseworks": { "command": "npx", "args": ["gooseworks-mcp"] }
          },
          "projects": {
            "/Users/x/repos/heartbeat": {
              "mcpServers": { "higgsfield": { "command": "hf-mcp" } },
              "enabledMcpjsonServers": []
            },
            "/Users/x/repos/leer": { "mcpServers": {} }
          }
        }
        """
        let config = ClaudeMCPInventory.parseConfigJSON(json.data(using: .utf8))
        XCTAssertEqual(config.userServers.map(\.name), ["atlassian", "gooseworks"])
        XCTAssertEqual(config.userServers[0].detail, "https://mcp.atlassian.com/v1/sse")
        XCTAssertEqual(config.userServers[1].detail, "npx gooseworks-mcp")
        XCTAssertEqual(config.projectServers.count, 1)
        XCTAssertEqual(config.projectServers[0].path, "/Users/x/repos/heartbeat")
        XCTAssertEqual(config.projectServers[0].name, "higgsfield")
    }

    func testParseConfigJSONToleratesMissingOrBrokenData() {
        XCTAssertEqual(ClaudeMCPInventory.parseConfigJSON(nil).userServers.count, 0)
        XCTAssertEqual(ClaudeMCPInventory.parseConfigJSON("kaputt".data(using: .utf8)).userServers.count, 0)
    }

    func testParseMCPJSON() {
        let json = #"{ "mcpServers": { "rankm8": { "command": "rankm8-mcp" } } }"#
        let servers = ClaudeMCPInventory.parseMCPJSON(json.data(using: .utf8))
        XCTAssertEqual(servers.map(\.name), ["rankm8"])
        XCTAssertTrue(ClaudeMCPInventory.parseMCPJSON(nil).isEmpty)
    }

    // MARK: - Merge & Klassifikation

    func testMergeClassifiesOriginsAndAttachesStatus() {
        let cli = ClaudeMCPInventory.parseMCPListOutput(cliFixture)
        let entries = ClaudeMCPInventory.merge(
            cliServers: cli,
            userServers: [(name: "imap-email", detail: "node …/index.js")],
            configProjectServers: [(path: "/Users/x/repos/heartbeat", name: "higgsfield", detail: "hf-mcp")],
            mcpJSONProjectServers: [
                // Duplikat zur projects-Sektion → wird dedupliziert.
                (path: "/Users/x/repos/heartbeat", name: "higgsfield", detail: "hf-mcp")
            ],
            pluginServers: [(pluginID: "apollo@claude-plugins-official", name: "apollo", detail: "https://mcp.apollo.io/mcp")]
        )

        let byOrigin = Dictionary(grouping: entries, by: \.origin)
        XCTAssertEqual(byOrigin[.connector]?.map(\.name).sorted(), ["claude.ai Apollo.io", "claude.ai Close"])
        XCTAssertEqual(byOrigin[.user]?.map(\.name), ["imap-email"])
        XCTAssertEqual(byOrigin[.project]?.count, 1)

        // Plugin-Server: Status kommt ueber den plugin:<name>:<server>-Abgleich.
        let apollo = entries.first { $0.origin == .plugin && $0.name == "apollo" }
        XCTAssertEqual(apollo?.status, "! Needs authentication")
        XCTAssertEqual(apollo?.pluginID, "apollo@claude-plugins-official")
        // slack kommt NUR aus der CLI (Plugin-Liste kannte ihn nicht) →
        // trotzdem als Plugin-Eintrag sichtbar.
        XCTAssertTrue(entries.contains { $0.origin == .plugin && $0.name == "slack" })

        // User-Server bekommt den CLI-Status angehaengt.
        let imap = entries.first { $0.name == "imap-email" }
        XCTAssertEqual(imap?.status?.hasPrefix("⏸ Pending approval"), true)

        // Connector-Klassifikation steuert das Profil-Feld.
        XCTAssertEqual(entries.first { $0.name == "claude.ai Close" }?.isDeniableConnector, true)
        XCTAssertEqual(imap?.isDeniableConnector, false)
    }

    func testMergeWithoutCLIOutputStillListsConfigSources() {
        let entries = ClaudeMCPInventory.merge(
            cliServers: [],
            userServers: [(name: "imap-email", detail: "node x")],
            configProjectServers: [],
            mcpJSONProjectServers: [(path: "/p", name: "rankm8", detail: "rankm8-mcp")],
            pluginServers: []
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].status)
    }
}
