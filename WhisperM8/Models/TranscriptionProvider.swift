import Foundation

// MARK: - Transcription Provider (OpenAI or Groq)

enum TranscriptionProvider: String, CaseIterable, Codable {
    case openai
    case groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    var keychainKey: String {
        switch self {
        case .openai: return "openai_apikey"
        case .groq: return "groq_apikey"
        }
    }

    var apiKeyLink: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .groq: return URL(string: "https://console.groq.com/keys")!
        }
    }

    var priceInfo: String {
        switch self {
        case .openai: return "$0.006/min"
        case .groq: return "$0.002/min"
        }
    }

    var availableModels: [TranscriptionModel] {
        switch self {
        case .openai: return [.openai_gpt4o, .openai_whisper]
        case .groq: return [.groq_whisper_v3, .groq_whisper_v3_turbo]
        }
    }

    var defaultModel: TranscriptionModel {
        switch self {
        case .openai: return .openai_gpt4o
        case .groq: return .groq_whisper_v3
        }
    }

    func createService(apiKey: String, model: TranscriptionModel) -> TranscriptionServiceProtocol {
        switch self {
        case .openai:
            let openAIModel: OpenAIModel = model == .openai_whisper ? .whisper1 : .gpt4oTranscribe
            return OpenAITranscriptionService(apiKey: apiKey, model: openAIModel)
        case .groq:
            let groqModel: GroqModel = model == .groq_whisper_v3_turbo ? .whisperV3Turbo : .whisperV3
            return GroqTranscriptionService(apiKey: apiKey, model: groqModel)
        }
    }
}

// MARK: - Transcription Model

enum TranscriptionModel: String, CaseIterable, Codable {
    // OpenAI models
    case openai_gpt4o = "gpt-4o-transcribe"
    case openai_whisper = "whisper-1"

    // Groq models
    case groq_whisper_v3 = "whisper-large-v3"
    case groq_whisper_v3_turbo = "whisper-large-v3-turbo"

    var displayName: String {
        switch self {
        case .openai_gpt4o: return "GPT-4o Transcribe"
        case .openai_whisper: return "Whisper"
        case .groq_whisper_v3: return "Whisper Large v3"
        case .groq_whisper_v3_turbo: return "Whisper Large v3 Turbo"
        }
    }

    var description: String {
        switch self {
        case .openai_gpt4o: return "Beste Qualität, schnell bei kurzen Audios"
        case .openai_whisper: return "Bewährt, stabiler bei langen Aufnahmen"
        case .groq_whisper_v3: return "Beste Qualität bei Groq, 299x Echtzeit"
        case .groq_whisper_v3_turbo: return "Schneller, 216x Echtzeit"
        }
    }

    var provider: TranscriptionProvider {
        switch self {
        case .openai_gpt4o, .openai_whisper: return .openai
        case .groq_whisper_v3, .groq_whisper_v3_turbo: return .groq
        }
    }
}

// MARK: - Migration from old APIProvider

struct TranscriptionSettings {
    /// Migrate old APIProvider format to new Provider + Model format
    /// Old format: "openai_gpt4o", "openai_whisper", "groq"
    /// New format: provider="openai"/"groq", model="gpt-4o-transcribe"/"whisper-1" etc.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard

        // Check if already migrated (new keys exist)
        if defaults.string(forKey: "selectedModel") != nil {
            return  // Already migrated
        }

        // Read old provider value
        let oldProviderRaw = defaults.string(forKey: "selectedProvider") ?? "openai_gpt4o"

        // Map old values to new provider + model
        let (newProvider, newModel): (TranscriptionProvider, TranscriptionModel)

        switch oldProviderRaw {
        case "openai_gpt4o", "openai":
            newProvider = .openai
            newModel = .openai_gpt4o
        case "openai_whisper":
            newProvider = .openai
            newModel = .openai_whisper
        case "groq":
            newProvider = .groq
            newModel = .groq_whisper_v3
        default:
            // Default to OpenAI GPT-4o
            newProvider = .openai
            newModel = .openai_gpt4o
        }

        // Save new values
        defaults.set(newProvider.rawValue, forKey: "selectedProvider")
        defaults.set(newModel.rawValue, forKey: "selectedModel")

        Logger.debug("Migrated settings: \(oldProviderRaw) -> provider=\(newProvider.rawValue), model=\(newModel.rawValue)")
    }

    /// Load current provider from UserDefaults
    static func loadProvider() -> TranscriptionProvider {
        let raw = UserDefaults.standard.string(forKey: "selectedProvider") ?? "openai"
        return TranscriptionProvider(rawValue: raw) ?? .openai
    }

    /// Load current model from UserDefaults
    static func loadModel() -> TranscriptionModel {
        let raw = UserDefaults.standard.string(forKey: "selectedModel") ?? "gpt-4o-transcribe"
        return TranscriptionModel(rawValue: raw) ?? .openai_gpt4o
    }

    /// Save provider and update model if needed
    static func saveProvider(_ provider: TranscriptionProvider) {
        let defaults = UserDefaults.standard
        defaults.set(provider.rawValue, forKey: "selectedProvider")

        // If current model doesn't belong to new provider, switch to default
        let currentModel = loadModel()
        if currentModel.provider != provider {
            defaults.set(provider.defaultModel.rawValue, forKey: "selectedModel")
        }
    }

    /// Save model (also updates provider to match)
    static func saveModel(_ model: TranscriptionModel) {
        let defaults = UserDefaults.standard
        defaults.set(model.rawValue, forKey: "selectedModel")
        defaults.set(model.provider.rawValue, forKey: "selectedProvider")
    }
}
