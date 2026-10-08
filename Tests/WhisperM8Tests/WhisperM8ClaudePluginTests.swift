import XCTest
@testable import WhisperM8

/// Plugin `whisperm8`: Zusammensetzen aus dem Bundle, atomares Ablegen über
/// versionierte Ordner + Symlink, Umgebung für den Launch und die einmalige
/// Migration der losen Skill-Kopien.
final class WhisperM8ClaudePluginTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func makePlugin(version: String = "9.9.9") -> WhisperM8ClaudePlugin {
        WhisperM8ClaudePlugin(
            rootDirectory: temp.appendingPathComponent("root", isDirectory: true),
            bundle: .module,
            appVersion: version,
            homeDirectory: temp.appendingPathComponent("home", isDirectory: true)
        )
    }

    // MARK: Zusammensetzen

    func testAssembledPluginHasManifestModAndAllSkills() throws {
        let files = try makePlugin().assembleFiles()
        let manifest = try XCTUnwrap(files[".claude-plugin/plugin.json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "whisperm8")
        XCTAssertEqual(object["version"] as? String, "9.9.9")
        XCTAssertEqual(object["types"] as? String, "./types/index.d.ts")
        XCTAssertNil(files["plugin.json"], "Manifest gehört nach .claude-plugin/")
        XCTAssertNotNil(files["hooks/hooks.json"])
        XCTAssertNotNil(files["hooks/register.tsx"])
        XCTAssertNotNil(files["types/index.d.ts"])
        for definition in CLISkillExporter.SkillDefinition.plugin {
            let skill = try XCTUnwrap(files["skills/\(definition.name)/SKILL.md"], definition.name)
            XCTAssertTrue(String(decoding: skill, as: UTF8.self).contains("name: \(definition.name)"),
                          "Ordnername muss dem Frontmatter entsprechen: \(definition.name)")
        }
        XCTAssertNotNil(files["skills/codex-subagent/references/codex-cli.md"])
        XCTAssertNotNil(files["skills/gpt-workflow/examples/wf-code-review.js"])
        XCTAssertFalse(files.keys.contains { $0.hasSuffix(".test.ts") }, "Mod-Tests werden nicht ausgeliefert")
    }

    func testJarvisShipsOnlyInPluginNotInSettingsList() {
        XCTAssertFalse(CLISkillExporter.SkillDefinition.all.contains(.jarvis))
        XCTAssertTrue(CLISkillExporter.SkillDefinition.plugin.contains(.jarvis))
    }

    func testContentHashIgnoresOrderButSeesContent() {
        let a = ["a": Data("1".utf8), "b": Data("2".utf8)]
        let b = ["b": Data("2".utf8), "a": Data("1".utf8)]
        XCTAssertEqual(WhisperM8ClaudePlugin.contentHash(a), WhisperM8ClaudePlugin.contentHash(b))
        XCTAssertNotEqual(WhisperM8ClaudePlugin.contentHash(a),
                          WhisperM8ClaudePlugin.contentHash(["a": Data("1".utf8), "b": Data("3".utf8)]))
    }

    func testShipsFilter() {
        XCTAssertTrue(WhisperM8ClaudePlugin.ships("hooks/register.tsx"))
        XCTAssertFalse(WhisperM8ClaudePlugin.ships("hooks/board.test.ts"))
        XCTAssertFalse(WhisperM8ClaudePlugin.ships("hooks/.DS_Store"))
    }

    // MARK: Ablegen

    func testInstallWritesVersionAndPointsLink() throws {
        let plugin = makePlugin()
        let result = try plugin.install()
        XCTAssertTrue(result.wroteNewVersion)
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: plugin.activeLinkURL.path)
        XCTAssertEqual(target, "versions/\(result.hash)/whisperm8", "Link relativ, damit der Ordner umziehen kann")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: plugin.activeLinkURL.appendingPathComponent(".claude-plugin/plugin.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: plugin.activeLinkURL.appendingPathComponent("skills/jarvis/SKILL.md").path))
    }

    func testInstallIsIdempotentForSameContent() throws {
        let plugin = makePlugin()
        let first = try plugin.install()
        let second = try plugin.install()
        XCTAssertEqual(first.hash, second.hash)
        XCTAssertFalse(second.wroteNewVersion)
    }

    func testNewVersionLeavesOldFolderForRunningSessions() throws {
        let old = try makePlugin(version: "1.0.0").install()
        let new = try makePlugin(version: "1.1.0").install()
        XCTAssertNotEqual(old.hash, new.hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.versionDirectory.path),
                      "Laufende Sessions stehen noch auf dem alten Stand")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: makePlugin().activeLinkURL.path)
        XCTAssertEqual(target, "versions/\(new.hash)/whisperm8")
    }

    func testPruneKeepsOnlyRetainedVersions() throws {
        for minor in 0..<(WhisperM8ClaudePlugin.retainedVersions + 3) {
            try makePlugin(version: "1.\(minor).0").install()
        }
        let versions = try FileManager.default.contentsOfDirectory(atPath: makePlugin().versionsDirectory.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(versions.count, WhisperM8ClaudePlugin.retainedVersions)
    }

    // MARK: Umgebung

    func testLaunchEnvironmentOnlyWhenEnabledAndInstalled() throws {
        let plugin = makePlugin()
        XCTAssertEqual(WhisperM8ClaudePlugin.launchEnvironment(
            enabled: true, linkURL: plugin.activeLinkURL, inherited: nil), [:], "noch nicht abgelegt")
        try plugin.install()
        XCTAssertEqual(WhisperM8ClaudePlugin.launchEnvironment(
            enabled: false, linkURL: plugin.activeLinkURL, inherited: nil), [:], "Kill-Switch")
        XCTAssertEqual(WhisperM8ClaudePlugin.launchEnvironment(
            enabled: true, linkURL: plugin.activeLinkURL, inherited: nil),
            ["CLAUDE_CODE_PLUGIN_DIRS": plugin.activeLinkURL.path])
    }

    func testLaunchEnvironmentKeepsUserPluginDirsWithoutDuplicates() {
        let link = URL(fileURLWithPath: "/x/claude-plugin/whisperm8")
        let env = WhisperM8ClaudePlugin.launchEnvironment(
            enabled: true, linkURL: link, inherited: "/mine/a:/x/claude-plugin/whisperm8:/mine/b",
            fileExists: { _ in true })
        XCTAssertEqual(env["CLAUDE_CODE_PLUGIN_DIRS"], "/mine/a:/mine/b:/x/claude-plugin/whisperm8")
    }

    func testBuilderPassesPluginEnvironmentToClaudeLaunch() throws {
        var builder = AgentCommandBuilder(commandResolver: { "/usr/local/bin/\($0)" })
        builder.gptBackendEnabledResolver = { false }
        builder.extraArgumentsResolver = { _ in [] }
        builder.claudePluginEnvironmentResolver = { ["CLAUDE_CODE_PLUGIN_DIRS": "/p/whisperm8"] }
        let project = AgentProject(name: "P", path: FileManager.default.temporaryDirectory.path)
        let session = AgentChatSession(provider: .claude, projectID: project.id, title: "Chat")
        let command = try builder.command(for: session, project: project)
        XCTAssertEqual(command.environmentOverrides["CLAUDE_CODE_PLUGIN_DIRS"], "/p/whisperm8")
    }

    // MARK: Migration

    private var home: URL { temp.appendingPathComponent("home", isDirectory: true) }

    private func installLoose(_ definition: CLISkillExporter.SkillDefinition) throws -> CLISkillExporter {
        let exporter = CLISkillExporter(definition: definition, homeDirectory: home, bundle: .module)
        try exporter.installForClaudeCode()
        return exporter
    }

    func testMigrationBacksUpOwnedSkillsAndJarvis() throws {
        _ = try installLoose(.chats)
        let jarvis = home.appendingPathComponent(".claude/skills/jarvis", isDirectory: true)
        try FileManager.default.createDirectory(at: jarvis, withIntermediateDirectories: true)
        try "---\nname: jarvis\n---\nlokal".write(to: jarvis.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let outcome = ClaudePluginSkillMigration(homeDirectory: home, bundle: .module).run()

        XCTAssertEqual(Set(outcome.moved), ["whisperm8-chats", "jarvis"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: jarvis.path))
        let backup = try XCTUnwrap(outcome.backupDirectory)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("jarvis/SKILL.md"), encoding: .utf8),
                       "---\nname: jarvis\n---\nlokal", "gesichert, nicht gelöscht")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("whisperm8-chats/SKILL.md").path))
    }

    func testMigrationKeepsLocallyModifiedSkillsAndSymlinks() throws {
        let edited = try installLoose(.gptCoworker)
        try "lokal geändert".write(to: edited.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let skills = home.appendingPathComponent(".claude/skills", isDirectory: true)
        let elsewhere = temp.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skills.appendingPathComponent("whisperm8-chats"), withDestinationURL: elsewhere)

        let outcome = ClaudePluginSkillMigration(homeDirectory: home, bundle: .module).run()

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(outcome.kept.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited.claudeCodeSkillURL.path))
    }

    func testMigrationWithoutSkillsDoesNothing() {
        let outcome = ClaudePluginSkillMigration(homeDirectory: home, bundle: .module).run()
        XCTAssertEqual(outcome, ClaudePluginSkillMigration.Outcome())
    }
}
