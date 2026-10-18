---
status: aktiv
updated: 2026-10-17
description: Lagebild der Agent-Laufzeit (Launch, Hook-Bridge, Status, Queue, Background-Agents, Codex-Subagent-Jobs, Terminal-PTY) auf Stand a8e0f35 — Datenfluss, Dateien, Zustände, Invarianten, Top-Risiken.
---

# Lagebild: Agent-Laufzeit

Stand: Commit `a8e0f35`. Ausgeklammert (Delta-Lauf): Agent-Chats-UI/Grid/Tabs/Sidebar, `AgentWindowStore`, Jarvis-Board, Control-Server, `CLI/Chats*`, `claude-plugin/`.

## Zweck

Die Laufzeit startet **echte** Claude- und Codex-CLIs (kein SDK, kein Eigen-UI) als Vordergrund-PTY, als Claude-Background-Agent (`claude --bg`) oder als detachten Codex-Subagent-Job (`whisperm8 agent`). Sie leitet daraus einen verlässlichen Zustand ab (arbeitet, wartet auf Eingabe, ruhig, gestoppt, Fehler), bindet die reale externe Session-ID an die lokale UUID, stellt vorgemerkte Folgeaufträge am Turn-Ende zu und holt nach einem Absturz die zuvor laufenden Chats zurück. Die Anzeige liegt außerhalb dieses Bereichs.

## Datenfluss

```
Start-Anfrage (Tab sichtbar / chats new / resume / Crash-Recovery)
  -> AgentSessionDetailView.launchAfterCacheWarmup (off-main: Login-PATH, Binary)
  -> repairedSessionForLaunch -> AgentCommandBuilder.command(for:project:)
       |- claude: neu | --resume <id> | --fork-session | attach <short-id> (Roster-Fallback)
       |- codex:  neu | resume <thread>      |- terminal: Login-Shell -i -l
  -> AgentSessionStatusCoordinator.prepareLaunchSettings
       -> ClaudeHookBridge.prepareSettingsFile -> claude --settings <claude-hooks/<id>.json>
  -> AgentTerminalRegistry.startController -> AgentTerminalController.start (SwiftTerm-PTY,
       Env = LoginShellEnvironment + Overrides + WHISPERM8_SESSION_ID/TOKEN)

Claude (Hooks)                                   Transcript (JSONL)
  Hook-Command: (cat;echo) >> claude-session-events/<id>.jsonl     ~/.claude/projects/..., ~/.codex/sessions/...
  -> ClaudeHookBridge (vnode, initialer Drain)   -> AgentSessionRuntimeWatcher (vnode + 1,5-s-Timer,
  -> ClaudeHookEventStore (Byte-Cursor)             stat-first, 64-KB-Tail)
              \                                       /
               v                                     v
        AgentSessionStatusCoordinator  (einziger Schreiber des Laufzeitstatus)
          Hook-Primat -> AgentSessionStateMachine -> Effekte
          -> AgentSessionRuntimeStatusStore (Sidebar-Status)
          -> Binding der externen ID -> AgentSessionStore (Workspace-Datei)
          -> Effekt turnCompleted: Ton, Mitteilung, AgentPromptQueueDelivery.deliverNext
               -> SendDeliveryTokenStore.stage -> PTY-Paste
               -> Hook UserPromptSubmit -> `whisperm8 chats _prompt-guard` (Send-Guard) -> Token verbrauchen

Codex-Subagent:  whisperm8 agent run -> AgentJobStore (agent-jobs/<id>/state.json)
  -> AgentSupervisorLauncher (detacht) -> AgentJobSupervisor -> CodexTurnExecutor -> CodexExecRunner
  -> `codex exec --json` -> Events/Report/last-message im Job-Ordner
  -> AgentJobDirectoryMonitor (FSEvents) -> AgentJobWorkspaceSync -> Workspace-Zeilen (+ Retention)

Background-Agent: BackgroundAgentSpawner (`claude --bg`, Short-ID aus stdout) -> Supervisor-Daemon
  -> `claude attach <short-id>` im PTY; BackgroundAgentLifecycle (logs/stop/respawn/rm);
  SupervisorJobReader / SupervisorRosterReader / ActiveBackgroundSessionTracker (lesen, nie schreiben)

Absturz: AgentTerminalRegistry.onRunningSetChanged -> AgentCrashRecoveryMarker (running-sessions.json)
  -> nächster Start: AgentCrashRecoveryCoordinator -> shouldLaunchOnOpen
```

