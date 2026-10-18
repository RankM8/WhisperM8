---
status: aktiv
updated: 2026-10-17
description: Lagebild des Subsystems agent-daten (Persistenz, Indexierung, Transcript-Lesen, Verlaufsansicht, Zusammenfassungen, Retention, Crash-Recovery der Agent Chats) auf Stand a8e0f35.
---

# Lagebild agent-daten

## Zweck

Das Subsystem hält alles, was ein Agent-Chat an Daten hat, und liest alles, was Claude Code und Codex selbst schreiben.

- Es persistiert Projekte und Sessions in `AgentSessions.json`.
- Es erkennt extern gestartete Sessions (Indexer, FSEvents).
- Es liest die nativen Transcripts (JSONL) und zeigt sie als Verlauf.
- Es erzeugt Titel und Zusammenfassungen.
- Es räumt Altlasten weg (Retention) und nimmt nach einem Absturz laufende Chats wieder auf.

`~/.claude` und `~/.codex` sind dabei externe Quellen und bleiben read-only.

Ausgeklammert und hier nicht beschrieben: Chats-UI, Grid, Tabs, `AgentWindowStore`, Jarvis-Board, Control-Server und `WhisperM8/CLI/Chats*`. Sie werden im Delta-Lauf behandelt.

## Datenfluss

```
 ~/.claude/projects/**/*.jsonl      ~/.codex/sessions/Y/M/D/*.jsonl
            |  (FSEvents, Foreground, Launch, manuell)    |
            v                                             v
   AgentDirectoryEventMonitor --> AgentScanCoordinator (Single-Flight, Cooldown 30/10 s, suspend/resume)
                                          |  Task.detached(.utility)
                                          v
              ClaudeSessionIndexer / CodexSessionIndexer  (BoundedJSONLReader, mtime+size-Cache
                                          |                 agent-index-cache.json)
                                          v  MainActor: applyIndexedScan
   AgentSessionStore (Facade) --> AgentWorkspaceStore (NSLock, diff-gated, debounced 0,5 s)
                                          |  flushQueue (utility) + willTerminate-Drain
                                          v
          AgentWorkspaceRepository --> AgentSessions.json (+ .bak.1-3, .pre-migration/.decode-failed)
                                          |
                                          v  AgentWorkspaceUIModel (Projektion, nie loadWorkspace zum Refresh)
                                         UI

 Transcript (JSONL) --> AgentTranscriptLocator --> AgentTranscriptCache (Tail 512 KiB, LRU 24, 2 Reads)
        --> Claude-/CodexTranscriptReader --> AgentChatTranscript
        --> TranscriptTextRenderer (off-main, abbrechbar) --> TranscriptTextView (1 NSTextView, TextKit 2)
        --> TranscriptTimelineBuilder --> TranscriptEvidenceExtractor --> AgentSessionSummarizer
                                              --> headless claude -p / codex exec --> AgentSessionSummary

 Turn-Ende (Runtime-Watcher) --> AgentSessionAutoNamer --> NativeSessionTitle (Transcript lesen, kein Modell)
 PTY-Menge --> AgentCrashRecoveryMarker (running-sessions.json) --> Resume-Vormerkung beim nächsten Start
 agent-jobs/ --> AgentJobWorkspaceSync --> SubagentJobRetention (7 Tage) --> agent-jobs-archive/
```

## Schlüsseldateien

