import SwiftUI
import KeyboardShortcuts
import AVFoundation
import ApplicationServices
import AppKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    @State private var currentStep = 0
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var hotkeySet = false
    @State private var apiKey = ""
    @State private var selectedProvider = TranscriptionProvider.openai
    @State private var selectedModel = TranscriptionModel.openai_gpt4o
    @State private var testResult: String?
    @State private var isTestingRecording = false

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            // Content
            Group {
                switch currentStep {
                case 0:
                    WelcomeStep()
                case 1:
                    PermissionsStep(
                        micGranted: $micPermissionGranted,
                        accessibilityGranted: $accessibilityGranted
                    )
                case 2:
                    HotkeyStep(hotkeySet: $hotkeySet)
                case 3:
                    APIKeyStep(
                        apiKey: $apiKey,
                        selectedProvider: $selectedProvider,
                        selectedModel: $selectedModel
                    )
                case 4:
                    TestStep(
                        testResult: $testResult,
                        isTestingRecording: $isTestingRecording
                    )
                    .environment(appState)
                default:
                    WelcomeStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button("Next") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button("Done") {
                        onboardingCompleted = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canFinish)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    private var canProceed: Bool {
        switch currentStep {
        case 1:
            return micPermissionGranted && accessibilityGranted
        case 2:
            return hotkeySet
        case 3:
            return !apiKey.isEmpty
        default:
            return true
        }
    }

    private var canFinish: Bool {
        return hotkeySet
            && micPermissionGranted
            && accessibilityGranted
            && !apiKey.isEmpty
    }
}

// MARK: - Welcome Step

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            // App Logo
            if let imageURL = Bundle.module.url(forResource: "AppLogo", withExtension: "png"),
               let nsImage = NSImage(contentsOf: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
            } else {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)
            }

            Text("Welcome to WhisperM8")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Native macOS dictation app with best-in-class transcription.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "keyboard", text: "Press hotkey to start/stop recording")
                FeatureRow(icon: "waveform", text: "Real-time audio feedback")
                FeatureRow(icon: "doc.on.clipboard", text: "Auto-paste or clipboard")
            }
            .padding(.top, 16)
        }
        .padding(40)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Permissions Step (Combined)

struct PermissionsStep: View {
    @Binding var micGranted: Bool
    @Binding var accessibilityGranted: Bool

