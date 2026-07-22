import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeGPTAgentDefinitionTests: XCTestCase {
    private var directory: URL!
    private var mainFileURL: URL!
    private var installer: ClaudeGPTAgentDefinitionInstaller!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpt-agent-tests-\(UUID().uuidString)")
        mainFileURL = directory.appendingPathComponent("main/agents/gpt.md")
        installer = ClaudeGPTAgentDefinitionInstaller(fileURLs: [mainFileURL])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Extrahiert den YAML-Frontmatter-Block (zwischen erstem und zweitem
    /// `---`). Substring-Checks auf dem Gesamtinhalt wuerden auch eine
    /// auskommentierte oder hinter den Delimiter gerutschte `model:`-Zeile
    /// akzeptieren — gegen genau das sichern die Frontmatter-Assertions ab.
    private func frontmatter(of content: String) throws -> String {
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else {
            XCTFail("Kein Frontmatter-Block gefunden")
            return ""
        }
        return parts[1]
    }

    private func assertFrontmatterModel(
        _ expected: String,
        in content: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let frontmatter = try frontmatter(of: content)
        XCTAssertTrue(
            frontmatter.contains("\nmodel: \(expected)\n"),
            "Frontmatter enthaelt nicht die aktive Zeile 'model: \(expected)': \(frontmatter)",
            file: file,
            line: line
        )
    }

    func testInstallsDefinitionWithConfiguredModel() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-terra", fastEnabled: false),
            [.installed]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("gpt-5.6-terra", in: content)
        XCTAssertTrue(content.contains("name: gpt"))
        XCTAssertTrue(content.contains(ClaudeGPTAgentDefinitionInstaller.managedMarker))
    }

    func testEmptyModelFallsBackToCanonicalModel() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "  \n", fastEnabled: false),
            [.installed]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel(AppPreferences.claudeGPTCanonicalModel, in: content)
    }

    func testFastModeUsesEffectiveAliasThroughoutDefinition() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-terra", fastEnabled: true),
            [.installed]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("gpt-5.6-terra-fast", in: content)
        XCTAssertTrue(content.contains("(gpt-5.6-terra-fast, high thinking)"))
        XCTAssertTrue(content.contains("GPT-Subagent (gpt-5.6-terra-fast)"))
    }

    func testFastModeAppliesAfterCanonicalFallback() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "", fastEnabled: true),
            [.installed]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("\(AppPreferences.claudeGPTCanonicalModel)-fast", in: content)
    }

    func testFastModeStripsMemorySuffix() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol[1m]", fastEnabled: true),
            [.installed]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("gpt-5.6-sol-fast", in: content)
        XCTAssertFalse(content.lowercased().contains("gpt-5.6-sol-fast[1m]"))
    }

    func testDisallowedSubagentModelsFallBackToCanonicalSol() throws {
        XCTAssertEqual(
            installer.sync(
                backendEnabled: true,
                model: "GPT-5.6-LUNA[1M]",
                fastEnabled: true
            ),
            [.installed]
        )
        XCTAssertEqual(
            installer.sync(
                backendEnabled: true,
                model: "gpt-5.5",
                fastEnabled: true
            ),
            [.upToDate]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("gpt-5.6-sol-fast", in: content)
        XCTAssertFalse(content.lowercased().contains("gpt-5.6-luna"))
        XCTAssertFalse(content.lowercased().contains("gpt-5.5"))
    }

    func testToggleChangeUpdatesManagedDefinition() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: false),
            [.installed]
        )
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: true),
            [.updated]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("gpt-5.6-sol-fast", in: content)
    }

    func testSyncIsIdempotentAndUpdatesOnModelChange() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: false), [.installed])
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: false), [.upToDate])
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-terra", fastEnabled: false), [.updated])

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        try assertFrontmatterModel("gpt-5.6-terra", in: content)
    }

    func testDisabledBackendRemovesManagedDefinition() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: false), [.installed])
        XCTAssertEqual(installer.sync(backendEnabled: false, model: "gpt-5.6-sol", fastEnabled: false), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainFileURL.path))
        XCTAssertEqual(installer.sync(backendEnabled: false, model: "gpt-5.6-sol", fastEnabled: false), [.nothingToDo])
    }

    /// Claude Code liest User-Level-Agents aus dem CLAUDE_CONFIG_DIR der
    /// jeweiligen Session — der Installer muss deshalb main UND jedes
    /// Account-Profil bedienen (QA-Befund 2026-07-18).
    func testSyncsEveryConfiguredProfileRoot() throws {
        let profileFileURL = directory.appendingPathComponent("profiles/firma/agents/gpt.md")
        installer = ClaudeGPTAgentDefinitionInstaller(fileURLs: [mainFileURL, profileFileURL])

        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: false),
            [.installed, .installed]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mainFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileFileURL.path))

        XCTAssertEqual(
            installer.sync(backendEnabled: false, model: "gpt-5.6-sol", fastEnabled: false),
            [.removed, .removed]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileFileURL.path))
    }

    func testForeignFileIsNeverTouched() throws {
        try FileManager.default.createDirectory(
            at: mainFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = "---\nname: gpt\nmodel: claude-opus-4-8\n---\nEigene Definition des Users."
        try foreign.write(to: mainFileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol", fastEnabled: false),
            [.leftForeignFileAlone]
        )
        XCTAssertEqual(
            installer.sync(backendEnabled: false, model: "gpt-5.6-sol", fastEnabled: false),
            [.leftForeignFileAlone],
            "Auch beim Deaktivieren darf eine fremde Datei nicht entfernt werden"
        )
        XCTAssertEqual(
            try String(contentsOf: mainFileURL, encoding: .utf8),
            foreign
        )
    }
}
