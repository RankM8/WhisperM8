---
status: aktiv
updated: 2026-07-09
description: High-Level-Architektur und Querschnitts-Infrastruktur von WhisperM8 als Einstieg für Entwickler.
---

# WhisperM8 – Architekturüberblick

WhisperM8 ist eine native macOS-App in Swift 5.9 und SwiftUI für macOS 14+. Das SwiftPM-Paket erzeugt ein gemeinsames Executable, das entweder die GUI oder die CLI startet. Fachlich bilden die Hotkey-gesteuerte Diktat-Pipeline und der Session-Manager für Claude Code und Codex CLI die zwei Kernbereiche; CLI und Settings ergänzen sie als Automatisierungs- und Konfigurationsflächen. Der Feature-Index führt diese vier Bereiche gemeinsam als Dokumentationssäulen.

Diese Datei ist die Einstiegskarte. Sie beschreibt die App-Shell, Modulgrenzen, Querschnitts-Infrastruktur und Persistenzorte; die fachlichen Details der Kernbereiche und ihrer Zugangsflächen stehen unter [`features/`](features/README.md).

## Big Picture

```text
                         gemeinsames WhisperM8-Executable
                                      │
                         CLIEntryPoint / CLIModeDetector
                              ┌───────┴────────┐
                              │                │
                         GUI-Modus         CLI-Modus
                              │                │
                    WhisperM8App-Szenen        ├─ transcribe
                              │                ├─ modes
                              │                ├─ agent
                 ┌────────────┼────────────┐   └─ agent-supervise (intern)
                 │            │            │
             Dictation    Agent Chats   Settings
                 │            │            │
        AppState /        Session-,      AppPreferences,
        Recording-        Fenster- und   Keychain,
        Coordinator       Runtime-Stores Berechtigungen
                 │            │            │
                 └────────────┴────────────┘
                              │
             Shared Infrastructure + Application Support
```

### Kernbereich Dictation

Der globale Hotkey ruft `AppState` auf, das den Aufnahme-Lifecycle an den `RecordingCoordinator` delegiert. Die Pipeline verbindet Audioaufnahme, optionale Text-/Bild-/Chat-Kontexte, OpenAI- oder Groq-Transkription und optionale Codex-Nachbearbeitung. `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift` kopiert das Ergebnis immer ins Clipboard und führt bei aktivierter Option zusätzlich Auto-Paste aus; eine Auslieferung an Agent Chats existiert nicht mehr. Beim Task-Modus ergänzt ein Matching zur zuletzt indizierten Codex-Session lediglich Metadaten im Run-Report. `WhisperM8/Models/OutputMode.swift` hält die frühere Chat-ID nur noch für die Migration persistierter Einstellungen vor. Der technische Einstieg liegt in [`features/dictation/`](features/dictation/).

### Kernbereich Agent Chats

Agent Chats verwaltet lokale Projektionen von Claude- und Codex-Sessions, interaktive PTY-Terminals, Fenster und Tabs, Laufzeitstatus, Claude-Background-Agents sowie WhisperM8-eigene Codex-Subagent-Jobs. Externe Sessiondateien werden entdeckt und gelesen; WhisperM8-eigener Workspace-, UI- und Job-Zustand liegt separat unter Application Support. Der technische Einstieg liegt in [`features/agent-chats/`](features/agent-chats/).

### CLI und Settings

`WhisperM8/CLI/CLIEntryPoint.swift` trägt den eigentlichen `@main`-Entry-Point und multiplext dasselbe Binary zwischen GUI und CLI. Die CLI nutzt dadurch dieselben Services, Output-Modes, Job-Dateien und denselben Keychain-Service wie die App; ihre Befehle sind in [`features/cli/`](features/cli/) dokumentiert.

`WhisperM8/Views/SettingsView.swift` ist der Router des Settings-Fensters. Die Seiten konfigurieren Dictation, Agent Chats, CLI/Skills, Nutzungsprofil, Theme, Berechtigungen und den lokalen Output-Workspace; Aufbau und Routen stehen in [`features/settings/`](features/settings/).

## Modulkarte

