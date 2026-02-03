# WhisperM8 - Komponenten & Architektur

## Architektur-Diagramm

```
┌─────────────────────────────────────────────────────────────┐
│  WhisperM8App                                               │
│  ├─ MenuBarExtra (Icon in Menüleiste)                      │
│  ├─ Settings Scene (API-Keys, Hotkey)                      │
│  └─ Recording Overlay (NSPanel, floating)                  │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  AppState (@Observable)                                     │
│  ├─ isRecording: Bool                                      │
│  ├─ isTranscribing: Bool                                   │
│  ├─ audioLevel: Float                                      │
│  ├─ recordingDuration: TimeInterval                        │
│  └─ selectedProvider: APIProvider                          │
└─────────────────────────────────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ KeyboardShortcuts│ │ AudioRecorder   │ │ Transcription   │
│ (Hold-to-Record)│ │ (AVAudioEngine) │ │ Service         │
│                 │ │                 │ │ (OpenAI/Groq)   │
│ • onKeyDown     │ │ • installTap    │ │ • multipart POST│
│ • onKeyUp       │ │ • M4A export    │ │ • error handling│
└─────────────────┘ └─────────────────┘ └─────────────────┘
         │                 │                 │
         │                 ▼                 │
         │         ┌─────────────────┐       │
         │         │ temp.m4a        │───────┘
         │         │ (16kHz, mono)   │
         │         └─────────────────┘
         │                                   │
         │                                   ▼
         │                           ┌─────────────────┐
         └──────────────────────────▶│ NSPasteboard   │
                                     │ (System Copy)   │
                                     └─────────────────┘
```

---

## Komponenten im Detail

### 1. App-Grundstruktur (Menübar-App)

```swift
@main
struct WhisperM8App: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.isRecording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
```

**Info.plist:**
```xml
<key>LSUIElement</key>
<true/>
<key>NSMicrophoneUsageDescription</key>
<string>WhisperM8 benötigt Mikrofon-Zugriff für die Sprachaufnahme.</string>
```

---

### 2. Globale Hotkeys (KeyboardShortcuts)

```swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording")
}

// In App-Initialisierung:
KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
    appState.startRecording()
}

KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
    appState.stopRecording()
}
```

**Hotkey-Konfiguration in Settings:**
```swift
Form {
    KeyboardShortcuts.Recorder("Aufnahme-Taste:", name: .toggleRecording)
}
```

**Wichtig:**
- Keine Accessibility-Permission benötigt!
- Hold-to-Record: KeyDown startet, KeyUp stoppt
- macOS Sequoia Bug: Option-only Shortcuts vermeiden

---

### 3. Audio-Aufnahme (AVAudioEngine)

```swift
class AudioRecorder: ObservableObject {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?

    @Published var audioLevel: Float = 0

    func startRecording() throws {
        let inputNode = engine.inputNode
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // Audio-Level Metering
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let level = self.calculateLevel(buffer)
            DispatchQueue.main.async {
                self.audioLevel = level
            }
        }

        try engine.start()
    }

    func stopRecording() -> URL {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return exportToM4A()
    }
}
```

**Audio-Format:**
| Parameter | Wert |
|-----------|------|
| Format | M4A (AAC) |
| Sample Rate | 16 kHz |
| Kanäle | Mono |
| Bitrate | 32 kbps |
| Max. Größe | <25 MB (API-Limit) |

---

### 4. Floating Overlay (NSPanel)

```swift
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
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

**UI-Elemente:**
```
┌────────────────────────────────────┐
│  🔴  Aufnahme...  00:05  ▁▃▅▇▅▃▁  │
└────────────────────────────────────┘
     │       │        │       │
     │       │        │       └── Audio-Level Bars
     │       │        └── Timer
     │       └── Status-Text
     └── Pulsierender roter Punkt
```

**Position:** Bottom-center, 40pt vom unteren Bildschirmrand

---

### 5. Transkriptions-Service

```swift
protocol TranscriptionProvider {
    func transcribe(audioURL: URL, language: String?) async throws -> String
}

class OpenAITranscriptionService: TranscriptionProvider {
    private let baseURL = "https://api.openai.com/v1/audio/transcriptions"
    private let model = "gpt-4o-transcribe"  // Beste Qualität!

    func transcribe(audioURL: URL, language: String?) async throws -> String {
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)",
                        forHTTPHeaderField: "Content-Type")

        var body = Data()
        // ... multipart form-data aufbauen
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")
        // ... file und optional language

        let (data, _) = try await URLSession.shared.upload(for: request, from: body)
        let response = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return response.text
    }
}

