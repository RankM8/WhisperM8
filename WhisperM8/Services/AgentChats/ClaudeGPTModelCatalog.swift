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

    /// Alle Backend-Modelle des Codex-Katalogs, die das gewählte
    /// MAX_CONTEXT-Profil tragen, plus konfigurierte Werte (kanonisiert; `auto`
    /// → Frontier). Beim erweiterten 900k-Profil fallen dadurch Modelle
    /// ohne 1M-Klasse (z. B. gpt-5.5, gpt-5.4-mini) aus dem Picker.
    static func availableModelsFragment(
        defaultModel: String,
        pickerModel: String,
        subagentModel: String,
        sessionModel: String? = nil,
        contextWindow: Int = ClaudeGPTModelAlias.maximumKnownSharedContextWindow,
        catalog: CodexModelCatalog = ClaudeGPTModelAlias.catalog()
    ) -> [String: Any] {
        let configuredModels = [
            ClaudeGPTModelAlias.autoModel,
            defaultModel,
            pickerModel,
            subagentModel,
            sessionModel ?? "",
        ] + ClaudeGPTModelAlias.backendModelSlugs(catalog: catalog)

        var gptModels = Set<String>()
        for configuredModel in configuredModels {
            guard var plainModel = ClaudeGPTModelAlias.canonicalGPTModel(
                configuredModel,
                catalog: catalog
            ) else {
                continue
            }
            if plainModel.hasSuffix("-fast") {
                plainModel.removeLast("-fast".count)
            }
            guard ClaudeGPTModelAlias.isSupportedCanonicalModel(
                plainModel,
                contextWindow: contextWindow,
                catalog: catalog
            ) else {
                continue
            }
            gptModels.insert(plainModel)
            if ClaudeGPTModelAlias.supportsFast(plainModel, catalog: catalog) {
                gptModels.insert("\(plainModel)-fast")
            }
        }

        return ["availableModels": claudeAliases + gptModels.sorted()]
    }
}