| Modul | Verantwortung |
|---|---|
| `WhisperM8/Models/` | Gemeinsame Domänen- und Zustandsmodelle für Diktat, Output, Transkript-Reports und Agent Chats. `AppState.swift` bildet den zentralen beobachtbaren GUI-Zustand der Diktat-Pipeline. |
| `WhisperM8/Views/` | SwiftUI-Komposition für Menüleiste, Onboarding, Recording-Overlay und Agent Chats einschließlich Sidebar, Tabs, Terminal und Detailflächen. Große Agent-Chats-Belange sind als thematische `AgentChatsView+<Thema>.swift`-Extensions getrennt. |
| `WhisperM8/Views/Settings/` | Settings-Seiten, wiederverwendbares Settings-Kit und testbare Seitenmodelle. `Pages/`, `Kit/` und `Models/` trennen Komposition, UI-Bausteine und Zustandslogik. |
| `WhisperM8/Views/Transcript/` | Darstellung und Parsing vereinheitlichter Agent-Transkripte, Timelines, Runden und Session-Zusammenfassungen. Die Dateien konsumieren Transkriptmodelle, besitzen aber nicht deren externe Persistenz. |
| `WhisperM8/Windows/` | AppKit-Brücken für Fensterverhalten, das SwiftUI allein nicht abbildet. Dazu gehören das nicht aktivierende Recording-Panel und dessen Bildschirm-/Frame-Auflösung. |
| `WhisperM8/Services/Dictation/` | Aufnahme, Kontext-Capture, Speech-to-Text, Codex-Nachbearbeitung, Output-Modes, Reports, Clipboard und Fehler-Retention. `RecordingCoordinator` und seine Extension-Dateien orchestrieren den Lifecycle. |
| `WhisperM8/Services/AgentChats/` | Workspace- und Session-Persistenz, externe Discovery, Runtime-Status, Hook-Bridge, PTY-/Command-Verträge, Background-Agents, Subagent-Jobs und Transkriptleser. Dauerhafter Workspace-Zustand und ephemerer Laufzeitstatus bleiben getrennt. |
| `WhisperM8/Services/Shared/` | Infrastruktur, die mehrere Säulen oder die App-Shell verwenden: Subprozess-Environment, Berechtigungen, Keychain, Logging/Signposts, Datei-Events, Fenster-Routing, Updates, CLI-Installation, Modellkatalog und Systemintegrationen. |
| `WhisperM8/CLI/` | Argument-Parsing, Dispatch und Ausführung der Befehle `transcribe`, `agent` und `agent-supervise`. Die CLI ist ein Adapter auf bestehende Dictation- und Agent-Chats-Services, kein separates Produkt-Binary. |
| `WhisperM8/Support/` | Leichte, app-weite Supporttypen: `AppPreferences`, Theme-Tokens, Appearance-Override und Textnormalisierung. Hier liegen keine Feature-Orchestratoren. |

SwiftPM entdeckt Swift-Quellen rekursiv. Die Ordner sind deshalb Architekturgrenzen für Verantwortlichkeit und Navigation, keine separaten Swift-Module.

## Querschnitts-Infrastruktur

### Subprozess-Environment: `LoginShellEnvironment`

`WhisperM8/Services/Shared/LoginShellEnvironment.swift` behebt einen zentralen macOS-Gotcha: Über `launchd` gestartete GUI-Apps erben nur einen minimalen `PATH`; ein direkt gestarteter `Process` findet dann häufig Homebrew, `claude`, `codex`, `git`, `npm`, `mise` oder andere Shell-Shims nicht.

Beim ersten Bedarf fragt der Service lazy `/bin/zsh -l -c 'echo $PATH'` ab, cached das veröffentlichte Ergebnis und ergänzt fehlende Standardpfade einschließlich `~/.local/bin`, Apple-Silicon- und Intel-Homebrew. Der Cache-Zugriff ist geschützt, die Auflösung nach einem Cache-Miss aber nicht: Parallele erste Zugriffe können `pathLoader` daher mehrfach ausführen, bevor einer der Werte gespeichert ist. Schlägt die Login-Shell fehl, greift ein konservativer Fallback-PATH. `processEnvironment()` ergänzt außerdem Terminal- und Locale-Variablen und entfernt geerbte `CLAUDE_CODE_*`-/`CLAUDECODE`-Variablen. Dass Claude Code einen so gestarteten Prozess als eigenständige Top-Level-Session behandelt, ist Verhalten des externen Tools; WhisperM8 stellt dafür die bereinigte Umgebung bereit.

