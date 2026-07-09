import SwiftUI
import KeyboardShortcuts
import AVFoundation
import ApplicationServices
import AppKit

/// Ein logischer Onboarding-Schritt. Die konkrete Reihenfolge ergibt sich profilabhängig
/// (der Codex-Schritt entfällt für reine Diktat-Profile).
enum OnboardingStep {
    case welcome
    case profile
    case permissions
    case hotkey
    case apiKey
    case codex
    case test
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(AppState.self) private var appState

    @State private var currentStepIndex = 0
    @State private var selectedProfile: AppUsageProfile = AppPreferences.shared.usageProfile
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var hotkeySet = false
    @State private var apiKey = ""
    @State private var apiKeyAvailable = false
    @State private var selectedProvider = TranscriptionProvider.groq
    @State private var selectedModel = TranscriptionModel.groq_whisper_v3
    @State private var testResult: String?
    @State private var isTestingRecording = false

    /// Profilabhängige Schrittfolge. Der Codex-Schritt erscheint nur, wenn das gewählte
    /// Profil Enrichment nutzt (Dictation+Enrichment / Full).
    private var steps: [OnboardingStep] {
        var result: [OnboardingStep] = [.welcome, .profile, .permissions, .hotkey, .apiKey]
        if selectedProfile.wantsCodexEnrichment {
            result.append(.codex)
        }
        result.append(.test)
        return result
    }

    private var currentStep: OnboardingStep {
        let steps = steps
        let index = min(max(currentStepIndex, 0), steps.count - 1)
        return steps[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index <= currentStepIndex ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

            // Content
            Group {
                stepView(for: currentStep)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStepIndex > 0 {
                    Button("Back") {
                        withAnimation { currentStepIndex -= 1 }
                    }
                }

                Spacer()

                if currentStepIndex < steps.count - 1 {
                    Button("Next") {
                        withAnimation { currentStepIndex += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button("Done") {
                        finishOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canFinish)
                }
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder
    private func stepView(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:
            WelcomeStep()
        case .profile:
            ProfileStep(selectedProfile: $selectedProfile)
        case .permissions:
            PermissionsStep(
                micGranted: $micPermissionGranted,
                accessibilityGranted: $accessibilityGranted
            )
        case .hotkey:
            HotkeyStep(hotkeySet: $hotkeySet)
        case .apiKey:
            APIKeyStep(
                apiKey: $apiKey,
                apiKeyAvailable: $apiKeyAvailable,
                selectedProvider: $selectedProvider,
                selectedModel: $selectedModel
            )
        case .codex:
            CodexConnectStep()
        case .test:
            TestStep(
                testResult: $testResult,
                isTestingRecording: $isTestingRecording
            )
            .environment(appState)
        }
    }

    private func finishOnboarding() {
        // Profil anwenden: persistieren, Aktivierungs-Policy setzen, Fenster-Freigabe.
        AppProfileActivator.apply(selectedProfile)

        if selectedProfile.wantsAgentChats {
            // Voll-Profil: in den Agent-Chats-Hub springen (bisheriges Verhalten).
            WindowRequestCenter.shared.request(.agentChats)
        } else {
            // Menüleisten-Profile: keine Agent-Chats-Fenster. Falls beim Launch welche
            // aufgegangen sind (Default-Profil war .full), Primär- und Sekundärfenster
            // schließen.
            AppProfileActivator.closeAgentChatWindows(using: dismissWindow)
        }
        dismiss()
    }

    private var canProceed: Bool {
        switch currentStep {
        case .permissions:
            return micPermissionGranted && accessibilityGranted
        case .hotkey:
            return hotkeySet
        case .apiKey:
            return !apiKey.isEmpty || apiKeyAvailable
        default:
            // Welcome, Profil (Default gewählt), Codex (optional), Test.
            return true
        }
    }

    private var canFinish: Bool {
        return hotkeySet
            && micPermissionGranted
            && accessibilityGranted
            && (!apiKey.isEmpty || apiKeyAvailable)
    }
}

// MARK: - Welcome Step

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            // App Logo
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)

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

// MARK: - Profile Step

/// Nutzungsprofil-Auswahl (3 Presets). Bestimmt, wie die App danach läuft
/// (Menüleisten-Utility vs. Dock-App) und welche Modi verfügbar sind.
struct ProfileStep: View {
    @Binding var selectedProfile: AppUsageProfile

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("How will you use WhisperM8?")
                .font(.title)
                .fontWeight(.bold)

            Text("You can change this later in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(AppUsageProfile.allCases, id: \.self) { profile in
                    ProfileOptionCard(
                        profile: profile,
                        isSelected: selectedProfile == profile
                    ) {
                        selectedProfile = profile
                        // Wahl sofort persistieren, damit sie beim Wizard-Abbruch nicht
                        // verloren geht (die Aktivierungs-Policy wird erst bei „Done"
                        // umgeschaltet).
                        AppPreferences.shared.usageProfile = profile
                    }
                }
            }
        }
        .padding(32)
    }
}

