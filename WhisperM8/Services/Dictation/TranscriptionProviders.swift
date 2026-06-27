import Foundation

// MARK: - OpenAI Models

enum OpenAIModel: String, CaseIterable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case whisper1 = "whisper-1"

    var displayName: String {
        switch self {
        case .gpt4oTranscribe: return "GPT-4o Transcribe (Schneller)"
        case .whisper1: return "Whisper (Stabiler)"
        }
    }

    var description: String {
        switch self {
        case .gpt4oTranscribe: return "Neuestes Modell, sehr schnell bei kurzen Audios"
        case .whisper1: return "Bewährtes Modell, zuverlässig bei langen Audios"
        }
    }
}

// MARK: - OpenAI Service

class OpenAITranscriptionService: TranscriptionServiceProtocol {
    private let client: MultipartTranscriptionClient

    init(apiKey: String, model: OpenAIModel = .gpt4oTranscribe) {
        self.client = MultipartTranscriptionClient(
            apiKey: apiKey,
            config: .openAI(model: model.rawValue)
        )
    }

    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval? = nil) async throws -> String {
        try await client.transcribe(audioURL: audioURL, language: language, audioDuration: audioDuration)
    }
}

// MARK: - Groq Models

enum GroqModel: String, CaseIterable {
    case whisperV3 = "whisper-large-v3"
    case whisperV3Turbo = "whisper-large-v3-turbo"

    var displayName: String {
        switch self {
        case .whisperV3: return "Whisper Large v3"
        case .whisperV3Turbo: return "Whisper Large v3 Turbo"
        }
    }
}

// MARK: - Groq Service

class GroqTranscriptionService: TranscriptionServiceProtocol {
    private let client: MultipartTranscriptionClient

    init(apiKey: String, model: GroqModel = .whisperV3) {
        self.client = MultipartTranscriptionClient(
            apiKey: apiKey,
            config: .groq(model: model.rawValue)
        )
    }

    func transcribe(audioURL: URL, language: String?, audioDuration: TimeInterval? = nil) async throws -> String {
        try await client.transcribe(audioURL: audioURL, language: language, audioDuration: audioDuration)
    }
}
