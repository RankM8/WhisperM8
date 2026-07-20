import Foundation

/// Baut das `availableModels`-Settings-Fragment für GPT-Backend-Sessions.
enum ClaudeGPTModelCatalog {
    /// Vollständige Built-in-Aliasse (Doku `model-config`, 2.1.215) — jede
    /// Auslassung würde den Alias aus dem `/model`-Picker entfernen.
    /// `fable[1m]` statt `fable`: Fable ist laut Doku immer 1M, aber ein
    /// Picker-Wechsel über den suffixlosen Alias ließ nach einem
    /// GPT-Zwischenwechsel Claude Codes 200k-Annahme stehen (2026-07-20).
    /// Das explizite Suffix erzwingt den 1M-Refresh; das Matching strippt
    /// `[1m]` beidseitig, suffixlose fable-Requests bleiben also erlaubt.
    static let claudeAliases = [
        "default", "best", "fable[1m]", "opus", "sonnet", "haiku",
        "opus[1m]", "sonnet[1m]", "opusplan",
    ]

    /// Die Liste ist bewusst großzügig: Ein beim Resume restauriertes
    /// Off-List-Modell fällt sonst still auf die normale Modell-Präzedenz
    /// zurück. Explizite `-fast`-Eingaben liefern deshalb auch ihr Plain-
    /// Pendant; ein `[1m]`-Suffix bleibt bei beiden Varianten erhalten.
    static func availableModelsFragment(
        defaultModel: String,
        subagentModel: String
    ) -> [String: Any] {
        let configuredModels = [
            AppPreferences.claudeGPTCanonicalModel,
            defaultModel,
            subagentModel,
            "gpt-5.6-luna",
            "gpt-5.6-terra",
        ]

        var gptModels = Set<String>()
        for configuredModel in configuredModels {
            let trimmed = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let plainModel = plainModelAlias(trimmed)
            gptModels.insert(plainModel)
            gptModels.insert(ClaudeGPTModelAlias.effectiveModel(plainModel, fastEnabled: true))
        }

        let aliases = Set(claudeAliases)
        let sortedGPTModels = gptModels.subtracting(aliases).sorted()
        return ["availableModels": claudeAliases + sortedGPTModels]
    }

    private static func plainModelAlias(_ model: String) -> String {
        let hasMemorySuffix = model.lowercased().hasSuffix("[1m]")
        let memorySuffix = hasMemorySuffix ? String(model.suffix(4)) : ""
        var baseModel = hasMemorySuffix ? String(model.dropLast(4)) : model
        if baseModel.hasPrefix("gpt-"), baseModel.hasSuffix("-fast") {
            baseModel.removeLast("-fast".count)
        }
        return baseModel + memorySuffix
    }
}
