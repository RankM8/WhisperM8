import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeGPTAgentDefinitionTests: XCTestCase {
    private var directory: URL!
    private var installer: ClaudeGPTAgentDefinitionInstaller!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpt-agent-tests-\(UUID().uuidString)")
        installer = ClaudeGPTAgentDefinitionInstaller(
            fileURL: directory.appendingPathComponent("agents/gpt.md")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testInstallsDefinitionWithConfiguredModel() throws {
        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-terra"),
            .installed
        )

        let content = try String(contentsOf: installer.fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model: gpt-5.6-terra"))
        XCTAssertTrue(content.contains("name: gpt"))
        XCTAssertTrue(content.contains(ClaudeGPTAgentDefinitionInstaller.managedMarker))
    }

    func testEmptyModelFallsBackToCanonicalModel() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "  \n"), .installed)

        let content = try String(contentsOf: installer.fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model: \(AppPreferences.claudeGPTCanonicalModel)"))
    }

    func testSyncIsIdempotentAndUpdatesOnModelChange() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol"), .installed)
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol"), .upToDate)
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-luna"), .updated)

        let content = try String(contentsOf: installer.fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("model: gpt-5.6-luna"))
    }

    func testDisabledBackendRemovesManagedDefinition() throws {
        XCTAssertEqual(installer.sync(backendEnabled: true, model: "gpt-5.6-sol"), .installed)
        XCTAssertEqual(installer.sync(backendEnabled: false, model: "gpt-5.6-sol"), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.fileURL.path))
        XCTAssertEqual(installer.sync(backendEnabled: false, model: "gpt-5.6-sol"), .nothingToDo)
    }

    func testForeignFileIsNeverTouched() throws {
        try FileManager.default.createDirectory(
            at: installer.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = "---\nname: gpt\nmodel: claude-opus-4-8\n---\nEigene Definition des Users."
        try foreign.write(to: installer.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            installer.sync(backendEnabled: true, model: "gpt-5.6-sol"),
            .leftForeignFileAlone
        )
        XCTAssertEqual(
            installer.sync(backendEnabled: false, model: "gpt-5.6-sol"),
            .leftForeignFileAlone,
            "Auch beim Deaktivieren darf eine fremde Datei nicht entfernt werden"
        )
        XCTAssertEqual(
            try String(contentsOf: installer.fileURL, encoding: .utf8),
            foreign
        )
    }
}