Für PATH-abhängige, vom Nutzer installierte Tools wie `claude`, `codex` oder `ffmpeg` verwenden die zentralen Startpfade `LoginShellEnvironment.shared.processEnvironment()` beziehungsweise `terminalEnvironmentArray()` und eine Toolauflösung wie `AgentCommandBuilder.commandPath(_:)`. Das ist im Ist-Zustand kein universeller Vertrag für jeden `Process`: `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift` startet `/usr/bin/git` über einen absoluten Systempfad ohne eigene Prozessumgebung, und `WhisperM8/Services/Shared/PhpStormLauncher.swift` startet das aufgelöste Binary aus dem App-Bundle ebenfalls direkt. Diese Pfade sind nicht von der Login-Shell-Auflösung abhängig.

### Systemberechtigungen: `PermissionService`

`WhisperM8/Services/Shared/PermissionService.swift` kapselt die drei relevanten TCC-Bereiche: Mikrofon über AVFoundation, Accessibility über `AXIsProcessTrusted` und Screen Recording über CoreGraphics. Der Service bietet Statusabfragen, System-Prompts und Deep-Links in die jeweiligen macOS-Datenschutzseiten; die fachlichen Aufrufer bleiben in Onboarding, Settings und Dictation.

Mikrofon und Accessibility bilden das Gate für das automatische Onboarding. Screen Recording ist optional und wird nur für visuellen Kontext benötigt. TCC-Zustand wird vom Betriebssystem verwaltet und nicht in WhisperM8-Dateien gespiegelt.

### Secrets: `KeychainManager`

`WhisperM8/Services/Shared/KeychainManager.swift` speichert API-Schlüssel als Generic Passwords im macOS Keychain-Service `com.whisperm8.app`. Lesen wird pro Prozess gecached; Speichern aktualisiert oder erzeugt den Account-Eintrag, Löschen räumt zusätzlich mögliche Legacy-Werte aus `UserDefaults` auf.

Beim ersten Lesen migriert der Manager einen noch vorhandenen Klartext-Legacywert aus `UserDefaults` in den Keychain und entfernt anschließend den alten Wert. GUI und CLI teilen den Zugriff, weil `~/.local/bin/whisperm8` auf dasselbe App-Executable zeigt.

### Performance: `PerfSignposts`, `PerformanceBudget` und `PerfBudgets`

`WhisperM8/Services/Shared/PerformanceSignposts.swift` instrumentiert die heißen Pfade mit `OSSignposter`. `PerformanceBudget` umschließt synchrone oder asynchrone Arbeit strukturiert und schreibt bei Überschreitung eine `perf_budget_exceeded`-Warnung über `os.Logger`; der Warnpfad verwendet bewusst kein optionales Datei-Logging.

| Kategorie | Budgetpunkte |
|---|---|
| `perf.recording` | Start 400 ms, Stop 300 ms, Context Capture 150 ms, Chat Tail 100 ms, Engine Start 250 ms |
| `perf.store` | Mutation 30 ms, Load 15 ms, Save 20 ms, UI-State-Save 10 ms |
| `perf.sidebar` | Workspace Load 50 ms, Background Index 2 s, Status Poll 100 ms |

Die Werte sind operative Startbudgets, keine fachlichen Timeouts. Sie werden in Instruments über `os_signpost` und im Unified Log über das Subsystem `com.whisperm8.app` ausgewertet.

### Datei-Ereignisse: `FileEventSource`

`WhisperM8/Services/Shared/FileEventSource.swift` ist ein wiederverwendbarer, `@MainActor`-gebundener Wrapper um `DispatchSourceFileSystemObject` für genau eine Datei. Er meldet Writes/Extends über `onChange`; bei Delete/Rename baut er Watcher und File Descriptor ab und überlässt dem Aufrufer über `onFileGone` das erneute Aufsetzen.

Der Service ist die schlanke vnode-Schicht für event-getriebenes Transcript-Watching. Verzeichnisweite Discovery bleibt bei den FSEvents-basierten Agent-Chats-Diensten; fachliche Interpretation und Debouncing bleiben bei deren Konsumenten.

### Fenster-Routing: `WindowRequestCenter`

`WhisperM8/Services/Shared/WindowRequestCenter.swift` entkoppelt Menüleiste, Notifications und App-Lifecycle vom SwiftUI-Environment `openWindow`. Der Singleton publiziert Wünsche für Settings, Output, Onboarding und das Agent-Chats-Primärfenster; `WindowRequestHandler` übersetzt sie innerhalb der View-Hierarchie in SwiftUI-Fensteraktionen und aktiviert anschließend die App.

