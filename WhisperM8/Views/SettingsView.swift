import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    var body: some View {
        TabView {
            APISettingsView()
                .tabItem {
                    Label("API", systemImage: "key")
                }

            HotkeySettingsView()
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
                }

            BehaviorSettingsView()
                .tabItem {
                    Label("Behavior", systemImage: "gearshape")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 400, height: 320)
    }
}

// MARK: - API Settings

struct APISettingsView: View {
    @AppStorage("selectedProvider") private var selectedProviderRaw = APIProvider.openai_gpt4o.rawValue
    @AppStorage("language") private var language = "de"
    @State private var apiKey = ""
    @State private var showingAPIKey = false

    private var provider: APIProvider {
        APIProvider.fromLegacy(selectedProviderRaw)
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProviderRaw) {
                    ForEach(APIProvider.allCases, id: \.rawValue) { p in
                        VStack(alignment: .leading) {
                            Text(p.displayName)
                            Text(p.modelDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(p.rawValue)
                    }
                }
                .onChange(of: selectedProviderRaw) { _, newValue in
                    // Load API key for new provider
                    let newProvider = APIProvider.fromLegacy(newValue)
                    apiKey = KeychainManager.load(key: newProvider.keychainKey) ?? ""
                }

                HStack {
                    FocusableTextField(
                        text: $apiKey,
                        placeholder: "Enter API key...",
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
                    KeychainManager.save(key: provider.keychainKey, value: newValue)
                }

                Picker("Language", selection: $language) {
                    Text("German").tag("de")
                    Text("English").tag("en")
                    Text("Auto-detect").tag("")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model: \(provider.modelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Price: \(provider.priceInfo)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Show appropriate API key link based on provider
                if provider == .groq {
                    Link("Get Groq API key →", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                } else {
                    Link("Get OpenAI API key →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear {
            apiKey = KeychainManager.load(key: provider.keychainKey) ?? ""
        }
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Recording Hotkey:", name: .toggleRecording)
                    .padding(.vertical, 4)

                Text("Press and hold to record, release to transcribe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Behavior Settings

struct BehaviorSettingsView: View {
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Auto-paste after transcription", isOn: $autoPasteEnabled)

                Text(autoPasteEnabled
                    ? "Transcribed text will be automatically pasted"
                    : "Transcribed text will only be copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LaunchAtLogin.Toggle("Start at Login")
            }
        }
        .padding()
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            if let imageURL = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
               let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            }

            Text("WhisperM8")
                .font(.title2.bold())

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Native macOS dictation with AI transcription")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Link("Built by 360WebManager", destination: URL(string: "https://360web-manager.com/")!)
                .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
