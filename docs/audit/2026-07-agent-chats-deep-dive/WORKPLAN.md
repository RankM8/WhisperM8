# Workplan: Ultra Deep Dive (Multi-Agent-Workflow)

Ausgeführt am 2026-07-18 als Claude Dynamic Workflow mit Fable-Agents (Claude) und
Codex-Subagents (`whisperm8 agent`, gpt-5.6-sol, effort high/xhigh).

## Phasen

### Phase 1 — Kartierung (9 Codex-Jobs, workspace-write, parallel)

Jeder Job kartiert ein Subsystem und schreibt genau eine Datei nach `01-subsysteme/`:

| # | Subsystem | Datei |
|---|---|---|
| 1 | Persistenz (WorkspaceStore/SessionStore/Repository/UIState) | `persistenz.md` |
| 2 | Runtime-Status (Watcher/Coordinator/FileEventSource) | `runtime-status.md` |
| 3 | Terminal/PTY (SwiftTerm, Registry, CommandBuilder, Links) | `terminal.md` |
| 4 | Indexierung & Transcripts (Indexer, Reader, Timeline) | `indexierung.md` |
| 5 | Background-Jobs & CLI (Spawner, Supervisor, CodexExecRunner) | `background-jobs.md` |
| 6 | Hooks & Accounts (HookBridge, AccountProfiles, Resolver) | `hooks-accounts.md` |
| 7 | UI-Shell (AgentChatsView+Extensions, WindowStore, Tabs, Grid) | `ui-shell.md` |
| 8 | Diktat-Pipeline (AudioRecorder, RecordingCoordinator, Transcription) | `diktat.md` |
| 9 | Shared-Infrastruktur (LoginShellEnvironment, Keychain, App-Szenen) | `shared-infra.md` |

### Phase 2 — Vergleich (5 Fable-Research-Agents, parallel zu Phase 1)

Web-Recherche zu ähnlichen Open-Source-Projekten, Ergebnisse nach `03-vergleich/`:

1. Claude-Code-Session-Manager (Crystal, claudecodeui, VibeTunnel, opencode, Conductor, …)
2. Open-Source-Diktat-Apps für macOS (VoiceInk, Handy, whisper.cpp-Ökosystem)
3. Terminal-Emulation & PTY-Handling (SwiftTerm-Grenzen, Alternativen, Best Practices)
4. SwiftUI-App-Architektur in großen OSS-Swift-Apps (Store-Patterns, Persistenz)
5. Claude-CLI-Integrationsmuster im Ökosystem (Hooks, Resume, Multi-Account)

### Phase 3 — Problemjagd (6 Codex- + 5 Fable-Finder, parallel)

Finder lesen Code + Subsystem-Karten, schreiben Findings nach `02-findings/`:

| Dimension | Codex | Fable |
|---|---|---|
| Crash Diktat/Transkription (User-Report!) | ✓ | ✓ |
| Concurrency/Races Agent Chats | ✓ | ✓ |
| Performance | ✓ | ✓ |
| Memory/Leaks | ✓ | — |
| Fehlerbehandlung/Robustheit | ✓ | — |
| Claude-Code-Integration (Korrektheit) | ✓ | ✓ |
| Architektur/Wartbarkeit | — | ✓ |

### Phase 4 — Triage & Adversariale Verifikation

Ein Fable-Agent extrahiert die 12–16 wichtigsten Behauptungen; pro Behauptung
ein Codex-Refuter (read-only, effort xhigh) mit dem Auftrag zu WIDERLEGEN.
Ergebnis: `04-verifikation/verdicts.md` (BESTÄTIGT / WIDERLEGT / UNKLAR).

### Phase 5 — Synthese

Fable-Agent liest alles und schreibt `05-roadmap/refactor-roadmap.md`
(P0 Stabilität → P1 Claude-Code-UX/Performance → P2 Wartbarkeit, je Maßnahme:
Aufwand, Risiko, betroffene Dateien, Reihenfolge) und finalisiert `README.md`.

## Regeln für alle Agents

- Nur analysieren + die jeweils zugewiesene Doku-Datei schreiben. Kein Code-Change, keine Commits.
- Jede Behauptung mit `Datei:Zeile` belegen. Keine Stil-Nitpicks.
- NIEMALS `make dev` / `make kill` / `make run` (Session läuft ggf. in der App). `swift build`/`swift test` ist erlaubt (Fable-Agents).
- Codex-Jobs: immer `--model gpt-5.6-sol`, Analyse `--effort high`, Verifikation `--effort xhigh`.
