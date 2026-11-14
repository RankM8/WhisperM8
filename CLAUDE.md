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
wegen TCC, Signier-Zertifikat): [DEVELOPMENT](docs/DEVELOPMENT.md).

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
  [ui-testing](docs/features/ui-testing.md).
- **Guards, die die Suite erzwingt:** `SourceSizeGuardTests` (max. 1.500 Zeilen je Datei, Ausnahmeliste nur
  schrumpfend — aufteilen statt Grenze anheben), `LocalizationCatalogTests`, `DocsLintTests`,
  `InfoPlistContractTests`, `AgentStatusPulseGuardTests`, `PreferenceBedienwegGuardTests`, `ChatsFontSizeGuardTests`
  (informationstragende Texte ≥ 11 pt).

## Lokalisierung (E1)

Englisch ist Basis, Deutsch wird vollständig übersetzt: neue UI-Texte englisch schreiben und die deutsche
Übersetzung in `WhisperM8/Localization/Localizable.xcstrings` eintragen. `Text("…")` mit Literal wird automatisch
Schlüssel; für String-Parameter (`.help`, NSAlert, Rückgabewerte) `String(localized:)`. Keine Ternär-Literale in
`Text(cond ? "a" : "b")`. Fachnamen und CLI-Befehle bleiben unübersetzt. Regeln: [lokalisierung](docs/features/lokalisierung.md).

## Debugging und Performance

```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```

- Hot-Paths haben `os_signpost`-Intervalle mit Budgets (`PerfBudgets`); Überschreitungen loggen
  `perf_budget_exceeded`, ein hängender Main Thread `main_thread_blocked_ongoing`.
- **Nie pro Byte/Zeichen/Zeile messen** — dort `PerformanceCounters`. Neue Signposts an häufigen Stellen nur
  in der Stufe `.detail`.
- Alles, was App oder Build langsam macht, mit Kosten melden. Messläufe gegen Budgets mit `make dev-release`.
- Doku: [performance-messung](docs/features/performance-messung.md).

## Architektur

`Services/` ist geteilt in `Dictation/`, `AgentChats/`, `Shared/`, `VoiceGate/` (SwiftPM findet rekursiv).
Große Views/Services wachsen über thematische `extension`-Dateien (`AgentChatsView+…`,
`RecordingCoordinator+…`); verschobene Logik ist `internal`. Roadmap: `docs/refactor/REFACTORING-AUDIT.md`.

**App-Hülle:** Dock-App plus `MenuBarExtra`; Szenen in `WhisperM8App.swift`; das letzte Fenster zu schließen
beendet die App nicht; `WindowRequestCenter` routet Fenster-Anfragen. Absturzschutz, SIGPIPE, ObjC-Exceptions,
Cmd+Q-Dialog und Wiederaufnahme nach Absturz: [app-shell](docs/features/app-shell/ARCHITECTURE.md).

**Diktat:** Hotkey → `AppState`/`RecordingCoordinator` → `AudioRecorder` (M4A 16 kHz mono) → Kontext
(`SelectedContextService`, Screenshots, Chat-Tail) → `TranscriptionService` (OpenAI/Groq/ChatGPT-Abo) →
optional `PostProcessingService` (Codex mit `OutputMode`) → Zwischenablage/Auto-Paste oder Agent Chat.
Doku: [dictation](docs/features/dictation/).

**Agent Chats:** Discovery (`AgentScanCoordinator` → `AgentSessionIndexer`) → Persistenz
(`AgentWorkspaceStore` hinter `AgentSessionStore`, UI über `AgentWorkspaceUIModel`) → Laufzeitstatus
(Claudes Registry, Hook-Bridge, `AgentSessionRuntimeWatcher`) → UI (SwiftTerm-PTYs, Tabs, Grid, Verlauf).
Doku-Einstieg: [agent-chats](docs/features/agent-chats/README.md); Konten:
[claude-konten](docs/features/agent-chats/claude-konten.md), [gpt-konten](docs/features/agent-chats/gpt-konten.md);
CLI: [agent-chats-cli](docs/features/agent-chats-cli.md); Board/Plugin: [jarvis-board](docs/features/jarvis-board.md);
Ansagen: [speech-callouts](docs/features/speech-callouts.md); Zwischenablage-Verlauf: [clipboard-history](docs/features/clipboard-history.md); Voice Gate: [voice-gate](docs/features/voice-gate.md).
Notch: [notch](docs/features/notch.md); Statistik: [statistics](docs/features/statistics.md); Controller: [controller](docs/features/controller.md); Tickets: [tickets](docs/features/tickets.md).

## Invarianten (nicht brechen)

