---
status: aktiv
description: Projekt-README — Überblick, Quick Start, Dokumentationslandkarte und Build von WhisperM8
description_long: |
  Einstiegspunkt der WhisperM8-Dokumentation: Kurzbeschreibung der nativen
  macOS-Diktier-App (OpenAI Whisper / Groq), Quick Start, Dokumentationslandkarte
  und Install-/Build-Hinweise. Verweist auf USER_GUIDE.md und die Detail-Docs.
updated: 2026-07-09
---

# WhisperM8

Native macOS dictation app with OpenAI Whisper / Groq transcription.

> **Additional documentation:** [USER_GUIDE.md](USER_GUIDE.md) - Detailed user guide

## Quick Start (TL;DR)

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
# Launch app → grant permissions → enter API key → done!
```

**Having issues (crashes, strange behavior)?**
```bash
make clean-install
```

---

## Dokumentationslandkarte

Seit der Neuordnung vom 2026-07-09 trennt die Dokumentation den aktuellen
Produktstand, offene Vorhaben, historische Quellen und externe Referenzen.
Diese Seite beschränkt sich auf Navigation und betriebliche Kurzreferenz;
fachliche und UI-bezogene Details liegen in den verlinkten Dokumenten.

### Produkt-Säulen

| Säule | Rolle |
|---|---|
| [`features/dictation/`](features/dictation/) | Beschreibt die Diktat-Pipeline vom Hotkey über Aufnahme, Transkription und optionale AI-Nachbearbeitung bis zur Ausgabe. |
| [`features/agent-chats/`](features/agent-chats/) | Beschreibt Agent-Sessions, Terminal- und Timeline-UI, Subagents, Background-Agents und die Codex-Exec-Integration. |
| [`features/cli/`](features/cli/) | Beschreibt das gemeinsame `whisperm8`-Binary mit den Befehlen für Transkription, Agent-Jobs und deren Supervisor. |
| [`features/settings/`](features/settings/) | Beschreibt die aktuelle Settings-Struktur, ihr Routing sowie die wiederverwendbaren UI- und Zustandsbausteine. |
| [`features/app-shell/`](features/app-shell/) | Beschreibt die App-Hülle: Nutzungsprofile (Dock/MenuBar), Onboarding-Wizard, Menüleisten-Aktionen und den Update-Flow. |

Der Einstieg in alle Bereiche liegt unter
[`features/README.md`](features/README.md).

### Weitere Dokumentationsbereiche

| Pfad | Rolle |
|---|---|
| [`plans/`](plans/) | Offene, noch nicht vollständig umgesetzte Vorhaben; sie beschreiben nicht den Ist-Zustand. |
| [`archive/`](archive/) | Historie und Quellenlager für abgelöste Pläne, Recherchen und frühere Dokumentationsstände. |
| [`referenz/claude-code/`](referenz/claude-code/) | Externe CLI-Referenz für Claude Code und dessen Session-, Hook- und Agent-Verhalten. |
| [`adr/`](adr/) | Architekturentscheidungen mit Kontext, Entscheidung und Folgen. |
| [`refactor/`](refactor/) | Querschnittliche Refactoring-Befunde und technische Konsolidierung. |
| [`commit-doc/`](commit-doc/) | Änderungsbezogene Commit- und WIP-Dokumentation mit globalem Index. |

### Schlüsseldateien

| Pfad | Rolle |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Querschnittliche Systemarchitektur und Infrastruktur-Leitplanken. |
| [`USER_GUIDE.md`](USER_GUIDE.md) | Anwenderorientierte Bedienungsanleitung. |
| [`DMG_BAUEN.md`](DMG_BAUEN.md) | Betriebliche Anleitung zum Erzeugen eines DMG-Pakets. |

---

## Installation

### Build from source (current supported path)

**Requirements:**
- macOS 14.0+
- Vollständiges Xcode unter `/Applications/Xcode.app`; der Makefile-Build setzt
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` für die
  SwiftUI-Makros. Command Line Tools allein reichen für den regulären Build
  nicht aus.

```bash
git clone git@github.com:RankM8/whisperm8.git
cd whisperm8
make install
```

The app will be installed to `/Applications/WhisperM8.app`.

