import Foundation

/// Baut das `availableModels`-Settings-Fragment für GPT-Backend-Sessions.
enum ClaudeGPTModelCatalog {
    /// Vollständige Built-in-Aliasse (Doku `model-config`, 2.1.215) — jede
    /// Auslassung würde den Alias aus dem `/model`-Picker entfernen.
    /// `fable[1m]` statt `fable`: Fable ist laut Doku immer 1M, aber ein
    /// Picker-Wechsel über den suffixlosen Alias ließ nach einem
    /// GPT-Zwischenwechsel Claude Codes 200k-Annahme stehen (2026-07-20).
    static let claudeAliases = [
        "default", "best", "fable[1m]", "opus", "sonnet", "haiku",
        "opus[1m]", "sonnet[1m]", "opusplan",
    ]

    /// Nur GPT-Modelle mit bekannter, zum gewählten MAX_CONTEXT-Profil
    /// kompatibler Kapazität werden in den Picker aufgenommen. Beim
    /// experimentellen 372k-Profil bleibt dadurch ausschließlich Sol sichtbar.
    static func availableModelsFragment(
        defaultModel: String,
        pickerModel: String,
        subagentModel: String,
        sessionModel: String? = nil,
        contextWindow: Int = ClaudeGPTModelAlias.maximumKnownSharedContextWindow
    ) -> [String: Any] {
        let configuredModels = [
            AppPreferences.claudeGPTCanonicalModel,
            defaultModel,
            pickerModel,
            subagentModel,
            sessionModel ?? "",
            "gpt-5.6-luna",
            "gpt-5.6-terra",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
        ]

        var gptModels = Set<String>()
        for configuredModel in configuredModels {
            guard var plainModel = ClaudeGPTModelAlias.canonicalGPTModel(configuredModel) else {
                continue
            }
            if plainModel.hasSuffix("-fast") {
                plainModel.removeLast("-fast".count)
            }
            guard ClaudeGPTModelAlias.isSupportedCanonicalModel(
                plainModel,
                contextWindow: contextWindow
            ) else {
                continue
            }
            gptModels.insert(plainModel)
            if ClaudeGPTModelAlias.supportsFast(plainModel) {
                gptModels.insert("\(plainModel)-fast")
            }
        }

        return ["availableModels": claudeAliases + gptModels.sorted()]
    }
}
