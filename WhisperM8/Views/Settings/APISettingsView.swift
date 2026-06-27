import SwiftUI

struct APISettingsView: View {
    @AppStorage("selectedProvider") private var selectedProviderRaw = TranscriptionProvider.openai.rawValue
    @AppStorage("selectedModel") private var selectedModelRaw = TranscriptionModel.openai_gpt4o.rawValue
    @AppStorage("language") private var language = "de"
    @State private var apiKey = ""
    @State private var apiKeyAvailable = false
    @State private var showingAPIKey = false

    private var provider: TranscriptionProvider {
        TranscriptionProvider(rawValue: selectedProviderRaw) ?? .openai
    }

    var body: some View {
        Form {
            // Provider & API Key
            Section {
                Picker("Provider", selection: $selectedProviderRaw) {
                    ForEach(TranscriptionProvider.allCases, id: \.rawValue) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProviderRaw) { _, newValue in
                    let newProvider = TranscriptionProvider(rawValue: newValue) ?? .openai
                    apiKey = ""
                    apiKeyAvailable = KeychainManager.exists(key: newProvider.keychainKey)
                    if let currentModel = TranscriptionModel(rawValue: selectedModelRaw),
                       currentModel.provider != newProvider {
                        selectedModelRaw = newProvider.defaultModel.rawValue
                    }
                }

                HStack {
                    FocusableTextField(
                        text: $apiKey,
                        placeholder: apiKeyAvailable ? "Saved \(provider.displayName) API key" : "\(provider.displayName) API key...",
                        isSecure: !showingAPIKey
                    )
                    .frame(height: 22)

                    Button {
                        showingAPIKey.toggle()
                    } label: {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
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
                    Label("API key is saved in Keychain", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
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
            selectedProviderRaw = AppPreferences.shared.selectedProviderRaw ?? TranscriptionProvider.openai.rawValue
            selectedModelRaw = AppPreferences.shared.selectedModelRaw ?? TranscriptionModel.openai_gpt4o.rawValue
            apiKey = ""
            apiKeyAvailable = KeychainManager.exists(key: provider.keychainKey)
        }
    }
}
