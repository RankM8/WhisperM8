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

    func testAgentSkillResourceLoadsAndMatchesDefinitionName() throws {
        let markdown = try makeAgentExporter().skillMarkdown()
        XCTAssertTrue(markdown.hasPrefix("---"), "Skill braucht YAML-Frontmatter")
        XCTAssertTrue(markdown.contains("name: \(CLISkillExporter.SkillDefinition.codexAgent.name)"))
        XCTAssertTrue(markdown.contains("whisperm8 agent run"))
        // Der Skill muss die verbindlichen Exit-Codes dokumentieren.
        XCTAssertTrue(markdown.contains("Exit-Codes"))
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

        try exporter.installForClaudeCode()
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

    func testInstallIsIdempotentAndUpdatesOutdatedSkill() throws {
        let exporter = makeExporter()
        let destination = try exporter.installForClaudeCode()

        // Veraltete/abweichende Installation simulieren.
        try "old content".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertTrue(exporter.isInstalledForClaudeCode)
        XCTAssertFalse(exporter.installedSkillIsCurrent)

        try exporter.installForClaudeCode()
        XCTAssertTrue(exporter.installedSkillIsCurrent)
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

    func testInstallStateUpdateAvailableWhenBundleMovedOn() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        // Simulierter alter Installationsstand: Der installierte Inhalt weicht
        // vom Bundle ab, entspricht aber exakt dem Stempel; der Stempel trägt
        // die Bundle-Hashes von damals.
        try "installierter Altstand".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let oldHashes = try XCTUnwrap(exporter.installedHashes())
        try exporter.writeInstallStamp(CLISkillExporter.InstallStamp(
            source: CLISkillExporter.InstallStamp.sourceBundle,
            updatedAt: "2026-07-01T00:00:00Z",
            installed: oldHashes,
            bundled: oldHashes
        ))

        XCTAssertEqual(exporter.installState(), .updateAvailable)
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

    func testInstallStateUpdateAvailableAfterRepoSyncWhenBundleAdvances() throws {
        let exporter = makeExporter()
        try exporter.installForClaudeCode()

        // Repo-Sync von früher, aber das Bundle hat sich seither geändert
        // (die Stempel-Bundle-Hashes passen nicht mehr) → Update ist sicher.
        try "älterer Repo-Stand".write(
            to: exporter.claudeCodeSkillURL, atomically: true, encoding: .utf8)
        let repoHashes = try XCTUnwrap(exporter.installedHashes())
        try exporter.writeInstallStamp(CLISkillExporter.InstallStamp(
            source: CLISkillExporter.InstallStamp.sourceResources,
            updatedAt: "2026-07-01T00:00:00Z",
            installed: repoHashes,
            bundled: ["SKILL.md": "veralteter-bundle-hash"]
        ))

        XCTAssertEqual(exporter.installState(), .updateAvailable)
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
