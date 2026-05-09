import Foundation
import XCTest
@testable import WhisperM8

final class OutputDashboardTests: XCTestCase {
    func testBuiltInModesUseExpectedLabels() {
        let modes = OutputMode.builtInModes

        XCTAssertEqual(modes.map(\.id), [
            OutputMode.rawID,
            OutputMode.cleanID,
            OutputMode.promptID,
            OutputMode.taskID,
            OutputMode.emailID,
            OutputMode.slackID,
            OutputMode.whatsappID,
            OutputMode.notesID
        ])
        XCTAssertEqual(OutputMode.mode(for: OutputMode.emailID).shortLabel, "Mail")
        XCTAssertEqual(OutputMode.mode(for: OutputMode.whatsappID).shortLabel, "WA")
        XCTAssertEqual(OutputMode.mode(for: OutputMode.slackID).contextPolicy, .auto)
        XCTAssertEqual(OutputMode.mode(for: OutputMode.promptID).contextPolicy, .auto)
        XCTAssertEqual(OutputMode.mode(for: OutputMode.taskID).contextPolicy, .auto)
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
        try withIsolatedOutputPreferences { preferences in
            preferences.defaultOutputModeID = OutputMode.cleanID
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Modes-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let store = OutputModeStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var modes = OutputMode.builtInModes
        modes[0].isEnabled = false
        modes[2].shortLabel = "Ask"
        modes[2].isEnabled = false

        try store.saveModes(modes)

        XCTAssertTrue(store.mode(for: OutputMode.rawID).isEnabled)
        XCTAssertEqual(store.mode(for: OutputMode.promptID).shortLabel, "Ask")
        XCTAssertFalse(store.mode(for: OutputMode.promptID).isEnabled)
        }
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
            instruction: "{rawTranscript} {selectedContext} {activeApp} {visualContextSummary} {attachmentCount} {language} {date}",
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

    func testBuiltInTemplatesIncludePromptAndTaskModes() {
        let promptTemplate = PostProcessingTemplate.builtInTemplates.first { $0.id == PostProcessingTemplate.promptID }
        let taskTemplate = PostProcessingTemplate.builtInTemplates.first { $0.id == PostProcessingTemplate.taskID }

        XCTAssertEqual(promptTemplate?.name, "Agent prompt")
        XCTAssertTrue(promptTemplate?.instruction.contains("Markdown prompt") == true)
        XCTAssertEqual(taskTemplate?.name, "Agent task")
        XCTAssertTrue(taskTemplate?.instruction.contains("Execute this task") == true)
        XCTAssertTrue(taskTemplate?.instruction.contains("Do not output a prompt") == true)
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
        var capturedContext = TranscriptContextBundle.empty
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

        XCTAssertEqual(capturedContext.selectedText, selectedContext)

        _ = try await service.process(
            rawText: "raw",
            mode: OutputMode.mode(for: OutputMode.cleanID),
            language: "de",
            selectedContext: selectedContext
        )

        XCTAssertEqual(capturedContext, .empty)
    }

    func testCodexInvocationIncludesImageArguments() {
        let outputURL = URL(fileURLWithPath: "/tmp/output.txt")
        let imageURL = URL(fileURLWithPath: "/tmp/context.png")

        let arguments = CodexInvocation.arguments(
            promptImageURLs: [imageURL],
            outputURL: outputURL,
            model: "gpt-5.5",
            reasoningEffort: "medium"
        )

        XCTAssertTrue(arguments.contains("--image"))
        XCTAssertTrue(arguments.contains("/tmp/context.png"))
        XCTAssertEqual(arguments.last, "-")
    }

    func testReplyIntentRouterClassifiesModes() {
        let router = ReplyIntentRouter()
        let context = TranscriptContextBundle(
            screenshots: [ContextAttachment(kind: .screenshot, fileURL: URL(fileURLWithPath: "/tmp/shot.png"))]
        )

        XCTAssertEqual(
            router.route(rawText: "formuliere das locker", mode: OutputMode.mode(for: OutputMode.slackID), contextBundle: .empty),
            .rewrite
        )
        XCTAssertEqual(
            router.route(rawText: "antworte darauf", mode: OutputMode.mode(for: OutputMode.slackID), contextBundle: context),
            .agenticReply
        )
        XCTAssertEqual(
            router.route(rawText: "mach daraus einen prompt", mode: OutputMode.mode(for: OutputMode.promptID), contextBundle: context),
            .promptPackage
        )
        XCTAssertEqual(
            router.route(rawText: "recherchiere das kurz", mode: OutputMode.mode(for: OutputMode.taskID), contextBundle: context),
            .taskPrompt
        )
    }

    func testTaskPromptPackageInstructsExecutionNotPromptGeneration() {
        let package = PromptPackageBuilder().build(
            rawText: "Recherchiere kurz, ob das funktioniert, und gib mir eine Antwort.",
            mode: OutputMode.mode(for: OutputMode.taskID),
            template: PostProcessingTemplate.builtInTemplate(id: PostProcessingTemplate.taskID)!,
            language: "de",
            contextBundle: .empty
        )

        XCTAssertEqual(package.intent, .taskPrompt)
        XCTAssertTrue(package.prompt.contains("Task mode must not return a prompt"))
        XCTAssertTrue(package.prompt.contains("Execute this task"))
    }

    func testPromptPackageIncludesGlobalContractAndVisualManifest() {
        let screenshot = ContextAttachment(
            kind: .screenshot,
            fileURL: URL(fileURLWithPath: "/tmp/context.png"),
            sourceAppName: "Chrome"
        )
        let bundle = TranscriptContextBundle(screenshots: [screenshot], sourceAppName: "Chrome")
        let package = PromptPackageBuilder().build(
            rawText: "Schreib einen guten Prompt.",
            mode: OutputMode.mode(for: OutputMode.promptID),
            template: PostProcessingTemplate.builtInTemplate(id: PostProcessingTemplate.promptID)!,
            language: "de",
            contextBundle: bundle
        )

        XCTAssertEqual(package.intent, .promptPackage)
        XCTAssertTrue(package.prompt.contains("You are WhisperM8's post-processing agent."))
        XCTAssertTrue(package.prompt.contains("Visual manifest:"))
        XCTAssertTrue(package.prompt.contains("Screenshot 1"))
        XCTAssertTrue(package.prompt.contains("/tmp/context.png"))
    }

    func testContextBundleStoresAttachments() {
        let screenshot = ContextAttachment(
            kind: .screenshot,
            fileURL: URL(fileURLWithPath: "/tmp/shot.png")
        )
        let frame = ContextAttachment(
            kind: .visualFrame,
            fileURL: URL(fileURLWithPath: "/tmp/frame.png")
        )
        let annotation = ContextAttachment(
            kind: .annotation,
            fileURL: URL(fileURLWithPath: "/tmp/mark.png"),
            annotationNumber: 1,
            annotationComment: "Make this smaller",
            annotationRect: CGRect(x: 10, y: 20, width: 30, height: 40)
        )
        let bundle = TranscriptContextBundle(
            selectedText: SelectedContext(text: "Selected", sourceAppName: "Slack", sourceBundleIdentifier: nil),
            screenshots: [screenshot],
            annotations: [annotation],
            visualFrames: [frame]
        )

        XCTAssertEqual(bundle.attachmentCount, 3)
        XCTAssertEqual(bundle.visualAttachments.map(\.fileURL.path), ["/tmp/shot.png", "/tmp/mark.png", "/tmp/frame.png"])
        XCTAssertTrue(bundle.displaySummary.contains("Text"))
        XCTAssertTrue(bundle.displaySummary.contains("Shot"))
        XCTAssertTrue(bundle.displaySummary.contains("Mark"))
        XCTAssertTrue(bundle.visualContextSummary.contains("Make this smaller"))
    }

    func testVideoVisualInputKeepsFramesAndVideoPath() {
        let clipURL = URL(fileURLWithPath: "/tmp/clip.mp4")
        let frameURL = URL(fileURLWithPath: "/tmp/frame.png")
        let bundle = TranscriptContextBundle(
            screenClips: [ContextAttachment(kind: .screenClip, fileURL: clipURL)],
            visualFrames: [ContextAttachment(kind: .visualFrame, fileURL: frameURL)]
        )

        let selection = CodexVisualInputSelection(
            contextBundle: bundle,
            modeRaw: CodexVisualInputMode.video.rawValue
        )

        XCTAssertEqual(selection.videoURLs.map(\.path), ["/tmp/clip.mp4"])
        XCTAssertEqual(selection.imageURLs.map(\.path), ["/tmp/frame.png"])
        XCTAssertTrue(selection.usesFrameFallback)
        XCTAssertTrue(bundle.visualContextSummary.contains("/tmp/clip.mp4"))
    }

    func testTranscriptRunReportStorePersistsContextAndOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ReportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceImage = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: sourceImage)

