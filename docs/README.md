# WhisperM8

Native macOS Diktier-App mit OpenAI Whisper / Groq Transkription.

> **Weitere Dokumentation:** [USER_GUIDE.md](USER_GUIDE.md) - Ausführliches Benutzerhandbuch

## Schnellstart (TL;DR)

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
# App starten → Berechtigungen erteilen → API-Key eingeben → Fertig!
```

**Bei Problemen (Crashes, seltsames Verhalten):**
```bash
make clean-install
```

---

## Features

- **Push-to-Talk**: Hotkey gedrückt halten → sprechen → loslassen → Text wird transkribiert und eingefügt
- **Auto-Paste**: Transkribierter Text wird automatisch in die aktive App eingefügt
- **Aufnahme abbrechen**: X-Button im Overlay klicken um abzubrechen (ohne Transkription)
- **Dual-Provider**: OpenAI Whisper oder Groq (schneller, günstiger)
- **Menu Bar App**: Läuft diskret in der Menüleiste

---

## Installation

### Option A: DMG (empfohlen)

1. DMG-Datei erhalten (von Kollegen oder `make dmg`)
2. DMG öffnen
3. `WhisperM8.app` in den `Applications`-Ordner ziehen
4. App starten

### Option B: Aus Source bauen

**Voraussetzungen:**
- macOS 14.0+
- Xcode Command Line Tools: `xcode-select --install`

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

Die App landet in `/Applications/WhisperM8.app`.

---

## Make-Befehle

| Befehl | Beschreibung |
|--------|--------------|
| `make build` | Release-Build erstellen (App bleibt im Repo) |
| `make install` | Build + nach `/Applications` installieren |
| `make run` | Debug-Build + sofort starten |
| `make dmg` | DMG für Verteilung erstellen (`dist/WhisperM8-1.0.0.dmg`) |
| `make clean-install` | **Alles zurücksetzen** + neu installieren |
| `make kill` | Alle laufenden Instanzen beenden |
| `make clean` | Build-Artefakte löschen |

---

## Clean Install (bei Problemen)

Falls die App crasht, sich seltsam verhält, oder nach dem ersten Mal nicht mehr startet:

```bash
make clean-install
```

**Was das Script macht (`scripts/clean-install.sh`):**
1. Beendet alle WhisperM8-Prozesse
2. Löscht alte App-Installationen (`/Applications`, `~/Applications`, `~/Desktop`, `~/Downloads`)
3. Setzt **alle** TCC-Berechtigungen zurück (für alle möglichen Bundle-IDs)
4. Löscht UserDefaults (für alle möglichen Bundle-IDs)
5. Löscht Preferences-Dateien direkt
6. Löscht Keychain-Einträge (API-Keys)
7. Löscht Cache-Daten
8. Löscht Application Support
9. Löscht gespeicherten Window-State
10. Löscht Container-Daten (falls vorhanden)
11. Löscht temporäre Dateien
12. Installiert die App neu

**Danach musst du:**
- Berechtigungen neu erteilen (Mikrofon + Accessibility)
- API-Key neu eingeben
- Hotkey festlegen

### Manueller Reset (ohne Neuinstallation)

Falls du nur die Berechtigungen zurücksetzen willst:
```bash
./scripts/clean-install.sh
# Dann manuell: make install
```

---

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
- Falls verweigert: **Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon → WhisperM8** aktivieren

#### Accessibility (für Auto-Paste)
- Wird benötigt um Cmd+V an andere Apps zu senden
- **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → WhisperM8** aktivieren

**Falls WhisperM8 nicht in der Liste erscheint:**
1. Klick auf "+"
2. Drücke `Cmd+Shift+G` und gib ein: `/Applications/WhisperM8.app`
3. Hinzufügen und Toggle aktivieren

---

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

---

## Troubleshooting

### App crasht nach dem ersten Mal / bei jedem Start

**Lösung:** Clean Install
```bash
make clean-install
```

Das liegt meist an alten Einstellungen oder Berechtigungen von früheren Versionen.

### Auto-Paste funktioniert nicht

1. **Accessibility-Berechtigung prüfen:**
   - Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen
   - WhisperM8 muss aktiviert sein

2. **App neu starten** nach Berechtigungsänderung

3. **Auto-Paste deaktiviert?** → Einstellungen → Allgemein prüfen

4. **Logs prüfen:**
   ```bash
   log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
   ```

### Mikrofon-Fehler / "Microphone usage description" Crash

```bash
make clean-install
```

### API-Fehler

- Key korrekt eingegeben? (keine Leerzeichen am Ende)
- Groq Rate-Limit erreicht? → Warten oder zu OpenAI wechseln
- Netzwerk-Verbindung prüfen

### App erscheint nicht in Menüleiste

- Schon eine Instanz offen? `make kill`
- Console.app → WhisperM8 Logs prüfen

### Berechtigungen komplett zurücksetzen

```bash
# Nur Berechtigungen zurücksetzen (ohne Neuinstallation)
tccutil reset Accessibility com.whisperm8.app
tccutil reset Microphone com.whisperm8.app
```

---

## Debug Logging

```bash
# Live-Logs während App läuft
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug

# Kategorien:
# - AutoPaste: Paste-Sequenz
# - Focus: App-Aktivierung
# - Permission: Berechtigungen
```

---

## Projektstruktur

```
whisperm8/
├── WhisperM8/                    # Source Code
│   ├── WhisperM8App.swift        # App-Entry, Single-Instance Check
│   ├── Models/
│   │   └── AppState.swift        # Zentraler State, Recording + Paste Logic
│   ├── Views/
│   │   ├── MenuBarView.swift     # Menüleisten-UI
│   │   ├── SettingsView.swift    # Einstellungen
│   │   └── OnboardingView.swift
│   ├── Windows/
│   │   └── RecordingPanel.swift  # Floating Overlay + Controller
│   ├── Services/
│   │   ├── AudioRecorder.swift   # AVAudioRecorder Wrapper
│   │   ├── TranscriptionService.swift # OpenAI/Groq API
│   │   ├── KeychainManager.swift # Sichere API-Key Speicherung
│   │   └── Logger.swift          # Debug Logging
│   ├── Resources/
│   │   └── AppIcon.icns          # App Icon
│   └── Info.plist                # App-Konfiguration, Permissions
├── scripts/
│   ├── build-dmg.sh              # DMG erstellen
│   └── clean-install.sh          # Reset + Neuinstallation
├── docs/
│   ├── README.md                 # Technische Dokumentation (diese Datei)
│   └── USER_GUIDE.md             # Benutzerhandbuch
├── Makefile                      # Build-Befehle
└── Package.swift                 # Swift Package Definition
```

---

## Für Entwickler

### Wichtige Code-Stellen

#### Auto-Paste Sequenz (`AppState.swift`)
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

#### Previous App Capture (`RecordingPanel.swift`)
Die App die vor dem Overlay aktiv war wird in `show()` gespeichert:
```swift
previousApp = NSWorkspace.shared.frontmostApplication
```

#### Accessibility Permission Check (`AppState.swift`)
```swift
var hasAccessibilityPermission: Bool {
    AXIsProcessTrusted()
}

func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
```

---

## Lizenz

Intern - nur für Team-Nutzung.
