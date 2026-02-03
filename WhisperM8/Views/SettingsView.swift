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
                    Label("Allgemein", systemImage: "gear")
                }
        }
        .frame(width: 450, height: 280)
        .onAppear {
            // Temporarily show in dock to allow keyboard input
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.title.contains("Einstellungen") }) {
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
                        placeholder: "API-Key eingeben...",
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

                Picker("Sprache", selection: $language) {
                    Text("Deutsch").tag("de")
                    Text("Englisch").tag("en")
                    Text("Automatisch erkennen").tag("")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Modell: \(provider.modelName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Preis: \(provider.priceInfo)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if provider == .openai {
                    Link("OpenAI API-Key erstellen →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                } else {
                    Link("Groq API-Key erstellen →", destination: URL(string: "https://console.groq.com/keys")!)
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
                KeyboardShortcuts.Recorder("Aufnahme-Taste:", name: .toggleRecording)

                Text("Halte diese Taste gedrückt, um zu diktieren. Lass los, um die Transkription zu starten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hinweise:")
                        .font(.caption)
                        .fontWeight(.medium)

                    Text("• Vermeide Option-only Shortcuts auf macOS 15+")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("• Empfohlen: Control + Shift + Space")
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
    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle("Bei Anmeldung starten")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WhisperM8")
                        .font(.headline)
                    Text("Version 1.0.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Native macOS Diktier-App mit bester Transkriptionsqualität.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

