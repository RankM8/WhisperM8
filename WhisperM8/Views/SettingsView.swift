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
    case agentChats = "Agent Chats"
    case permissions = "Permissions"
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
        case .agentChats:
            return "terminal"
        case .permissions:
            return "shield.checkered"
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
        case .agentChats:
            return "Agents"
        case .permissions, .hotkey, .audio, .behavior:
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

                Section("Agents") {
                    sidebarRow(.agentChats)
                }

                Section("App") {
                    sidebarRow(.permissions)
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
        .onChange(of: selection) { _, newSelection in
            if newSelection == .agentChats {
                WindowRequestCenter.shared.request(.agentChats)
            }
        }
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
        case .agentChats:
            AgentChatsAccessView()
                .navigationTitle(section.rawValue)
        case .permissions:
            PermissionsSettingsView()
                .navigationTitle(section.rawValue)
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

struct AgentChatsAccessView: View {
    @AppStorage("defaultAgentProvider") private var defaultAgentProviderRaw = "claude"
    @AppStorage("codexExtraArguments") private var codexExtraArguments = ""
    @AppStorage("claudeExtraArguments") private var claudeExtraArguments = ""

    var body: some View {
        Form {
            Section("Agent Workspace") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent Chats")
                            .font(.headline)
                        Text("Open the Codex and Claude session hub for project chats, resumes, and task follow-up.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        WindowRequestCenter.shared.request(.agentChats)
                    } label: {
                        Label("Open Agent Chats", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section("Standard-Provider") {
                Picker("Neuer Chat startet mit", selection: $defaultAgentProviderRaw) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                }
                .pickerStyle(.segmented)

                Text("Bestimmt, welcher Provider beim 'Neuer Chat'-Button und beim Plus-Knopf eines Projekts genutzt wird.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude CLI · Extra-Argumente") {
                TextField("z. B. --dangerously-skip-permissions", text: $claudeExtraArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                Text("Wird vorne an jeden `claude`-Aufruf angehängt — auch beim Resume bestehender Sessions. Whitespace-getrennt; Quotes erlaubt für Argumente mit Leerzeichen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex CLI · Extra-Argumente") {
                TextField("z. B. --ask-for-approval untrusted", text: $codexExtraArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                Text("Wird vorne an jeden `codex`-Aufruf angehängt (vor `-C`/`-m`/`resume`). Whitespace-getrennt; Quotes erlaubt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Permissions Settings

struct PermissionsSettingsView: View {
    @State private var microphoneStatus = PermissionService.microphoneAuthorizationStatus
    @State private var accessibilityGranted = PermissionService.hasAccessibilityPermission
    @State private var screenRecordingGranted = PermissionService.hasScreenRecordingPermission
    @State private var permissionTimer: Timer?

    private var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    private var allGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: allGranted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.system(size: 28))
                        .foregroundStyle(allGranted ? .green : .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(allGranted ? "All system permissions are active" : "WhisperM8 needs system access")
                            .font(.headline)
                        Text("You can re-check or repair permissions here without running onboarding again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Refresh") {
                        refreshPermissions()
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Required") {
                SystemPermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to record your voice for transcription.",
                    statusText: microphoneStatusText,
                    isGranted: microphoneGranted,
                    primaryButtonTitle: microphonePrimaryButtonTitle,
                    primaryAction: handleMicrophoneAction,
                    secondaryButtonTitle: "Open Settings",
                    secondaryAction: PermissionService.openMicrophonePrivacySettings
                )

                SystemPermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required for auto-paste and selected text capture.",
                    statusText: accessibilityGranted ? "Granted" : "Not granted",
                    isGranted: accessibilityGranted,
                    primaryButtonTitle: accessibilityGranted ? "Check Again" : "Grant",
                    primaryAction: handleAccessibilityAction,
                    secondaryButtonTitle: "Open Settings",
                    secondaryAction: PermissionService.openAccessibilityPrivacySettings
                )
            }

            Section("Optional Visual Context") {
                SystemPermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Required only when you add screenshots or screen clips as context.",
                    statusText: screenRecordingGranted ? "Granted" : "Not granted",
                    isGranted: screenRecordingGranted,
                    primaryButtonTitle: screenRecordingGranted ? "Check Again" : "Grant",
                    primaryAction: handleScreenRecordingAction,
                    secondaryButtonTitle: "Open Settings",
                    secondaryAction: PermissionService.openScreenRecordingPrivacySettings
                )
            }

            Section("What happens without permissions") {
                Text("Without Microphone access, recording cannot start. Without Accessibility access, WhisperM8 can still transcribe and copy to clipboard, but auto-paste and selected text capture will be blocked by macOS. Screen Recording is optional and only needed for screenshot or screen clip context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshPermissions()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }
    }

    private var microphoneStatusText: String {
        switch microphoneStatus {
        case .authorized:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    private var microphonePrimaryButtonTitle: String {
        switch microphoneStatus {
        case .authorized:
            return "Check Again"
        case .denied, .restricted:
            return "Open Settings"
        case .notDetermined:
            return "Grant"
        @unknown default:
            return "Open Settings"
        }
    }

    private func handleMicrophoneAction() {
        switch microphoneStatus {
        case .authorized:
            refreshPermissions()
        case .notDetermined:
            Task {
                _ = await PermissionService.requestMicrophonePermission()
                await MainActor.run {
                    refreshPermissions()
                }
            }
        case .denied, .restricted:
            PermissionService.openMicrophonePrivacySettings()
        @unknown default:
            PermissionService.openMicrophonePrivacySettings()
        }
    }

    private func handleAccessibilityAction() {
        if accessibilityGranted {
            refreshPermissions()
        } else {
            PermissionService.requestAccessibilityPermission()
            PermissionService.openAccessibilityPrivacySettings()
        }
    }

    private func handleScreenRecordingAction() {
        if screenRecordingGranted {
            refreshPermissions()
        } else {
            _ = PermissionService.requestScreenRecordingPermission()
            PermissionService.openScreenRecordingPrivacySettings()
        }
    }

    private func refreshPermissions() {
        microphoneStatus = PermissionService.microphoneAuthorizationStatus
        accessibilityGranted = PermissionService.hasAccessibilityPermission
        screenRecordingGranted = PermissionService.hasScreenRecordingPermission
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshPermissions()
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}

struct SystemPermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let statusText: String
    let isGranted: Bool
    let primaryButtonTitle: String
    let primaryAction: () -> Void
    let secondaryButtonTitle: String
    let secondaryAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(isGranted ? .green : .blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(minWidth: 86, alignment: .trailing)

            if isGranted {
                Button(primaryButtonTitle) {
                    primaryAction()
                }
                .buttonStyle(.borderless)
            } else {
                Button(primaryButtonTitle) {
                    primaryAction()
                }
                .buttonStyle(.borderedProminent)
            }

            Button(secondaryButtonTitle) {
                secondaryAction()
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
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
    @AppStorage("selectedContextCaptureEnabled") private var selectedContextCaptureEnabled = true
    @AppStorage("visualContextCaptureEnabled") private var visualContextCaptureEnabled = true
    @AppStorage("maxScreenshotsPerRecording") private var maxScreenshotsPerRecording = AppPreferences.defaultMaxScreenshotsPerRecording
    @AppStorage("maxScreenRecordingDuration") private var maxScreenRecordingDuration = 30.0
    @AppStorage("deleteContextFilesAfterProcessing") private var deleteContextFilesAfterProcessing = false

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

            Section("Selected Context") {
                Toggle("Use selected text as context", isOn: $selectedContextCaptureEnabled)

                Text("When enabled, WhisperM8 can capture highlighted text from the active app before recording and pass it to context-aware modes like Slack, WhatsApp, and Email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Visual Context") {
                Toggle("Allow screenshots and screen clips as context", isOn: $visualContextCaptureEnabled)

                Stepper(
                    "Screenshots per recording: \(maxScreenshotsPerRecording)",
                    value: $maxScreenshotsPerRecording,
                    in: 1...AppPreferences.maximumScreenshotsPerRecording
                )

                HStack {
                    Text("Max screen clip")
                    Slider(value: $maxScreenRecordingDuration, in: 5...60, step: 5)
                    Text("\(Int(maxScreenRecordingDuration))s")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }

                Toggle("Delete visual context files after processing", isOn: $deleteContextFilesAfterProcessing)

                Text("Clipboard screenshots are captured automatically while recording when you use macOS screenshot-to-clipboard. Screen clips still require Screen Recording permission.")
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
