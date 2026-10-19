# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
Sie enthält nur Arbeitsregeln und Invarianten. Mechanik, Messwerte und Vorgeschichte stehen in der
Feature-Doku (Verweise unten) — dort nachlesen, bevor ein Subsystem geändert wird.

## Project Overview

WhisperM8 is a native macOS app (Swift 5.9, SwiftUI, macOS 14+, pure SwiftPM — no .xcodeproj) with two halves:

1. **Dictation** — hotkey-driven speech-to-text via OpenAI Whisper or Groq, with optional Codex-CLI post-processing and configurable output modes (rewrite, email, Slack, …).
2. **Agent Chats** — a session manager for Claude Code and Codex CLI: foreground PTY terminals, background agents (`claude --bg`), project organization, live status tracking, and transcript browsing.

Endnutzer installieren und aktualisieren nur per `brew install --cask rankm8/tap/whisperm8`.
Code comments are largely written in German — match that style when editing existing files.

## Build und Test

```bash
make dev          # inkrementeller Release-Build (.build-dev), Sync nach /Applications, Start
make dev-release  # voller Release-Build (WMO) wie ausgeliefert — für Performance-Messungen
make run          # Debug-Build aus dem Projektordner (eigener TCC-Eintrag)
make build        # nur Release-Build
make snapshots [ONLY=<name>]   # UI-Fixtures hell+dunkel als PNG, ohne App-Start
make skills       # Agent-Skills ins Plugin synchronisieren, ohne Build/Neustart
make clean-install             # löscht ALLE App-Daten + Neuinstallation (nur Onboarding/Migration testen)
```

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Pflicht für swift build/test (SwiftUI-Makros)
swift test                                    # volle Suite
swift test --filter AgentSessionStoreTests    # eine Klasse
```

Details zu `make dev` (kein WMO, `-incremental`, kein Debug+O wegen SwiftTerm-`abort()`, rsync statt Neukopie
wegen TCC, Signier-Zertifikat): [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

**WICHTIG — wenn du als Agent-Chat IN der WhisperM8-App läufst** (der übliche Fall): führe NIEMALS `make dev`,
`make kill`, `make run`, `make install` oder `make clean-install` aus und nie `swift run` ohne Argument. Diese
Ziele beenden die laufende App — und damit deine eigene Session samt aller anderen Chats. Baue und teste nur mit
`swift build` / `swift test`; den Neustart macht der User. Aus einem Chat (`WHISPERM8_SESSION_ID` gesetzt)
brechen `dev`, `dev-release`, `install`, `run` und `clean-install` ab; `FORCE=1` lässt `dev` nach dem Build abgekoppelt weiterlaufen.

- **Tests:** DI über einfache Closures und kleine Protokolle (`commandResolver: { _ in "/path" }`,
  `ProcessRunner`-Spies) — kein DI-Framework. Gemeinsame Helfer in `AgentTestSupport.swift`.
- **UI ansehen:** `make snapshots` (sicher aus einem Chat); an der laufenden App `whisperm8 debug …` hinter
  `debugControlEnabled`; isolierte Test-Instanz `scripts/test-instance.sh`. Ansichten mit Keychain-/Proxy-/
  Datei-Zugriff bekommen für Snapshots eine Abhängigkeits-Struktur mit `.live`-Default. Nach UI-Änderungen an
  einer Ansicht mit Fixture: rendern und ansehen. Doku:
  [docs/features/ui-testing.md](docs/features/ui-testing.md).
- **Guards, die die Suite erzwingt:** `SourceSizeGuardTests` (max. 1.500 Zeilen je Datei, Ausnahmeliste nur
  schrumpfend — aufteilen statt Grenze anheben), `LocalizationCatalogTests`, `DocsLintTests`,
  `InfoPlistContractTests`, `AgentStatusPulseGuardTests`.

## Lokalisierung (E1)

Englisch ist Basis, Deutsch wird vollständig übersetzt: neue UI-Texte englisch schreiben und die deutsche
Übersetzung in `WhisperM8/Localization/Localizable.xcstrings` eintragen. `Text("…")` mit Literal wird automatisch
Schlüssel; für String-Parameter (`.help`, NSAlert, Rückgabewerte) `String(localized:)`. Keine Ternär-Literale in
`Text(cond ? "a" : "b")`. Fachnamen und CLI-Befehle bleiben unübersetzt. Regeln: [docs/features/lokalisierung.md](docs/features/lokalisierung.md).

## Debugging und Performance

```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```

- Hot-Paths haben `os_signpost`-Intervalle mit Budgets (`PerfBudgets`); Überschreitungen loggen
  `perf_budget_exceeded`, ein hängender Main Thread `main_thread_blocked_ongoing`.
- **Nie pro Byte/Zeichen/Zeile messen** — dort `PerformanceCounters`. Neue Signposts an häufigen Stellen nur
  in der Stufe `.detail`.
- Alles, was App oder Build langsam macht, mit Kosten melden. Messläufe gegen Budgets mit `make dev-release`.
- Doku: [docs/features/performance-messung.md](docs/features/performance-messung.md).

## Architektur

`Services/` ist geteilt in `Dictation/`, `AgentChats/`, `Shared/`, `VoiceGate/` (SwiftPM findet rekursiv).
Große Views/Services wachsen über thematische `extension`-Dateien (`AgentChatsView+…`,
`RecordingCoordinator+…`); verschobene Logik ist `internal`. Roadmap: `docs/refactor/REFACTORING-AUDIT.md`.

**App-Hülle:** Dock-App plus `MenuBarExtra`; Szenen in `WhisperM8App.swift`; das letzte Fenster zu schließen
beendet die App nicht; `WindowRequestCenter` routet Fenster-Anfragen. Absturzschutz, SIGPIPE, ObjC-Exceptions,
Cmd+Q-Dialog und Wiederaufnahme nach Absturz: [docs/features/app-shell/ARCHITECTURE.md](docs/features/app-shell/ARCHITECTURE.md).

**Diktat:** Hotkey → `AppState`/`RecordingCoordinator` → `AudioRecorder` (M4A 16 kHz mono) → Kontext
(`SelectedContextService`, Screenshots, Chat-Tail) → `TranscriptionService` (OpenAI/Groq/ChatGPT-Abo) →
optional `PostProcessingService` (Codex mit `OutputMode`) → Zwischenablage/Auto-Paste oder Agent Chat.
Doku: [docs/features/dictation/](docs/features/dictation/).

**Agent Chats:** Discovery (`AgentScanCoordinator` → `AgentSessionIndexer`) → Persistenz
(`AgentWorkspaceStore` hinter `AgentSessionStore`, UI über `AgentWorkspaceUIModel`) → Laufzeitstatus
(Claudes Registry, Hook-Bridge, `AgentSessionRuntimeWatcher`) → UI (SwiftTerm-PTYs, Tabs, Grid, Verlauf).
Doku-Einstieg: [docs/features/agent-chats/](docs/features/agent-chats/README.md); Konten:
[claude-konten.md](docs/features/agent-chats/claude-konten.md), [gpt-konten.md](docs/features/agent-chats/gpt-konten.md);
CLI: [agent-chats-cli.md](docs/features/agent-chats-cli.md); Board/Plugin: [jarvis-board.md](docs/features/jarvis-board.md);
Ansagen: [speech-callouts.md](docs/features/speech-callouts.md); Voice Gate: [voice-gate.md](docs/features/voice-gate.md).

## Invarianten (nicht brechen)

**Prozesse und Umgebung**
- GUI-Apps haben einen minimalen `PATH`. Subprozesse nie mit dem rohen `ProcessInfo`-Environment starten,
  immer `LoginShellEnvironment.shared.processEnvironment()` + `AgentCommandBuilder.commandPath(_:)`.
- `LoginShellEnvironment` strippt geerbte `CLAUDE_CONFIG_DIR`, `ANTHROPIC_CUSTOM_HEADERS`, `CCP_CONFIG_DIR`.
- Neue Dateideskriptoren (Locks, Sockets, Watcher) close-on-exec — SwiftTerm `forkpty`+`execve` schließt nichts.
- An Pipes nur `write(contentsOf:)` (throwing), nie `FileHandle.write(_:)` (NSException bei EPIPE). SIGPIPE
  wird per leerem `sigaction`-Handler abgefangen, nie per `SIG_IGN` (würde an jede Chat-Shell vererbt).
- Kein `installTap` ohne `ObjCException.catching`; das Format unmittelbar vor dem Tap neu lesen.
  Absturzrelevante Ereignisse auf `Logger.info` oder höher (`.info` ist per `OSLogPreferences` persistent).

**Workspace und Daten**
- Mutations-Closures des `AgentWorkspaceStore` laufen unter dem prozessweiten Lock: keine Subprozesse, kein
  blockierendes I/O (Git-Lookups vorher). UI nie über `loadWorkspace()` „auffrischen“.
- Die App ist einziger Schreiber von Workspace und Board; die CLI liest von Disk und handelt über den Socket.
- Fremde Daten unter `~/.claude*` und `~/.codex/` sind extern und werden nur gelesen — **Ausnahmen, alle
  absichtlich und dokumentiert:** WhisperM8s eigene Hook-Settings-Dateien (`claude-hooks/<id>.json`);
  `claude mcp add-json` beim MCP-Angleich (schreibt die CLI selbst); „Zum Hauptkonto machen“ (Keychain,
  `oauthAccount` in `~/.claude.json`, Mischen von `projects/` und `file-history/`); die einmalige
  Memory-Migration (kopiert nach main, mit Backup); das Wegsichern loser Skill-Kopien nach
  `~/.claude/skills/.whisperm8-backup/`; Subagent-Retention verschiebt Rollouts aus `~/.codex/sessions` ins Archiv.
- Logins werden zwischen Konten **verschoben, nie kopiert** (gleiche Refresh-Familie entwertet sich sonst).
- Eigene Daten: `~/Library/Application Support/WhisperM8/` (`AgentSessions.json` = Workspace, `agent-ui-state.json`,
  `agent-index-cache.json`, `jarvis-board.json`, `running-sessions.json`, Reports, FailedRecordings).
- Neue Bundle-Ressourcen brauchen `Package.swift` UND den Makefile-Schritt `_bundle`.

**Agent Chats**
- Status für Claude-Chats kommt aus Claudes Registry (`<config-dir>/sessions/<pid>.json`); Hooks binden nur die
  Session-ID und tragen den Send-Guard. Ein `SessionStart` übernimmt die externe ID nicht ungeprüft
  (`externalIDBindingDecision`).
- WhisperM8 hostet die echte Claude-/Codex-CLI im PTY — keine Eigen-UI oder SDK-Runtime als Ersatz.
- Welches Modell ein Claude-Chat nutzt, entscheidet Claude Code; `--model` nur beim ausdrücklichen „Neuer GPT-Chat“.
- GPT-Chats nennen ihr Konto immer per `X-WhisperM8-GPT-Profile`, auch `main`. Angeboten werden nur Modelle,
  die Codex-Katalog und laufender Proxy beide kennen.
- Das Plugin wird nie in den laufenden Ordner kopiert, nur per Symlink-Tausch (`rename(2)`) umgestellt — sonst
  laden alle Sessions mitten im Turn neu. In `register.tsx` keine Abschnitte in eigene Dateien auslagern.
- Board-Felder nur ergänzen, nie umbenennen (`work` und `next` werden gleich geschrieben).
- Tab-Logik (Auswahl, Reorder, Switcher-Umfang) bleibt pur und getestet; Drag/Drop/Menüs sind manuelle QA.
- Status-Punkte in Sidebar, Tab und Kopf folgen derselben Logik (`AgentStatusIndicator`); Grün heißt nur „arbeitet“.

**UI-Performance**
- Kein I/O, kein Session-Scan und kein `.contextMenu` in Bodies, die bei Statusänderungen neu ausgewertet werden;
  die Sidebar beobachtet den `AgentSessionActivityStore` nie.
- Keine Dauerbewegung in SwiftUI (`repeatForever`): sie hält die Layout-Schleife des Fensters beschäftigt. Der
  Status-Puls läuft nur über `SoftPulseRing` (Core Animation, gedrosselt, pausiert bei verdecktem Fenster).
- Verlauf nur über `TranscriptTextRenderer` + `TranscriptTextView` (ein `NSTextView`), keine SwiftUI-Hierarchie
  pro Nachricht und kein `.defaultScrollAnchor(.bottom)` über langen Listen.
- Kein Hover-only-UI: Zustände und Aktionen sind ohne Hover sichtbar und erreichbar.

## Kill-Switches (`defaults write com.whisperm8.app <Schlüssel> -bool NO`)

Notbremsen, kein Bedienweg — jede für Nutzer gedachte Einstellung braucht einen UI-Schalter.
`agentEventDrivenWatchEnabled`, `claudeRegistryStatusEnabled`, `chatsPromptGuardEnabled`,
`agentControlServerEnabled`, `agentCrashRecoveryEnabled`, `subagentJobRetentionEnabled`,
`claudeCodeProxyAutoUpdateEnabled`, `gptAccountProfilesEnabled`, `chatGPTTranscriptionEnabled`,
`claudeSharedMemoryEnabled`, `accountSwitchAfterTurnEnabled`, `claudePluginEnabled`, `jarvisBoardEnabled`,
`jarvisNotesEnabled`, `speechCalloutsEnabled`, `codexVoiceGateEnabled`, `agentStatusSoftPulseEnabled`.
Opt-in (`-bool YES`): `agentTerminalMetalEnabled`, `agentPerfDetailEnabled`, `debugControlEnabled`,
`mcpAutoSyncEnabled`, `agentStatusPulseEnabled` (alter Puls, nur A/B-Messung).

## Dependencies (Package.swift)

- **KeyboardShortcuts** (exact 1.16.1), **Defaults**, **LaunchAtLogin-Modern**
- **SwiftTerm** — eigener Fork, gepinnt auf v1.15.0 + Selection-Patches (Begründung in `Package.swift`). Der
  Metal-Renderer bleibt Opt-in, bis eine Messung einen Gewinn zeigt
  ([terminal.md](docs/features/agent-chats/ui/terminal.md)).
