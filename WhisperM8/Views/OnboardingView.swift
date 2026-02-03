import SwiftUI
import KeyboardShortcuts
import AVFoundation

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    @State private var currentStep = 0
    @State private var micPermissionGranted = false
    @State private var apiKey = ""
    @State private var selectedProvider = APIProvider.openai
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
                    HotkeyStep()
                case 2:
                    MicrophoneStep(isGranted: $micPermissionGranted)
                case 3:
                    APIKeyStep(
                        apiKey: $apiKey,
                        selectedProvider: $selectedProvider
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
                    Button("Zurück") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    Button("Weiter") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button("Fertig") {
                        onboardingCompleted = true
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canFinish)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 450)
    }

    private var canProceed: Bool {
        switch currentStep {
        case 1:
            return KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil
        case 2:
            return micPermissionGranted
        case 3:
            return !apiKey.isEmpty
        default:
            return true
        }
    }

    private var canFinish: Bool {
        return KeyboardShortcuts.getShortcut(for: .toggleRecording) != nil
            && micPermissionGranted
            && !apiKey.isEmpty
    }
}

// MARK: - Welcome Step

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            Text("Willkommen bei WhisperM8")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Die native macOS Diktier-App mit bester Transkriptionsqualität.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "keyboard", text: "Globaler Hotkey für schnelles Diktieren")
                FeatureRow(icon: "waveform", text: "Echtzeit Audio-Feedback")
                FeatureRow(icon: "doc.on.clipboard", text: "Text direkt in die Zwischenablage")
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

// MARK: - Hotkey Step

struct HotkeyStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Hotkey konfigurieren")
                .font(.title)
                .fontWeight(.bold)

            Text("Wähle eine Tastenkombination für die Aufnahme. Halte sie gedrückt, um zu diktieren.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            KeyboardShortcuts.Recorder("Aufnahme-Taste:", name: .toggleRecording)
                .padding(.top, 16)

            Text("Empfehlung: Control + Shift + Space")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

// MARK: - Microphone Step

struct MicrophoneStep: View {
    @Binding var isGranted: Bool

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "mic.circle")
                .font(.system(size: 60))
                .foregroundStyle(isGranted ? .green : .blue)

            Text("Mikrofon-Zugriff")
                .font(.title)
                .fontWeight(.bold)

            Text("WhisperM8 benötigt Zugriff auf dein Mikrofon, um deine Sprache aufzunehmen.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isGranted {
                Label("Berechtigung erteilt", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                Button("Berechtigung anfragen") {
                    Task {
                        isGranted = await AVCaptureDevice.requestAccess(for: .audio)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .onAppear {
            checkPermission()
        }
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            isGranted = true
        default:
            isGranted = false
        }
    }
}

// MARK: - API Key Step

struct APIKeyStep: View {
    @Binding var apiKey: String
    @Binding var selectedProvider: APIProvider

    @State private var showingAPIKey = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "key")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("API-Key eingeben")
                .font(.title)
                .fontWeight(.bold)

            Text("Wähle deinen Transkriptions-Provider und gib deinen API-Key ein.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 16) {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(APIProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    if showingAPIKey {
                        TextField("API-Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API-Key", text: $apiKey)
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
                    KeychainManager.save(key: "\(selectedProvider.rawValue)_apikey", value: newValue)
                }
                .onChange(of: selectedProvider) { oldValue, newValue in
                    // Save current key
                    if !apiKey.isEmpty {
                        KeychainManager.save(key: "\(oldValue.rawValue)_apikey", value: apiKey)
                    }
                    // Load key for new provider
                    apiKey = KeychainManager.load(key: "\(newValue.rawValue)_apikey") ?? ""
                    // Save selected provider
                    UserDefaults.standard.set(newValue.rawValue, forKey: "selectedProvider")
                }

                if selectedProvider == .openai {
                    Link("OpenAI API-Key erstellen →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                } else {
                    Link("Groq API-Key erstellen →", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                }
            }
            .padding(.top, 16)
        }
        .padding(40)
        .onAppear {
            apiKey = KeychainManager.load(key: "\(selectedProvider.rawValue)_apikey") ?? ""
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

            Text("Alles bereit!")
                .font(.title)
                .fontWeight(.bold)

            Text("Teste jetzt deine Konfiguration. Halte deinen Hotkey gedrückt und sage etwas.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
                Text("Dein Hotkey: \(shortcut.description)")
                    .font(.headline)
                    .foregroundStyle(.blue)
            }

            if appState.isRecording {
                HStack(spacing: 12) {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                    Text("Aufnahme läuft...")
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.1)))
            } else if appState.isTranscribing {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Transkribiere...")
                }
                .padding()
            }

            if let result = appState.lastTranscription {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ergebnis:")
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

