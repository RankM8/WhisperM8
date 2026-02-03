import Foundation

enum APIProvider: String, CaseIterable, Codable {
    case openai
    case groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI (Beste Qualität)"
        case .groq: return "Groq (Günstiger)"
        }
    }

    var modelName: String {
        switch self {
        case .openai: return "gpt-4o-transcribe"
        case .groq: return "whisper-large-v3"
        }
    }

    var priceInfo: String {
        switch self {
        case .openai: return "$0.006/min"
        case .groq: return "$0.002/min"
        }
    }

    func createService(apiKey: String) -> TranscriptionProvider {
        switch self {
        case .openai: return OpenAITranscriptionService(apiKey: apiKey)
        case .groq: return GroqTranscriptionService(apiKey: apiKey)
        }
    }
}
