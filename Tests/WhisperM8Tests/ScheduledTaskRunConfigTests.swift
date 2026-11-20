import XCTest
@testable import WhisperM8

/// WM8-110 Paket 4: Ein Lauf bekommt nur die Freigaben der Aufgabe. Die
/// Lauf-Einstellungen ersetzen die Einstellungsdateien von Konto und Projekt.
final class ScheduledTaskRunConfigTests: XCTestCase {
    private var root: URL!
    private var account: URL!
    private var project: URL!
    private var run: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("runcfg-\(UUID().uuidString)", isDirectory: true)
        account = root.appendingPathComponent("konto", isDirectory: true)
        project = root.appendingPathComponent("projekt", isDirectory: true)
        run = root.appendingPathComponent("lauf", isDirectory: true)
        for dir in [account!, project!, run!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func task(_ tools: [String] = [], access: ScheduledTaskPermissions.Access = .projectWrite) -> ScheduledTask {
        ScheduledTask(name: "Probe", prompt: "x", directory: project.path, account: "main",
                      schedule: ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]),
                      permissions: ScheduledTaskPermissions(access: access, extraTools: tools), createdAt: Date())
    }

    private func prepare(_ task: ScheduledTask) throws -> ScheduledTaskRunConfig {
        try ScheduledTaskRunConfigBuilder.prepare(
            task: task,
            sources: .init(configDirectory: account, claudeJSON: root.appendingPathComponent("claude.json")),
            runDirectory: run)
    }

    private func json(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    // MARK: Einstellungen

    func testSettingsDropPermissionsHooksAndPlugins() throws {
        try write("""
        {"permissions": {"allow": ["Bash(rm:*)", "Read(//**)"], "defaultMode": "auto"},
         "hooks": {"PreToolUse": []}, "enabledPlugins": {"x@y": true},
         "env": {"ENABLE_TOOL_SEARCH": "1"}, "language": "Deutsch", "cleanupPeriodDays": 3650}
        """, account.appendingPathComponent("settings.json"))
        let config = try prepare(task())
        let settings = try json(config.settingsFile)
        XCTAssertNil(settings["permissions"], "Freigaben des Kontos gelten im Lauf nicht")
        XCTAssertNil(settings["hooks"], "Ein Hook könnte Werkzeuge freigeben")
        XCTAssertNil(settings["enabledPlugins"])
        XCTAssertEqual(settings["language"] as? String, "Deutsch")
        XCTAssertEqual(settings["cleanupPeriodDays"] as? Int, 3650, "Sonst räumte Claude alte Verläufe nach 30 Tagen")
        XCTAssertEqual((settings["env"] as? [String: String])?["ENABLE_TOOL_SEARCH"], "1")
        let attributes = try FileManager.default.attributesOfItem(atPath: config.settingsFile)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(config.settingsFile.hasPrefix(run.appendingPathComponent("claude-config").path))
    }

    func testBrokenSettingsStopTheRun() throws {
        try write("{ kaputt", account.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try prepare(task()), "Ohne cleanupPeriodDays räumte Claude alte Verläufe weg")
    }

    func testSandboxStaysButDoesNotAllowBashByItself() throws {
        try write(#"{"sandbox": {"enabled": true}}"#, account.appendingPathComponent("settings.json"))
        let sandbox = try json(try prepare(task()).settingsFile)["sandbox"] as? [String: Any]
        XCTAssertEqual(sandbox?["enabled"] as? Bool, true)
        XCTAssertEqual(sandbox?["autoAllowBashIfSandboxed"] as? Bool, false)
    }

    func testMissingSettingsGiveAnEmptyFile() throws {
        let config = try prepare(task())
        XCTAssertTrue(try json(config.settingsFile).isEmpty)
        XCTAssertNil(config.pluginDirectory)
        XCTAssertNil(config.contextFile)
        XCTAssertNil(config.mcpConfigFile)
        XCTAssertEqual(config.extraAllowedTools(for: .init()), [])
    }

    // MARK: Skills

    func testSkillsBecomePluginsWithoutTheirOwnGrants() throws {
        try write("---\nname: plain\ndescription: d\n---\nText\n", account.appendingPathComponent("skills/plain/SKILL.md"))
        try write("""
        ---
        name: greedy
        allowed-tools: Bash(mkdir:*)
        hooks:
          PreToolUse:
            - matcher: Bash
        description: d
        ---
        Text
        """, account.appendingPathComponent("skills/greedy/SKILL.md"))
        try write("x", account.appendingPathComponent("skills/greedy/scripts/run.py"))
        try write("x", account.appendingPathComponent("skills/.whisperm8-backup/old/SKILL.md"))
        try write("---\nname: local\n---\n", project.appendingPathComponent(".claude/skills/local/SKILL.md"))

        let config = try prepare(task())
        let plugins = try XCTUnwrap(config.pluginDirectory)
        let fm = FileManager.default
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        XCTAssertEqual(resolved(try fm.destinationOfSymbolicLink(atPath: plugins + "/account/skills/plain")),
                       resolved(account.appendingPathComponent("skills/plain").path))
        XCTAssertFalse(fm.fileExists(atPath: plugins + "/account/skills/.whisperm8-backup"))
        let greedy = try String(contentsOfFile: plugins + "/account/skills/greedy/SKILL.md", encoding: .utf8)
        XCTAssertFalse(greedy.contains("allowed-tools"))
        XCTAssertFalse(greedy.contains("PreToolUse"))
        XCTAssertTrue(greedy.contains("description: d"))
        XCTAssertEqual(resolved(try fm.destinationOfSymbolicLink(atPath: plugins + "/account/skills/greedy/scripts")),
                       resolved(account.appendingPathComponent("skills/greedy/scripts").path))
        XCTAssertTrue(fm.fileExists(atPath: plugins + "/project/skills/local/SKILL.md"))
        let manifest = try json(plugins + "/account/.claude-plugin/plugin.json")
        XCTAssertEqual(manifest["name"] as? String, "account")
        XCTAssertEqual(config.extraAllowedTools(for: .init()), ["Read(/\(plugins)/**)"], "Skills lesen über den Pfad im Lauf")
        XCTAssertTrue(config.extraAllowedTools(for: .init())[0].hasPrefix("Read(//"))
        XCTAssertEqual(config.extraAllowedTools(for: .init(access: .custom, extraTools: ["Bash(x)"])), [],
                       "Ohne Skill kein Lesen über Symlinks in Skill-Ordnern")
    }

    func testProjectInHomeFolderDoesNotLoadAccountSkillsTwice() throws {
        try write("---\nname: a\n---\n", account.appendingPathComponent("skills/a/SKILL.md"))
        let home = try ScheduledTaskRunConfigBuilder.prepare(
            task: ScheduledTask(name: "Probe", prompt: "x", directory: root.path, account: "main",
                                schedule: ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]), createdAt: Date()),
            sources: .init(configDirectory: root.appendingPathComponent(".claude"), claudeJSON: root.appendingPathComponent("x.json")),
            runDirectory: run)
        XCTAssertNil(home.pluginDirectory, "Ohne Skills kein Plugin")
        try write("---\nname: a\n---\n", root.appendingPathComponent(".claude/skills/a/SKILL.md"))
        try? FileManager.default.removeItem(at: run.appendingPathComponent("claude-config"))
        let again = try ScheduledTaskRunConfigBuilder.prepare(
            task: ScheduledTask(name: "Probe", prompt: "x", directory: root.path, account: "main",
                                schedule: ScheduledTaskSchedule(kind: .daily, times: [ScheduledTaskClockTime(hour: 7, minute: 0)!]), createdAt: Date()),
            sources: .init(configDirectory: root.appendingPathComponent(".claude"), claudeJSON: root.appendingPathComponent("x.json")),
            runDirectory: run)
        let plugins = try XCTUnwrap(again.pluginDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugins + "/account"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugins + "/project"))
    }

    func testSkillTextWithoutGrants() {
        XCTAssertNil(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants("---\nname: a\n---\nallowed-tools: Bash\n"),
                     "Nur der Kopf zählt")
        XCTAssertNil(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants("Kein Kopf\nallowed-tools: Bash\n"))
        XCTAssertNil(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants("---\nallowed-tools: Bash\n"), "Kopf ohne Ende")
        XCTAssertEqual(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants(
            "---\nname: a\nallowed-tools:\n- Bash\n- Read\ndescription: b\n---\nText"),
            "---\nname: a\ndescription: b\n---\nText")
        XCTAssertEqual(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants(
            "\u{FEFF}---\n\"allowed-tools\": Bash\nname: a\n---\n"), "---\nname: a\n---\n", "BOM und Anführungszeichen")
        // Ein eingerücktes `---` in einem Block beendet den Kopf nicht.
        let indented = "---\ndescription: |\n  Text\n  ---\nallowed-tools: Bash(curl:*)\n---\nInhalt"
        XCTAssertEqual(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants(indented),
                       "---\ndescription: |\n  Text\n  ---\n---\nInhalt")
        XCTAssertTrue(ScheduledTaskRunConfigBuilder.skillHeaderMentionsGrants("---\nmeta:\n  allowed-tools: Bash\n---\n"))
        XCTAssertFalse(ScheduledTaskRunConfigBuilder.skillHeaderMentionsGrants("---\nname: a\n---\nallowed-tools im Text\n"))
    }

    func testSkillWithGrantsLeftAfterCleaningIsNotLoaded() throws {
        try write("---\nname: tief\nmeta:\n  allowed-tools: Bash\n---\n", account.appendingPathComponent("skills/tief/SKILL.md"))
        try write("---\nname: gut\n---\n", account.appendingPathComponent("skills/gut/SKILL.md"))
        let plugins = try XCTUnwrap(try prepare(task()).pluginDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugins + "/account/skills/gut"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugins + "/account/skills/tief"))
    }

    /// Das Plugin `whisperm8` lädt in jedem Lauf ungefiltert: Seine Skills
    /// dürfen keine eigenen Freigaben tragen.
    func testOwnPluginSkillsCarryNoGrants() throws {
        for file in try SkillTextsGuardTests.skillFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(ScheduledTaskRunConfigBuilder.skillHeaderMentionsGrants(text), file.lastPathComponent)
            XCTAssertNil(ScheduledTaskRunConfigBuilder.skillTextWithoutGrants(text), file.lastPathComponent)
        }
    }

    // MARK: CLAUDE.md

    func testClaudeMdOfAccountAndProjectAreAppended() throws {
        try write("Konto-Regel", account.appendingPathComponent("CLAUDE.md"))
        try write("Projekt-Regel", project.appendingPathComponent("CLAUDE.md"))
        try write("   ", project.appendingPathComponent(".claude/CLAUDE.md"))
        let config = try prepare(task())
        let text = try String(contentsOfFile: try XCTUnwrap(config.contextFile), encoding: .utf8)
        XCTAssertTrue(text.contains("Konto-Regel"))
        XCTAssertTrue(text.contains("Projekt-Regel"))
        XCTAssertTrue(text.contains(account.appendingPathComponent("CLAUDE.md").path))
        XCTAssertLessThan(text.range(of: "Konto-Regel")!.lowerBound, text.range(of: "Projekt-Regel")!.lowerBound)
    }

    // MARK: MCP

    func testOnlyTheNamedMCPServersAreWritten() throws {
        try write("""
        {"mcpServers": {"linear": {"type": "http", "url": "https://l"}, "playwright": {"type": "stdio", "command": "npx"},
                        "slack-team": {"type": "http", "url": "https://s"}},
         "projects": {"\(project.path)": {"mcpServers": {"linear": {"type": "http", "url": "https://projekt"}}}}}
        """, root.appendingPathComponent("claude.json"))
        let config = try prepare(task(["mcp__linear__get_issue", "mcp__slack-team__slack_read_channel",
                                       "mcp__linear__list_issues", "mcp__fehlt__x"]))
        let servers = try XCTUnwrap(try json(XCTUnwrap(config.mcpConfigFile))["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["linear", "slack-team"], "playwright lädt nicht")
        XCTAssertEqual((servers["linear"] as? [String: Any])?["url"] as? String, "https://projekt", "Projekt vor Konto")

        try? FileManager.default.removeItem(at: run.appendingPathComponent("claude-config"))
        XCTAssertNil(try prepare(task(["Bash(echo:*)"])).mcpConfigFile, "Ohne MCP-Freigabe keine Datei")
    }

    func testMCPServerNames() {
        let permissions = ScheduledTaskPermissions(access: .custom, extraTools: [
            "mcp__linear-team__save_issue", " mcp__notes", "mcp__linear-team__*", "mcp__*", "Read"])
        XCTAssertEqual(permissions.mcpServerNames, ["linear-team", "notes"])
        XCTAssertEqual(ScheduledTaskRunConfigBuilder.normalizedServerName("claude.ai Claude Docs"), "claude_ai_Claude_Docs")
        let selection = ScheduledTaskRunConfigBuilder.selectMCPServers(
            named: ["claude_ai_Docs", "x"], user: ["claude.ai Docs": ["type": "http"]], project: [:])
        XCTAssertEqual(Array(selection.servers.keys), ["claude.ai Docs"])
        XCTAssertEqual(selection.missing, ["x"])
    }

    // MARK: Regeln, die nie greifen

    func testRulesThatNeverMatchAreRejected() {
        XCTAssertEqual(ScheduledTaskPermissions.ruleProblem(in: ["Read(/Users/me/Archiv/**)"]),
                       .pathRuleAnchoredAtProject("Read(/Users/me/Archiv/**)"))
        XCTAssertEqual(ScheduledTaskPermissions.ruleProblem(in: ["Edit(/Volumes/x/**)"]),
                       .pathRuleAnchoredAtProject("Edit(/Volumes/x/**)"))
        XCTAssertEqual(ScheduledTaskPermissions.ruleProblem(in: ["Write(//Users/me/x/**)"]),
                       .writeRuleNeverMatches("Write(//Users/me/x/**)"))
        XCTAssertNil(ScheduledTaskPermissions.ruleProblem(in: [
            "Read(//Users/me/**)", "Edit(~/Archiv/**)", "Edit(/src/**)", "Edit(/**)", "Write", "Edit(/var/cache/**)",
            "Read(/tmp/**)",
            "Bash(/Users/me/bericht.sh:*)", "Bash(python3 -I /Users/me/x.py:*)", "mcp__linear__get_issue"]))
    }

    func testValidationRejectsRulesThatNeverMatch() {
        var broken = task(["Write(//Users/me/x/**)"], access: .custom)
        broken.directory = "/"
        XCTAssertEqual(ScheduledTaskValidation.problem(in: broken, others: [], directoryExists: { _ in true },
                                                       accountExists: { _ in true }),
                       .writeRuleNeverMatches("Write(//Users/me/x/**)"))
    }
}
