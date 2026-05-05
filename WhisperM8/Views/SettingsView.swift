import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

enum ControlCenterSection: String, CaseIterable, Identifiable {
    case api = "Transcription API"
    case codex = "Codex / ChatGPT"
    case outputOverview = "Output Overview"
    case modes = "Modes"
    case templates = "Templates"
    case testLab = "Test Lab"
    case hotkey = "Hotkey"
    case audio = "Audio"
    case behavior = "Behavior"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .api:
            return "key"
        case .codex:
            return "sparkles"
        case .outputOverview:
            return "rectangle.grid.2x2"
        case .modes:
            return "slider.horizontal.3"
        case .templates:
            return "doc.text"
        case .testLab:
            return "testtube.2"
        case .hotkey:
            return "keyboard"
        case .audio:
            return "waveform"
        case .behavior:
            return "gearshape"
        case .about:
            return "info.circle"
        }
    }

    var groupTitle: String {
        switch self {
        case .api, .codex:
            return "Accounts"
        case .outputOverview, .modes, .templates, .testLab:
            return "Output"
        case .hotkey, .audio, .behavior:
            return "App"
        case .about:
            return "About"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: ControlCenterSection? = .api

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Accounts") {
                    sidebarRow(.api)
                    sidebarRow(.codex)
                }

                Section("Output") {
                    sidebarRow(.outputOverview)
                    sidebarRow(.modes)
                    sidebarRow(.templates)
                    sidebarRow(.testLab)
                }

                Section("App") {
                    sidebarRow(.hotkey)
                    sidebarRow(.audio)
                    sidebarRow(.behavior)
                }

                Section("About") {
                    sidebarRow(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("WhisperM8")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detailView(for: selection ?? .api)
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private func sidebarRow(_ section: ControlCenterSection) -> some View {
        Label(section.rawValue, systemImage: section.systemImage)
            .tag(section)
    }

    @ViewBuilder
    private func detailView(for section: ControlCenterSection) -> some View {
        switch section {
        case .api:
            APISettingsView()
                .navigationTitle(section.rawValue)
        case .codex:
            CodexSettingsView()
        case .outputOverview:
            OutputOverviewView()
                .environment(appState)
        case .modes:
            OutputModesView()
        case .templates:
            OutputTemplatesView()
        case .testLab:
            OutputTestLabView()
        case .hotkey:
            HotkeySettingsView()
                .navigationTitle(section.rawValue)
        case .audio:
            AudioSettingsView()
                .navigationTitle(section.rawValue)
        case .behavior:
            BehaviorSettingsView()
                .navigationTitle(section.rawValue)
        case .about:
            AboutView()
                .navigationTitle(section.rawValue)
        }
    }
}

// MARK: - API Settings

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

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Recording Hotkey:", name: .toggleRecording)
                    .padding(.vertical, 4)

                Text("Press once to start recording, press again to stop and transcribe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio Settings

struct AudioSettingsView: View {
    @State private var deviceManager = AudioDeviceManager.shared
    @State private var selectedDeviceUID: String = ""

    var body: some View {
        Form {
            Section {
                Picker("Input Device", selection: $selectedDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(deviceManager.availableDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onChange(of: selectedDeviceUID) { _, newValue in
                    deviceManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue
                }

                Text("Select which microphone to use. Changes apply to the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            deviceManager.refreshDevices()
            selectedDeviceUID = deviceManager.selectedDeviceUID ?? ""
        }
    }
}

// MARK: - Behavior Settings

struct BehaviorSettingsView: View {
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true
    @AppStorage("audioDuckingEnabled") private var audioDuckingEnabled = true
    @AppStorage("audioDuckingFactor") private var audioDuckingFactor = 0.2
    @AppStorage("overlayStyle") private var overlayStyleRaw = OverlayStyle.full.rawValue

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

            Section("Audio Ducking") {
                Toggle("Reduce system volume while recording", isOn: $audioDuckingEnabled)

                if audioDuckingEnabled {
                    HStack {
                        Text("Target volume")
                        Slider(value: $audioDuckingFactor, in: 0.05...0.3, step: 0.05)
                        Text("\(Int(audioDuckingFactor * 100))%")
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }

                    Text("System volume will be set to \(Int(audioDuckingFactor * 100))% during recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recording Overlay") {
                Picker("Overlay UI", selection: $overlayStyleRaw) {
                    ForEach(OverlayStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Button("Reset Overlay Position") {
                    OverlayPositionStore.clearPosition()
                }

                Text("Overlay is draggable and remembers its position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LaunchAtLogin.Toggle("Start at Login")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)

            Text("WhisperM8")
                .font(.title2.bold())

            Text("Version 1.2.0")
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
