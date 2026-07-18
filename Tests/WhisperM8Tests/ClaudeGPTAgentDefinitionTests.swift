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

    func testInstallsDefinitionWithConfiguredModel() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-terra"),
            [.installed]
        )

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model: gpt-5.6-terra"))
        XCTAssertTrue(content.contains("name: gpt"))
        XCTAssertTrue(content.contains(ClaudeGPTAgentDefinitionInstaller.managedMarker))
    }

    func testEmptyModelFallsBackToCanonicalModel() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "  \n"), [.installed])

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model: \(AppPreferences.claudeGPTCanonicalModel)"))
    }

    func testSyncIsIdempotentAndUpdatesOnModelChange() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol"), [.installed])
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol"), [.upToDate])
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-luna"), [.updated])

        let content = try String(contentsOf: mainFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model: gpt-5.6-luna"))
    }

    func testDisabledBackendRemovesManagedDefinition() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol"), [.installed])
        XCTAssertEqual(installer.sync(backendEnabled: false, model: "gpt-5.6-sol"), [.removed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mainFileURL.path))
        XCTAssertEqual(installer.sync(backendEnabled: false, model: "gpt-5.6-sol"), [.nothingToDo])
    }

    /// Claude Code liest User-Level-Agents aus dem CLAUDE_CONFIG_DIR der
    /// jeweiligen Session — der Installer muss deshalb main UND jedes
    /// Account-Profil bedienen (QA-Befund 2026-07-18).
    func testSyncsEveryConfiguredProfileRoot() throws {
        let profileFileURL = directory.appendingPathComponent("profiles/firma/agents/gpt.md")
        installer = ClaudeGPTAgentDefinitionInstaller(fileURLs: [mainFileURL, profileFileURL])

        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol"),
            [.installed, .installed]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mainFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileFileURL.path))

        XCTAssertEqual(
            installer.sync(backendEnabled: false, model: "gpt-5.6-sol"),
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
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol"),
            [.leftForeignFileAlone]
        )
        XCTAssertEqual(
            installer.sync(backendEnabled: false, model: "gpt-5.6-sol"),
            [.leftForeignFileAlone],
            "Auch beim Deaktivieren darf eine fremde Datei nicht entfernt werden"
        )
        XCTAssertEqual(
            try String(contentsOf: mainFileURL, encoding: .utf8),
            foreign
        )
    }
}