class GroqTranscriptionService: TranscriptionProvider {
    private let baseURL = "https://api.groq.com/openai/v1/audio/transcriptions"
    private let model = "whisper-large-v3"  // Nicht turbo!

    // Identische Implementation - nur andere baseURL und model
}
```

**API-Vergleich:**
| Provider | Modell | Endpunkt | Preis |
|----------|--------|----------|-------|
| **OpenAI** | gpt-4o-transcribe | api.openai.com | $0.006/min |
| **Groq** | whisper-large-v3 | api.groq.com | $0.002/min |

---

### 6. Einstellungen

```swift
struct SettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = APIProvider.openai
    @AppStorage("language") private var language = "de"

    var body: some View {
        TabView {
            // API Tab
            Form {
                Picker("Provider", selection: $selectedProvider) {
                    Text("OpenAI (Beste Qualität)").tag(APIProvider.openai)
                    Text("Groq (Günstiger)").tag(APIProvider.groq)
                }

                SecureField("API-Key", text: apiKeyBinding)

                Picker("Sprache", selection: $language) {
                    Text("Deutsch").tag("de")
                    Text("Englisch").tag("en")
                    Text("Automatisch").tag("")
                }
            }
            .tabItem { Label("API", systemImage: "key") }

            // Hotkey Tab
            Form {
                KeyboardShortcuts.Recorder("Aufnahme-Taste:", name: .toggleRecording)
            }
            .tabItem { Label("Hotkey", systemImage: "keyboard") }
        }
        .frame(width: 400, height: 200)
    }
}
```

**API-Key Speicherung:** Keychain (nicht UserDefaults!)

---

### 7. Onboarding-Flow

```
┌─────────────────────────────────────┐
│  1. Willkommen                      │
│     "WhisperM8 - Diktieren leicht   │
│      gemacht"                       │
│                        [Weiter →]   │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  2. Hotkey wählen                   │
│     [KeyboardShortcuts.Recorder]    │
│     "Halte diese Taste zum          │
│      Diktieren"                     │
│                        [Weiter →]   │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  3. Mikrofon-Zugriff               │
│     [Berechtigung anfragen]         │
│     → System-Dialog erscheint       │
│                        [Weiter →]   │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  4. API-Key eingeben                │
│     ( ) OpenAI (Empfohlen)          │
│     ( ) Groq                        │
│     [____________________________]  │
│                        [Weiter →]   │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  5. Test-Aufnahme                   │
│     "Halte deinen Hotkey und        │
│      sage etwas..."                 │
│     [🎤 Testen]                     │
│                        [Fertig!]    │
└─────────────────────────────────────┘
```

**Keine Accessibility-Permission nötig!** Das vereinfacht das Onboarding erheblich.

---

### 8. Clipboard-Manager

```swift
func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
```

Das war's! Der Text landet automatisch in:
- macOS Zwischenablage (⌘V)
- Paste App
- Raycast Clipboard History
- Alfred Clipboard

**Keine eigene History nötig.**

---

## Dateistruktur

```
WhisperM8/
├── WhisperM8App.swift           # Entry Point, MenuBarExtra, Settings Scene
├── Info.plist                   # LSUIElement, Permissions
│
├── Views/
│   ├── MenuBarView.swift        # Menübar-Dropdown
│   ├── SettingsView.swift       # API-Keys, Hotkey
│   ├── OnboardingView.swift     # Setup-Wizard
│   └── RecordingOverlayView.swift # SwiftUI View für Overlay
│
├── Windows/
│   └── RecordingPanel.swift     # NSPanel Subclass
│
├── Services/
│   ├── AudioRecorder.swift      # AVAudioEngine + M4A Export
│   ├── TranscriptionService.swift # OpenAI/Groq API Calls
│   └── KeychainManager.swift    # Sichere API-Key Speicherung
│
├── Models/
│   ├── AppState.swift           # @Observable Hauptzustand
│   └── APIProvider.swift        # Enum: .openai, .groq
│
└── Resources/
    └── Assets.xcassets          # App-Icons
```

---

## Benötigte Permission

| Permission | Benötigt | Methode |
|------------|----------|---------|
| **Mikrofon** | ✅ Ja | Automatischer System-Dialog |
| **Accessibility** | ❌ Nein | — |

---

## Nächster Schritt

→ Siehe `03-implementierungsplan.md` für die Entwicklungs-Phasen.
