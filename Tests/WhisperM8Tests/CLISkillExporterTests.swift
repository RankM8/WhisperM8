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
