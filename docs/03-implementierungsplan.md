# WhisperM8 - Implementierungsplan

> **Status:** Recherche abgeschlossen, bereit zur Entwicklung

---

## Phase 1: Projekt-Setup

### Xcode-Projekt erstellen

```bash
# Neues Xcode-Projekt
# Template: macOS → App
# Interface: SwiftUI
# Language: Swift
# Bundle ID: com.yourname.WhisperM8
```

### Swift Package Dependencies

```swift
// Package.swift oder Xcode: File → Add Package Dependencies
dependencies: [
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    .package(url: "https://github.com/sindresorhus/Defaults", from: "8.0.0"),
    .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.0.0"),
]
```

### Info.plist konfigurieren

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <!-- Menübar-App ohne Dock-Icon -->
    <key>LSUIElement</key>
    <true/>

    <!-- Mikrofon-Permission -->
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisperM8 benötigt Mikrofon-Zugriff für die Sprachaufnahme.</string>
</dict>
</plist>
```

### Ordnerstruktur anlegen

```
WhisperM8/
├── WhisperM8App.swift
├── Info.plist
├── Views/
├── Windows/
├── Services/
├── Models/
└── Resources/
    └── Assets.xcassets
```

**Ergebnis Phase 1:** Kompilierbares leeres Projekt mit korrekter Konfiguration.

---

## Phase 2: Menübar-App Grundgerüst

### WhisperM8App.swift

```swift
import SwiftUI
import KeyboardShortcuts

@main
struct WhisperM8App: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
```

### Models/AppState.swift

```swift
import SwiftUI

@Observable
class AppState {
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var lastError: String?

    var menuBarIcon: String {
        if isRecording { return "mic.fill" }
        if isTranscribing { return "ellipsis.circle" }
        return "mic"
    }
}
```

### Views/MenuBarView.swift

```swift
import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isRecording {
                Text("🔴 Aufnahme läuft...")
            } else if appState.isTranscribing {
                Text("⏳ Transkribiere...")
            } else {
                Text("✓ Bereit")
            }
        }

        Divider()

        Button("Einstellungen...") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Beenden") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
```

**Ergebnis Phase 2:** Menübar-Icon sichtbar, Dropdown-Menü funktioniert.

---

## Phase 3: Globale Hotkeys

### KeyboardShortcuts Extension

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}
```

### Hotkey-Handler in App

```swift
@main
struct WhisperM8App: App {
    @State private var appState = AppState()

    init() {
        setupHotkeys()
    }

    private func setupHotkeys() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [self] in
            Task { @MainActor in
                await appState.startRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [self] in
            Task { @MainActor in
                await appState.stopRecording()
            }
        }
    }

    // ... rest of body
}
```

### Settings: Hotkey-Konfiguration

```swift
import KeyboardShortcuts

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Aufnahme-Taste:", name: .toggleRecording)

            Text("Halte diese Taste gedrückt, um zu diktieren.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

**Ergebnis Phase 3:** Hotkey startet/stoppt (noch ohne Funktion) - Console Log zur Verifikation.

---

## Phase 4: Audio-Aufnahme

### Services/AudioRecorder.swift

```swift
import AVFoundation
import Combine

@Observable
class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    var audioLevel: Float = 0
    var isRecording = false

    func startRecording() async throws {
        // Permission check
        let permission = await AVCaptureDevice.requestAccess(for: .audio)
        guard permission else {
            throw RecordingError.microphonePermissionDenied
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Format: 16kHz Mono
        let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Temp file
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        // Audio file für M4A output
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        recordingURL = url

        // Tap für Aufnahme + Level Metering
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self else { return }

            // Level berechnen
            let level = self.calculateLevel(buffer: buffer)
            Task { @MainActor in
                self.audioLevel = level
            }

            // In Datei schreiben (mit Resampling falls nötig)
            self.writeBuffer(buffer)
        }

        try engine.start()
        self.engine = engine
        isRecording = true
    }

    func stopRecording() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
        audioLevel = 0

        return recordingURL
    }

    private func calculateLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = buffer.frameLength

        var sum: Float = 0
        for i in 0..<Int(frames) {
            sum += abs(channelData[i])
        }
        let average = sum / Float(frames)

        // Normalisieren auf 0-1
        return min(average * 5, 1.0)
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        // Converter für 16kHz falls Input anders ist
        // ... implementation
    }
}

