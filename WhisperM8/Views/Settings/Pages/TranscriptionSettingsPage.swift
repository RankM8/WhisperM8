import SwiftUI

struct TranscriptionSettingsPage: View {
    @AppStorage("selectedProvider") private var selectedProviderRaw = TranscriptionProvider.groq.rawValue
    @AppStorage("selectedModel") private var selectedModelRaw = TranscriptionModel.groq_whisper_v3.rawValue
    @AppStorage("language") private var language = "de"

    @State private var apiKey = ""
    @State private var apiKeyAvailable = false
    @State private var isConfirmingKeyRemoval = false

    private var provider: TranscriptionProvider {
        TranscriptionProvider(rawValue: selectedProviderRaw) ?? .groq
    }

    /// Der Setter spiegelt die alte der früheren API-Seite-Logik: getippte Keys werden
    /// verworfen, die Keychain-Verfuegbarkeit wechselt mit dem Account und fremde
    /// Modelle werden auf den Provider-Default zurueckgesetzt.
    private var providerBinding: Binding<TranscriptionProvider> {
        Binding(
            get: { provider },
            set: { handleProviderChange(to: $0) }
        )
    }

    private var currentModel: TranscriptionModel? {
        TranscriptionModel(rawValue: selectedModelRaw)
    }

    var body: some View {
        SettingsPageContainer(
            title: "Transcription",
            subtitle: "Speech-to-text provider, API key, model and language."
        ) {
            SettingsSection("Provider") {
                TranscriptionProviderSegmentedRow(provider: providerBinding)

                TranscriptionAPIKeyInputRow(
                    text: $apiKey,
                    hasSavedKey: apiKeyAvailable,
                    providerName: provider.displayName
                )
                .onChange(of: apiKey) { _, newValue in
                    guard !newValue.isEmpty else {
                        return
                    }
                    KeychainManager.save(key: provider.keychainKey, value: newValue)
                    apiKeyAvailable = true
                }

                if apiKeyAvailable && apiKey.isEmpty {
                    SettingsStatusRow(
                        title: "Saved Key",
                        tone: .ok,
                        detail: "API key saved in Keychain"
                    ) {
                        Button("Remove Key…") {
                            isConfirmingKeyRemoval = true
                        }
                        .buttonStyle(SettingsButtonStyle.destructive)
                    }
                }

                TranscriptionAPIKeyLinkRow(provider: provider)
            }

            SettingsSection("Model") {
                SettingsPickerRow(
                    title: "Model",
                    selection: $selectedModelRaw,
                    options: provider.availableModels.map(\.rawValue)
                ) { rawValue in
                    Text(TranscriptionModel(rawValue: rawValue)?.displayName ?? rawValue)
                }

                if let currentModel {
                    SettingsHelpText(modelHelpText(for: currentModel))
                }

                SettingsRow(
                    title: "Price",
                    subtitle: "Static list price, as of 2026-07."
                ) {
                    Text(provider.priceInfo)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            SettingsSection("Language") {
                SettingsPickerRow(
                    title: "Spoken language",
                    selection: $language,
                    options: ["de", "en", ""]
                ) { code in
                    Text(languageDisplayName(for: code))
                }

                SettingsHelpText("Also used for AI Output post-processing and the Test Lab. Auto-detect omits the language field.")
            }
        }
        .onAppear(perform: syncFromPreferencesAndKeychain)
        .confirmationDialog("Remove \(provider.displayName) API key?", isPresented: $isConfirmingKeyRemoval) {
            Button("Remove Key", role: .destructive) {
                removeProviderKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved \(provider.displayName) API key from Keychain.")
        }
    }

    private func syncFromPreferencesAndKeychain() {
        // Migration läuft zentral beim App-Start (RecordingCoordinator) — hier
        // nur LESEN und nur bei echter Abweichung zurückschreiben, damit das
        // bloße Öffnen der Seite keine Preferences mutiert (Review-Befund K2).
        let providerRaw = AppPreferences.shared.selectedProviderRaw ?? TranscriptionProvider.groq.rawValue
        let modelRaw = AppPreferences.shared.selectedModelRaw ?? TranscriptionModel.groq_whisper_v3.rawValue
        if selectedProviderRaw != providerRaw { selectedProviderRaw = providerRaw }
        if selectedModelRaw != modelRaw { selectedModelRaw = modelRaw }
        apiKey = ""
        apiKeyAvailable = KeychainManager.exists(key: provider.keychainKey)
    }

    private func handleProviderChange(to newProvider: TranscriptionProvider) {
        apiKey = ""
        apiKeyAvailable = KeychainManager.exists(key: newProvider.keychainKey)
        if let currentModel = TranscriptionModel(rawValue: selectedModelRaw),
           currentModel.provider != newProvider {
            selectedModelRaw = newProvider.defaultModel.rawValue
        }
        selectedProviderRaw = newProvider.rawValue
    }

    private func removeProviderKey() {
        KeychainManager.delete(key: provider.keychainKey)
        apiKey = ""
        apiKeyAvailable = false
    }

    private func modelHelpText(for model: TranscriptionModel) -> String {
        switch model {
        case .openai_gpt4o:
            return "Best quality, fast for short audio."
        case .openai_whisper:
            return "Proven and stable for longer recordings."
        case .groq_whisper_v3:
            return "Best quality at Groq, 299x real-time."
        case .groq_whisper_v3_turbo:
            return "Faster, 216x real-time."
        }
    }

    private func languageDisplayName(for code: String) -> String {
        switch code {
        case "de":
            return "German"
        case "en":
            return "English"
        default:
            return "Auto-detect"
        }
    }
}

private struct TranscriptionProviderSegmentedRow: View {
    @Binding var provider: TranscriptionProvider

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                if let badge = provider.recommendationBadge {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(AppTheme.statusWorking.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppTheme.statusWorking)

                        if let hint = provider.recommendationHint {
                            Text(hint)
                                .font(.system(size: 11.5))
                                .foregroundStyle(AppTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Provider")
                        .font(.system(size: 13.5))
                        .foregroundStyle(AppTheme.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Provider", selection: $provider) {
                ForEach(TranscriptionProvider.displayOrder, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 2)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }
}

private struct TranscriptionAPIKeyInputRow: View {
    @Binding var text: String
    var hasSavedKey: Bool
    var providerName: String

    @State private var isRevealed = false

    private static let maskedPlaceholder = String(repeating: "•", count: 16)

    private var placeholder: String {
        hasSavedKey ? Self.maskedPlaceholder : "\(providerName) API key..."
    }

    var body: some View {
        SettingsRow(title: "API Key") {
            HStack(spacing: 8) {
                FocusableTextField(
                    text: $text,
                    placeholder: placeholder,
                    isSecure: !isRevealed
                )
                // `isSecure` tauscht die AppKit-View-Klasse; die Identitaet muss
                // wechseln, damit der Eye-Toggle nicht nur den State aendert.
                .id(isRevealed)
                .frame(width: 300, height: 24)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(AppTheme.control)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                }
                .help(isRevealed ? "Hide typed key" : "Show typed key")
                .accessibilityLabel(Text(isRevealed ? "Hide API key" : "Show API key"))
            }
        }
    }
}

private struct TranscriptionAPIKeyLinkRow: View {
    let provider: TranscriptionProvider

    var body: some View {
        HStack {
            Link("Get \(provider.displayName) API key →", destination: provider.apiKeyLink)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.accent)

            Spacer()
        }
        .padding(.top, 8)
        .padding(.horizontal, 2)
    }
}