Session-Fokuswünsche lösen zuerst Ziel-Fenster, Tab und Sidebar-Reveal über den `AgentWindowStore` auf und öffnen dann das Primär- oder Sekundärfenster. Eine Distributed Notification verbindet den Single-Instance-Check mit der bereits laufenden Instanz. `allowsAgentChatsPrimaryWindow` ist zugleich das Laufzeit-Gate für Menüleistenprofile.

### CLI-Verfügbarkeit und Skill-Export

`WhisperM8/Services/Shared/CLISymlinkInstaller.swift` installiert idempotent `~/.local/bin/whisperm8` als Symlink auf das laufende App-Executable. Ein falscher Symlink wird ersetzt, eine reguläre Datei am Ziel bleibt unangetastet. `CLIInstallStatus` in `WhisperM8/Services/Shared/CLISkillExporter.swift` liefert die lesende Statusprojektion für Settings.

`CLISkillExporter` liest die gebündelten Skills und Referenzen und kann sie explizit nach `~/.claude/skills/<name>/` installieren. Verwaltete Dateien werden aktualisiert, fremde Dateien im Zielordner bleiben bestehen; für andere Tools stellt der Exporter den Markdown-Inhalt zum Kopieren oder Speichern bereit.

### Theme und Appearance

`WhisperM8/Support/AppTheme.swift` definiert die dynamischen Light-/Dark-Farb-Tokens für Agent Chats und Settings; der Alias `AgentTheme` hält bestehende Aufrufer kompatibel. Die Tokens lösen sich aus der effektiven `NSAppearance` der View-Hierarchie auf.

`WhisperM8/Support/AppearanceOverride.swift` modelliert `system`, `light` und `dark` und übersetzt die Wahl sowohl in SwiftUIs `preferredColorScheme` als auch in eine optionale AppKit-`NSAppearance`. `WhisperM8/Support/ThemeManager.swift` ist die beobachtbare Single Source of Truth: Er persistiert den Override über `AppPreferences`, verfolgt Systemwechsel, aktualisiert AppKit-Flächen und benachrichtigt nicht rein SwiftUI-basierte Terminalansichten.

Der Manager synchronisiert außerdem über `ClaudeThemeWriter` den Theme-Key in `~/.claude/settings.json`; vor der ersten Mutation wird ein Backup unter Application Support angelegt. Das ist neben einem expliziten Skill-Export eine klar begrenzte Ausnahme von der sonst lesenden Behandlung externer Claude-Daten.

### Nutzungsprofil: `AppProfileActivator`

`WhisperM8/Models/AppUsageProfile.swift` beschreibt die Profile Dictation only, Dictation + AI enrichment und Full. Sie steuern, ob Codex-Nachbearbeitung und Agent Chats angeboten werden und ob die App als Dock-App (`regular`) oder reine Menüleisten-App (`accessory`) läuft.

`WhisperM8/Services/Shared/AppProfileActivator.swift` persistiert einen Profilwechsel, setzt die Activation Policy und gibt das Agent-Chats-Primärfenster frei oder sperrt dessen automatisches Öffnen. Das tatsächliche Öffnen bleibt beim SwiftUI-Aufrufer; die separate Schließoperation entfernt beim Wechsel in ein Menüleistenprofil Primär- und Sekundärfenster, erhält aber den persistierten Tab-/Fensterzustand für einen späteren Rückwechsel.

### App-Shell und SwiftUI-Szenen

`WhisperM8/WhisperM8App.swift` definiert die GUI-Shell. Die Reihenfolge und Art der Szenen ist Teil des Fenstervertrags:

- `Window("Agent Chats", id: "agent-chats")` ist die erste Scene und das nicht duplizierbare Primärfenster.
- `WindowGroup(..., for: UUID.self)` erzeugt ausschließlich abgelöste Agent-Chat-Sekundärfenster.
- `MenuBarExtra` hält Recording und Schnellaktionen auch ohne sichtbares Fenster verfügbar.
- `Window("WhisperM8", id: "settings")` ist das manuell geöffnete Settings-/Control-Center.
- `Window("WhisperM8 Setup", id: "onboarding")` führt durch essenzielle Berechtigungen und Profilwahl.

Das Recording-Overlay ist keine SwiftUI-Scene, sondern ein nicht aktivierendes `NSPanel` aus `WhisperM8/Windows/RecordingPanel.swift`. `AppDelegate` setzt die Activation Policy früh, startet Update-, Scan-, Watcher-, Job-Sync- und Retention-Dienste, routet Onboarding und Notifications und hält die App nach dem Schließen des letzten Fensters am Leben.

