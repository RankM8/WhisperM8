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

            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 450, height: 280)
        .onAppear {
            // Temporarily show in dock to allow keyboard input
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("Settings") }) {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(window.contentView)
                }
            }
        }
        .onDisappear {
            // Hide from dock again when settings close
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - API Settings

struct APISettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = APIProvider.openai.rawValue
    @AppStorage("language") private var language = "de"
    @State private var apiKey = ""
    @State private var showingAPIKey = false

    private var provider: APIProvider {
        APIProvider(rawValue: selectedProvider) ?? .openai
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(APIProvider.allCases, id: \.rawValue) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
                .onChange(of: selectedProvider) { _, newValue in
                    // Load API key for new provider
                    apiKey = KeychainManager.load(key: "\(newValue)_apikey") ?? ""
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
                    KeychainManager.save(key: "\(selectedProvider)_apikey", value: newValue)
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

                if provider == .openai {
                    Link("Get OpenAI API key →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                } else {
                    Link("Get Groq API key →", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear {
            apiKey = KeychainManager.load(key: "\(selectedProvider)_apikey") ?? ""
        }
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Recording key:", name: .toggleRecording)

                Text("Hold this key to dictate. Release to start transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes:")
                        .font(.caption)
                        .fontWeight(.medium)

                    Text("• Avoid Option-only shortcuts on macOS 15+")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("• Recommended: Control + Shift + Space")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true

    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle("Launch at login")

                Toggle("Auto-paste after transcription", isOn: $autoPasteEnabled)
                    .help("Automatically paste text or copy to clipboard only")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WhisperM8")
                        .font(.headline)
                    Text("Version 1.0.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Native macOS dictation app with best-in-class transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