**Prozesse und Umgebung**
- GUI-Apps haben einen minimalen `PATH`. Subprozesse nie mit dem rohen `ProcessInfo`-Environment starten,
  immer `LoginShellEnvironment.shared.processEnvironment()` + `AgentCommandBuilder.commandPath(_:)`.
- `LoginShellEnvironment` strippt geerbte `CLAUDE_CONFIG_DIR`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `ANTHROPIC_CUSTOM_HEADERS`, `CCP_CONFIG_DIR`.
- Neue Dateideskriptoren (Locks, Sockets, Watcher) close-on-exec — SwiftTerm `forkpty`+`execve` schließt nichts.
- An Pipes nur `write(contentsOf:)` (throwing), nie `FileHandle.write(_:)` (NSException bei EPIPE). SIGPIPE
  wird per leerem `sigaction`-Handler abgefangen, nie per `SIG_IGN` (würde an jede Chat-Shell vererbt).
- Eigene Schreibvorgänge auf der allgemeinen Zwischenablage direkt danach mit `ClipboardInternalWrites.claim(_:)`
  beanspruchen (schreibt eine fremde App für uns, etwa per Cmd+C, zusätzlich `begin()/end()`), sonst landen sie im
  Zwischenablage-Verlauf.
- Kein `installTap` ohne `ObjCException.catching`; das Format unmittelbar vor dem Tap neu lesen.
  Absturzrelevante Ereignisse auf `Logger.info` oder höher (`.info` ist per `OSLogPreferences` persistent).

**Workspace und Daten**
- Mutations-Closures des `AgentWorkspaceStore` laufen unter dem prozessweiten Lock: keine Subprozesse, kein
  blockierendes I/O (Git-Lookups vorher). UI nie über `loadWorkspace()` „auffrischen“.
- Die App ist einziger Schreiber von Workspace und Board; die CLI liest von Disk und handelt über den Socket.
  Das Ticket-System liest die App nur für die Ticket-Ansicht (`ticketBoardEnabled`), abseits des Main Threads;
  geschrieben wird nur über `whisperm8 tickets`.
- Fremde Daten unter `~/.claude*` und `~/.codex/` sind extern und werden nur gelesen — **Ausnahmen, alle
  absichtlich:** Theme-Schlüssel in `settings.json` (`ClaudeThemeWriter`, bei Theme-Wechsel);
  `agents/gpt.md` je Konto bei aktivem GPT-Backend (`ClaudeGPTAgentDefinition`); Statuszeile
  (`StatuslineInstaller`: Skripte + `statusLine` in `settings.json`, nutzerausgelöst); geteilte Einträge der
  Profil-Ordner (`ClaudeAccountProfiles+SharedConfig`, Symlinks); lose Skills nach `~/.claude/skills`
  („Install for Terminal…“, nutzerausgelöst) und das Wegsichern alter Kopien nach `skills/.whisperm8-backup/`;
  `claude mcp add-json` beim MCP-Angleich (schreibt die CLI selbst); die Login-Erneuerung (ersetzt `claudeAiOauth` im Keychain-Eintrag des Kontos durch den geprüften neuen Login,
  nutzerausgelöst); „Zum Hauptkonto machen“ (Keychain,
  `oauthAccount` in `~/.claude.json`, Mischen von `projects/` und `file-history/`); die einmalige
  Memory-Migration (kopiert nach main, mit Backup); Subagent-Retention verschiebt Rollouts aus
  `~/.codex/sessions` ins Archiv. Ein neuer Write kommt in diese Liste. Hook-Settings (`claude-hooks/<id>.json`)
  liegen in Application Support, nicht unter `~/.claude`.
- Logins werden zwischen Konten **verschoben, nie kopiert** (gleiche Refresh-Familie entwertet sich sonst).
- Ein Login wird nie direkt im Profil erneuert, immer über den Zwischenordner mit Konto-Abgleich (`ClaudeLoginRenewer`) —
  der Browser kennt nur eine claude.ai-Sitzung, ein falsches Konto überschriebe sonst einen gültigen Login.
- Eigene Daten: `~/Library/Application Support/WhisperM8/` (`AgentSessions.json` = Workspace, `agent-ui-state.json`,
  `agent-index-cache.json`, `jarvis-board.json`, `running-sessions.json`, `agent-task-lists.json`, `tickets.json`, `clipboard-history/` (Index plus Bilder, 0700/0600), `statistics/`, Reports, FailedRecordings).
- Neue Bundle-Ressourcen brauchen `Package.swift` UND den Makefile-Schritt `_bundle`.
- `pmset -a disablesleep 1` setzt nur der `StayAwakeController`, und nie ohne laufende Wache, die beim Tod
  der App zurücksetzt. Einziger Write außerhalb der eigenen Daten ist `/etc/sudoers.d/whisperm8-sleep`
  (nutzerausgelöst, mit Admin-Dialog): [ui](docs/features/agent-chats/ui/README.md).

