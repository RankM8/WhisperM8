import Foundation

enum APIProvider: String, CaseIterable, Codable {
    case openai_gpt4o = "openai_gpt4o"
    case openai_whisper = "openai_whisper"
    case groq = "groq"

    var displayName: String {
        switch self {
        case .openai_gpt4o: return "OpenAI GPT-4o"
        case .openai_whisper: return "OpenAI Whisper"
        case .groq: return "Groq"
        }
    }

    var modelName: String {
        switch self {
        case .openai_gpt4o: return "gpt-4o-transcribe"
        case .openai_whisper: return "whisper-1"
        case .groq: return "whisper-large-v3"
        }
    }

    var modelDescription: String {
        switch self {
        case .openai_gpt4o: return "Schnellstes Modell für kurze Audios (<60s)"
        case .openai_whisper: return "Stabiler für lange Audios, bewährte Qualität"
        case .groq: return "Sehr schnell, kosteneffizient"
        }
    }

    var priceInfo: String {
        switch self {
        case .openai_gpt4o: return "$0.006/min"
        case .openai_whisper: return "$0.006/min"
        case .groq: return "$0.002/min"
        }
    }

    /// The key used to store the API key in Keychain (both OpenAI variants use same key)
    var keychainKey: String {
        switch self {
        case .openai_gpt4o, .openai_whisper: return "openai_apikey"
        case .groq: return "groq_apikey"
        }
    }

    func createService(apiKey: String) -> TranscriptionProvider {
        switch self {
        case .openai_gpt4o:
            return OpenAITranscriptionService(apiKey: apiKey, model: .gpt4oTranscribe)
        case .openai_whisper:
            return OpenAITranscriptionService(apiKey: apiKey, model: .whisper1)
        case .groq:
            return GroqTranscriptionService(apiKey: apiKey)
        }
    }

    /// For migration: map old "openai" provider to new format
    static func fromLegacy(_ rawValue: String) -> APIProvider {
        if rawValue == "openai" {
            return .openai_gpt4o  // Default to GPT-4o for existing users
        }
        return APIProvider(rawValue: rawValue) ?? .openai_gpt4o
    }
}