## Schlüsseldateien

| Pfad | Rolle |
|---|---|
| `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` | Baut Argv und Umgebung für Claude, Codex, Terminal, Attach und `--bg`; Resume-Selbstheilung, Plugin- und Router-Env. |
| `WhisperM8/Views/AgentSessionDetailView.swift` | Startet den PTY beim Anzeigen, repariert Resume-Ziele, markiert Launch und Ende. |
| `WhisperM8/Views/AgentTerminalView.swift` | PTY-Controller, `AgentTerminalRegistry`, Tastaturprofile, Feed-Drosselung, Link-Klicks, Container und Adoption. |
| `WhisperM8/Views/TerminalFeedBatcher.swift` | Bündelt PTY-Bytes von Hintergrund-Panes (FIFO, ~12,5 Hz). |
| `WhisperM8/Views/AgentTerminalLinkInterceptor.swift` | Delegate-Proxy: fängt Links ab und verweigert OSC-52-Lesen. |
| `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift` | Baut die Session-Settings (Hooks, Send-Guard, gemergte Fragmente) mit 0600. |
| `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift` | Schreibt Settings und Event-Datei, beobachtet sie per vnode, liefert Events an den Koordinator. |
| `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift` | Liest Event-Dateien inkrementell mit Byte-Cursor, nur vollständige Zeilen. |
| `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift` | Besitzer des Laufzeitstatus: Hook-Primat, ID-Bindung, Abort- und Stau-Heilung, Effekte. |
| `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift` | Reine Zustandsmaschine (Signal -> Zustand + Effekte). |
| `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift` | Beobachtet Transcripts event- und pollbasiert, meldet nur Entscheidungen. |
| `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift` | Zustell-Tokens und Guard-Logik gegen wiedervorgelegte `[via whisperm8 chats]`-Prompts. |
| `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift` | Persistente Folgeauftrags-Queue (`agent-prompt-queue.json`), Reservierung, Reconcile. |
| `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift` | Stellt am Turn-Ende zu: höchstens einmal, mit Token vor dem Paste. |
| `WhisperM8/Services/AgentChats/AgentCrashRecovery.swift` | Marker laufender PTYs, Planer und Start-Verdrahtung der Wiederaufnahme. |
| `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift` | Startet `claude --bg`, parst die Short-ID; enthält den `DefaultProcessRunner`. |
| `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift` | Logs, Stop, Respawn, Remove, Healthcheck über kurzlebige CLI-Aufrufe. |
| `WhisperM8/Services/AgentChats/SupervisorJobReader.swift`, `SupervisorRosterReader.swift`, `ActiveBackgroundSessionTracker.swift` | Lesen Supervisor-`state.json` und `daemon/roster.json`; Anzeige des aktiven Jobs. |
| `WhisperM8/Services/AgentChats/AgentJobStore.swift`, `AgentJobState.swift` | Job-Verzeichnis, Zustandstabelle, Lock, atomare Writes, Orphan-Korrektur. |
| `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift`, `CodexTurnExecutor.swift`, `CodexExecRunner.swift` | Ein-Turn-Supervisor, Ergebnis-Mapping, `codex exec`-Prozess mit Idle-Watchdog. |
| `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift`, `SubagentJobRetention.swift` | Spiegelt Job-Zustand in den Workspace; räumt abgelaufene Spiegel samt Transcript-Archiv. |
| `WhisperM8/CLI/AgentCLICommand.swift`, `AgentCLIArguments.swift`, `AgentSuperviseCommand.swift` | CLI `whisperm8 agent` (run, send, list, status, wait, logs, stop, rm) und interner Detach-Modus. |
| `WhisperM8/Services/Shared/LoginShellEnvironment.swift` | Login-PATH und bereinigte Prozessumgebung für alle Spawns. |

## Zustände und Persistenz

Alles unter `~/Library/Application Support/WhisperM8/` (Ausnahme: externe Transcripts).