enum RecordingError: Error {
    case microphonePermissionDenied
    case recordingFailed
}
```

**Ergebnis Phase 4:** Audio wird aufgenommen und als M4A gespeichert.

---

## Phase 5: Aufnahme-Overlay

### Windows/RecordingPanel.swift

```swift
import AppKit

class RecordingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.hasShadow = true

        positionAtBottomCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

### Views/RecordingOverlayView.swift

```swift
import SwiftUI

struct RecordingOverlayView: View {
    let audioLevel: Float
    let duration: TimeInterval
    let isTranscribing: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Pulsierender roter Punkt
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .opacity(isTranscribing ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.5).repeatForever(), value: !isTranscribing)

            // Status Text
            Text(isTranscribing ? "Transkribiere..." : "Aufnahme...")
                .font(.system(size: 13, weight: .medium))

            // Timer
            Text(formatDuration(duration))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            // Audio Level Bars
            if !isTranscribing {
                AudioLevelBars(level: audioLevel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct AudioLevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .frame(height: 20)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let threshold = Float(index + 1) / 5.0
        let active = level >= threshold
        return active ? CGFloat(8 + index * 3) : 4
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / 5.0
        return level >= threshold ? .green : .gray.opacity(0.3)
    }
}
```

### Overlay-Controller

```swift
class OverlayController {
    private var panel: RecordingPanel?
    private var hostingView: NSHostingView<RecordingOverlayView>?

    func show(appState: AppState) {
        let panel = RecordingPanel()
        let view = RecordingOverlayView(
            audioLevel: appState.audioLevel,
            duration: appState.recordingDuration,
            isTranscribing: appState.isTranscribing
        )
        let hostingView = NSHostingView(rootView: view)
        panel.contentView = hostingView

        panel.orderFront(nil)
        self.panel = panel
        self.hostingView = hostingView
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    func update(appState: AppState) {
        // View neu rendern mit aktuellem State
    }
}
```

**Ergebnis Phase 5:** Overlay erscheint bei Aufnahme, zeigt Level und Timer.

---

## Phase 6: API-Integration

### Services/TranscriptionService.swift

```swift
import Foundation

protocol TranscriptionProvider {
    func transcribe(audioURL: URL, language: String?) async throws -> String
}

class OpenAITranscriptionService: TranscriptionProvider {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let model = "gpt-4o-transcribe"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        let boundary = UUID().uuidString

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()

        // Model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)

        // Language (optional)
        if let language, !language.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)
        }

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }
}

class GroqTranscriptionService: TranscriptionProvider {
    private let apiKey: String
    private let baseURL = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let model = "whisper-large-v3"

    // Identische Implementation wie OpenAI - nur andere URL und Model
    // ...
}

struct TranscriptionResponse: Codable {
    let text: String
}

enum TranscriptionError: Error {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
}
```

### Models/APIProvider.swift

```swift
enum APIProvider: String, CaseIterable, Codable {
    case openai
    case groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI (Beste Qualität)"
        case .groq: return "Groq (Günstiger)"
        }
    }

    func createService(apiKey: String) -> TranscriptionProvider {
        switch self {
        case .openai: return OpenAITranscriptionService(apiKey: apiKey)
        case .groq: return GroqTranscriptionService(apiKey: apiKey)
        }
    }
}
```

**Ergebnis Phase 6:** Audio wird erfolgreich transkribiert.

