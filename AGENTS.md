# AGENTS.md — Konventionen für Codex-Agenten in WhisperM8

WhisperM8 ist eine native macOS-App (Swift 5.9, SwiftUI, macOS 14+, pure
SwiftPM — kein .xcodeproj) mit zwei Hälften: Diktat-Pipeline (Hotkey →
Whisper/Groq → optional Codex-Nachbearbeitung) und Agent Chats
(Session-Manager für Claude Code und Codex CLI: PTY-Terminals,
Background-Agents, Subagent-Jobs). Ausführliche Architektur-Doku: `CLAUDE.md`.

## Sprache & Stil

- **Code-Kommentare auf Deutsch** — Repo-Konvention, auch für neue Dateien.
- Commit-Messages: Conventional Commits mit deutschem Beschreibungstext,
  z.B. `feat(overlay): Kern-Waveform mit alter Dynamik` oder
  `fix(agent-chats): Hooks als alleinige Statusquelle`.
- Kommentare erklären das **Warum** (Constraints, Gotchas), nicht das Was.

## Bauen & Testen

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Pflicht (SwiftUI-Makros)
swift build                                   # Debug-Build
swift test                                    # volle Suite
swift test --filter <TestKlasse>              # gezielt
```

- Als headless Agent NICHT `make dev`/`make run` starten (öffnet die GUI,
  braucht TCC-Permissions).
- Vor dem Committen: `swift test` muss komplett grün sein.

## Test-Konventionen

- Dependency Injection über einfache Closures und kleine Protokolle
  (`commandResolver: { _ in "/pfad" }`, `ProcessRunner`-Spies) — **kein**
  DI-Framework.
- Tests thematisch gesplittet in `Tests/WhisperM8Tests/`; geteilte Helpers
  in `AgentTestSupport.swift`.
- Pure Logik wird unit-getestet; SwiftUI-/NSEvent-Interaktionen sind
  manuelle QA — keine UI-Tests erfinden.

## Architektur-Leitplanken (Auswahl)

- `Services/` ist dreigeteilt: `Dictation/`, `AgentChats/`, `Shared/` —
  neue Dateien in den passenden Ordner (SwiftPM entdeckt rekursiv).
- Subprozesse NIE mit dem rohen ProcessInfo-Environment spawnen — immer
  `LoginShellEnvironment.shared.processEnvironment()` +
  `AgentCommandBuilder.commandPath(_:)` (GUI-PATH ist minimal).
- `AgentWorkspaceStore`-Mutation-Closures dürfen keine Subprozesse und kein
  blockierendes I/O ausführen (NSLock-serialisiert) — alles vorberechnen.
- Alles unter `~/.claude/` und `~/.codex/` ist extern und read-only.
- Neue Bundle-Ressourcen brauchen Package.swift UND Makefile (`_bundle`) —
  besser: kleine Ressourcen als Swift-String-Konstanten einbetten.
- Große Views/Services nicht aufblähen: thematische `extension`-Dateien
  (`AgentChatsView+<Thema>.swift`) sind das etablierte Muster.

## Debugging

```bash
log stream --predicate 'subsystem == "com.whisperm8.app"' --level debug
```