---

## Make Commands

| Command | Description |
|---------|-------------|
| `make build` | Create release build (app stays in repo) |
| `make install` | Build + install to `/Applications` |
| `make run` | Debug build + launch immediately |
| `make clean-install` | Remove app data, reset Microphone/Accessibility permissions, then reinstall |
| `make kill` | Stop all running instances |
| `make clean` | Delete build artifacts |

---

## Clean Install (for issues)

If the app crashes, behaves strangely, or won't start after the first time:

```bash
make clean-install
```

**What `make clean-install` does:**
1. Stops all WhisperM8 processes
2. Removes old app installations (`/Applications`, `~/Applications`, `~/Desktop`, `~/Downloads`)
3. Resets Accessibility and Microphone permissions for current and legacy bundle IDs; Screen Recording is not reset
4. Deletes UserDefaults (for all possible bundle IDs)
5. Deletes Preferences files directly
6. Deletes Keychain entries (API keys)
7. Deletes cached data
8. Deletes Application Support
9. Deletes saved window state
10. Deletes Container data (if present)
11. Deletes temporary files
12. Runs `make install` after `scripts/clean-install.sh` has completed

**After this you need to:**
- Grant Microphone permission again and, when using Auto-Paste, Accessibility
- Re-enter API key
- Set hotkey

### Cleanup without automatic reinstall

Running the cleanup script directly performs the same destructive cleanup,
including removal of app bundles, UserDefaults, Keychain entries, caches and
Application Support. It does **not** reinstall the app:

```bash
./scripts/clean-install.sh
# Required afterwards if you want the app installed again:
make install
```

---

## First Setup

### 1. Set up API Key

On first launch, the onboarding opens. You need an API key:

