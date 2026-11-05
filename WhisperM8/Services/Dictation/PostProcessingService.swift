import Foundation
import AppKit

struct PostProcessingService {
    var processor: PostProcessing

    /// Default: Weiche zwischen GPT-Backend und Codex-CLI. Die Kommandozeile
    /// (`whisperm8 transcribe --mode`) übergibt ausdrücklich den
    /// `CodexPostProcessor`, weil ein CLI-Prozess keinen Proxy starten soll.
    init(processor: PostProcessing = PostProcessingEngineRouter()) {
        self.processor = processor
    }

    func process(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle = .empty
    ) async throws -> String {
        try await processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle).text
    }

    /// Weg, den die Nacharbeit dieses Modus voraussichtlich nimmt.
    func plannedEngine(for mode: OutputMode) -> PostProcessingEngine? {
        mode.usesPostProcessing ? processor.plannedEngine(for: mode) : nil
    }

    /// Wie `process`, nennt aber den Weg der Nacharbeit (Diktat-Bericht).
    func processRun(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle = .empty
    ) async throws -> PostProcessingRun {
        guard mode.usesPostProcessing else {
            return PostProcessingRun(text: rawText)
        }

        let allowedContext = allowedContextBundle(for: mode, capturedContext: contextBundle)
        if mode.contextPolicy == .required, allowedContext.isEmpty {
            throw PostProcessingError.codexUnavailable("This mode requires context, but no selected text or visual context was captured.")
        }

        var run = try await processor.processRun(
            rawText: rawText,
            mode: mode,
            language: language,
            contextBundle: allowedContext
        )
        // Gedankenstriche verbietet der Prompt; Modelle setzen sie trotzdem.
        run.text = DashFilter.apply(run.text)
        return run
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
