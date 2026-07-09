import XCTest
@testable import WhisperM8

@MainActor
final class AIOutputModelsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OutputModeStore._resetCacheForTesting()
    }

    override func tearDown() {
        OutputModeStore._resetCacheForTesting()
        super.tearDown()
    }

    /// Die alte GPT-5.5/"0.120."-Warnheuristik ist gestrichen — Modell-Warnungen
    /// kommen jetzt katalogbasiert aus der View (CodexModelCatalog).
    func testCodexConnectionModelRefreshUsesInjectedProbe() async {
        let model = CodexConnectionModel {
            return CodexConnectionModel.Snapshot(
                status: .signedIn,
                version: "codex 0.144.0"
            )
        }

        await model.refresh()

        XCTAssertEqual(model.status, .signedIn)
        XCTAssertEqual(model.codexVersion, "codex 0.144.0")
        XCTAssertEqual(model.statusTone, .ok)
    }

    func testOutputModesViewModelCanDisableMatchesRawAndDefaultRules() throws {
        try withAIOutputIsolatedPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.cleanID
            let fileURL = aiOutputTemporaryJSONURL(prefix: "Modes")
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let model = OutputModesViewModel(fileURL: fileURL)
            let raw = try XCTUnwrap(model.modes.first { $0.id == OutputMode.rawID })
            let clean = try XCTUnwrap(model.modes.first { $0.id == OutputMode.cleanID })
            let slack = try XCTUnwrap(model.modes.first { $0.id == OutputMode.slackID })

            XCTAssertFalse(model.canDisable(raw))
            XCTAssertFalse(model.canDisable(clean))
            XCTAssertTrue(model.canDisable(slack))
        }
    }

    func testOutputModesViewModelMakeDefaultPersistsAndKeepsDefaultEnabled() throws {
        try withAIOutputIsolatedPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.cleanID
            let fileURL = aiOutputTemporaryJSONURL(prefix: "Modes")
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let model = OutputModesViewModel(fileURL: fileURL)
            model.setEnabled(false, for: OutputMode.slackID)
            model.setDefault(OutputMode.slackID)

            let slack = try XCTUnwrap(model.modes.first { $0.id == OutputMode.slackID })
            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.slackID)
            XCTAssertTrue(slack.isDefault)
            XCTAssertTrue(slack.isEnabled)

            let reloaded = OutputModeStore(fileURL: fileURL).mode(for: OutputMode.slackID)
            XCTAssertTrue(reloaded.isDefault)
            XCTAssertTrue(reloaded.isEnabled)
        }
    }

    func testOutputModesViewModelDeleteCustomDefaultFallsBackToRawLikeOldView() throws {
        try withAIOutputIsolatedPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.cleanID
            let fileURL = aiOutputTemporaryJSONURL(prefix: "Modes")
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let model = OutputModesViewModel(fileURL: fileURL)
            model.addMode()
            let customID = try XCTUnwrap(model.selectedMode?.id)
            model.setDefault(customID)
            model.deleteSelectedMode()

            XCTAssertEqual(preferences.defaultOutputModeID, OutputMode.rawID)
            XCTAssertEqual(model.defaultOutputModeID, OutputMode.rawID)
            XCTAssertFalse(model.modes.contains { $0.id == customID })
        }
    }

    func testOutputModesViewModelCodexOverrideTogglesStoreResolvedValues() throws {
        try withAIOutputIsolatedPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.cleanID
            let fileURL = aiOutputTemporaryJSONURL(prefix: "Modes")
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let model = OutputModesViewModel(fileURL: fileURL)
            model.setUsesGlobalModel(false, for: OutputMode.cleanID, defaultModelRaw: CodexPostProcessingModel.gpt52.rawValue)
            model.setUsesGlobalReasoning(false, for: OutputMode.cleanID, defaultReasoningEffortRaw: CodexReasoningEffort.high.rawValue)
            model.setUsesGlobalServiceTier(false, for: OutputMode.cleanID, defaultServiceTierRaw: CodexServiceTier.standard.rawValue)

            var clean = try XCTUnwrap(model.modes.first { $0.id == OutputMode.cleanID })
            XCTAssertEqual(clean.codexModelRawOverride, CodexPostProcessingModel.gpt52.rawValue)
            XCTAssertEqual(clean.codexReasoningEffortRawOverride, CodexReasoningEffort.high.rawValue)
            XCTAssertEqual(clean.codexServiceTierRawOverride, CodexServiceTier.standard.rawValue)
            XCTAssertTrue(model.modeSummary(clean).contains("Clean transcript"))
            XCTAssertTrue(model.modeSummary(clean).contains("Standard"))

            model.setUsesGlobalModel(true, for: OutputMode.cleanID, defaultModelRaw: CodexPostProcessingModel.gpt55.rawValue)
            clean = try XCTUnwrap(model.modes.first { $0.id == OutputMode.cleanID })
            XCTAssertNil(clean.codexModelRawOverride)
        }
    }

    func testTemplateEditorModelNewTemplateDirtyStateAndSaveValidation() throws {
        let templateURL = aiOutputTemporaryJSONURL(prefix: "Templates")
        let modesURL = aiOutputTemporaryJSONURL(prefix: "Modes")
        defer {
            try? FileManager.default.removeItem(at: templateURL)
            try? FileManager.default.removeItem(at: modesURL)
        }

        let model = TemplateEditorModel(fileURL: templateURL, outputModesFileURL: modesURL)
        model.createTemplate()
        let templateID = model.selectedTemplateID

        XCTAssertEqual(model.selectedTemplate?.isBuiltIn, false)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canSave)

        model.editableName = "   "
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canSave)
        model.saveSelectedTemplate()

        XCTAssertEqual(model.errorMessage, "Template name cannot be empty.")
        var stored = PostProcessingTemplateStore(fileURL: templateURL).loadCustomTemplates()
        XCTAssertEqual(stored.first { $0.id == templateID }?.name, "Custom template")

        model.editableName = "Validated template"
        model.editableInstruction = "   "
        model.saveSelectedTemplate()
        XCTAssertEqual(model.errorMessage, "Template instruction cannot be empty.")

        model.editableInstruction = "Rewrite {rawTranscript}"
        model.saveSelectedTemplate()

        stored = PostProcessingTemplateStore(fileURL: templateURL).loadCustomTemplates()
        XCTAssertEqual(stored.first { $0.id == templateID }?.name, "Validated template")
        XCTAssertEqual(stored.first { $0.id == templateID }?.instruction, "Rewrite {rawTranscript}")
        XCTAssertFalse(model.isDirty)
    }

    func testTemplateEditorModelDuplicatesBuiltInAndReportsUsedModes() throws {
        try withAIOutputIsolatedPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.cleanID
            let templateURL = aiOutputTemporaryJSONURL(prefix: "Templates")
            let modesURL = aiOutputTemporaryJSONURL(prefix: "Modes")
            defer {
                try? FileManager.default.removeItem(at: templateURL)
                try? FileManager.default.removeItem(at: modesURL)
            }

            var modes = OutputMode.builtInModes
            modes.append(OutputMode(
                id: "custom-template-user",
                name: "Template User",
                shortLabel: "User",
                kind: .custom,
                templateID: PostProcessingTemplate.cleanID,
                isEnabled: true,
                isDefault: false
            ))
            try OutputModeStore(fileURL: modesURL).saveModes(modes)

            let model = TemplateEditorModel(fileURL: templateURL, outputModesFileURL: modesURL)
            model.select(PostProcessingTemplate.cleanID)
            XCTAssertEqual(model.usedByModes().map(\.name), ["Clean", "Template User"])

            model.duplicateSelectedTemplate()

            XCTAssertEqual(model.selectedTemplate?.isBuiltIn, false)
            XCTAssertTrue(model.editableName.hasSuffix(" Copy"))
            XCTAssertEqual(PostProcessingTemplateStore(fileURL: templateURL).loadCustomTemplates().count, 1)
        }
    }
}

private func withAIOutputIsolatedPreferences(_ body: (AppPreferences) throws -> Void) rethrows {
    let suiteName = "WhisperM8AIOutputModelsTests-\(UUID().uuidString)"
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

private func aiOutputTemporaryJSONURL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperM8AIOutput\(prefix)-\(UUID().uuidString)")
        .appendingPathExtension("json")
}