### Zentraler GUI-Zustand: `AppState`

`WhisperM8/Models/AppState.swift` ist ein `@MainActor`-gebundenes `@Observable`-Singleton. Es hält den sichtbaren Diktat-Zustand – Recording-Phase, Audio-Level, Dauer, Fehler, Roh-/Finaltranskript, Output-Modus, Kontext und Run-Report – und wird in Menüleiste, Settings, Onboarding und Recording-UI injiziert.

`AppState` führt die Pipeline nicht selbst aus: Start, Stop, Cancel und Kontextmutationen delegieren an `RecordingCoordinator`. Als schmale Brücke zu Agent Chats hält es den aktiven Chat-Kontext und bietet eine globale Aktion zum Stoppen aller Vordergrund-PTYs; die eigentlichen Agent-Session-, Workspace-, Fenster- und Runtime-Stores bleiben eigenständige Zustandsquellen.

### Weitere Shared-Dienste

Die übrigen Dateien in `WhisperM8/Services/Shared/` ergänzen diese Infrastruktur: `Logger.swift` bündelt Unified-Log-Kategorien und optionales Debug-Datei-Logging, `AppUpdateChecker.swift` und `SemanticVersion.swift` prüfen GitHub-Releases ohne Self-Update, `CodexModelCatalog.swift` liest den externen Codex-Modellcache mit eingebettetem Fallback, `PhpStormLauncher.swift` und `SystemSoundCatalog.swift` kapseln macOS-/Tool-Integrationen.

## Persistenz-Landkarte

### Application Support: WhisperM8-eigene Daten

Der kanonische Root ist `~/Library/Application Support/WhisperM8/`. Die wichtigsten Besitzer sind:

| Pfad relativ zum Root | Besitzer und Rolle |
|---|---|
| `AgentSessions.json` | `AgentWorkspaceRepository`: dauerhafter Projekt- und Session-Workspace. |
| `agent-ui-state.json` | `AgentSessionStore` / `AgentWindowStore`: Fenster, Tabs, Auswahl, Pinning und Sidebar-Zustand als separates UI-Sidecar. |
| `agent-session-index-cache.json` | `AgentSessionIndexCacheStore` (in `AgentSessionIndexer.swift`): Cache für die inkrementelle Discovery externer Sessiondateien. |
| `agent-jobs/<short-id>/` | `AgentJobStore`: Zustand, Events, Prompts, Logs und Reports der WhisperM8-eigenen Codex-Subagent-Jobs. |
| `OutputModes.json` | `OutputModeStore`: benutzerdefinierte und angepasste Output-Modi. |
| `PostProcessingTemplates.json` | `PostProcessingTemplateStore`: benutzerdefinierte Nachbearbeitungs-Templates. |
| `Reports/` | `TranscriptRunReportStore`: Run-Reports, Index und erhaltene Anhänge/Outputs. |
| `FailedRecordings/` | `FailedRecordingsStore`: begrenzt aufbewahrte Audiodateien und Fehler-Sidecars für Retry. |
| `claude-hooks/`, `claude-session-events/` | `ClaudeHookPaths`: pro lokaler Session erzeugte Hook-Konfiguration und Event-Stream. |
| `Backups/claude-settings-pre-theme-sync.json` | `ClaudeThemeWriter`: einmaliges Backup vor der ersten Theme-Synchronisation. |

Temporäre Arbeitsdaten haben keine einheitliche Retention. Die erfolgreiche Diktat-Auslieferung entfernt ihre Audiodatei explizit. Capture-Dateien unter dem temporären `WhisperM8Context/` entfernt `VisualContextCaptureService.cleanup(_:)` dagegen nur, wenn `deleteContextFilesAfterProcessing` aktiviert ist; der Default ist `false`. Für die von `VisualAttachmentDeliveryBuilder` erzeugten Run-Verzeichnisse unter dem temporären `WhisperM8Delivery/` enthält der aktuelle Code keinen Cleanup-Pfad. Eine eventuelle spätere Bereinigung des System-Temp-Verzeichnisses liegt außerhalb von WhisperM8 und ist Betriebssystemverhalten. Optionales Debug-Datei-Logging schreibt nach `~/Library/Logs/WhisperM8/WhisperM8-debug.log`.

### UserDefaults und `AppPreferences`