**Agent Chats**
- Status für Claude-Chats kommt aus Claudes Registry (`<config-dir>/sessions/<pid>.json`); Hooks binden nur die
  Session-ID. Ein `SessionStart` übernimmt die externe ID nicht ungeprüft
  (`externalIDBindingDecision`).
- WhisperM8 hostet die echte Claude-/Codex-CLI im PTY — keine Eigen-UI oder SDK-Runtime als Ersatz.
- Welches Modell ein Claude-Chat nutzt, entscheidet Claude Code; `--model` nur beim ausdrücklichen „Neuer GPT-Chat“.
- GPT-Chats nennen ihr Konto immer per `X-WhisperM8-GPT-Profile`, auch `main`. Angeboten werden nur Modelle,
  die Codex-Katalog und laufender Proxy beide kennen.
- Das Plugin wird nie in den laufenden Ordner kopiert, nur per Symlink-Tausch (`rename(2)`) umgestellt — sonst
  laden alle Sessions mitten im Turn neu. In `register.tsx` keine Abschnitte in eigene Dateien auslagern.
- Board-Felder nur ergänzen, nie umbenennen (`work` und `next` werden gleich geschrieben).
- Der Terminal-Delegate-Proxy (`AgentTerminalLinkInterceptor`) bleibt: er verweigert `clipboardRead` (OSC 52),
  sonst bekäme jede TUI den Klartext der Zwischenablage.
- Kontowechsel: Hat das Zielkonto den Ordner nie freigegeben (Trust), wird ein arbeitender Chat nicht vorgemerkt —
  der unbeobachtete Neustart landete sonst in Claudes Trust-Dialog mit Vorauswahl „No, exit“. Die CLI
  (`chats move-account --stop-and-resume`) hält dann ohne `--force` auch einen ruhenden Chat nicht an.
- Der GPT-Proxy wird zur Laufzeit nie neu gestartet (laufende GPT-Chats); Waisen ersetzt nur der Start-Guard.
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

Notbremsen, kein Bedienweg — jede für Nutzer gedachte Einstellung braucht einen UI-Schalter; neue Schlüssel
bekommen einen UI-Weg oder einen begründeten Eintrag in `PreferenceBedienweg.swift`. Labs-Funktionen gehören in die
Labs-Gruppe der Einstellungen, erweiterte Agent-Funktionen hinter `agentAdvancedFeaturesEnabled`.
`agentEventDrivenWatchEnabled`, `claudeRegistryStatusEnabled`, `codexStartGuardEnabled`,
`agentControlServerEnabled`, `agentCrashRecoveryEnabled`, `subagentJobRetentionEnabled`,
`claudeCodeProxyAutoUpdateEnabled`, `gptAccountProfilesEnabled`, `chatGPTTranscriptionEnabled`,
`claudeSharedMemoryEnabled`, `accountSwitchAfterTurnEnabled`, `claudePluginEnabled`, `jarvisBoardEnabled`,
`jarvisNotesEnabled`, `agentChatTasksInNotesEnabled`, `speechCalloutsEnabled`, `codexVoiceGateEnabled`, `agentStatusSoftPulseEnabled`, `notchStatusFeatureEnabled`,
`clipboardHistoryEnabled`, `statisticsEnabled` (beide zugleich UI-Schalter), `controllerFeatureEnabled`, `controllerPaddleHIDEnabled`,
`unifiedPillEnabled` (vereinte Pille; aus = getrennte Diktat- und Status-Pille).
Opt-in (`-bool YES`): `agentTerminalMetalEnabled`, `agentPerfDetailEnabled`, `debugControlEnabled`,
`mcpAutoSyncEnabled`, `ticketBoardEnabled`, `agentStatusPulseEnabled` (alter Puls, nur A/B-Messung), `restartKeepsChatsEnabled`
(Labs „Neustart ohne Chatverlust“, im Bau; bisher nur GPT-Router als eigener Dienst `gpt-router`, wirkt ab dem
nächsten App-Start; Plan [Plan](docs/plans/neustart-ohne-chatverlust.md)).

## Dependencies (Package.swift)

- **KeyboardShortcuts** (exact 1.16.1), **Defaults**, **LaunchAtLogin-Modern**
- **SwiftTerm** — eigener Fork, gepinnt auf v1.15.0 + Selection-Patches (Begründung in `Package.swift`). Der
  Metal-Renderer bleibt Opt-in, bis eine Messung einen Gewinn zeigt
  ([terminal](docs/features/agent-chats/ui/terminal.md)).