        let store = TranscriptRunReportStore(
            reportsDirectory: root.appendingPathComponent("Reports", isDirectory: true)
        )
        let report = try store.save(TranscriptRunReportDraft(
            sourceAppName: "Slack",
            sourceBundleIdentifier: "com.tinyspeck.slackmacgap",
            status: .succeeded,
            errorMessage: nil,
            mode: OutputMode.mode(for: OutputMode.slackID),
            provider: .openai,
            transcriptionModel: .openai_gpt4o,
            language: "de",
            audioDuration: 3.2,
            contextBundle: TranscriptContextBundle(
                selectedText: SelectedContext(text: "selected context", sourceAppName: "Slack", sourceBundleIdentifier: nil),
                screenshots: [ContextAttachment(kind: .screenshot, fileURL: sourceImage)]
            ),
            renderedPrompt: "Prompt",
            replyIntent: .contextAnswer,
            visualManifest: VisualManifest(entries: []),
            rawTranscript: "Raw",
            finalTranscript: "Final",
            copiedToClipboard: true,
            autoPasteRequested: true
        ))

        let recentReports = store.recentReports()
        XCTAssertEqual(recentReports.first?.id, report.id)
        XCTAssertEqual(recentReports.first?.selectedText, "selected context")
        XCTAssertEqual(recentReports.first?.attachments.count, 1)
        XCTAssertEqual(recentReports.first?.replyIntent, .contextAnswer)
        XCTAssertEqual(recentReports.first?.attachments.first?.includedInCodexInput, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentReports.first?.attachments.first?.storedPath ?? ""))
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