`WhisperM8/Support/AppPreferences.swift` ist die typisierte Fassade über `UserDefaults.standard`; SwiftUI-Seiten binden dieselben Schlüssel teilweise direkt über `@AppStorage`. Dort liegen kleine, nicht geheime Einstellungen wie Provider-/Modellwahl, Sprache, Recording- und Kontextoptionen, Output-Defaults, Agent-UI-Präferenzen, Feature-Kill-Switches, Theme und Nutzungsprofil.

Große oder strukturelle Zustände – Agent-Workspace, Fenster/Tabs, Jobs, Output-Modi, Templates und Reports – gehören nicht in `UserDefaults`. Geheimnisse gehören ausschließlich in den Keychain. Die externe `Defaults`-Bibliothek ist für diese Persistenzschicht im aktuellen Codepfad nicht die Zustandsquelle.

### Keychain

API-Schlüssel liegen als Generic Passwords unter dem Service `com.whisperm8.app`. `KeychainManager` ist der gemeinsame Zugang für GUI und CLI und enthält nur eine leseseitige Migration aus historischen `UserDefaults`-Einträgen; Klartextschlüssel werden nicht dauerhaft in Application Support geschrieben.

### Externe Tool-Bereiche

`~/.claude/` und `~/.codex/` gehören den jeweiligen CLIs. Session-Discovery, Transcript-Reader, Background-Status und `CodexModelCatalogStore` behandeln insbesondere `~/.claude/projects/`, `~/.claude/jobs/`, `~/.codex/sessions/` und `~/.codex/models_cache.json` als externe, read-only Quellen; WhisperM8s eigene Workspace-Wahrheit bleibt unter Application Support.

Begrenzte, explizite Integrationsschreibvorgänge sind `CLISkillExporter` nach `~/.claude/skills/` und `ClaudeThemeWriter` auf den Theme-Key in `~/.claude/settings.json`. Globale Claude-Hooks oder Codex-Sessiondateien werden nicht von WhisperM8 mutiert; die eigene Hook-Konfiguration liegt unter Application Support und wird nur beim Prozessstart per Argument injiziert.

Außerhalb davon installiert `CLISymlinkInstaller` den Link `~/.local/bin/whisperm8` auf das App-Executable.

## Vertiefende Dokumentation

- [`features/README.md`](features/README.md) ist der Index der vier Dokumentationssäulen.
- [`features/dictation/`](features/dictation/) führt in Recording, Transcription, AI Output und Visual Context.
- [`features/agent-chats/`](features/agent-chats/) führt in UI, Sessions, Subagents, Background-Agents und Codex Exec.
- [`features/cli/`](features/cli/) dokumentiert Binary-Dispatch, Befehle, Symlink und Skill-Export.
- [`features/settings/`](features/settings/) dokumentiert Settings-Routing, Seiten, Kit und ViewModels.
- [`refactor/REFACTORING-AUDIT.md`](refactor/REFACTORING-AUDIT.md) beschreibt Wartbarkeitsbefunde, bereits umgesetzte Zerlegungen und verbleibende Refactoring-Kontexte.
- [`adr/`](adr/) enthält Architekturentscheidungen; aktuell hält ADR 0001 den Verbleib beim nativen Swift-/SwiftUI-Stack fest.
- [`../CLAUDE.md`](../CLAUDE.md) ist die kompakte Arbeits- und Build-Referenz für Repository-Agenten und dient nicht als Ersatz für die Feature-Dokumentation.

## Keywords

WhisperM8, Architektur, High-Level-Architektur, Big Picture, Dictation, Diktat,
Agent Chats, Claude Code, Codex CLI, SwiftUI, macOS, SwiftPM, App-Shell,
`WhisperM8App`, `CLIEntryPoint`, `AppState`, `RecordingCoordinator`,
`LoginShellEnvironment`, Subprozess-PATH, launchd, `PermissionService`, TCC,
Mikrofon, Accessibility, Screen Recording, `KeychainManager`, Keychain,
`PerfSignposts`, `PerformanceBudget`, `PerfBudgets`, os_signpost,
`FileEventSource`, vnode, FSEvents, `WindowRequestCenter`, Multiwindow,
`CLISymlinkInstaller`, `CLISkillExporter`, `ThemeManager`, `AppTheme`,
`AppearanceOverride`, `AppProfileActivator`, `AppUsageProfile`, Dock-App,
Menüleisten-App, Application Support, UserDefaults, AppPreferences, @AppStorage,
AgentSessions.json, agent-ui-state.json, agent-jobs, OutputModes.json, Reports,
externe Sessiondateien, read-only, ~/.claude, ~/.codex.
