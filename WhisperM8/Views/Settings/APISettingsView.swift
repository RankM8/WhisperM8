import SwiftUI

struct APISettingsView: View {
    @AppStorage("selectedProvider") private var selectedProviderRaw = TranscriptionProvider.groq.rawValue
    @AppStorage("selectedModel") private var selectedModelRaw = TranscriptionModel.groq_whisper_v3.rawValue
    @AppStorage("language") private var language = "de"
    @State private var apiKey = ""
    @State private var apiKeyAvailable = false

    private var provider: TranscriptionProvider {
        TranscriptionProvider(rawValue: selectedProviderRaw) ?? .groq
    }

    /// Brücke zwischen dem persistierten `@AppStorage`-Rohwert und dem geteilten Picker,
    /// der mit `TranscriptionProvider` arbeitet. Der Setter durchläuft dieselbe
    /// Side-Effect-Logik wie zuvor (`handleProviderChange`).
    private var providerBinding: Binding<TranscriptionProvider> {
        Binding(
            get: { provider },
            set: { handleProviderChange(to: $0) }
        )
    }

    var body: some View {
        Form {
            // Provider & API Key
            Section {
                TranscriptionProviderPicker(provider: providerBinding)

                MaskedAPIKeyField(
                    text: $apiKey,
                    hasSavedKey: apiKeyAvailable,
                    providerName: provider.displayName
                )
                .onChange(of: apiKey) { _, newValue in
                    if newValue.isEmpty {
                        return
                    }
                    KeychainManager.save(key: provider.keychainKey, value: newValue)
                    apiKeyAvailable = true
                }

                Link("Get \(provider.displayName) API key \u{2192}", destination: provider.apiKeyLink)
                    .font(.caption)

                if apiKeyAvailable && apiKey.isEmpty {
                    TranscriptionKeychainStatusLabel()
                }
            }

            // Model Selection
            Section {
                Picker("Model", selection: $selectedModelRaw) {
                    ForEach(provider.availableModels, id: \.rawValue) { m in
                        Text(m.displayName).tag(m.rawValue)
                    }
                }

                if let currentModel = TranscriptionModel(rawValue: selectedModelRaw) {
                    Text(currentModel.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Language & Info
            Section {
                Picker("Language", selection: $language) {
                    Text("German").tag("de")
                    Text("English").tag("en")
                    Text("Auto-detect").tag("")
                }

                HStack {
                    Text("Price")
                    Spacer()
                    Text(provider.priceInfo)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            TranscriptionSettings.migrateIfNeeded()
            selectedProviderRaw = AppPreferences.shared.selectedProviderRaw ?? TranscriptionProvider.groq.rawValue
            selectedModelRaw = AppPreferences.shared.selectedModelRaw ?? TranscriptionModel.groq_whisper_v3.rawValue
            apiKey = ""
            apiKeyAvailable = KeychainManager.exists(key: provider.keychainKey)
        }
    }

    /// Provider-Wechsel: getippten Key verwerfen, Keychain-Verfügbarkeit neu prüfen,
    /// Modell auf Provider-Default wechseln wenn nötig, Rohwert persistieren.
    /// Verhalten 1:1 wie zuvor im inline-`onChange`.
    private func handleProviderChange(to newProvider: TranscriptionProvider) {
        apiKey = ""
        apiKeyAvailable = KeychainManager.exists(key: newProvider.keychainKey)
        if let currentModel = TranscriptionModel(rawValue: selectedModelRaw),
           currentModel.provider != newProvider {
            selectedModelRaw = newProvider.defaultModel.rawValue
        }
        selectedProviderRaw = newProvider.rawValue
    }
}
