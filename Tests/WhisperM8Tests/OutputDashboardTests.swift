import Foundation
import XCTest
@testable import WhisperM8

final class OutputDashboardTests: XCTestCase {
    func testBuiltInModesUseExpectedLabels() {
        let modes = OutputMode.builtInModes

        XCTAssertEqual(modes.map(\.id), [
            OutputMode.rawID,
            OutputMode.cleanID,
            OutputMode.emailID,
            OutputMode.notesID
        ])
        XCTAssertEqual(OutputMode.mode(for: OutputMode.emailID).shortLabel, "Mail")
        XCTAssertFalse(OutputMode.mode(for: OutputMode.rawID).usesPostProcessing)
        XCTAssertTrue(OutputMode.mode(for: OutputMode.cleanID).usesPostProcessing)
    }

    func testCodexPostProcessingModelDefaultsToGPT55() {
        XCTAssertEqual(CodexPostProcessingModel.defaultModel.rawValue, "gpt-5.5")
        XCTAssertEqual(CodexPostProcessingModel.resolve("unknown"), .gpt55)
        XCTAssertEqual(CodexPostProcessingModel.resolve("gpt-5.2"), .gpt52)
    }

    func testCodexReasoningEffortDefaultsToMedium() {
        XCTAssertEqual(CodexReasoningEffort.defaultEffort, .medium)
        XCTAssertEqual(CodexReasoningEffort.resolve("xhigh"), .xhigh)
        XCTAssertEqual(CodexReasoningEffort.resolve("unknown"), .medium)
    }

    func testDefaultModePreferenceSaveLoad() {
        withIsolatedOutputPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.notesID

            XCTAssertEqual(OutputMode.defaultMode().id, OutputMode.notesID)
        }
    }

    func testOutputModeStoreSavesModeOverrides() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Modes-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let store = OutputModeStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var modes = OutputMode.builtInModes
        modes[0].isEnabled = false
        modes[1].shortLabel = "Fix"
        modes[1].isEnabled = false

        try store.saveModes(modes)

        XCTAssertTrue(store.mode(for: OutputMode.rawID).isEnabled)
        XCTAssertEqual(store.mode(for: OutputMode.cleanID).shortLabel, "Fix")
        XCTAssertFalse(store.mode(for: OutputMode.cleanID).isEnabled)
    }

    func testTemplateRenderingReplacesPlaceholders() {
        let template = PostProcessingTemplate(
            id: "custom",
            name: "Custom",
            description: "Custom",
            instruction: "{rawTranscript} {language} {date}",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            isBuiltIn: false
        )
        let rendered = template.render(
            rawTranscript: "Hallo Welt",
            language: "de",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(rendered.contains("Hallo Welt"))
        XCTAssertTrue(rendered.contains("de"))
        XCTAssertTrue(rendered.contains("1970-01-01"))
    }

    func testBuiltInTemplatesIncludeTechDenglishCleanup() {
        let template = PostProcessingTemplate.builtInTemplates.first { $0.id == PostProcessingTemplate.techCleanID }

        XCTAssertEqual(template?.name, "Tech/Denglisch clean transcript")
        XCTAssertTrue(template?.instruction.contains("Claude Code") == true)
        XCTAssertTrue(template?.instruction.contains("Preserve the speaker's meaning") == true)
    }

    func testTemplateStoreLoadsBuiltInsAndSavesCustomTemplates() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Tests-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let store = PostProcessingTemplateStore(fileURL: fileURL)
        let custom = PostProcessingTemplate(
            id: "custom",
            name: "Custom",
            description: "Custom template",
            instruction: "{rawTranscript}",
            createdAt: Date(),
            updatedAt: Date(),
            isBuiltIn: false
        )

        try store.saveCustomTemplates([custom])
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(store.templates.contains { $0.isBuiltIn })
        XCTAssertEqual(store.loadCustomTemplates().map(\.id), ["custom"])
    }

    func testBuiltInTemplateCanBeDuplicatedAsCustomTemplate() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Tests-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let store = PostProcessingTemplateStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let duplicated = try store.duplicate(PostProcessingTemplate.builtInTemplates[0])

        XCTAssertFalse(duplicated.isBuiltIn)
        XCTAssertTrue(store.loadCustomTemplates().contains { $0.id == duplicated.id })
    }

    func testRawModeDoesNotCallConfiguredPostProcessor() async throws {
        let service = PostProcessingService(processor: MockPostProcessor(output: "processed"))
        let output = try await service.process(rawText: "raw", mode: OutputMode.mode(for: OutputMode.rawID), language: "de")

        XCTAssertEqual(output, "raw")
    }

    func testBuiltInModeCallsConfiguredPostProcessor() async throws {
        let service = PostProcessingService(processor: MockPostProcessor(output: "processed"))
        let output = try await service.process(rawText: "raw", mode: OutputMode.mode(for: OutputMode.cleanID), language: "de")

        XCTAssertEqual(output, "processed")
    }
}

private func withIsolatedOutputPreferences(_ body: (AppPreferences) -> Void) {
    let suiteName = "WhisperM8OutputTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let original = AppPreferences.shared
    let preferences = AppPreferences(defaults: defaults)
    AppPreferences.shared = preferences
    defer {
        AppPreferences.shared = original
        defaults.removePersistentDomain(forName: suiteName)
    }

    body(preferences)
}