| Provider | Link | Im Repository hinterlegter Richtwert |
|----------|------|--------------------------------------|
| OpenAI | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | $0.006/min |
| Groq | [console.groq.com/keys](https://console.groq.com/keys) | $0.002/min; die App weist zusätzlich auf einen kostenlosen Key und Freigrenzen hin |

Die Werte sind statische UI-Angaben des Repositorys, keine live geprüften
Providerpreise. Verfügbarkeit, Freikontingente, Abrechnung sowie relative
Geschwindigkeit und Kosten sind externe Eigenschaften der Provider.

### 2. Set Hotkey

On a fresh installation no default shortcut is registered. Set one in
Settings → Recording.

**Recommended:** `Control + Shift + Space`

**Empirical note:** Option-only shortcuts have historically been reported as
unreliable on macOS 15+. This behavior is not enforced by a platform check and
is not covered by repository tests.

### 3. Permissions

Microphone permission is required for dictation. Accessibility is also a
mandatory onboarding and startup gate, even when Auto-Paste is disabled;
Auto-Paste and selected-text capture use it at runtime. Optional visual-context
capture can additionally request Screen Recording permission.

#### Microphone
- Automatically requested on first recording attempt
- If denied: **System Settings → Privacy & Security → Microphone → WhisperM8** enable

#### Accessibility
- Missing permission reopens onboarding on every launch, keeps the regular Dock policy and blocks Next/Done
- Used to send Cmd+V to other apps and to capture selected text
- **System Settings → Privacy & Security → Accessibility → WhisperM8** enable

**If WhisperM8 doesn't appear in the list:**
1. Click "+"
2. Press `Cmd+Shift+G` and enter: `/Applications/WhisperM8.app`
3. Add and enable toggle

---

## Usage

Use the configured hotkey to start and stop dictation. Every successful result
is copied to the clipboard. If Auto-Paste is enabled, Accessibility is granted
and a target application was captured before the overlay opened, WhisperM8
pastes there; otherwise the text remains on the clipboard.

Detailed operation and UI behavior: [USER_GUIDE.md](USER_GUIDE.md) and
[features/dictation/](features/dictation/). Current Settings structure:
[features/settings/README.md](features/settings/README.md).

---

## Troubleshooting

### App crashes after first time / on every start

**Solution:** Clean Install
```bash
make clean-install
```

`make clean-install` is an empirical troubleshooting measure. The repository
contains no diagnostic or frequency data proving that old settings or
permissions are the usual cause of startup crashes.

### Auto-paste not working

1. **Check Accessibility permission:**
   - System Settings → Privacy & Security → Accessibility
   - WhisperM8 must be enabled

2. **Restart app** after permission change

3. **Auto-paste disabled?** → Check Settings → Recording

4. **Check logs:**
   ```bash
   log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
   ```

### Microphone error / "Microphone usage description" crash

```bash
make clean-install
```

### Bluetooth-Mikrofone (AirPods, etc.)

WhisperM8 beobachtet Audio-Konfigurationsänderungen während einer Aufnahme nur,
wenn als Eingabegerät **System Default** gewählt ist. In diesem Modus kann der
Recorder auf einen Wechsel des macOS-Standardgeräts reagieren und den Audio-Tap
mit dem neuen Format neu installieren. Für ein explizit ausgewähltes Gerät ist
dieser Observer nicht aktiv; ein unterbrechungsfreier Wechsel wird daher nicht
zugesichert.

Der Wechsel von Bluetooth-Audio zwischen A2DP und HFP ist externes
macOS-/Geräteverhalten und wird durch das Repository nicht allgemein
garantiert.

### API errors

- Key entered correctly? (no spaces at end)
- Groq rate limit reached? → Wait or switch to OpenAI
- Check network connection

### App not appearing in menu bar

- Already an instance running? `make kill`
- Check Console.app → WhisperM8 logs

### Reset Microphone and Accessibility permissions

```bash
# Reset these two permissions without reinstalling
tccutil reset Accessibility com.whisperm8.app
tccutil reset Microphone com.whisperm8.app
```

---

## Debug Logging

```bash
# Live logs while app runs
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug

# Categories:
# - AutoPaste: Paste sequence
# - Focus: App activation
# - Permission: Permissions
```

---

## Project Structure

```
whisperm8/
├── WhisperM8/                    # App- und CLI-Quellcode
│   ├── CLI/                      # CLI-Erkennung, Dispatch und Befehle
│   ├── Models/                   # Geteilte Zustands- und Datenmodelle
│   ├── Services/
│   │   ├── Dictation/            # Aufnahme, Kontext, STT und Nachbearbeitung
│   │   ├── AgentChats/           # Sessions, Agent-Jobs und Laufzeitbeobachtung
│   │   └── Shared/               # Prozess-, Berechtigungs- und Systemdienste
│   ├── Views/                    # SwiftUI-Oberflächen
│   └── Windows/                  # Fenster- und Overlay-Controller
├── Tests/WhisperM8Tests/         # Unit- und Integrationstests
├── scripts/                      # Installation, Bereinigung und Packaging
├── docs/                         # Dokumentationslandkarte und Detaildokumente
├── Makefile                      # Betriebliche Build- und Installationsbefehle
└── Package.swift                 # SwiftPM-Paketdefinition
```

---

## For Developers

### Important Code Locations

| Path | Role |
|---|---|
| `WhisperM8/CLI/CLIEntryPoint.swift` | Gemeinsamer Prozesseinstieg, der zwischen GUI- und CLI-Ausführung entscheidet. |
| `WhisperM8/Models/AppState.swift` | Beobachtbarer App-Zustand und schmale Fassade zum Diktat-Koordinator. |
| `WhisperM8/Services/Dictation/RecordingCoordinator.swift` | Orchestriert den Lebenszyklus einer Aufnahme; thematische Erweiterungen kapseln Kontext, Transkription, Ausgabe, Fehler und UI. |
| `WhisperM8/Services/Dictation/PasteService.swift` | Aktiviert die vorherige Ziel-App und führt die Auto-Paste-Sequenz aus. |
| `WhisperM8/Services/Shared/PermissionService.swift` | Bündelt Status, Anforderung und Systemeinstellungen für Mikrofon, Bedienungshilfen und Bildschirmaufnahme. |
| `WhisperM8/Windows/RecordingPanel.swift` | Steuert das schwebende Aufnahme-Overlay und merkt die zuvor aktive Anwendung. |

---

## License

MIT License — see [LICENSE](../LICENSE) for details.

Built by [360° Web Manager](https://360web-manager.com/)
