import Foundation

/// Wählt je Diktat den Weg der Nacharbeit.
///
/// - Modi mit Projektzugriff (Task, Ultra-Prompt) laufen immer über die
///   Codex-CLI: nur sie kann im Projekt lesen, und WhisperM8 baut keine eigene
///   Agent-Laufzeit.
/// - Alle anderen Modi laufen über das GPT-Backend, wenn es an ist und der
///   Schalter auf AI-Output → Konto nicht aus ist.
/// - Scheitert das Backend, übernimmt die Codex-CLI denselben Auftrag. Die
///   Daten gehen in beiden Fällen an denselben Anbieter, deshalb ist dieser
///   Rückfall vertretbar (anders als bei der Transkription). Kein Rückfall bei
///   Abbruch durch den Nutzer oder Zeitüberschreitung: dort würde der Nutzer
///   nur ein zweites Mal warten.
struct PostProcessingEngineRouter: PostProcessing {
    private let backend: PostProcessing
    private let codex: PostProcessing
    private let isBackendPreferred: () -> Bool

    init(
        backend: PostProcessing = GPTBackendPostProcessor(),
        codex: PostProcessing = CodexPostProcessor(),
        isBackendPreferred: @escaping () -> Bool = PostProcessingEngineRouter.liveBackendPreferred
    ) {
        self.backend = backend
        self.codex = codex
        self.isBackendPreferred = isBackendPreferred
    }

    /// Schalter auf AI-Output → Konto UND GPT-Backend an.
    static func liveBackendPreferred() -> Bool {
        AppPreferences.shared.isDictationGPTBackendPostProcessingEnabled
            && AppPreferences.shared.claudeGPTBackendEnabled
    }

    /// Darf dieser Modus überhaupt über das Backend laufen?
    static func isBackendEligible(_ mode: OutputMode) -> Bool {
        mode.projectAccess == .off
    }

    /// Weg, den ein Modus voraussichtlich nimmt (Einstellungen, Bericht).
    func plannedEngine(for mode: OutputMode) -> PostProcessingEngine {
        Self.isBackendEligible(mode) && isBackendPreferred() ? .gptBackend : .codexCLI
    }

    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        try await processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle).text
    }

    func processRun(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle
    ) async throws -> PostProcessingRun {
        guard plannedEngine(for: mode) == .gptBackend else {
            return try await runCodex(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle, fallbackReason: nil)
        }

        let backendError: Error
        do {
            var run = try await backend.processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle)
            run.engine = run.engine ?? .gptBackend
            return run
        } catch {
            if Self.endsRun(error) { throw error }
            backendError = error
        }

        let reason = backendError.localizedDescription
        Logger.transcription.info("dictation_postprocess_fallback from=gpt_backend to=codex_cli")
        do {
            return try await runCodex(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle, fallbackReason: reason)
        } catch {
            if Self.endsRun(error) { throw error }
            throw PostProcessingError.bothEnginesFailed(backend: reason, codex: error.localizedDescription)
        }
    }

    private func runCodex(
        rawText: String,
        mode: OutputMode,
        language: String,
        contextBundle: TranscriptContextBundle,
        fallbackReason: String?
    ) async throws -> PostProcessingRun {
        var run = try await codex.processRun(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle)
        run.engine = run.engine ?? .codexCLI
        run.fallbackReason = fallbackReason
        return run
    }

    /// Fehler, nach denen kein zweiter Weg mehr versucht wird.
    static func endsRun(_ error: Error) -> Bool {
        switch error {
        case PostProcessingError.userCancelled, PostProcessingError.timedOut, PostProcessingError.missingTemplate:
            return true
        case is CancellationError:
            return true
        default:
            return false
        }
    }
}