    @State private var checkTimer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 60))
                .foregroundStyle(allGranted ? .green : .blue)

            Text("App Permissions")
                .font(.title)
                .fontWeight(.bold)

            Text("WhisperM8 needs two permissions to work properly.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                // Microphone Permission
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Record your voice for transcription",
                    isGranted: micGranted,
                    action: requestMicrophonePermission
                )

                // Accessibility Permission
                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Auto-paste text into other apps",
                    isGranted: accessibilityGranted,
                    action: requestAccessibilityPermission
                )
            }
            .padding(.top, 8)

            if allGranted {
                Label("All permissions granted!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                    .padding(.top, 8)
            } else {
                Text("Click each button to grant permission")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .onAppear {
            checkPermissions()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }
    }

    private var allGranted: Bool {
        micGranted && accessibilityGranted
    }

    private func checkPermissions() {
        // Check microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micGranted = true
        default:
            micGranted = false
        }

        // Check accessibility
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func requestMicrophonePermission() {
        Task {
            micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    private func requestAccessibilityPermission() {
        // This opens System Settings to the Accessibility pane
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func startPermissionPolling() {
        // Poll for accessibility permission since user grants it in System Settings
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            checkPermissions()
        }
    }

    private func stopPermissionPolling() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(isGranted ? .green : .blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
            } else {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isGranted ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
        )
    }
}

// MARK: - Hotkey Step

struct HotkeyStep: View {
    @Binding var hotkeySet: Bool
    @State private var shortcutName: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard")
                .font(.system(size: 60))
                .foregroundStyle(hotkeySet ? .green : .blue)

            Text("Configure Hotkey")
                .font(.title)
                .fontWeight(.bold)

            Text("Press once to start recording, press again to stop and transcribe.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            KeyboardShortcuts.Recorder("Recording key:", name: .toggleRecording)
                .padding(.top, 16)
                .onChange(of: shortcutName) { _, _ in
                    checkHotkey()
                }

            if hotkeySet {
                Label("Hotkey configured!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Text("Recommended: Control + Shift + Space")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .onAppear {
            checkHotkey()
            // Poll for shortcut changes since Recorder doesn't have a direct callback
            startPolling()
        }
    }

    private func checkHotkey() {
        hotkeySet = KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil
    }

    private func startPolling() {
        // Check every 0.3s if shortcut was set
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            let wasSet = hotkeySet
            checkHotkey()
            if hotkeySet && !wasSet {
                timer.invalidate()
            }
        }
    }
}

// MARK: - API Key Step

struct APIKeyStep: View {
    @Binding var apiKey: String
    @Binding var selectedProvider: TranscriptionProvider
    @Binding var selectedModel: TranscriptionModel

    @State private var showingAPIKey = false
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 50))
                .foregroundStyle(.blue)

            Text("Configuration")
                .font(.title)
                .fontWeight(.bold)

            // Provider & API Key Section
            VStack(spacing: 12) {
                Text("Provider")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Provider", selection: $selectedProvider) {
                    ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { oldValue, newValue in
                    // Save current key if not empty and switching to different keychain
                    if !apiKey.isEmpty && oldValue.keychainKey != newValue.keychainKey {
                        KeychainManager.save(key: oldValue.keychainKey, value: apiKey)
                    }
                    apiKey = KeychainManager.load(key: newValue.keychainKey) ?? ""
                    // Switch to default model if current doesn't match provider
                    if selectedModel.provider != newValue {
                        selectedModel = newValue.defaultModel
                    }
                    UserDefaults.standard.set(newValue.rawValue, forKey: "selectedProvider")
                }

                HStack {
                    if showingAPIKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showingAPIKey.toggle()
                    } label: {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                .onChange(of: apiKey) { _, newValue in
                    KeychainManager.save(key: selectedProvider.keychainKey, value: newValue)
                }

                Link("Get \(selectedProvider.displayName) API key \u{2192}", destination: selectedProvider.apiKeyLink)
                    .font(.caption)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

            // Model Selection
            VStack(spacing: 8) {
                Text("Model")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(selectedProvider.availableModels, id: \.rawValue) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .fontWeight(selectedModel == model ? .semibold : .regular)
                            Text(model.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedModel == model {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedModel = model
                        UserDefaults.standard.set(model.rawValue, forKey: "selectedModel")
                    }
                }

                HStack {
                    Text("Price: \(selectedProvider.priceInfo)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

            // Auto-Paste Option
            VStack(spacing: 8) {
                Toggle(isOn: $autoPasteEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-paste text")
                            .font(.body)
                        Text(autoPasteEnabled
                            ? "Text will be automatically pasted"
                            : "Text will only be copied to clipboard")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
        }
        .padding(24)
        .onAppear {
            // Migrate if needed
            TranscriptionSettings.migrateIfNeeded()
            selectedProvider = TranscriptionSettings.loadProvider()
            selectedModel = TranscriptionSettings.loadModel()
            apiKey = KeychainManager.load(key: selectedProvider.keychainKey) ?? ""
        }
    }
}

// MARK: - Test Step

struct TestStep: View {
    @Environment(AppState.self) private var appState
    @Binding var testResult: String?
    @Binding var isTestingRecording: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("All set!")
                .font(.title)
                .fontWeight(.bold)

            Text("Test your configuration now. Press your hotkey to start, speak, then press again to stop.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
                Text("Your hotkey: \(shortcut.description)")
                    .font(.headline)
                    .foregroundStyle(.blue)
            }

            if appState.isRecording {
                HStack(spacing: 12) {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                    Text("Recording...")
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
            } else if appState.isTranscribing {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Transcribing...")
                }
                .padding()
            }

            if let result = appState.lastTranscription {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Result:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1)))
                }
            }

            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
    }
}
