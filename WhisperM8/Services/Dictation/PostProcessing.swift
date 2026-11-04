import Foundation

/// Welcher Weg die Nacharbeit geliefert hat (Diktat-Bericht, Log).
enum PostProcessingEngine: String, Codable, Equatable {
    /// Direkte Anfrage an den GPT-Proxy (`/v1/messages`).
    case gptBackend
    /// `codex exec` als eigener Prozess.
    case codexCLI
}

/// Ergebnis eines Nacharbeits-Laufs samt Herkunft.
struct PostProcessingRun: Equatable {
    var text: String
    /// `nil` = Prozessor ohne Angabe (Tests, Rohtext-Modus).
    var engine: PostProcessingEngine?
    /// GPT-Konto, wenn das Backend geliefert hat.
    var gptProfile: String?
    /// Warum das Backend nicht geliefert hat und Codex übernommen hat.
    var fallbackReason: String?
}

protocol PostProcessing {
    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String
    /// Wie `process`, nennt aber den Weg. Default: `process` ohne Angabe.
    func processRun(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> PostProcessingRun
}

extension PostProcessing {
    func processRun(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> PostProcessingRun {
        PostProcessingRun(
            text: try await process(rawText: rawText, mode: mode, language: language, contextBundle: contextBundle)
        )
    }
}

enum PostProcessingError: LocalizedError, Equatable {
    case missingTemplate
    case userCancelled
    case timedOut(TimeInterval)
    case codexUnavailable(String)
    /// GPT-Backend und der Rückfall auf die Codex-CLI sind beide gescheitert.
    case bothEnginesFailed(backend: String, codex: String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate:
            return "No template is configured for this output mode."
        case .userCancelled:
            return String(localized: "The text clean-up was cancelled.")
        case .timedOut(let seconds):
            // Verständlich statt Fachwort (Review W2b). Unter zwei Minuten in
            // Sekunden, sonst in Minuten.
            if seconds < 120 {
                let wholeSeconds = Int(seconds.rounded())
                return String(localized: "The text clean-up didn't answer within \(wholeSeconds) seconds and was stopped.")
            }
            let minutes = max(1, Int((seconds / 60).rounded()))
            return String(localized: "The text clean-up didn't answer within \(minutes) minutes and was stopped.")
        case .codexUnavailable(let message):
            return message
        case .bothEnginesFailed(let backend, let codex):
            return String(localized: "The text clean-up failed. GPT backend: \(backend) Codex CLI: \(codex)")
        }
    }
}

struct NoOpPostProcessor: PostProcessing {
    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        rawText
    }
}

struct MockPostProcessor: PostProcessing {
    var output: String
    var onProcess: ((String, OutputMode, String, TranscriptContextBundle) -> Void)?

    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String {
        onProcess?(rawText, mode, language, contextBundle)
        return output
    }
}
