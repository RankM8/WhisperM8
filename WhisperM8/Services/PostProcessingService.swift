import Foundation
import AppKit

struct PostProcessingService {
    var processor: PostProcessing

    init(processor: PostProcessing = CodexPostProcessor()) {
        self.processor = processor
    }

    func process(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle = .empty
    ) async throws -> String {
        guard mode.usesPostProcessing else {
            return try await NoOpPostProcessor().process(
                rawText: rawText,
                mode: mode,
                language: language,
                contextBundle: contextBundle
            )
        }

        let allowedContext = allowedContextBundle(for: mode, capturedContext: contextBundle)
        if mode.contextPolicy == .required, allowedContext.isEmpty {
            throw PostProcessingError.codexUnavailable("This mode requires context, but no selected text or visual context was captured.")
        }

        return try await processor.process(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: allowedContext
        )
    }

    func allowedContextBundle(for mode: OutputMode, capturedContext: TranscriptContextBundle) -> TranscriptContextBundle {
        switch mode.contextPolicy {
        case .off:
            return .empty
        case .auto, .required:
            return capturedContext
        }
    }

    func renderedPrompt(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) -> String? {
        guard mode.usesPostProcessing,
              let template = PostProcessingTemplateStore().template(for: mode.templateID) else {
            return nil
        }
        return PromptPackageBuilder().build(
            rawText: rawText,
            mode: mode,
            template: template,
            language: language,
            contextBundle: contextBundle
        ).prompt
    }

    func promptPackage(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) -> PromptPackage? {
        guard mode.usesPostProcessing,
              let template = PostProcessingTemplateStore().template(for: mode.templateID) else {
            return nil
        }
        return PromptPackageBuilder().build(
            rawText: rawText,
            mode: mode,
            template: template,
            language: language,
            contextBundle: contextBundle
        )
    }

    func process(
        rawText: String,
        mode: OutputMode,
        language: String,
        selectedContext: SelectedContext
    ) async throws -> String {
        try await process(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: TranscriptContextBundle(selectedText: selectedContext)
        )
    }
}