---

## Phase 7: Einstellungen

### Views/SettingsView.swift

```swift
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    var body: some View {
        TabView {
            APISettingsView()
                .tabItem { Label("API", systemImage: "key") }

            HotkeySettingsView()
                .tabItem { Label("Hotkey", systemImage: "keyboard") }

            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gear") }
        }
        .frame(width: 450, height: 250)
    }
}

struct APISettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = APIProvider.openai
    @AppStorage("language") private var language = "de"
    @State private var apiKey = ""

    var body: some View {
        Form {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(APIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            SecureField("API-Key", text: $apiKey)
                .onChange(of: apiKey) { _, newValue in
                    KeychainManager.save(key: selectedProvider.rawValue, value: newValue)
                }
                .onAppear {
                    apiKey = KeychainManager.load(key: selectedProvider.rawValue) ?? ""
                }

            Picker("Sprache", selection: $language) {
                Text("Deutsch").tag("de")
                Text("Englisch").tag("en")
                Text("Automatisch erkennen").tag("")
            }

            if selectedProvider == .openai {
                Text("Modell: gpt-4o-transcribe (beste Qualität)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Modell: whisper-large-v3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

struct HotkeySettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Aufnahme-Taste:", name: .toggleRecording)

            Text("Halte diese Taste gedrückt, um zu diktieren. Lass los, um die Transkription zu starten.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    // LaunchAtLogin integration
                }
        }
        .padding()
    }
}
```

### Services/KeychainManager.swift

```swift
import Security

enum KeychainManager {
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }
}
```

**Ergebnis Phase 7:** Einstellungen persistent, API-Keys sicher gespeichert.

---

## Phase 8: Onboarding

### Views/OnboardingView.swift

```swift
import SwiftUI
import KeyboardShortcuts
import AVFoundation

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0
    @State private var micPermissionGranted = false

    var body: some View {
        VStack {
            TabView(selection: $currentStep) {
                WelcomeStep()
                    .tag(0)

                HotkeyStep()
                    .tag(1)

                MicrophoneStep(isGranted: $micPermissionGranted)
                    .tag(2)

                APIKeyStep()
                    .tag(3)

                TestStep()
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Zurück") {
                        withAnimation { currentStep -= 1 }
                    }
                }

                Spacer()

                if currentStep < 4 {
                    Button("Weiter") {
                        withAnimation { currentStep += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button("Fertig") {
                        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    private var canProceed: Bool {
        switch currentStep {
        case 2: return micPermissionGranted
        default: return true
        }
    }
}

struct MicrophoneStep: View {
    @Binding var isGranted: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Mikrofon-Zugriff")
                .font(.title)

            Text("WhisperM8 benötigt Zugriff auf dein Mikrofon, um deine Sprache aufzunehmen.")
                .multilineTextAlignment(.center)

            Button("Berechtigung anfragen") {
                Task {
                    isGranted = await AVCaptureDevice.requestAccess(for: .audio)
                }
            }
            .buttonStyle(.borderedProminent)

            if isGranted {
                Label("Berechtigung erteilt", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding()
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
```

**Ergebnis Phase 8:** Neuer User wird durch Setup geführt.

---

## Phase 9: Integration & Polish

### AppState - Vollständiger Flow

