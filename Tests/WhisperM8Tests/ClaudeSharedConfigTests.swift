import XCTest
@testable import WhisperM8

/// Analyse 11.10.2026: geteilte Einträge heilen, Plugin-Registry schützen.
final class ClaudeSharedConfigTests: XCTestCase {
    private var home: URL!
    private var backup: URL!
    private var profiles: ClaudeAccountProfiles { ClaudeAccountProfiles(homeDirectory: home) }

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-config-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/agents"), withIntermediateDirectories: true)
        try "gpt".write(to: home.appendingPathComponent(".claude/agents/gpt.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func profileDir(_ name: String) throws -> URL {
        let dir = home.appendingPathComponent(".claude-profiles/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    func testIdenticalCopyIsReplacedDivergentStaysMissingIsLinked() throws {
        let same = try profileDir("same")
        try FileManager.default.createDirectory(at: same.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "gpt".write(to: same.appendingPathComponent("agents/gpt.md"), atomically: true, encoding: .utf8)
        let own = try profileDir("own")
        try FileManager.default.createDirectory(at: own.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "eigen".write(to: own.appendingPathComponent("agents/eigen.md"), atomically: true, encoding: .utf8)

        let report = profiles.healSharedItems(backupRoot: backup)

        XCTAssertTrue(isLink(same.appendingPathComponent("agents")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("same/agents/gpt.md").path))
        XCTAssertFalse(isLink(own.appendingPathComponent("agents")), "eigener Inhalt bleibt")
        XCTAssertEqual(report.replacedCopies, ["same/agents"])
        XCTAssertEqual(report.divergent, ["own/agents"])
        // output-styles fehlte überall → in main angelegt und verlinkt
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/output-styles").path))
        XCTAssertTrue(isLink(own.appendingPathComponent("output-styles")))
        XCTAssertTrue(report.linked.contains("own/output-styles"))

        // zweiter Lauf: nichts mehr zu tun außer dem Abweichenden
        let second = profiles.healSharedItems(backupRoot: backup)
        XCTAssertEqual(second, .init(divergent: ["own/agents"]))
    }

    func testCreateProfileLinksDirectoriesMissingInMain() throws {
        let created = try profiles.createProfile(named: "neu")
        XCTAssertTrue(isLink(created.configDir.appendingPathComponent("output-styles")))
        XCTAssertTrue(isLink(created.configDir.appendingPathComponent("agents")))
    }

    func testPluginRegistryReferencesThroughProfileFolder() throws {
        let plugins = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let viaProfile = home.path + "/.claude-profiles/PowerUser/plugins/cache/x/clay/1.0"
        let viaOther = home.path + "/.claude-profiles/PowerUser2/plugins/cache/x/dev/1.0"
        let viaMain = home.path + "/.claude/plugins/cache/x/slack/1.0"
        try JSONSerialization.data(withJSONObject: ["version": 2, "plugins": [
            "clay@x": [["scope": "user", "installPath": viaProfile], ["scope": "project", "installPath": viaProfile]],
            "dev@x": [["scope": "user", "installPath": viaOther]],
            "slack@x": [["scope": "user", "installPath": viaMain]],
        ]]).write(to: plugins.appendingPathComponent("installed_plugins.json"))
        try JSONSerialization.data(withJSONObject: [
            "clay-plugins": ["installLocation": home.path + "/.claude-profiles/PowerUser/plugins/marketplaces/clay-plugins"],
        ]).write(to: plugins.appendingPathComponent("known_marketplaces.json"))

        XCTAssertEqual(
            profiles.pluginRegistryReferences(toProfile: "PowerUser"),
            ["clay@x (user)", "clay@x (project)", "Marketplace clay-plugins"])
        XCTAssertEqual(profiles.pluginRegistryReferences(toProfile: "Power"), [], "Präfix nur bis zum Ordnerende")
    }

    func testPromoteIsBlockedWhilePluginsHangOnTheProfile() throws {
        let dir = try profileDir("PowerUser")
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["emailAddress": "x@y"]])
            .write(to: dir.appendingPathComponent(".claude.json"))
        let plugins = home.appendingPathComponent(".claude/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 2, "plugins": [
            "clay@x": [["scope": "user", "installPath": dir.path + "/plugins/cache/x/clay/1.0"]],
        ]]).write(to: plugins.appendingPathComponent("installed_plugins.json"))

        XCTAssertThrowsError(try profiles.promoteToMain("PowerUser", trashItem: { _ in XCTFail("nie löschen") })) { error in
            guard case ClaudeAccountProfiles.PromoteError.pluginsRegisteredViaProfile(let name, let refs) = error else {
                return XCTFail("falscher Fehler: \(error)")
            }
            XCTAssertEqual(name, "PowerUser")
            XCTAssertEqual(refs, ["clay@x (user)"])
        }
    }
}
