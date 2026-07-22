import XCTest
@testable import WhisperM8

/// Tests für den Skill-Export (Bundle-Ressource → ~/.claude/skills bzw.
/// Datei/Clipboard) und die CLI-Symlink-Statusermittlung.
final class CLISkillExporterTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func makeExporter() -> CLISkillExporter {
        CLISkillExporter(homeDirectory: tempHome, bundle: .module)
    }

    // MARK: Ressource

    func testSkillResourceLoadsAndMatchesExporterName() throws {
        let markdown = try makeExporter().skillMarkdown()
        XCTAssertTrue(markdown.hasPrefix("---"), "Skill braucht YAML-Frontmatter")
        // Ordnername in ~/.claude/skills muss dem Frontmatter-Namen entsprechen.
        XCTAssertTrue(markdown.contains("name: \(CLISkillExporter.skillName)"))
        XCTAssertTrue(markdown.contains("description:"))
        XCTAssertTrue(markdown.contains("whisperm8 transcribe"))
    }

    // MARK: Codex-Agent-Skill

    private func makeAgentExporter() -> CLISkillExporter {
        CLISkillExporter(definition: .codexAgent, homeDirectory: tempHome, bundle: .module)
    }

    private func makeGPTWorkflowExporter() -> CLISkillExporter {
        CLISkillExporter(definition: .gptWorkflow, homeDirectory: tempHome, bundle: .module)
    }

    func testAgentSkillResourceLoadsAndMatchesDefinitionName() throws {
        let markdown = try makeAgentExporter().skillMarkdown()
        XCTAssertTrue(markdown.hasPrefix("---"), "Skill braucht YAML-Frontmatter")
        XCTAssertTrue(markdown.contains("name: \(CLISkillExporter.SkillDefinition.codexAgent.name)"))
        XCTAssertTrue(markdown.contains("whisperm8 agent run"))
        // Der Skill muss die verbindlichen Exit-Codes und die sichtbare,
        // technische Modell-Deklaration für jeden Subagent dokumentieren.
        XCTAssertTrue(markdown.contains("Exit-Codes"))
        XCTAssertTrue(markdown.contains("subagent_type: \"gpt\""))
        XCTAssertTrue(markdown.contains("agentType: \"gpt\""))
        XCTAssertTrue(markdown.contains("Niemals Haiku"))
    }

    func testCodexRunnerDeclaresGPT56SolModel() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let definition = try String(
            contentsOf: repositoryRoot.appendingPathComponent(".claude/agents/codex-runner.md"),
            encoding: .utf8
        )

        XCTAssertTrue(definition.contains("model: gpt-5.6-sol"))
        XCTAssertFalse(definition.contains("model: sonnet"))
        XCTAssertFalse(definition.contains("model: haiku"))
    }

    func testGPTCoworkerSkillResourceLoadsAndMatchesDefinitionName() throws {
        let exporter = CLISkillExporter(
            definition: .gptCoworker,
            homeDirectory: tempHome,
            bundle: .module
        )
        let markdown = try exporter.skillMarkdown()
        XCTAssertTrue(markdown.hasPrefix("---"), "Skill braucht YAML-Frontmatter")
        XCTAssertTrue(markdown.contains("name: gpt-coworker"))
        XCTAssertEqual(exporter.definition.name, "gpt-coworker")
    }

    func testGPTWorkflowDefaultBundleLoadsProductionResources() throws {
        let exporter = CLISkillExporter(
            definition: .gptWorkflow,
            homeDirectory: tempHome
        )

        XCTAssertTrue(try exporter.skillMarkdown().contains("name: gpt-workflow"))
        for asset in exporter.definition.assets {
            XCTAssertFalse(try exporter.assetContent(asset).isEmpty)
        }
    }

    func testGPTWorkflowSkillLoadsWithExampleAssets() throws {
        let exporter = makeGPTWorkflowExporter()
        let markdown = try exporter.skillMarkdown()

        XCTAssertTrue(markdown.hasPrefix("---"), "Skill braucht YAML-Frontmatter")
        XCTAssertTrue(markdown.contains("name: gpt-workflow"))
        XCTAssertTrue(markdown.contains("examples/wf-code-review.js"))
        XCTAssertTrue(markdown.contains("examples/wf-docs-review.js"))
        XCTAssertEqual(exporter.definition.assets.count, 2)
    }

    func testAgentSkillInstallsIntoOwnFolder() throws {
        let exporter = makeAgentExporter()
        let destination = try exporter.installForClaudeCode()
        XCTAssertEqual(
            destination.deletingLastPathComponent().lastPathComponent,
            "codex-subagent"
        )
        XCTAssertTrue(exporter.installedSkillIsCurrent)
        // Beide Skills koexistieren in getrennten Ordnern.
        let transcription = makeExporter()
        try transcription.installForClaudeCode()
        XCTAssertTrue(transcription.isInstalledForClaudeCode)
        XCTAssertTrue(exporter.isInstalledForClaudeCode)
    }

    func testAgentSkillInstallsReferences() throws {
        let exporter = makeAgentExporter()
        try exporter.installForClaudeCode()

        let references = CLISkillExporter.SkillDefinition.codexAgent.references
        XCTAssertFalse(references.isEmpty, "codex-subagent muss references mitbringen")
        for reference in references {
            let url = exporter.claudeCodeReferenceURL(for: reference)
            XCTAssertTrue(
                url.path.contains("/codex-subagent/references/"),
                "Referenz muss unter references/ liegen: \(url.path)"
            )
            let written = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(written, try exporter.referenceMarkdown(reference))
        }
        // Die SKILL.md muss auf jede installierte Referenz verweisen.
        let skill = try exporter.skillMarkdown()
        for reference in references {
            XCTAssertTrue(
                skill.contains("references/\(reference.fileName)"),
                "SKILL.md verweist nicht auf \(reference.fileName)"
            )
        }
    }

    func testGPTWorkflowSkillInstallsExampleAssets() throws {
        let exporter = makeGPTWorkflowExporter()
        try exporter.installForClaudeCode()

        for asset in CLISkillExporter.SkillDefinition.gptWorkflow.assets {
            let url = exporter.claudeCodeAssetURL(for: asset)
            XCTAssertTrue(
                url.path.contains("/gpt-workflow/examples/"),
                "Workflow-Vorlage muss unter examples/ liegen: \(url.path)"
            )
            XCTAssertEqual(
                try String(contentsOf: url, encoding: .utf8),
                try exporter.assetContent(asset)
            )
        }
        XCTAssertEqual(exporter.installState(), .current)
    }

    func testGPTWorkflowSkillExportsCompleteFolder() throws {
        let exporter = makeGPTWorkflowExporter()
        let destination = tempHome.appendingPathComponent("export/gpt-workflow")

        try exporter.exportSkillDirectory(to: destination)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("examples/wf-code-review.js").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("examples/wf-docs-review.js").path))
        XCTAssertThrowsError(try exporter.exportSkillDirectory(to: destination))
    }

    func testGPTWorkflowSkillNotCurrentWhenExampleIsModified() throws {
        let exporter = makeGPTWorkflowExporter()
        try exporter.installForClaudeCode()
        let asset = try XCTUnwrap(exporter.definition.assets.first)
        let assetURL = exporter.claudeCodeAssetURL(for: asset)

        try "lokal geändert".write(to: assetURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(exporter.installState(), .modifiedLocally)
        XCTAssertThrowsError(try exporter.installForClaudeCode())
        try exporter.installForClaudeCode(force: true)
        XCTAssertEqual(exporter.installState(), .current)
    }

    func testAgentSkillNotCurrentWhenReferenceOutdated() throws {
        let exporter = makeAgentExporter()
        try exporter.installForClaudeCode()
        XCTAssertTrue(exporter.installedSkillIsCurrent)

        let reference = try XCTUnwrap(
            CLISkillExporter.SkillDefinition.codexAgent.references.first
        )
        try "veraltet".write(
            to: exporter.claudeCodeReferenceURL(for: reference),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertFalse(exporter.installedSkillIsCurrent)

        try exporter.installForClaudeCode(force: true)
        XCTAssertTrue(exporter.installedSkillIsCurrent)
    }

    func testAgentSkillInstallLeavesForeignReferenceFilesAlone() throws {
        let exporter = makeAgentExporter()
        try exporter.installForClaudeCode()

        // Lokale Ergänzung des Users simulieren — Update darf sie nicht löschen.
        let foreign = exporter.claudeCodeReferencesDirectory
            .appendingPathComponent("lokales-mapping.md")
        try "privates Betriebswissen".write(to: foreign, atomically: true, encoding: .utf8)

        try exporter.installForClaudeCode()
        XCTAssertEqual(
            try String(contentsOf: foreign, encoding: .utf8),
            "privates Betriebswissen"
        )
        XCTAssertTrue(exporter.installedSkillIsCurrent)
    }

    // MARK: Claude-Code-Install

    func testClaudeCodeSkillURLUsesSkillNamedFolder() {
        let url = makeExporter().claudeCodeSkillURL
        XCTAssertEqual(url.lastPathComponent, "SKILL.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, CLISkillExporter.skillName)
        XCTAssertTrue(url.path.hasPrefix(tempHome.path))
        XCTAssertTrue(url.path.contains("/.claude/skills/"))
    }

    func testInstallForClaudeCodeWritesSkillFile() throws {
        let exporter = makeExporter()
        XCTAssertFalse(exporter.isInstalledForClaudeCode)

        let destination = try exporter.installForClaudeCode()

        XCTAssertTrue(exporter.isInstalledForClaudeCode)
        XCTAssertTrue(exporter.installedSkillIsCurrent)
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(written, try exporter.skillMarkdown())
    }

    func testInstallRequiresForceToReplaceModifiedSkill() throws {
        let exporter = makeExporter()
        let destination = try exporter.installForClaudeCode()

        try "old content".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertTrue(exporter.isInstalledForClaudeCode)
        XCTAssertFalse(exporter.installedSkillIsCurrent)

        XCTAssertThrowsError(try exporter.installForClaudeCode())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old content")

        try exporter.installForClaudeCode(force: true)
        XCTAssertTrue(exporter.installedSkillIsCurrent)
    }

    func testInstallRejectsForeignSkillWithoutStamp() throws {
        let exporter = makeExporter()
        try FileManager.default.createDirectory(
            at: exporter.claudeCodeSkillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "fremder Skill".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try exporter.installForClaudeCode())
        XCTAssertEqual(
            try String(contentsOf: exporter.claudeCodeSkillURL, encoding: .utf8),
            "fremder Skill"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: exporter.installStampURL.path))
    }

    func testInstallNeverWritesThroughSkillSymlink() throws {
        let exporter = makeExporter()
        let external = tempHome.appendingPathComponent("external-skill.md")
        try "extern gepflegt".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: exporter.claudeCodeSkillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: exporter.claudeCodeSkillURL,
            withDestinationURL: external
        )

        XCTAssertThrowsError(try exporter.installForClaudeCode(force: true))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "extern gepflegt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: exporter.installStampURL.path))
    }

    // MARK: Drei-Wege-Status

    func testInstallStateNotInstalledWithoutSkillFile() {
        XCTAssertEqual(makeExporter().installState(), .notInstalled)
    }

    func testInstallWritesStampAndReportsCurrent() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        XCTAssertEqual(exporter.installState(), .current)
        let stamp = try XCTUnwrap(exporter.readInstallStamp())
        XCTAssertEqual(stamp.source, CLISkillExporter.InstallStamp.sourceBundle)
        XCTAssertEqual(stamp.installed, try exporter.bundledHashes())
        XCTAssertEqual(stamp.bundled, try exporter.bundledHashes())
    }

    func testInstallStateModifiedLocallyWhenInstalledDiffersFromStamp() throws {
        let exporter = makeAgentExporter()
        try exporter.installForClaudeCode()

        try "lokal editiert".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(exporter.installState(), .modifiedLocally)
    }

    func testInstallStateUnknownDriftWithoutStamp() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()
        try FileManager.default.removeItem(at: exporter.installStampURL)

        try "alter Bestand".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(exporter.installState(), .unknownDrift)
    }

    func testInstallStateUnknownDriftWhenStampedBundleDiffers() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        // Der installierte Inhalt entspricht dem Stempel. Der abweichende
        // aktuelle Bundle-Hash beweist aber weder Upgrade noch Downgrade.
        try "abweichender Installationsstand".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let stampedHashes = try XCTUnwrap(exporter.installedHashes())
        try exporter.writeInstallStamp(CLISkillExporter.InstallStamp(
            source: CLISkillExporter.InstallStamp.sourceBundle,
            updatedAt: "2026-07-01T00:00:00Z",
            installed: stampedHashes,
            bundled: stampedHashes
        ))

        XCTAssertEqual(exporter.installState(), .unknownDrift)
        XCTAssertThrowsError(try exporter.installForClaudeCode())
        XCTAssertEqual(
            try String(contentsOf: exporter.claudeCodeSkillURL, encoding: .utf8),
            "abweichender Installationsstand"
        )
        try exporter.installForClaudeCode(force: true)
        XCTAssertEqual(exporter.installState(), .current)
    }

    func testInstallStateRepoSyncedWhenResourcesNewerThanBundle() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        // Simulierter `make skills`-Stand: installiert kommt aus dem Repo und
        // ist neuer als das Bundle; die Bundle-Hashes im Stempel sind aktuell.
        try "neuerer Repo-Stand".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let repoHashes = try XCTUnwrap(exporter.installedHashes())
        try exporter.writeInstallStamp(CLISkillExporter.InstallStamp(
            source: CLISkillExporter.InstallStamp.sourceResources,
            updatedAt: "2026-07-20T00:00:00Z",
            installed: repoHashes,
            bundled: try exporter.bundledHashes()
        ))

        XCTAssertEqual(exporter.installState(), .repoSynced)
    }

    func testInstallStateRepoSyncedWithoutBundledHashes() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        try "Repo-Stand ohne App".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let repoHashes = try XCTUnwrap(exporter.installedHashes())
        try exporter.writeInstallStamp(CLISkillExporter.InstallStamp(
            source: CLISkillExporter.InstallStamp.sourceResources,
            updatedAt: "2026-07-20T00:00:00Z",
            installed: repoHashes,
            bundled: nil
        ))

        XCTAssertEqual(exporter.installState(), .repoSynced)
    }

    func testInstallStateUnknownDriftAfterRepoSyncWhenBundleDiffers() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        // Hashes belegen nur eine Abweichung, aber keine zeitliche Richtung:
        // Der installierte Repo-Stand kann neuer oder älter als das Bundle sein.
        try "abweichender Repo-Stand".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let repoHashes = try XCTUnwrap(exporter.installedHashes())
        try exporter.writeInstallStamp(CLISkillExporter.InstallStamp(
            source: CLISkillExporter.InstallStamp.sourceResources,
            updatedAt: "2026-07-01T00:00:00Z",
            installed: repoHashes,
            bundled: ["SKILL.md": "anderer-bundle-hash"]
        ))

        XCTAssertEqual(exporter.installState(), .unknownDrift)
    }

    func testInstallStampSurvivesScriptFormat() throws {
        // Das Stempel-Format von scripts/sync-skills.sh muss dekodierbar sein.
        let exporter = makeExporter()
        try exporter.installForClaudeCode()
        let json = """
        {
          "source": "resources",
          "updatedAt": "2026-07-20T12:00:00Z",
          "installed": { "SKILL.md": "abc" },
          "bundled": { "SKILL.md": "def" }
        }
        """
        try Data(json.utf8).write(to: exporter.installStampURL)
        let stamp = try XCTUnwrap(exporter.readInstallStamp())
        XCTAssertEqual(stamp.source, "resources")
        XCTAssertEqual(stamp.installed["SKILL.md"], "abc")
        XCTAssertEqual(stamp.bundled?["SKILL.md"], "def")
    }

    // MARK: sync-skills.sh

    func testSyncSkillsInstallsGPTWorkflowWithExamplesAndStamp() throws {
        let skillsHome = tempHome.appendingPathComponent("skills", isDirectory: true)

        let result = try runSyncSkills(skillsHome: skillsHome)

        XCTAssertEqual(result.status, 0, result.output)
        let workflowDirectory = skillsHome.appendingPathComponent("gpt-workflow")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workflowDirectory.appendingPathComponent("SKILL.md").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workflowDirectory.appendingPathComponent("examples/wf-code-review.js").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workflowDirectory.appendingPathComponent("examples/wf-docs-review.js").path))

        let stampData = try Data(contentsOf: workflowDirectory
            .appendingPathComponent(".whisperm8-state.json"))
        let stamp = try JSONDecoder().decode(
            CLISkillExporter.InstallStamp.self,
            from: stampData
        )
        XCTAssertNotNil(stamp.installed["examples/wf-code-review.js"])
        XCTAssertNotNil(stamp.installed["examples/wf-docs-review.js"])
    }

    func testSyncSkillsRejectsSymlinkedAssetDirectoryInRepoMirror() throws {
        let skillsHome = tempHome.appendingPathComponent("skills", isDirectory: true)
        let mirror = tempHome.appendingPathComponent("repo-mirror/gpt-workflow", isDirectory: true)
        let external = tempHome.appendingPathComponent("external-examples", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("wf-code-review.js")
        try "extern gepflegt".write(to: externalFile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: mirror.appendingPathComponent("examples"),
            withDestinationURL: external
        )

        let result = try runSyncSkills(skillsHome: skillsHome)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try String(contentsOf: externalFile, encoding: .utf8),
            "extern gepflegt"
        )
    }

    func testSyncSkillsRejectsForeignSkillAndPreservesContent() throws {
        let skillsHome = tempHome.appendingPathComponent("skills", isDirectory: true)
        let target = skillsHome.appendingPathComponent("whisperm8-transcription/SKILL.md")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fremder Skill".write(to: target, atomically: true, encoding: .utf8)

        let result = try runSyncSkills(skillsHome: skillsHome)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "fremder Skill")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.deletingLastPathComponent()
                .appendingPathComponent(".whisperm8-state.json").path
        ))
    }

    func testSyncSkillsNeverWritesThroughSkillSymlink() throws {
        let skillsHome = tempHome.appendingPathComponent("skills", isDirectory: true)
        let target = skillsHome.appendingPathComponent("whisperm8-transcription/SKILL.md")
        let external = tempHome.appendingPathComponent("external-skill.md")
        try "extern gepflegt".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)

        let result = try runSyncSkills(skillsHome: skillsHome, arguments: ["--force"])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "extern gepflegt")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.deletingLastPathComponent()
                .appendingPathComponent(".whisperm8-state.json").path
        ))
    }

    func testSyncSkillsCopyFailureDoesNotWriteStamp() throws {
        let skillsHome = tempHome.appendingPathComponent("skills", isDirectory: true)
        let failingCopy = tempHome.appendingPathComponent("failing-cp.sh")
        try "#!/bin/sh\nexit 42\n".write(
            to: failingCopy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: failingCopy.path)

        let result = try runSyncSkills(
            skillsHome: skillsHome,
            extraEnvironment: ["WHISPERM8_CP_BIN": failingCopy.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: skillsHome
                .appendingPathComponent("whisperm8-transcription/.whisperm8-state.json").path
        ))
        XCTAssertTrue(result.output.contains("FEHLER"), result.output)
    }

    private func runSyncSkills(
        skillsHome: URL,
        arguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent("scripts/sync-skills.sh").path,
        ] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["WHISPERM8_SKILLS_HOME"] = skillsHome.path
        environment["WHISPERM8_CLAUDE_HOME"] = tempHome
            .appendingPathComponent("claude-home", isDirectory: true).path
        environment["WHISPERM8_REPO_MIRROR"] = tempHome
            .appendingPathComponent("repo-mirror", isDirectory: true).path
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: CLI-Symlink-Status

    func testInstallStatusMissingWithoutSymlink() {
        let state = CLIInstallStatus.current(homeDirectory: tempHome, executableURL: nil)
        guard case .missing(let expectedPath) = state else {
            return XCTFail("Erwartet .missing, war \(state)")
        }
        XCTAssertTrue(expectedPath.hasSuffix("/.local/bin/whisperm8"))
    }

    func testInstallStatusLinkedWhenSymlinkPointsToExecutable() throws {
        let binDir = tempHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let fakeBinary = tempHome.appendingPathComponent("WhisperM8")
        try Data().write(to: fakeBinary)
        let link = binDir.appendingPathComponent(CLISymlinkInstaller.linkName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fakeBinary)

        let state = CLIInstallStatus.current(homeDirectory: tempHome, executableURL: fakeBinary)
        guard case .linked(let path) = state else {
            return XCTFail("Erwartet .linked, war \(state)")
        }
        XCTAssertEqual(path, link.path)
    }

    func testInstallStatusLinkedElsewhereWhenSymlinkPointsToOtherBinary() throws {
        let binDir = tempHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let otherBinary = tempHome.appendingPathComponent("OtherApp")
        try Data().write(to: otherBinary)
        let currentBinary = tempHome.appendingPathComponent("WhisperM8")
        try Data().write(to: currentBinary)
        let link = binDir.appendingPathComponent(CLISymlinkInstaller.linkName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: otherBinary)

        let state = CLIInstallStatus.current(homeDirectory: tempHome, executableURL: currentBinary)
        guard case .linkedElsewhere(_, let destination) = state else {
            return XCTFail("Erwartet .linkedElsewhere, war \(state)")
        }
        XCTAssertEqual(destination, otherBinary.resolvingSymlinksInPath().path)
    }

    func testInstallStatusTreatsRegularFileAsForeignInstall() throws {
        let binDir = tempHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let link = binDir.appendingPathComponent(CLISymlinkInstaller.linkName)
        try Data("#!/bin/sh".utf8).write(to: link)

        let state = CLIInstallStatus.current(homeDirectory: tempHome, executableURL: nil)
        guard case .linkedElsewhere = state else {
            return XCTFail("Erwartet .linkedElsewhere für reguläre Datei, war \(state)")
        }
    }
}