private struct ProfileOptionCard: View {
    let profile: AppUsageProfile
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(.headline)
                    Text(profile.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Codex Connect Step (optional)

/// Optionaler Schritt für Enrichment-/Voll-Profile: Codex (ChatGPT) verbinden. Immer
/// überspringbar — die Modi funktionieren später auch, sobald Codex verbunden ist, und
/// ohne Codex bleibt der Raw-Fallback.
struct CodexConnectStep: View {
    @State private var status = CodexConnectionStatus.unknown

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(status == .signedIn ? .green : .blue)

            Text("Connect Codex (optional)")
                .font(.title)
                .fontWeight(.bold)

            Text("AI enrichment modes (Clean, Email, Slack …) use the Codex CLI with your ChatGPT login. This is optional — you can skip it now and connect later in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack {
                Text("Status")
                Spacer()
                Text(status.displayText)
                    .foregroundStyle(status == .signedIn ? .green : .secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

            HStack {
                Button(status == .signedIn ? "Reconnect ChatGPT" : "Sign in with ChatGPT") {
                    CodexStatusProbe().openLoginInTerminal()
                }
                .buttonStyle(.borderedProminent)

                Button("Check Again") {
                    refreshStatus()
                }
            }

            Text("You can continue without connecting — without Codex, only Raw dictation runs; enrichment modes fall back to Raw.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .onAppear {
            refreshStatus()
        }
    }

    /// Die Probe spawnt einen Subprozess (`codex login status`) — nie synchron
    /// auf dem Main-Thread laufen lassen, sonst friert das Onboarding kurz ein.
    private func refreshStatus() {
        Task.detached(priority: .userInitiated) {
            let result = CodexStatusProbe().status()
            await MainActor.run { status = result }
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
    @State private var pollingTimer: Timer?

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
        .onDisappear {
            stopPolling()
        }
    }

    private func checkHotkey() {
        hotkeySet = KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil
    }

    private func startPolling() {
        stopPolling()

        // Check every 0.3s if shortcut was set
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            let wasSet = hotkeySet
            checkHotkey()
            if hotkeySet && !wasSet {
                timer.invalidate()
                pollingTimer = nil
            }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}

// MARK: - API Key Step

struct APIKeyStep: View {
    @Binding var apiKey: String
    @Binding var apiKeyAvailable: Bool
    @Binding var selectedProvider: TranscriptionProvider
    @Binding var selectedModel: TranscriptionModel

    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)

                Text("Configuration")
                    .font(.title)
                    .fontWeight(.bold)

            // Provider & API Key Section
            VStack(spacing: 12) {
                Text("Provider")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TranscriptionProviderPicker(provider: providerBinding)

                MaskedAPIKeyField(
                    text: $apiKey,
                    hasSavedKey: apiKeyAvailable,
                    providerName: selectedProvider.displayName
                )
                .onChange(of: apiKey) { _, newValue in
                    if newValue.isEmpty {
                        return
                    }
                    KeychainManager.save(key: selectedProvider.keychainKey, value: newValue)
                    apiKeyAvailable = true
                }

                Link("Get \(selectedProvider.displayName) API key \u{2192}", destination: selectedProvider.apiKeyLink)
                    .font(.caption)

                if apiKeyAvailable && apiKey.isEmpty {
                    TranscriptionKeychainStatusLabel()
                }
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
                        TranscriptionSettings.saveModel(model)
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
        }
        .onAppear {
            // Migrate if needed
            TranscriptionSettings.migrateIfNeeded()
            selectedProvider = TranscriptionSettings.loadProvider()
            selectedModel = TranscriptionSettings.loadModel()
            apiKey = ""
            apiKeyAvailable = KeychainManager.exists(key: selectedProvider.keychainKey)
        }
    }

    /// Brücke für den geteilten Picker; Setter behält die bisherige Side-Effect-Logik
    /// (Key sichern/leeren, Keychain prüfen, Modell wechseln, Provider persistieren).
    private var providerBinding: Binding<TranscriptionProvider> {
        Binding(
            get: { selectedProvider },
            set: { handleProviderChange(to: $0) }
        )
    }

    private func handleProviderChange(to newProvider: TranscriptionProvider) {
        let oldProvider = selectedProvider
        // Getippten Key sichern, falls Provider gewechselt wird und etwas eingegeben wurde.
        if !apiKey.isEmpty && oldProvider.keychainKey != newProvider.keychainKey {
            KeychainManager.save(key: oldProvider.keychainKey, value: apiKey)
        }
        selectedProvider = newProvider
        apiKey = ""
        apiKeyAvailable = KeychainManager.exists(key: newProvider.keychainKey)
        if selectedModel.provider != newProvider {
            selectedModel = newProvider.defaultModel
        }
        TranscriptionSettings.saveProvider(newProvider)
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
