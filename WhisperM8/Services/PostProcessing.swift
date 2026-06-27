import Foundation

protocol PostProcessing {
    func process(rawText: String, mode: OutputMode, language: String, contextBundle: TranscriptContextBundle) async throws -> String
}

enum PostProcessingError: LocalizedError, Equatable {
    case missingTemplate
    case userCancelled
    case codexUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingTemplate:
            return "No template is configured for this output mode."
        case .userCancelled:
            return "Codex wurde abgebrochen."
        case .codexUnavailable(let message):
            return message
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
