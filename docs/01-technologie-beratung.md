# Technologie-Beratung: WhisperM8

> **Entscheidung:** Swift/SwiftUI ✅

## Warum Swift/SwiftUI?

| Kriterium | Electron | Tauri | Swift/SwiftUI |
|-----------|----------|-------|---------------|
| **App-Größe** | 150-200 MB | 10-20 MB | **5-15 MB** ✅ |
| **RAM-Verbrauch** | 100-300 MB | 50-100 MB | **20-50 MB** ✅ |
| **Startup-Zeit** | 2-5 Sek | 1-2 Sek | **<1 Sek** ✅ |
| **Native APIs** | Über Node.js | Über Rust-Bridge | **Direkt** ✅ |
| **Globale Hotkeys** | Kompliziert | Kompliziert | **Einfach** ✅ |
| **Menübar-Apps** | Hacky | Möglich | **Erstklassig** ✅ |
| **Audio-Aufnahme** | Externe Libs | Externe Libs | **AVFoundation** ✅ |

**Fazit:** Für eine kleine, performante macOS-only Menübar-App ist Swift/SwiftUI die einzig sinnvolle Wahl.

---

## Empfohlene Libraries

| Library | Zweck | Quelle |
|---------|-------|--------|
| **KeyboardShortcuts** | Globale Hotkeys (ohne Accessibility!) | sindresorhus/KeyboardShortcuts |
| **Defaults** | Type-safe UserDefaults | sindresorhus/Defaults |
| **LaunchAtLogin** | Auto-Start bei Login | sindresorhus/LaunchAtLogin |
| **Sparkle** | Auto-Updates | sparkle-project/Sparkle |

### KeyboardShortcuts - Der Schlüssel

Diese Library ist entscheidend, weil sie:
- **Keine Accessibility-Permission** benötigt (nutzt Carbon API intern)
- Hold-to-Record Pattern unterstützt (KeyDown → Start, KeyUp → Stop)
- Eingebauten `RecorderCocoa`-View für Hotkey-Konfiguration hat
- Von sindresorhus gepflegt wird (sehr zuverlässig)

```swift
// Beispiel: Hold-to-Record
KeyboardShortcuts.onKeyDown(for: .startRecording) {
    appState.startRecording()
}
KeyboardShortcuts.onKeyUp(for: .startRecording) {
    appState.stopRecording()
}
```

---

## Technische Entscheidungen

### Audio-Aufnahme

| Entscheidung | Wert |
|--------------|------|
| **API** | AVAudioEngine (nicht AVAudioRecorder) |
| **Format** | M4A (AAC) |
| **Sample Rate** | 16 kHz |
| **Kanäle** | Mono |
| **Bitrate** | 32 kbps |
| **Max. Dauer** | 100+ Minuten (unter 25MB API-Limit) |

**Warum AVAudioEngine?** `installTap` auf `inputNode` ermöglicht Echtzeit-Buffer-Zugriff für Audio-Level-Metering.

### Floating Overlay

| Entscheidung | Wert |
|--------------|------|
| **Window-Typ** | NSPanel (nicht NSWindow) |
| **Style Mask** | `.nonactivatingPanel` |
| **Window Level** | `.floating` |
| **Größe** | 180×56pt |
| **Position** | Bottom-center, 40pt vom Rand |

**Wichtig:** `canBecomeKey` und `canBecomeMain` → `false` (kein Fokus-Stealing)

### Menübar-App

| Entscheidung | Wert |
|--------------|------|
| **API** | SwiftUI `MenuBarExtra` |
| **macOS Minimum** | 14 (Sonoma) |
| **Style** | `.menu` für Dropdown |
| **Dock-Icon** | Versteckt (`LSUIElement = true`) |

---

## Benötigte Permissions

| Permission | Benötigt? | Grund |
|------------|-----------|-------|
| **Mikrofon** | ✅ Ja | Audio-Aufnahme |
| **Accessibility** | ❌ **Nein!** | KeyboardShortcuts nutzt Carbon API |

Das ist ein großer UX-Vorteil gegenüber anderen Apps, die Accessibility benötigen!

---

## Bekannte Einschränkungen

### macOS Sequoia Bug
Option-only Shortcuts (z.B. nur ⌥) funktionieren nicht mehr in sandboxed Apps.

**Empfehlung:** Shortcuts mit Cmd-Key verwenden (z.B. ⌘⇧R).

---

## Architektur-Übersicht

```
WhisperM8/
├── WhisperM8App.swift           # Entry Point, MenuBarExtra, Settings Scene
├── Info.plist                   # LSUIElement, NSMicrophoneUsageDescription
│
├── Views/
│   ├── MenuBarView.swift        # Menübar-Dropdown
│   ├── SettingsView.swift       # API-Keys, Hotkey-Konfiguration
│   ├── OnboardingView.swift     # Setup-Wizard
│   └── RecordingOverlay.swift   # NSPanel-basiertes Floating Window
│
├── Services/
│   ├── AudioRecorder.swift      # AVAudioEngine + M4A Export
│   ├── TranscriptionService.swift # OpenAI/Groq API
│   └── KeychainManager.swift    # Sichere API-Key Speicherung
│
├── Models/
│   ├── AppState.swift           # @Observable Hauptzustand
│   └── APIProvider.swift        # Enum: .openai, .groq
│
└── Resources/
    └── Assets.xcassets          # App-Icons, SF Symbols
```

---

## Nächster Schritt

→ Siehe `02-komponenten-architektur.md` für Details zu jeder Komponente.