```swift
@Observable
class AppState {
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0
    var lastError: String?

    private var audioRecorder = AudioRecorder()
    private var overlayController = OverlayController()
    private var timer: Timer?

    @MainActor
    func startRecording() async {
        guard !isRecording else { return }

        do {
            try await audioRecorder.startRecording()
            isRecording = true
            recordingDuration = 0

            overlayController.show(appState: self)

            // Timer für Duration
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.recordingDuration += 0.1
                self?.audioLevel = self?.audioRecorder.audioLevel ?? 0
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @MainActor
    func stopRecording() async {
        guard isRecording else { return }

        timer?.invalidate()
        timer = nil

        guard let audioURL = audioRecorder.stopRecording() else {
            isRecording = false
            overlayController.hide()
            return
        }

        isRecording = false
        isTranscribing = true

        do {
            let provider = UserDefaults.standard.string(forKey: "selectedProvider")
                .flatMap { APIProvider(rawValue: $0) } ?? .openai
            let apiKey = KeychainManager.load(key: provider.rawValue) ?? ""
            let language = UserDefaults.standard.string(forKey: "language")

            let service = provider.createService(apiKey: apiKey)
            let text = try await service.transcribe(audioURL: audioURL, language: language)

            // In Clipboard kopieren
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

            // Cleanup
            try? FileManager.default.removeItem(at: audioURL)

        } catch {
            lastError = error.localizedDescription
        }

        isTranscribing = false
        overlayController.hide()
    }
}
```

**Ergebnis Phase 9:** Kompletter Flow funktioniert end-to-end.

---

## Phase 10: Distribution

### App-Signing (mit Developer ID)

```bash
# 1. Archive erstellen
xcodebuild archive \
  -scheme WhisperM8 \
  -archivePath build/WhisperM8.xcarchive

# 2. Export signieren
xcodebuild -exportArchive \
  -archivePath build/WhisperM8.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist

# 3. Notarization
xcrun notarytool submit build/export/WhisperM8.app.zip \
  --apple-id "your@email.com" \
  --team-id "TEAMID" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# 4. Staple
xcrun stapler staple build/export/WhisperM8.app
```

### DMG erstellen

```bash
# Mit create-dmg
create-dmg \
  --volname "WhisperM8" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "WhisperM8.app" 150 190 \
  --app-drop-link 450 190 \
  "WhisperM8.dmg" \
  "build/export/"
```

### Alternative: Ohne Developer Account

Für Team-interne Verteilung ohne $99/Jahr:

1. Ad-hoc signieren
2. User-Anleitung für Gatekeeper-Bypass:
   - Rechtsklick → Öffnen
   - Oder: `xattr -cr /Applications/WhisperM8.app`

### Auto-Updates (Sparkle)

```swift
// In App-Init
import Sparkle

let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
```

**Ergebnis Phase 10:** App ist verteilbar via DMG + GitHub Releases.

---

## Abhängigkeiten

```
Phase 1 (Setup)
    ↓
Phase 2 (Menübar)
    ↓
Phase 3 (Hotkeys) ←──┐
    ↓                │
Phase 4 (Audio) ─────┤
    ↓                │
Phase 5 (Overlay) ───┘
    ↓
Phase 6 (API)
    ↓
Phase 7 (Settings)
    ↓
Phase 8 (Onboarding)
    ↓
Phase 9 (Integration)
    ↓
Phase 10 (Distribution)
```

---

## Checkliste

- [ ] **Phase 1:** Projekt-Setup, Dependencies, Info.plist
- [ ] **Phase 2:** MenuBarExtra, AppState, MenuBarView
- [ ] **Phase 3:** KeyboardShortcuts Integration
- [ ] **Phase 4:** AudioRecorder mit AVAudioEngine
- [ ] **Phase 5:** RecordingPanel (NSPanel), Overlay UI
- [ ] **Phase 6:** TranscriptionService (OpenAI + Groq)
- [ ] **Phase 7:** SettingsView, KeychainManager
- [ ] **Phase 8:** OnboardingView
- [ ] **Phase 9:** Vollständiger Flow, Clipboard-Integration
- [ ] **Phase 10:** Signing, Notarization, DMG, Distribution

---

## Offene Entscheidungen

| Frage | Empfehlung |
|-------|------------|
| Default-Hotkey | Keiner - User wählt im Onboarding |
| Sprache-Default | "de" (schneller als Auto) |
| Auto-Paste nach Transkription? | Nein - nur Clipboard (sicherer) |
