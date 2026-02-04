# WhisperM8

Native macOS Diktier-App mit OpenAI Whisper / Groq Transkription.

## Features

- **Push-to-Talk**: Hotkey gedrückt halten → sprechen → loslassen → Text wird transkribiert und eingefügt
- **Auto-Paste**: Transkribierter Text wird automatisch in die aktive App eingefügt
- **Aufnahme abbrechen**: X-Button im Overlay klicken um abzubrechen (ohne Transkription)
- **Dual-Provider**: OpenAI Whisper oder Groq (schneller, günstiger)
- **Menu Bar App**: Läuft diskret in der Menüleiste

## Installation

### Option A: DMG (empfohlen für Endnutzer)

1. DMG-Datei von Kollegen erhalten (oder selbst bauen: `make dmg`)
2. DMG öffnen
3. `WhisperM8.app` in den `Applications`-Ordner ziehen
4. App starten

### Option B: Aus Source bauen

**Voraussetzungen:**
- macOS 14.0+
- Xcode Command Line Tools: `xcode-select --install`

```bash
git clone <repo-url>
cd whisperm8

# Release build + Installation
make install

# Oder nur bauen (App bleibt im Repo-Ordner)
make build

# DMG für Verteilung erstellen
make dmg
```

Die App landet in `/Applications/WhisperM8.app`.

### Entwicklung

```bash
# Debug build + starten
make run

# Alte Instanzen killen
make kill

# Aufräumen
make clean
```

### Clean Install (bei Problemen)

Falls die App crasht oder sich seltsam verhält:

```bash
make clean-install
```

Das entfernt alle alten Einstellungen, Berechtigungen und Cache-Daten und installiert komplett neu.

## Ersteinrichtung

### 1. API-Key einrichten

Beim ersten Start öffnet sich das Onboarding. Du brauchst einen API-Key:

| Provider | Link | Preis |
|----------|------|-------|
| OpenAI | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | ~$0.006/min |
| Groq | [console.groq.com/keys](https://console.groq.com/keys) | Kostenlos (Rate-Limited) |

### 2. Hotkey festlegen

Standard: **Fn** (Globe-Taste) oder selbst wählen in Einstellungen → Hotkey.

**Empfohlen:** `Control + Shift + Space`

**Hinweis:** Option-only Shortcuts funktionieren auf macOS 15+ nicht zuverlässig.

### 3. Berechtigungen

Die App benötigt zwei Berechtigungen:

#### Mikrofon
- Wird beim ersten Aufnahmeversuch automatisch angefragt
- Falls verweigert: Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon → WhisperM8 aktivieren

#### Accessibility (für Auto-Paste)
- Wird benötigt um Cmd+V an andere Apps zu senden
- Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → WhisperM8 aktivieren

**Falls WhisperM8 nicht in der Liste erscheint:**
1. Klick auf "+"
2. Navigiere zu `/Applications/WhisperM8.app`
3. Hinzufügen und Toggle aktivieren

## Verwendung

1. **Cursor platzieren** in einem Textfeld (TextEdit, Slack, Browser, etc.)
2. **Hotkey gedrückt halten** und sprechen
3. **Hotkey loslassen** → Transkription startet
4. **Text erscheint** automatisch im Textfeld

### Aufnahme abbrechen

Während der Aufnahme kannst du jederzeit abbrechen:
- **X-Button** im Overlay klicken

Die Aufnahme wird verworfen, nichts wird transkribiert oder eingefügt.

### Overlay-Anzeige

Während der Aufnahme erscheint unten am Bildschirm:
- Rote Aufnahme-Anzeige mit Dauer
- Audio-Level Visualisierung
- X-Button zum Abbrechen (rechts)
- "Transkribiere..." während API-Aufruf

### Einstellungen

Über das Menüleisten-Icon → "Einstellungen...":

| Tab | Optionen |
|-----|----------|
| API | Provider wählen, API-Key, Sprache (de/en/auto) |
| Hotkey | Aufnahme-Taste konfigurieren |
| Allgemein | Auto-Start, Auto-Paste an/aus |

## Architektur

```
WhisperM8/
├── WhisperM8App.swift      # App-Entry, Single-Instance Check
├── Models/
│   └── AppState.swift      # Zentraler State, Recording + Paste Logic
├── Views/
│   ├── MenuBarView.swift   # Menüleisten-UI
│   ├── SettingsView.swift  # Einstellungen
│   └── OnboardingView.swift
├── Windows/
│   └── RecordingPanel.swift # Floating Overlay + Controller
├── Services/
│   ├── AudioRecorder.swift # AVAudioRecorder Wrapper
│   ├── TranscriptionService.swift # OpenAI/Groq API
│   ├── KeychainManager.swift # Sichere API-Key Speicherung
│   └── Logger.swift        # Debug Logging
└── Info.plist              # App-Konfiguration, Permissions
```

### Wichtige Code-Stellen

#### Auto-Paste Sequenz (`AppState.swift:166-237`)
```
1. AXIsProcessTrusted() Check
2. previousApp von OverlayController holen
3. Panel verstecken
4. 50ms warten
5. targetApp.activate()
6. Polling bis App aktiv (max 1s)
7. 100ms warten
8. CGEvent Cmd+V posten
```

#### Previous App Capture (`RecordingPanel.swift:50-53`)
Die App die vor dem Overlay aktiv war wird in `show()` gespeichert:
```swift
previousApp = NSWorkspace.shared.frontmostApplication
```

#### Accessibility Permission (`AppState.swift:157-164`)
```swift
var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
}

func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
```

## Troubleshooting

### Auto-Paste funktioniert nicht

1. **Accessibility-Berechtigung prüfen:**
   ```bash
   # Logs anschauen
   log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
   ```
   Falls "Accessibility permission missing" → Berechtigung in Systemeinstellungen aktivieren

2. **App neu starten** nach Berechtigungsänderung

3. **Auto-Paste deaktiviert?** → Einstellungen → Allgemein prüfen

### Mikrofon-Fehler

- Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon → WhisperM8 aktivieren
- Bei "Microphone usage description" Crash: `make clean && make install`

### API-Fehler

- Key korrekt eingegeben? (keine Leerzeichen am Ende)
- Groq Rate-Limit erreicht? → Warten oder zu OpenAI wechseln
- Netzwerk-Verbindung prüfen

### App erscheint nicht in Menüleiste

- Schon eine Instanz offen? `make kill`
- Console.app → WhisperM8 Logs prüfen

## Debug Logging

```bash
# Live-Logs während App läuft
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug

# Kategorien:
# - AutoPaste: Paste-Sequenz
# - Focus: App-Aktivierung
# - Permission: Berechtigungen
```

## Lizenz

Intern - nur für Team-Nutzung.