- `Services/AgentChats/AgentSessionStore.swift`: Facade für alle Workspace-Mutationen. Enthält Merge und Adoption indexierter Sessions, `migratedWorkspace`, Subagent-Merge und Resume-Reparatur.
- `Services/AgentChats/AgentWorkspaceStore.swift`: In-Memory-Kern mit Lock und Equatable-Diff-Gate. Debounce 0,5 s, spätestens 2 s, `willTerminate`-Drain, Registry pro Datei-URL und UI-Modell-Projektion.
- `Services/AgentChats/AgentWorkspaceRepository.swift`: Disk-I/O. Atomares Schreiben, drei rotierende Generation-Backups, Quarantäne bei Decode-Fehler, schreibfreier `loadReadOnly` für die CLI.
- `Models/AgentChat.swift`: Workspace-Schema (`currentSchemaVersion`), Session-Typen und `canAutoRenameTitle`.
- `Services/AgentChats/AgentScanCoordinator.swift`: Scan-Auslöser mit Coalescing, Cooldown und `suspendScans`/`resumeScans` für Kontoumzüge.
- `Services/AgentChats/AgentDirectoryEventMonitor.swift`: FSEvents-Überwachung der Transcript-Wurzeln, 5 s Debounce, filtert Subagent-Pfade und live beobachtete Transcripts.
- `Services/AgentChats/AgentSessionIndexer.swift`: Index-Cache (Schema 3) mit Lookup und Prune.
- `Services/AgentChats/ClaudeSessionIndexer.swift`: Claude-Index. Überspringt `subagents/` und Worktree-CWDs, höchstens 200 Zeilen bzw. 1 MiB je Datei.
- `Services/AgentChats/CodexSessionIndexer.swift`: Codex-Index. Liest nur die erste `session_meta`-Zeile (256 KiB).
- `Services/AgentChats/BoundedJSONLReader.swift`: Begrenztes Präfix-Lesen für die Indexer.
- `Services/AgentChats/AgentSessionTranscript.swift`: Event-Parser und Statusentscheider für den Runtime-Watcher sowie der `AgentTranscriptLocator` (profil- und codex-bewusst).
- `Services/AgentChats/ClaudeTranscriptReader.swift`: Claude-JSONL zu `AgentChatTranscript`. Enthält den `TranscriptTailReader`.
- `Services/AgentChats/CodexTranscriptReader.swift`: Codex-Rollout zu `AgentChatTranscript`.
- `Services/AgentChats/AgentTranscriptCache.swift`: Actor-Cache mit LRU, geteilten In-flight-Reads und globaler Lese-Drosselung.
- `Services/AgentChats/TranscriptTextRenderer.swift`: Macht aus dem Transcript einen CLI-artigen Zeilenstrom. Kürzt nur Tool-Ausgaben.
- `Views/Transcript/TranscriptTextView.swift`: Der Verlauf als ein `NSTextView` mit TextKit 2.
- `Views/Transcript/AgentTranscriptContainerView.swift`: Baut den Verlauf off-main, hält Meta-Leiste, Summary-Karte und Nachlade-Pille.
- `Views/Transcript/SessionSummaryCard.swift`: Zusammenfassungs-Karte. Löst das Erzeugen beim Anzeigen aus.
- `Services/AgentChats/AgentSessionSummarizer.swift`: Headless-Zusammenfassung mit Digest-Guard, Backoff und Anzeige-Trigger.
- `Services/AgentChats/AgentHeadlessCLI.swift`: Spawn der Headless-Läufe. `AgentTitleGenerator.defaultRunner` liegt in `AgentSessionAutoNamer.swift`.
- `Services/AgentChats/TranscriptTimelineBuilder.swift` und `TranscriptEvidenceExtractor.swift`: Runden-Projektion und Belege (Tests, Commits) für den Summary-Prompt.
- `Services/AgentChats/NativeSessionTitle.swift` und `AgentSessionAutoNamer.swift`: Native Titel aus dem Transcript.
- `Services/AgentChats/SubagentJobRetention.swift`: Frist-Policy und Transcript-Archivierung der Subagent-Spiegel.
- `Services/AgentChats/AgentSessionRetentionService.swift`: Räumt verwaiste Hook-Settings und Hook-Events.
- `Services/AgentChats/AgentCrashRecovery.swift`: Marker, Planer und Coordinator für die Wiederaufnahme.
- `Services/AgentChats/LegacyDataCleanup.swift`: Einmaliges Entfernen von `TerminalSnapshots/`.
- `Services/AgentChats/GitBranchReader.swift`: Dateibasiertes Branch-Lesen ohne Subprozess.
- `Services/AgentChats/GitProjectStatus.swift` und `GitChangesSnapshot.swift`: Git-Status per Subprozess mit 10-s-Deadline.
- `Services/AgentChats/ProjectChangesWatcher.swift`: Beobachtet Projekt-Änderungen für den Git-Status.

## Zustände und Persistenz

| Datei oder Key | Inhalt | Schreiber |
|---|---|---|
| `Application Support/WhisperM8/AgentSessions.json` | Projekte und Sessions | nur `AgentWorkspaceStore` über das Repository (Debounce, atomar) |
| `AgentSessions.json.bak.1-3` | Last-known-good-Generationen, Rotation höchstens alle 5 min | Repository |
| `AgentSessions.json.<grund>.<zeit>.bak` | Quarantäne bei Decode-Fehler, Backup vor Migration und vor großer Retention | Repository, `AgentJobWorkspaceSync` |
| `agent-ui-state.json` | Tabs, Auswahl, Pins, Grid (Sidecar) | `AgentWindowStore` (nicht in diesem Bereich) |
| `agent-index-cache.json` | Index-Cache nach Provider, Pfad, mtime und Größe | `AgentSessionIndexCacheStore`, atomar |
| `running-sessions.json` | Marker der laufenden PTYs und der PID | `AgentCrashRecoveryMarker`, Löschen bei sauberem Quit |
| `agent-jobs-archive/` | Rollout-Transcripts abgelaufener Subagent-Jobs | `SubagentJobTranscriptArchiver` |
| `claude-hooks/<id>.json` und Events-Datei je Session | Hook-Settings und Events | Hook-Bridge. Aufräumen durch `AgentSessionRetentionService` beim Start |
| `UserDefaults` | `isAutoSummaryEnabled` (Default an), `summaryStartupReconciliationEnabled` (Default aus), `agentCrashRecoveryEnabled`, `subagentJobRetentionEnabled`, `subagentJobRetentionDays`, `subagentJobRetentionInitialPurgeDone`, `terminalSnapshotsPurged`, `agentEventDrivenWatchEnabled` | Settings und Defaults |

Der Runtime-Status ist bewusst ephemer und liegt in `AgentSessionRuntimeStatusStore`.

## Externe Abhängigkeiten