| Datei / Schlüssel | Schreiber | Inhalt |
|---|---|---|
| `claude-hooks/<local-id>.json` (0600) | Hook-Bridge je Launch | Settings mit Hooks und Fragmenten; Löschung nicht belegt. |
| `claude-session-events/<local-id>.jsonl` (0600) | Hook-Commands der CLI; Bridge legt sie leer neu an | Hook-Events, Byte-Cursor nur im Speicher. |
| `send-tokens/<uuid>.json` (0600) | App (stage), Guard-Prozess (consume) | Prompt-Hash + Zeitstempel, TTL 30 min. |
| `agent-prompt-queue.json` | `AgentPromptQueueStore` (Single-Writer App) | Folgeaufträge mit Zustand pending/delivering/delivered/failed/unknown. |
| `running-sessions.json` | `AgentCrashRecoveryMarker` | PID, laufende Session-IDs; Löschung bei sauberem Ende. |
| `agent-jobs/<short-id>/` | `whisperm8 agent`, Supervisor | `state.json`, Events, Report, last-message, pending-prompt, Supervisor-Log, Worktree. |
| `agent-jobs-archive/` | Retention | Archivierte Codex-Rollouts abgelaufener Jobs. |
| `AgentSessions.json` (Workspace) | `AgentSessionStore` | `externalSessionID`, `shouldLaunchOnOpen`, `hasLaunchedInitialPrompt`, Profil-Stempel. |
| In-Memory | Koordinator | Lifecycle-Zustände, Hook-live-Menge, Abort-Verdacht, zurückgestellte IDs, Fork-IDs. |

Kill-Switches (UserDefaults, `com.whisperm8.app`): `claudeHooksEnabled`, `chatsPromptGuardEnabled`, `agentEventDrivenWatchEnabled`, `agentCrashRecoveryEnabled`, `subagentJobRetentionEnabled`, `subagentJobRetentionDays`.

## Externe Abhängigkeiten

- **CLIs:** `claude` (Hooks, `--settings`, `--resume`, `--bg`, `attach`, `logs`, `rm`, `agents`) und `codex` (`exec --json`, `resume`); Auflösung nur über `LoginShellEnvironment` und `AgentCommandBuilder.commandPath`. `git` für Worktrees.
- **Dateiformate Dritter (lesend):** Claude-Transcripts und `~/.claude/jobs/*/state.json`, `<config-dir>/daemon/roster.json`, Codex-Rollouts. Keine Stabilitätszusage der Hersteller.
- **Netz:** keines in diesem Bereich; Modell- und Proxy-Pfade laufen in Claude/Codex bzw. im GPT-Backend.
- **TCC:** keine eigene Berechtigung; die PTY-Kinder erben die der App (Dateizugriff, Automation). Benachrichtigungsrecht für Fertig-Mitteilungen.
- **Eigenes Binary:** Der Send-Guard-Hook ruft den absoluten Pfad der App-Executable (`chats _prompt-guard`); App und CLI sind dasselbe Programm.

## Invarianten, die jeder Umbau erhalten muss

