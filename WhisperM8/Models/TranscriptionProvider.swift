import Foundation

// MARK: - Transcription Provider (OpenAI, Groq oder ChatGPT-Abo)

enum TranscriptionProvider: String, CaseIterable, Codable {
    case openai
    case groq
    /// ChatGPT-Abo über den lokalen GPT-Proxy (GPT-Backend) — kein API-Key,
    /// inoffizieller Upstream-Endpoint. Opt-in, nur im Diktat der App (die
    /// CLI lehnt ihn ab). Kill-Switch: `chatGPTTranscriptionEnabled`.
    case chatgpt

    /// Anzeige-/Auswahlreihenfolge in Pickern: Groq zuerst (empfohlen, kostenloser
    /// API-Key), OpenAI als Alternative. Bewusst getrennt von `allCases`, damit die
    /// Enum-Reihenfolge (und damit versteckte Abhängigkeiten) unangetastet bleibt.
    /// Enthält bewusst nur die Key-Anbieter — `.chatgpt` hängt
    /// `selectableProviders(chatGPTAvailable:)` an, wenn er wählbar ist.
    static let displayOrder: [TranscriptionProvider] = [.groq, .openai]

    /// Picker-Optionen: `displayOrder` plus, falls verfügbar, „ChatGPT-Abo"
    /// am Ende.
    static func selectableProviders(chatGPTAvailable: Bool) -> [TranscriptionProvider] {
        chatGPTAvailable ? displayOrder + [.chatgpt] : displayOrder
    }

    /// Empfohlener Default-Provider für neue Nutzer (kostenloser Key, für Personal Use
    /// ausreichend).
    static let recommended: TranscriptionProvider = .groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        case .chatgpt: return "ChatGPT-Abo"
        }
    }

    /// Braucht der Anbieter einen eigenen API-Key im Schlüsselbund? Das
    /// ChatGPT-Abo nutzt den Login des GPT-Backends.
    var requiresAPIKey: Bool {
        self != .chatgpt
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

    /// Schlüsselbund-Eintrag des API-Keys; `nil` für Anbieter ohne Key
    /// (`requiresAPIKey == false`).
    var keychainKey: String? {
        switch self {
        case .openai: return "openai_apikey"
        case .groq: return "groq_apikey"
        case .chatgpt: return nil
        }
    }

    var apiKeyLink: URL? {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .groq: return URL(string: "https://console.groq.com/keys")!
        case .chatgpt: return nil
        }
    }

    var priceInfo: String {
        switch self {
        case .openai: return "$0.006/min"
        case .groq: return "$0.002/min"
        // Bewusst nicht „kostenlos": unklar, ob die Transkription auf die
        // Nutzungslimits des ChatGPT-Kontos zählt.
        case .chatgpt: return "im ChatGPT-Abo enthalten"
        }
    }

    var availableModels: [TranscriptionModel] {
        switch self {
        case .openai: return [.openai_gpt4o, .openai_whisper]
        case .groq: return [.groq_whisper_v3, .groq_whisper_v3_turbo]
        case .chatgpt: return [.chatgpt_transcribe]
        }
    }

    var defaultModel: TranscriptionModel {
        switch self {
        case .openai: return .openai_gpt4o
        case .groq: return .groq_whisper_v3
        case .chatgpt: return .chatgpt_transcribe
        }
    }

    /// `apiKey` wird für `.chatgpt` ignoriert (der Proxy authentifiziert).
    func createService(apiKey: String, model: TranscriptionModel) -> TranscriptionServiceProtocol {
        switch self {
        case .openai:
            let openAIModel: OpenAIModel = model == .openai_whisper ? .whisper1 : .gpt4oTranscribe
            return OpenAITranscriptionService(apiKey: apiKey, model: openAIModel)
        case .groq:
            let groqModel: GroqModel = model == .groq_whisper_v3_turbo ? .whisperV3Turbo : .whisperV3
            return GroqTranscriptionService(apiKey: apiKey, model: groqModel)
        case .chatgpt:
            return ChatGPTSubscriptionTranscriptionService()
        }
    }
}

