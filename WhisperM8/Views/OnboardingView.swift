import SwiftUI
import KeyboardShortcuts
import AVFoundation
import ApplicationServices
import AppKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(AppState.self) private var appState

    @State private var currentStepIndex = 0
    @State private var selectedProfile: AppUsageProfile = AppPreferences.shared.usageProfile
    @State private var micPermissionGranted = false
    @State private var accessibilityGranted = false
    @State private var hotkeySet = false
    @State private var apiKeyAvailable = false
    @State private var keychainWriteFailed = false
    /// Zählerstand beim Öffnen des Test-Schritts; davor Entstandenes zählt nicht (LR-ONB-013).
    @State private var testBaseline: OnboardingTestBaseline?
    @State private var selectedProvider = TranscriptionProvider.groq
    @State private var selectedModel = TranscriptionModel.groq_whisper_v3

    /// Profilabhängige Schrittfolge (pure Ableitung, siehe `OnboardingStepPlanner`).
    private var steps: [OnboardingStep] {
        OnboardingStepPlanner.steps(for: selectedProfile)
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
        .onChange(of: currentStep) { _, newStep in
            // Beim Betreten des Test-Schritts zählen nur noch neue Ergebnisse (LR-ONB-013).
            testBaseline = newStep == .test
                ? OnboardingTestBaseline(
                    transcriptionRevision: appState.transcriptionRevision,
                    errorRevision: appState.errorRevision)
                : nil
        }
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
                apiKeyAvailable: $apiKeyAvailable,
                keychainWriteFailed: $keychainWriteFailed,
                selectedProvider: $selectedProvider,
                selectedModel: $selectedModel
            )
        case .language:
            LanguageStep()
        case .claudeCLI:
            ClaudeCLIStep()
        case .codex:
            CodexConnectStep()
        case .test:
            TestStep(gate: completionGate, baseline: effectiveTestBaseline)
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

    private var credentialsSatisfied: Bool {
        // Nur ein bestätigt gespeicherter Key zählt — getippte Entwürfe nicht (LR-ONB-006/007).
        TranscriptionCredentialGate.isSatisfied(
            provider: selectedProvider,
            typedKey: "",
            hasSavedKey: apiKeyAvailable
        )
    }

    private var completionGate: OnboardingCompletionGate {
        OnboardingCompletionGate(
            micGranted: micPermissionGranted,
            accessibilityGranted: accessibilityGranted,
            hotkeySet: hotkeySet,
            credentialsSatisfied: credentialsSatisfied,
            keychainWriteFailed: keychainWriteFailed,
            testOutcome: OnboardingTestOutcome.derive(
                lastTranscription: appState.lastTranscription,
                lastError: appState.lastError,
                baseline: effectiveTestBaseline,
                transcriptionRevision: appState.transcriptionRevision,
                errorRevision: appState.errorRevision
            )
        )
    }

    /// Vor dem Betreten des Test-Schritts gilt der aktuelle Stand als Baseline
    /// (also noch nichts getestet).
    private var effectiveTestBaseline: OnboardingTestBaseline {
        testBaseline ?? OnboardingTestBaseline(
            transcriptionRevision: appState.transcriptionRevision,
            errorRevision: appState.errorRevision)
    }

    private var canProceed: Bool {
        switch currentStep {
        case .permissions:
            return micPermissionGranted && accessibilityGranted
        case .hotkey:
            return hotkeySet
        case .apiKey:
            return credentialsSatisfied && !keychainWriteFailed
        default:
            // Welcome, Profil (Default gewählt), Sprache, Claude/Codex (optional), Test.
            return true
        }
    }

    private var canFinish: Bool {
        completionGate.canFinish
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
    let text: LocalizedStringKey

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
    @State private var installModel = AgentCLIInstallModel(cli: .codex)

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

            if status == .notInstalled {
                // Statt „Sign In" ohne CLI: geführte Installation (Homebrew-Cask, nach Rückfrage).
                AgentCLIInstallPanel(model: installModel, onInstalled: { refreshStatus() })
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
            } else {
                HStack {
                    Button {
                        CodexStatusProbe().openLoginInTerminal()
                    } label: {
                        status == .signedIn ? Text("Reconnect ChatGPT") : Text("Sign in with ChatGPT")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Check Again") {
                        refreshStatus()
                    }
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
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

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
                    actionTitle: MicrophoneOnboardingAction.buttonTitle(status: micStatus),
                    action: requestMicrophonePermission
                )

                if let hint = MicrophoneOnboardingAction.hint(status: micStatus), !micGranted {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

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
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = micStatus == .authorized

        // Check accessibility
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Nur bei „noch nicht entschieden" wirkt `requestAccess`; bei Ablehnung führt der
    /// Button in die Systemeinstellungen (LR-ONB-004). Der 0,5-s-Poll erkennt die Rückkehr.
    private func requestMicrophonePermission() {
        switch MicrophoneOnboardingAction.decide(status: micStatus) {
        case .request:
            Task {
                micGranted = await AVCaptureDevice.requestAccess(for: .audio)
                checkPermissions()
            }
        case .openSystemSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
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
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let isGranted: Bool
    var actionTitle: String = String(localized: "Grant")
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
                Button(actionTitle) {
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
    @Binding var apiKeyAvailable: Bool
    /// Der letzte Schreibversuch in den Schlüsselbund ist gescheitert (LR-ONB-007).
    @Binding var keychainWriteFailed: Bool
    @Binding var selectedProvider: TranscriptionProvider
    @Binding var selectedModel: TranscriptionModel

    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true
    /// „ChatGPT-Abo" nur anbieten, wenn das GPT-Backend aktiv ist oder der
    /// Anbieter schon gewählt war — neue Nutzer haben kein GPT-Backend, die
    /// Option wäre für sie eine Sackgasse. Einmal beim Erscheinen bestimmt,
    /// damit die Option nicht verschwindet, sobald man wegklickt.
    @State private var showsChatGPTOption = false
    /// Aktives GPT-Konto für den Hinweis — Dateizugriff, deshalb im `.task`.
    @State private var chatGPTActiveAccount: String?
    /// Key-Entwurf des gewählten Anbieters; gespeichert wird nur per „Save".
    @State private var keyDraft: APIKeyDraftModel?

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

                TranscriptionProviderPicker(
                    provider: providerBinding,
                    options: TranscriptionProvider.selectableProviders(chatGPTAvailable: showsChatGPTOption)
                )

                if selectedProvider.requiresAPIKey, let keyDraft {
                    @Bindable var draft = keyDraft
                    MaskedAPIKeyField(
                        text: $draft.draft,
                        hasSavedKey: keyDraft.hasSavedKey,
                        providerName: selectedProvider.displayName,
                        onSubmit: { saveDraft() }
                    )

                    HStack {
                        Button("Save Key") { saveDraft() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!keyDraft.canCommit)
                        if keyDraft.canCommit {
                            Text("Click Save Key to store it in your Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if let error = keyDraft.saveError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let apiKeyLink = selectedProvider.apiKeyLink {
                        Link("Get \(selectedProvider.displayName) API key \u{2192}", destination: apiKeyLink)
                            .font(.caption)
                    }

                    if keyDraft.hasSavedKey && !keyDraft.canCommit {
                        TranscriptionKeychainStatusLabel()
                    }
                } else if !selectedProvider.requiresAPIKey {
                    ChatGPTTranscriptionNotice(
                        activeAccount: chatGPTActiveAccount,
                        backendEnabled: AppPreferences.shared.claudeGPTBackendEnabled
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task {
                        chatGPTActiveAccount = await Task.detached(priority: .utility) {
                            AppPreferences.shared.isGPTAccountProfilesEnabled
                                ? GPTAccountProfiles().activeProfileName()
                                : GPTAccountProfiles.mainProfileName
                        }.value
                    }
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
                    // Echte Buttons: per Tastatur fokussierbar, VoiceOver liest „ausgewählt" (LR-ONB-014).
                    Button {
                        selectedModel = model
                        TranscriptionSettings.saveModel(model)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .fontWeight(selectedModel == model ? .semibold : .regular)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selectedModel == model ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedModel == model ? Color.blue : Color.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selectedModel == model ? [.isSelected] : [])
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
                        if autoPasteEnabled {
                            Text("Text will be automatically pasted")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Text will only be copied to clipboard")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
            showsChatGPTOption = AppPreferences.shared.isChatGPTTranscriptionEnabled
                && (AppPreferences.shared.claudeGPTBackendEnabled || selectedProvider == .chatgpt)
            rebuildDraft(for: selectedProvider)
        }
        .onChange(of: keyDraft?.draft ?? "") { _, newValue in
            keychainWriteFailed = OnboardingKeychainFailure.afterDraftEdit(
                current: keychainWriteFailed,
                draftIsEmpty: newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasSavedKey: keyDraft?.hasSavedKey ?? false)
        }
    }

    private func saveDraft() {
        guard let keyDraft else { return }
        let saved = keyDraft.commit()
        // Ein bereits gespeicherter Key bleibt gültig — dann blockiert der Fehler nicht.
        keychainWriteFailed = !saved && keyDraft.saveError != nil && !keyDraft.hasSavedKey
        apiKeyAvailable = keyDraft.hasSavedKey
    }

    /// Neuer Entwurf für den Anbieter; ein ungespeicherter Entwurf des alten Anbieters
    /// wird bewusst verworfen — gespeichert wird nur ausdrücklich per „Save Key".
    private func rebuildDraft(for provider: TranscriptionProvider) {
        keychainWriteFailed = false
        if let keychainKey = provider.keychainKey {
            let model = APIKeyDraftModel(keychainKey: keychainKey)
            keyDraft = model
            apiKeyAvailable = model.hasSavedKey
        } else {
            keyDraft = nil
            apiKeyAvailable = false
        }
    }

    /// Brücke für den geteilten Picker; Setter behält die bisherige Side-Effect-Logik
    /// (Keychain prüfen, Modell wechseln, Provider persistieren).
    private var providerBinding: Binding<TranscriptionProvider> {
        Binding(
            get: { selectedProvider },
            set: { handleProviderChange(to: $0) }
        )
    }

    private func handleProviderChange(to newProvider: TranscriptionProvider) {
        selectedProvider = newProvider
        rebuildDraft(for: newProvider)
        if selectedModel.provider != newProvider {
            selectedModel = newProvider.defaultModel
        }
        TranscriptionSettings.saveProvider(newProvider)
    }
}

// MARK: - Language Step (LR-DIK-024)

/// Diktiersprache vor dem Testdiktat: Voreinstellung folgt der Systemsprache.
struct LanguageStep: View {
    @State private var language = AppPreferences.shared.language

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Which language do you dictate in?")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("Whisper transcribes best when it knows the language. We preselected the language of your Mac. You can change this later in Settings → Transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Picker("Spoken language", selection: $language) {
                ForEach(DictationLanguage.pickerCodes, id: \.self) { code in
                    Text(DictationLanguage.displayName(for: code)).tag(code)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .onChange(of: language) { _, newValue in
                AppPreferences.shared.language = newValue
            }
        }
        .padding(32)
        .onAppear {
            // Auch die unveränderte Voreinstellung festschreiben: eine spätere Änderung
            // der Systemsprache soll die Diktiersprache nicht stillschweigend umschalten.
            AppPreferences.shared.language = language
        }
    }
}

// MARK: - Claude CLI Step (LR-ONB-003)

/// Nur im Full-Profil: Claude Code installieren (Homebrew-Cask, nach Rückfrage) und
/// den Login erklären. Immer überspringbar — Diktat funktioniert ohne.
struct ClaudeCLIStep: View {
    @State private var model = AgentCLIInstallModel(cli: .claude)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(model.state.isInstalled ? .green : .blue)

                Text("Set up Claude Code")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Agent Chats run the Claude Code command line tool. This is optional — you can skip it now and install it later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                AgentCLIInstallPanel(
                    model: model,
                    loginHint: Text("The first time you start a chat, Claude Code opens right inside WhisperM8 and walks you through signing in with your Claude account.")
                )
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))
            }
            .padding(32)
        }
    }
}

// MARK: - Test Step

struct TestStep: View {
    @Environment(AppState.self) private var appState
    let gate: OnboardingCompletionGate
    var baseline = OnboardingTestBaseline(transcriptionRevision: 0, errorRevision: 0)

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: gate.showsSuccess ? "checkmark.circle" : "mic.circle")
                .font(.system(size: 60))
                .foregroundStyle(gate.showsSuccess ? .green : .blue)

            // „All set!" erst nach bestandenem Testdiktat (LR-ONB-013).
            if gate.showsSuccess {
                Text("All set!")
                    .font(.title)
                    .fontWeight(.bold)
            } else {
                Text("Test your setup")
                    .font(.title)
                    .fontWeight(.bold)
            }

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

            if appState.transcriptionRevision > baseline.transcriptionRevision, let result = appState.lastTranscription {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Result:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1)))
                }
            }

            switch gate.notice {
            case .none:
                EmptyView()
            case .untested:
                Text("You haven't tested dictation yet. You can finish now, but we recommend a quick test first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .testFailed(let message):
                VStack(spacing: 6) {
                    Text("The test dictation failed. Check your API key and try again.")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(40)
    }
}