- **CLIs:** `claude -p ... --no-session-persistence` und `codex exec --ephemeral` für Zusammenfassungen. Das sind Modellaufrufe auf dem Konto der jeweiligen CLI. `/usr/bin/git` für Status und Änderungen.
- **Dateiformate Dritter:** Claude- und Codex-JSONL sind intern und können sich ändern. Der Parser muss degradieren, nicht abstürzen.
- **Netz:** kein eigener Netzzugriff. Zusammenfassungen gehen indirekt über die CLIs zum Anbieter.
- **TCC:** keine eigenen Rechte. `~/.claude` und `~/.codex` liegen im Home und brauchen unter normalem Betrieb keinen Dialog.
- **Prozessumgebung:** Subprozesse laufen mit `LoginShellEnvironment`, nie mit der rohen GUI-Umgebung.

## Invarianten für jeden Umbau

1. Der Workspace hat genau einen Schreiber: den In-Memory-Kern. Eine Instanz pro Datei-URL, Mutationen unter Lock.
2. Mutations-Closures führen keine Subprozesse oder blockierendes I/O aus (Git-Lookups und Resolver vorher).
3. Persistenz ist diff-gated, debounced (0,5 s), spätestens nach 2 s fällig. `willTerminate` drainiert synchron.
4. Die UI liest über `AgentWorkspaceUIModel`. `loadWorkspace()` ist kein Refresh-Mittel.
5. `~/.claude` und `~/.codex` werden nie beschrieben. Das gilt auch für den Indexer.
6. Subagent-Transcripts werden nie indiziert. Indexer-Filter und `relevantPaths` im FSEvents-Monitor ändern sich nur gemeinsam.
7. Ein Scan läuft höchstens einmal gleichzeitig, und ein Pending-Grund geht nie verloren.
8. Manuell vergebene Titel (`titleIsAutoGenerated == false`) werden nie überschrieben.
9. Die Verlaufsansicht bleibt eine einzige Ansicht, ein `NSTextView`. Gekürzt werden nur Tool-Ausgaben, Antworttexte nie.
10. Das Attributieren des Verlaufs läuft off-main und abbrechbar. Das Lesen ist Tail-first mit globaler Drosselung.
11. Der Retention-Reihenfolge entsprechend wandert das Transcript aus dem Scan-Root, bevor die Session gelöscht wird. Laufende, sichtbare und lebende Jobs sind tabu.
12. Zusammenfassungen sind ein Ausnahme-Datenfluss: Digest-Guard (unverändert gibt keinen CLI-Lauf), Backoff und Kill-Switch bleiben erhalten.
13. Die Crash-Recovery markiert nur `chat` und `backgroundChat`. Ein sauberes Beenden entfernt den Marker, eine zweite Instanz fasst ihn nicht an.
14. Pipes werden nur mit `write(contentsOf:)` beschrieben. `installTap` nur mit `ObjCException.catching`.

## Top-Risiken (LR-IDs aus `findings.jsonl`)

| Risiko | Befund |
|---|---|
| Ungültige Modellausgabe (`}` vor `{`) beendet die App | LR-AK-001 (P0) |
| Höhere Schema-Version wird beim Load überschrieben und migriert zurück (Downgrade-Datenverlust) | LR-AK-002 (P0), LR-AK-029 (P0) |
| Chat-Inhalt liegt im argv der Summary-Prozesse | LR-AK-003 (P0) |
| Skalare Tool-Payloads gehen durch NSException-gefährdete JSON-Serialisierung | LR-AK-004 (P0, Konfidenz mittel) |
| Fehlgeschlagene Workspace-Writes bleiben unsichtbar und ohne Retry | LR-AK-005 (P1) |
| Codex-Statusparser versteht das Rollout-Format nicht | LR-AK-006 (P1) |
| Ein sehr großes letztes JSONL-Event macht den Verlauf unerreichbar | LR-AK-007 (P1) |
| UTF-8-Schnittkante blockiert den Import einer gültigen Session dauerhaft | LR-AK-008 (P1) |
| Summary-Läufe verlieren Konto und Backend des Chats | LR-AK-009 (P1) |
| Automatische Zusammenfassungen sind standardmäßig an und erklären den Datenabfluss nicht | LR-AK-010 (P1), LR-ONB-008 (P2) |
| `resumeScans` umgeht Single-Flight, Account-Stempel können zurückgesetzt werden | LR-AK-011 (P1) |
| Retention löscht anhand eines nach `await` veralteten Schutz-Snapshots | LR-AK-012 (P1) |
| Parallele Tool-Ergebnisse vertauscht, nur gestarteter Test gilt als bestanden | LR-AK-013, LR-AK-014 (P2) |
| Abgebrochene Verlaufsbauten rechnen weiter | LR-AK-015 (P2) |
| Dauernde externe Writes verschieben die Erkennung endlos | LR-AK-016 (P2) |
| Feature-Doku beschreibt abgelöste Transcript- und Titelpfade | LR-DOK-006 (P2) |

Angrenzend im Runtime-Bereich (nicht Teil von agent-daten): LR-AK-019, LR-AK-025.
