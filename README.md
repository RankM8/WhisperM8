# WhisperM8

Eine native macOS Diktier-App mit bester Transkriptionsqualität.

## Features

- Globaler Hotkey (Hold-to-Record) fur Sprachaufnahme
- Automatische Transkription via OpenAI gpt-4o-transcribe oder Groq whisper-large-v3
- Minimales Floating Overlay wahrend der Aufnahme mit Audio-Level Anzeige
- Text direkt in die Zwischenablage
- Einfache Konfiguration uber Onboarding-Wizard
- Leichtgewichtige native macOS App (kein Dock-Icon)

## Systemanforderungen

- macOS 14+ (Sonoma)
- OpenAI API Key oder Groq API Key

## Installation

### Option 1: In Xcode offnen (Empfohlen)

1. Repository klonen:
   ```bash
   git clone https://github.com/yourname/whisperm8.git
   cd whisperm8
   ```

2. Das Projekt in Xcode offnen:
   ```bash
   open WhisperM8.xcodeproj
   ```

3. In Xcode: Product > Run (Cmd+R)

### Option 2: Swift Package (Xcode erforderlich)

Das Projekt nutzt externe Dependencies mit #Preview Makros, die nur in Xcode funktionieren.

## Verwendung

1. **Erster Start:** Der Onboarding-Wizard fuhrt dich durch die Einrichtung:
   - Hotkey konfigurieren (z.B. Ctrl+Shift+Space)
   - Mikrofon-Berechtigung erteilen
   - API-Key eingeben (OpenAI oder Groq)

2. **Diktieren:**
   - Halte deinen Hotkey gedruckt
   - Sprich deinen Text
   - Lass den Hotkey los
   - Der transkribierte Text ist automatisch in der Zwischenablage

3. **Einstellungen:** Klicke auf das Mikrofon-Icon in der Menubar > Einstellungen

## Tech Stack

- Swift / SwiftUI
- macOS 14+ (Sonoma)
- AVFoundation (Audio-Aufnahme)
- KeyboardShortcuts (sindresorhus)
- Defaults (sindresorhus)
- LaunchAtLogin-Modern (sindresorhus)

## API-Provider

| Provider | Modell | Preis |
|----------|--------|-------|
| OpenAI | gpt-4o-transcribe | $0.006/min |
| Groq | whisper-large-v3 | $0.002/min |

## Projektstruktur

```
WhisperM8/
├── WhisperM8App.swift         # Entry Point, MenuBarExtra, Hotkey-Setup
├── Models/
│   ├── AppState.swift         # Zentraler App-Zustand
│   └── APIProvider.swift      # Provider-Enum (OpenAI/Groq)
├── Views/
│   ├── MenuBarView.swift      # Menubar-Dropdown
│   ├── SettingsView.swift     # Einstellungen
│   ├── OnboardingView.swift   # Setup-Wizard
│   └── RecordingOverlayView.swift # Overlay UI
├── Windows/
│   └── RecordingPanel.swift   # NSPanel fur Overlay
├── Services/
│   ├── AudioRecorder.swift    # AVAudioEngine Recording
│   ├── TranscriptionService.swift # API Integration
│   └── KeychainManager.swift  # Sichere Key-Speicherung
├── Info.plist
└── WhisperM8.entitlements
```

## Berechtigungen

| Berechtigung | Benotigt | Methode |
|--------------|----------|---------|
| Mikrofon | Ja | Automatischer System-Dialog |
| Accessibility | Nein | - |

## Lizenz

MIT

---

Made with Claude Code