1. Echte CLI im PTY: kein SDK- oder Eigen-UI-Ersatz; Subprozesse nie mit der rohen `ProcessInfo`-Umgebung.
2. Der Koordinator ist der einzige Schreiber des Laufzeitstatus; nach dem ersten Hook-Event schlägt Hook-Evidenz das Transcript, und das Transcript erzeugt nie `awaitingInput`.
3. `Notification` bleibt ungehookt (sonst falsches „wartet" durch `idle_prompt`); `Stop` beendet den Turn, nicht den Prozess; `SessionEnd(clear|resume|compact)` ist ein In-Place-Wechsel.
4. Nur echte, von Claude vergebene externe IDs binden; Fork-IDs und leere Vordergrund-Sessions werden zurückgestellt; `--session-id` wird nie erzwungen. Resume folgt dem realen Transcript-Root, nicht dem Profilstempel.
5. Queue-Zustellung höchstens einmal (`delivering` vor dem Paste persistiert, nach Neustart `unknown`, kein Auto-Retry), nur am Turn-Ende, nie bei `awaitingInput`, FIFO nach `sequence`, ein Auftrag je Session gleichzeitig.
6. Send-Guard ist fail-open bei jedem Parse- oder IO-Fehler und bleibt auf Claude beschränkt; Token-Abgleich whitespace-tolerant; Retry nach nachgewiesenem Modellfehler erlaubt.
7. Hook-Event-Datei: Reads am Byte-Cursor, nur newline-terminierte Records, Initial-Drain zwischen Settings-Erzeugung und Watch; Settings-Dateien 0600; User- und Projekt-Settings bleiben unangetastet.
8. Der Watcher schreibt keinen Status selbst; Writeback nur bei gleicher Generation; stat-first; laufende Polls pro Session exklusiv; Fallback auf Polling bei Kill-Switch.
9. Job-Zustand nur über die zentrale Übergangstabelle unter Datei-Lock; `takenOver` ist terminal; Supervisor bearbeitet genau einen Turn; erste Thread-ID früh gesichert; stdout/stderr bis EOF gedraint; Idle-Watchdog statt Gesamt-Timeout.
10. Retention löscht nur, was auf Disk ohnehin weg ist; Rollout wird vorher archiviert (sonst Wiederaufnahme als normaler Codex-Chat).
11. Terminal: ein Controller und eine NSView je Session; `dismantleNSView` beendet nichts; Link-Proxy reicht alle übrigen Delegate-Callbacks durch und verweigert `clipboardRead`; Feed-Batcher verliert keine Bytes und bleibt FIFO; Beenden zuerst graceful (2x Ctrl+C), dann Kill, Zombie abholen.
12. Crash-Recovery ist opt-out, setzt nur `shouldLaunchOnOpen`, fasst Marker einer lebenden zweiten Instanz nicht an und wiederholt keine gestoppten oder archivierten Chats.
13. `CLAUDE_CODE_*`, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_CUSTOM_HEADERS` und `CCP_CONFIG_DIR` werden aus geerbtem Env entfernt; Routing nur über explizite Launch-Overrides.

## Top-Risiken (Verweise auf `findings.jsonl`)

- **Datenverlust und Fremdkonfiguration:** `LR-AK-017` (Theme-Writer überschreibt konkurrierende `~/.claude.json`-Änderungen; zusammengelegt mit `LR-SH-002/005/011`), `LR-AK-018` (Queue meldet Erfolg trotz fehlgeschlagenem Schreiben, Decode-Fehler wird als leere Queue zurückgeschrieben), `LR-AK-002/029` (Downgrade überschreibt neueres Workspace-Schema).
- **Sicherheit:** `LR-SH-001` (zusammengelegt mit `LR-SH-006/010`: Parent-Secrets gelangen in alle Chat-, Shell- und Subagent-Kinder).
- **Falscher Status oder falsche Zuordnung:** `LR-AK-019` (Watcher bleibt nach ID-Umbindung am alten Transcript), `LR-AK-020` (ignorierter Background-Fork verändert Vordergrundstatus und kann Queue auslösen), `LR-AK-021` (gestarteter Chat ohne Bindung startet still als neuer leerer Chat), `LR-AK-006` (Codex-Statusparser versteht Rollout-Format nicht).
- **Send-Guard:** `LR-AK-026` (blockt Erstzustellung bei Token-IO-Fehler, widerspricht der Fail-open-Zusage), `LR-AK-027` (Token mehrfach konsumierbar).
- **Jobs und Rennen:** `LR-AK-023` (zusammengelegt mit `LR-AK-032`: frühes Stop verhindert den Codex-Start nicht), `LR-AK-024` und `LR-AK-031` (Orphan-Korrektur und PID-Nachtrag überschreiben neuere Zustände), `LR-AU-001` (UI-Composer umgeht die PID-Transaktion), `LR-AK-028` (zusammengelegt mit `LR-AK-030`: Exit 0 ohne bestätigtes Turn-Ende gilt als Erfolg), `LR-AK-012` (Retention mit veraltetem Schutz-Snapshot).
- **Robustheit und Performance:** `LR-AK-022` (Background-Logs blockieren am vollen Pipe-Puffer), `LR-TRM-001` (Alle-stoppen blockiert den Main Thread linear pro PTY), `LR-SH-007` (Login-Shell-Abfrage kann den ersten Chatstart blockieren), `LR-AK-025` (Background-Task-Cache verwirft Resets).
- **Nicht im Register, aber offen:** Gleiche externe ID kann an mehrere lokale Zeilen gebunden werden (alt `C07`, siehe Oracle AC-41).
- **Doku-Drift:** `LR-DOK-006` (aktive Feature-Doku beschreibt abgelöste Transcript- und Titelpfade).
