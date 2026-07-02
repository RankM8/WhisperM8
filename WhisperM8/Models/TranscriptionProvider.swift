import Foundation

// MARK: - Transcription Provider (OpenAI or Groq)

enum TranscriptionProvider: String, CaseIterable, Codable {
    case openai
    case groq

    /// Anzeige-/Auswahlreihenfolge in Pickern: Groq zuerst (empfohlen, kostenloser
    /// API-Key), OpenAI als Alternative. Bewusst getrennt von `allCases`, damit die
    /// Enum-Reihenfolge (und damit versteckte Abhängigkeiten) unangetastet bleibt.
    static let displayOrder: [TranscriptionProvider] = [.groq, .openai]

    /// Empfohlener Default-Provider für neue Nutzer (kostenloser Key, für Personal Use
    /// ausreichend).
    static let recommended: TranscriptionProvider = .groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    var isRecommended: Bool { self == Self.recommended }

    /// Kleine, zurückhaltende Badge — nur für den empfohlenen Provider.
    var recommendationBadge: String? {
        isRecommended ? "Free API key" : nil
    }

    /// Kurze, sachliche Empfehlungszeile — nur für den empfohlenen Provider.
    var recommendationHint: String? {
        isRecommended
            ? "Recommended for personal use. Free key available; low-cost if you exceed free limits."
            : nil
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
        let preferences = AppPreferences.shared

        // Check if already migrated (new keys exist)
        if preferences.selectedModelRaw != nil {
            return  // Already migrated
        }

        // Clean install: noch nie ein Provider gespeichert → empfohlener Default (Groq,
        // kostenloser Key). Nur echte Erstinstallationen landen hier; Bestandsnutzer haben
        // `selectedProviderRaw` gesetzt und durchlaufen unten das Legacy-Mapping.
        guard let oldProviderRaw = preferences.selectedProviderRaw else {
            preferences.selectedProviderRaw = TranscriptionProvider.groq.rawValue
            preferences.selectedModelRaw = TranscriptionModel.groq_whisper_v3.rawValue
            Logger.debug("Clean install: defaulting transcription to Groq / whisper-large-v3")
            return
        }

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
        preferences.selectedProviderRaw = newProvider.rawValue
        preferences.selectedModelRaw = newModel.rawValue

        Logger.debug("Migrated settings: \(oldProviderRaw) -> provider=\(newProvider.rawValue), model=\(newModel.rawValue)")
    }

    /// Load current provider from UserDefaults. Fallback = empfohlener Default (Groq),
    /// falls noch nichts gesetzt/migriert wurde.
    static func loadProvider() -> TranscriptionProvider {
        let raw = AppPreferences.shared.selectedProviderRaw ?? TranscriptionProvider.groq.rawValue
        return TranscriptionProvider(rawValue: raw) ?? .groq
    }

    /// Load current model from UserDefaults. Fallback = Groq-Default-Modell.
    static func loadModel() -> TranscriptionModel {
        let raw = AppPreferences.shared.selectedModelRaw ?? TranscriptionModel.groq_whisper_v3.rawValue
        return TranscriptionModel(rawValue: raw) ?? .groq_whisper_v3
    }

    /// Save provider and update model if needed
    static func saveProvider(_ provider: TranscriptionProvider) {
        let preferences = AppPreferences.shared
        preferences.selectedProviderRaw = provider.rawValue

        // If current model doesn't belong to new provider, switch to default
        let currentModel = loadModel()
        if currentModel.provider != provider {
            preferences.selectedModelRaw = provider.defaultModel.rawValue
        }
    }

    /// Save model (also updates provider to match)
    static func saveModel(_ model: TranscriptionModel) {
        let preferences = AppPreferences.shared
        preferences.selectedModelRaw = model.rawValue
        preferences.selectedProviderRaw = model.provider.rawValue
    }
}
