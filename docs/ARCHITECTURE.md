# WhisperM8 - Architektur & Entwickler-Dokumentation

## Übersicht

WhisperM8 ist eine native macOS Diktier-App, die als MenuBar-App (LSUIElement) läuft.

```
┌─────────────────────────────────────────────────────────────┐
│  WhisperM8App (@main)                                       │
│  ├─ MenuBarExtra (Icon in Menüleiste)                      │
│  ├─ Window: Settings                                        │
│  ├─ Window: Onboarding                                      │
│  └─ RecordingPanel (NSPanel, floating)                     │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  AppState (@Observable)                                     │
│  ├─ isRecording: Bool                                      │
│  ├─ isTranscribing: Bool                                   │
│  ├─ audioLevel: Float                                      │
│  ├─ recordingDuration: TimeInterval                        │
│  └─ lastTranscription: String?                             │
└─────────────────────────────────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ KeyboardShortcuts│ │ AudioRecorder   │ │ Transcription   │
│ (Hold-to-Record)│ │ (AVAudioEngine) │ │ Service         │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

---

## Dateistruktur

```
WhisperM8/
├── WhisperM8App.swift          # @main Entry Point
├── Info.plist                  # App-Konfiguration (LSUIElement)
├── WhisperM8.entitlements      # Berechtigungen
│
├── Models/
│   ├── AppState.swift          # Zentraler App-Zustand (@Observable)
│   └── APIProvider.swift       # Enum für OpenAI/Groq
│
├── Views/
│   ├── MenuBarView.swift       # Menüleisten-Dropdown
│   ├── SettingsView.swift      # Einstellungen (TabView)
│   ├── OnboardingView.swift    # Ersteinrichtungs-Wizard
│   ├── RecordingOverlayView.swift # Overlay während Aufnahme
│   └── FocusableTextField.swift   # NSTextField-Wrapper für LSUIElement
│
├── Windows/
│   └── RecordingPanel.swift    # NSPanel + OverlayController
│
└── Services/
    ├── AudioRecorder.swift     # AVAudioEngine Recording
    ├── TranscriptionService.swift # API-Aufrufe
    └── KeychainManager.swift   # Sichere Key-Speicherung
```

---

## Komponenten im Detail

### 1. WhisperM8App.swift

Entry Point mit:
- `MenuBarExtra` für Menüleisten-Integration
- `Window` Scenes für Settings und Onboarding
- Hotkey-Setup via `KeyboardShortcuts.onKeyDown/onKeyUp`

```swift
@main
struct WhisperM8App: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra { ... }
        Window("Settings", id: "settings") { ... }
        Window("Onboarding", id: "onboarding") { ... }
    }
}
```

### 2. AppState.swift

Zentraler Zustand als `@Observable` Klasse:

```swift
@Observable
class AppState {
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var recordingDuration: TimeInterval = 0

    func startRecording() async { ... }
    func stopRecording() async { ... }
}
```

**Flow:**
1. `startRecording()` → AudioRecorder starten, Overlay zeigen, Timer starten
2. `stopRecording()` → Aufnahme stoppen, API-Call, Clipboard, Overlay verstecken

### 3. AudioRecorder.swift

AVAudioEngine-basierte Aufnahme:

```swift
class AudioRecorder {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?

    func startRecording() async throws {
        // 1. Permission check
        // 2. AVAudioEngine setup
        // 3. installTap für Buffer-Zugriff
        // 4. Audio-Level Berechnung (RMS)
        // 5. M4A Export (AAC, 16kHz, mono)
    }
}
```

**Audio-Format:**
- Format: M4A (AAC)
- Sample Rate: 16 kHz
- Channels: Mono
- Bitrate: 32 kbps

### 4. TranscriptionService.swift

Protokoll-basiertes Design für Provider-Austauschbarkeit:

```swift
protocol TranscriptionProvider {
    func transcribe(audioURL: URL, language: String?) async throws -> String
}

class OpenAITranscriptionService: TranscriptionProvider { ... }
class GroqTranscriptionService: TranscriptionProvider { ... }
```

**API-Endpunkte:**
- OpenAI: `https://api.openai.com/v1/audio/transcriptions`
- Groq: `https://api.groq.com/openai/v1/audio/transcriptions`

**Request-Format:** Multipart/form-data

### 5. RecordingPanel.swift

NSPanel für nicht-aktivierendes Overlay:

```swift
class RecordingPanel: NSPanel {
    init() {
        super.init(
            styleMask: [.borderless, .nonactivatingPanel],
            ...
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

### 6. KeychainManager.swift

Sichere Speicherung von API-Keys:

```swift
enum KeychainManager {
    static func save(key: String, value: String) { ... }
    static func load(key: String) -> String? { ... }
    static func delete(key: String) { ... }
}
```

---

## Bekannte Einschränkungen

### LSUIElement Focus-Problem

MenuBar-Apps (LSUIElement=true) haben Probleme mit Keyboard-Focus in Fenstern.

**Lösung:** Temporärer Wechsel zu `.regular` Activation Policy:

```swift
.onAppear {
    NSApp.setActivationPolicy(.regular)  // Zeigt im Dock
    NSApp.activate(ignoringOtherApps: true)
}
.onDisappear {
    NSApp.setActivationPolicy(.accessory)  // Versteckt aus Dock
}
```

### KeyboardShortcuts #Preview Makro

Die KeyboardShortcuts-Library enthält `#Preview` Makros, die mit `swift build` (ohne Xcode) nicht kompilieren.

**Workaround:** Makros in `.build/checkouts/` auskommentieren oder mit Xcode bauen.

---

## Dependencies

| Package | Version | Zweck |
|---------|---------|-------|
| KeyboardShortcuts | 1.16.1 | Globale Hotkeys ohne Accessibility |
| Defaults | 8.2.0 | UserDefaults-Wrapper |
| LaunchAtLogin-Modern | 1.1.0 | Login-Item Management |

---

## Build & Run

```bash
# Debug Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build

# Release Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

# Run
.build/debug/WhisperM8
```

---

## Testing

Manuelle Test-Checkliste:

- [ ] App startet, Menüleisten-Icon erscheint
- [ ] Einstellungen öffnen sich
- [ ] API-Key kann eingegeben werden
- [ ] Hotkey kann konfiguriert werden
- [ ] Hotkey-Druck startet Aufnahme
- [ ] Overlay erscheint mit Audio-Level
- [ ] Loslassen startet Transkription
- [ ] Text landet in Zwischenablage
- [ ] Fehler werden im Menü angezeigt

---

## Erweiterungsmöglichkeiten

1. **Lokale Whisper-Integration** - Offline-Transkription
2. **History** - Transkriptions-Verlauf speichern
3. **Auto-Paste** - Automatisches Einfügen nach Transkription
4. **Shortcuts-Integration** - Apple Shortcuts Support
5. **Multiple Hotkeys** - Verschiedene Hotkeys für verschiedene Sprachen