// MARK: - Zugangs-Prüfung (Onboarding + Coordinator)

/// Pur: Ist der Zugang für einen Anbieter erfüllt? Anbieter ohne Key immer;
/// sonst getippter oder gespeicherter Key. Ein Ort für Onboarding und
/// Diktat-Pfad, damit beide dieselbe Regel anwenden.
enum TranscriptionCredentialGate {
    static func isSatisfied(provider: TranscriptionProvider, typedKey: String, hasSavedKey: Bool) -> Bool {
        !provider.requiresAPIKey || !typedKey.isEmpty || hasSavedKey
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

    // ChatGPT-Abo — Pseudo-Modell: hält die Invariante `model.provider ==
    // provider` (saveProvider/saveModel, Run-Report) ohne Sonderfälle. Der
    // Raw-Value geht nie an den Server (der Proxy kennt kein Modellfeld).
    case chatgpt_transcribe = "chatgpt-transcribe"

    var displayName: String {
        switch self {
        case .openai_gpt4o: return "GPT-4o Transcribe"
        case .openai_whisper: return "Whisper"
        case .groq_whisper_v3: return "Whisper Large v3"
        case .groq_whisper_v3_turbo: return "Whisper Large v3 Turbo"
        case .chatgpt_transcribe: return "ChatGPT-Transkription"
        }
    }

    var description: String {
        switch self {
        case .openai_gpt4o: return "Beste Qualität, schnell bei kurzen Audios"
        case .openai_whisper: return "Bewährt, stabiler bei langen Aufnahmen"
        case .groq_whisper_v3: return "Beste Qualität bei Groq, 299x Echtzeit"
        case .groq_whisper_v3_turbo: return "Schneller, 216x Echtzeit"
        case .chatgpt_transcribe: return "Interne ChatGPT-Transkription über den GPT-Proxy"
        }
    }

    var provider: TranscriptionProvider {
        switch self {
        case .openai_gpt4o, .openai_whisper: return .openai
        case .groq_whisper_v3, .groq_whisper_v3_turbo: return .groq
        case .chatgpt_transcribe: return .chatgpt
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
    /// falls noch nichts gesetzt/migriert wurde. Ist „ChatGPT-Abo" gespeichert,
    /// aber per Kill-Switch abgeschaltet → Groq, OHNE zurückzuschreiben: beim
    /// Wiedereinschalten ist die Wahl wieder da.
    static func loadProvider(
        chatGPTEnabled: Bool = AppPreferences.shared.isChatGPTTranscriptionEnabled
    ) -> TranscriptionProvider {
        let raw = AppPreferences.shared.selectedProviderRaw ?? TranscriptionProvider.groq.rawValue
        let provider = TranscriptionProvider(rawValue: raw) ?? .groq
        if provider == .chatgpt, !chatGPTEnabled { return .groq }
        return provider
    }

    /// Load current model from UserDefaults. Fallback = Groq-Default-Modell
    /// (auch für das ChatGPT-Pseudo-Modell bei abgeschaltetem Kill-Switch).
    static func loadModel(
        chatGPTEnabled: Bool = AppPreferences.shared.isChatGPTTranscriptionEnabled
    ) -> TranscriptionModel {
        let raw = AppPreferences.shared.selectedModelRaw ?? TranscriptionModel.groq_whisper_v3.rawValue
        let model = TranscriptionModel(rawValue: raw) ?? .groq_whisper_v3
        if model.provider == .chatgpt, !chatGPTEnabled { return .groq_whisper_v3 }
        return model
    }

    /// Save provider and update model if needed
    static func saveProvider(_ provider: TranscriptionProvider) {
        let preferences = AppPreferences.shared
        preferences.selectedProviderRaw = provider.rawValue

        // If current model doesn't belong to new provider, switch to default.
        // Gegen den GESPEICHERTEN Wert prüfen (Kill-Switch ignorieren) — sonst
        // bliebe bei abgeschaltetem ChatGPT-Abo „chatgpt-transcribe" neben Groq
        // stehen und käme beim Wiedereinschalten als inkonsistentes Paar zurück.
        let currentModel = loadModel(chatGPTEnabled: true)
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
