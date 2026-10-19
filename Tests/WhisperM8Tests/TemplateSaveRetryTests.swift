import Foundation
import XCTest
@testable import WhisperM8

/// LR-ONB-015: nach einem fehlgeschlagenen Speichern bleibt der Entwurf dirty und Save aktiv.
@MainActor
final class TemplateSaveRetryTests: XCTestCase {
    func testFailedSaveKeepsDraftDirtyAndRetryWorksAfterFix() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemplateSaveRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let templateURL = directory.appendingPathComponent("templates.json")
        let modesURL = directory.appendingPathComponent("modes.json")

        let model = TemplateEditorModel(fileURL: templateURL, outputModesFileURL: modesURL)
        model.createTemplate()
        let originalName = try XCTUnwrap(model.selectedTemplate?.name)

        // Schreibschutz simuliert volle Platte / fehlende Rechte.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        model.editableName = "Neuer Name"
        model.saveSelectedTemplate()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.canSave, "Save muss für den Retry aktiv bleiben")
        XCTAssertEqual(model.selectedTemplate?.name, originalName, "bestätigter Stand bleibt unverändert")

        // Problem behoben: derselbe, unveränderte Entwurf lässt sich speichern.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        model.saveSelectedTemplate()

        XCTAssertEqual(model.selectedTemplate?.name, "Neuer Name")
        XCTAssertFalse(model.canSave)
    }
}
