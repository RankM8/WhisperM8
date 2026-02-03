# WhisperM8

Native macOS Diktier-App mit bester Transkriptionsqualität.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Hold-to-Record Hotkey** - Halte eine Taste gedrückt zum Diktieren
- **Beste Transkription** - OpenAI gpt-4o-transcribe oder Groq whisper-large-v3
- **Floating Overlay** - Echtzeit Audio-Level Anzeige während der Aufnahme
- **Clipboard Integration** - Text landet automatisch in der Zwischenablage
- **Native macOS App** - Läuft in der Menüleiste, kein Dock-Icon
- **Sicher** - API-Keys im macOS Keychain gespeichert

## Screenshots

```
┌────────────────────────────────────┐
│  MIC  Aufnahme...  00:05  ▁▃▅▇▅▃▁  │
└────────────────────────────────────┘
```

## Quick Start

```bash
# Repository klonen
git clone https://github.com/yourname/whisperm8.git
cd whisperm8

# Bauen (Xcode muss installiert sein)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build

# Starten
.build/debug/WhisperM8
```

## Systemanforderungen

- macOS 14+ (Sonoma)
- Xcode (zum Bauen)
- OpenAI oder Groq API-Key

## Einrichtung

1. **App starten** - Mikrofon-Icon erscheint in der Menüleiste
2. **Einstellungen öffnen** - Klick auf Icon → "Einstellungen..."
3. **API-Key eingeben** - OpenAI oder Groq Key eintragen
4. **Hotkey wählen** - z.B. `Ctrl + Shift + Space`
5. **Diktieren** - Hotkey halten, sprechen, loslassen → Text in Zwischenablage

## Dokumentation

- [Benutzerhandbuch](docs/USER_GUIDE.md)
- [Architektur](docs/ARCHITECTURE.md)
- [Implementierungsplan](docs/03-implementierungsplan.md)

## API-Provider

| Provider | Modell | Qualität | Preis |
|----------|--------|----------|-------|
| OpenAI | gpt-4o-transcribe | Beste | $0.006/min |
| Groq | whisper-large-v3 | Sehr gut | $0.002/min |

## Tech Stack

- Swift / SwiftUI
- AVFoundation (Audio)
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- [Defaults](https://github.com/sindresorhus/Defaults)
- [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern)

## Projektstruktur

```
WhisperM8/
├── WhisperM8App.swift         # Entry Point
├── Models/                    # AppState, APIProvider
├── Views/                     # SwiftUI Views
├── Windows/                   # NSPanel für Overlay
└── Services/                  # Audio, API, Keychain
```

## Lizenz

MIT

---

Made with Claude Code
