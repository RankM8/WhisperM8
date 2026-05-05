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
            OutputMode.slackID,
            OutputMode.whatsappID,
            OutputMode.notesID
        ])
        XCTAssertEqual(OutputMode.mode(for: OutputMode.emailID).shortLabel, "Mail")
        XCTAssertEqual(OutputMode.mode(for: OutputMode.whatsappID).shortLabel, "WA")
        XCTAssertEqual(OutputMode.mode(for: OutputMode.slackID).contextPolicy, .auto)
        XCTAssertEqual(OutputMode.mode(for: OutputMode.rawID).contextPolicy, .off)
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

    func testOutputModeStoreKeepsDefaultModeEnabled() throws {
        try withIsolatedOutputPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.emailID
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("WhisperM8Modes-\(UUID().uuidString)")
                .appendingPathExtension("json")
            let store = OutputModeStore(fileURL: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            var modes = OutputMode.builtInModes
            let defaultIndex = try XCTUnwrap(modes.firstIndex { $0.id == OutputMode.emailID })
            modes[defaultIndex].isEnabled = false

            try store.saveModes(modes)

            XCTAssertTrue(store.mode(for: OutputMode.emailID).isEnabled)
            XCTAssertTrue(store.enabledModes.contains { $0.id == OutputMode.emailID })
        }
    }

    func testTemplateRenderingReplacesPlaceholders() {
        let template = PostProcessingTemplate(
            id: "custom",
            name: "Custom",
            description: "Custom",
            instruction: "{rawTranscript} {selectedContext} {activeApp} {language} {date}",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            isBuiltIn: false
        )
        let rendered = template.render(
            rawTranscript: "Hallo Welt",
            language: "de",
            selectedContext: SelectedContext(
                text: "Selected Slack thread",
                sourceAppName: "Slack",
                sourceBundleIdentifier: "com.tinyspeck.slackmacgap"
            ),
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(rendered.contains("Hallo Welt"))
        XCTAssertTrue(rendered.contains("Selected Slack thread"))
        XCTAssertTrue(rendered.contains("Slack"))
        XCTAssertTrue(rendered.contains("de"))
        XCTAssertTrue(rendered.contains("1970-01-01"))
    }

    func testBuiltInTemplatesIncludeTechDenglishCleanup() {
        let template = PostProcessingTemplate.builtInTemplates.first { $0.id == PostProcessingTemplate.techCleanID }

        XCTAssertEqual(template?.name, "Tech/Denglisch clean transcript")
        XCTAssertTrue(template?.instruction.contains("Claude Code") == true)
        XCTAssertTrue(template?.instruction.contains("Preserve the speaker's meaning") == true)
    }

    func testBuiltInTemplatesIncludeChatMessageModes() {
        let slackTemplate = PostProcessingTemplate.builtInTemplates.first { $0.id == PostProcessingTemplate.slackID }
        let whatsappTemplate = PostProcessingTemplate.builtInTemplates.first { $0.id == PostProcessingTemplate.whatsappID }

        XCTAssertEqual(slackTemplate?.name, "Slack message")
        XCTAssertTrue(slackTemplate?.instruction.contains("Use Du-Form") == true)
        XCTAssertTrue(slackTemplate?.instruction.contains("friendly teammate") == true)

        XCTAssertEqual(whatsappTemplate?.name, "WhatsApp message")
        XCTAssertTrue(whatsappTemplate?.instruction.contains("Use Du-Form") == true)
        XCTAssertTrue(whatsappTemplate?.instruction.contains("short and conversational") == true)
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

    func testContextPolicyPassesSelectedContextOnlyWhenEnabled() async throws {
        let selectedContext = SelectedContext(text: "Context", sourceAppName: "Slack", sourceBundleIdentifier: nil)
        var capturedContext = SelectedContext.empty
        let service = PostProcessingService(
            processor: MockPostProcessor(output: "processed") { _, _, _, context in
                capturedContext = context
            }
        )

        _ = try await service.process(
            rawText: "raw",
            mode: OutputMode.mode(for: OutputMode.slackID),
            language: "de",
            selectedContext: selectedContext
        )

        XCTAssertEqual(capturedContext, selectedContext)

        _ = try await service.process(
            rawText: "raw",
            mode: OutputMode.mode(for: OutputMode.cleanID),
            language: "de",
            selectedContext: selectedContext
        )

        XCTAssertEqual(capturedContext, .empty)
    }
}

private func withIsolatedOutputPreferences(_ body: (AppPreferences) throws -> Void) rethrows {
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

    try body(preferences)
}
