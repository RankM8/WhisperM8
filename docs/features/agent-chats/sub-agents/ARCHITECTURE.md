---
status: aktiv
updated: 2026-07-09
---

# Sub-Agents — Architektur

Die Subagent-Architektur trennt drei Ebenen: die CLI erzeugt und steuert Jobs,
der Supervisor fährt jeweils einen Codex-Turn, und die App synchronisiert
persistierte Job-Snapshots in den Agent-Workspace. Die gemeinsame Wahrheit ist
das Job-Verzeichnis auf Disk.

## Persistenz

Produktive Job-Daten liegen unter:

`~/Library/Application Support/WhisperM8/agent-jobs/<short-id>/`

| Datei | Inhalt |
|-------|--------|
| `state.json` | `AgentJobState`, atomar per Temp-Datei und `rename` geschrieben. |
| `events.jsonl` | Roher `codex exec --json` Event-Strom, append-only. |
| `last-message.txt` | Letzte Antwort aus `--output-last-message`; parsebarer Report oder Rohtext-Fallback. |
| `pending-prompt.txt` | Prompt-Handoff von CLI/App an den nächsten Supervisor-Turn. |
| `supervisor.log` | stdout/stderr des detachten `agent-supervise`-Prozesses. |
| `report-schema.json` | JSON-Schema, das der Supervisor vor dem Turn schreibt. |
| `.claim.lock` | Advisory Lock für konkurrierende `send`-Claims. |
| `worktree/` | Optionaler Git-Worktree für Jobs mit `--worktree`. |

Workspace-Daten liegen weiterhin in
`~/Library/Application Support/WhisperM8/AgentSessions.json`; UI-Tab-State
liegt in `~/Library/Application Support/WhisperM8/agent-ui-state.json`.
`~/.claude/` und `~/.codex/` bleiben externe Systeme: WhisperM8 liest daraus
Subagent-Definitionen beziehungsweise Codex-Transkripte, schreibt aber die
Job-Wahrheit in den eigenen Application-Support-Bereich.

## Komponenten

- `WhisperM8/Services/AgentChats/AgentJobStore.swift` verwaltet das Job-Verzeichnis, atomare State-Writes, Short-IDs, Liveness-Korrektur, Prompt-Handoff, Logs und Job-Removal.
- `WhisperM8/Services/AgentChats/AgentJobState.swift` beschreibt den persistierten Vertrag inklusive Status, Thread-ID, Parent-Information, Sandbox, Turn-Parametern, Worktree und Metriken.
- `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift` konsumiert genau einen Pending-Prompt, startet `codex exec`, schreibt Events und finalisiert `done`, `failed` oder `stopped`.
- `WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift` startet dasselbe WhisperM8-Binary detached als `agent-supervise <short-id>` und leitet stdout/stderr nach `supervisor.log`.
- `WhisperM8/CLI/AgentSuperviseCommand.swift` löst den Supervisor per `setsid()` vom Terminal, ignoriert SIGHUP und behandelt SIGTERM als sauberen Stop.
- `WhisperM8/Services/AgentChats/AgentJobDirectoryMonitor.swift` beobachtet das Job-Root per FSEvents und filtert nur `state.json` und `last-message.txt` als sync-relevante Änderungen.
- `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift` liest Jobs off-main, korrigiert Orphans, merged sie in den Workspace und füllt Runtime-Modell, Status-Dots und Unread-Marker.
- `WhisperM8/Services/AgentChats/AgentJobRuntimeModel.swift` hält ephemere UI-Snapshots pro lokaler Session-ID und die Zahl aktiver Kinder pro Parent.
- `WhisperM8/Services/AgentChats/SubAgentDiscovery.swift` scannt Claude-Subagent-Definitionen unter `<project>/.claude/agents/*.md` und `~/.claude/agents/*.md` und extrahiert Frontmatter-Felder für die Dispatch-Anzeige.
- `WhisperM8/Services/AgentChats/ProcessAncestry.swift` liest Prozess-Vorfahren und Startzeiten per `sysctl`, damit parentlose CLI-Aufrufe einer laufenden Claude-PTY-Session zugeordnet werden können.
- `WhisperM8/Views/SubagentJobDetailView.swift` ist die nicht-PTY Detailansicht für Jobs vor der Übernahme.
- `WhisperM8/Views/AgentChatsView+Subagents.swift` schreibt `takenOver` und startet den normalen Codex-Resume-Pfad im Terminal-Tab.

`SubAgentDiscovery` gehört zur Claude-Subagent-Definitionsebene: Es liest
Felder wie `permissionMode`, `model`, `tools` und `isolation: worktree` aus
Markdown-Dateien. Das ist nicht die Discovery der Codex-Subagent-Jobs selbst;
Jobs entstehen erst durch `whisperm8 agent run` und werden über
`AgentJobStore` gefunden.

## Datenfluss: run

1. `AgentRunCLI` parst den Prompt und die Optionen, prüft `codex`, erzeugt eine
   Short-ID und schreibt `state.json` mit `spawning`.
2. Ohne explizites `--parent` schreibt der Startpfad die PID-Kette aus
   `ProcessAncestry.ancestorChain()` und optional den Best-Guess
   `parentProcessID` für einen `claude`-Vorfahren.
3. Bei `--worktree` legt `AgentWorktreeManager` einen Worktree im
   Job-Verzeichnis an und speichert Pfad und Branch im State.
4. Der Prompt wird zusammen mit dem WhisperM8-Report-Suffix als
   `pending-prompt.txt` gespeichert.
5. `AgentSupervisorLauncher` startet IMMER den internen, detachten
   `agent-supervise`-Prozess und persistiert dessen PID als Liveness-Anker.
   Mit `--wait` wird der CLI-Prozess zusätzlich zum Zuschauer
   (`followAndEmit`: state.json-Polling mit Orphan-Korrektur +
   events.jsonl-Tail) — stirbt er (Bash-Timeout, Ctrl-C), läuft der Turn
   weiter; `agent wait <id>` hängt sich wieder an. Turns stoppt nur
   `agent stop`. (Ersetzt die frühere E1-Inline-Supervision, die den Turn
   mit dem Waiter sterben ließ — Ursache der „supervisor died"-Fails.)

## Datenfluss: Supervisor-Turn

1. Der Supervisor liest und löscht `pending-prompt.txt`.
2. Er markiert den Job unter dem Job-Lock als `running` und trägt seine PID ein.
3. Er schreibt `report-schema.json` und baut einen `CodexTurnRequest`.
4. `CodexExecRunner` startet `codex -a never exec --json`, streamt stdout als
   JSONL und setzt `currentDirectoryURL` auf das effektive CWD.
5. Der `JobDirectorySink` hängt jede rohe Event-Zeile an `events.jsonl` an und
   speichert die erste Codex-Thread-ID sofort in `state.json`.
6. Beim Abschluss schreibt der Supervisor Metriken, löscht die Supervisor-PID
   und wechselt auf `done`, `failed` oder `stopped`.

Ein Turn ist immer ein Prozess. `send` startet keinen long-lived Worker,
sondern reserviert einen ruhenden Job erneut als `spawning`, schreibt einen
neuen Pending-Prompt und startet wieder genau einen Supervisor-Turn.

## Datenfluss: App-Sync

`AgentJobDirectoryMonitor` beobachtet das Job-Root mit kurzem Debounce.
Änderungen an `events.jsonl`, Temp-Dateien und `supervisor.log` lösen keinen
Workspace-Sync aus. `AgentJobWorkspaceSync` liest bei Launch, Foreground und
FSEvent alle Jobs über `readAllCorrected()`, erkennt Statusübergänge, setzt
Unread-Marker bei abgeschlossenen Turns und ruft
`AgentSessionStore.mergeSubagentJobs`.

`mergeSubagentJobs` ist idempotent. Bekannte Jobs aktualisieren nur echte
Änderungen wie Codex-Thread-ID, Parent, CWD, Titel oder Aktivität. Neue Jobs
werden als `AgentChatSession(provider: .codex, kind: .subagentJob)` angelegt.
Wenn ein Parent existiert, übernimmt der Job dessen Projekt; sonst nutzt der
Merge das Job-CWD als Projekt-Fallback.

## Effektive Codex-Defaults

Jobs ohne explizites `--model` beziehungsweise `--effort` werden im
Workspace auf die Top-Level-Werte `model` und `model_reasoning_effort` aus
`~/.codex/config.toml` projiziert. `CodexGlobalConfigReader` liest dafür nur
den Bereich vor der ersten TOML-Sektion und cached das Ergebnis anhand von
Änderungszeit und Dateigröße. Ist die Datei nicht statbar oder vorübergehend
unlesbar, gilt der letzte erfolgreich gelesene Stand, andernfalls ein leerer
Default.

Die Fallback-Reihenfolge je Feld lautet: expliziter Wert aus `state.json`,
Top-Level-Wert aus `config.toml`, beim erstmaligen Anlegen einer Session der
eingebaute App-Default. Bei späteren Syncs korrigiert `mergeSubagentJobs` auch
bestehende Session-Metadaten auf das so ermittelte effektive Modell und den
Default-Effort. Der Vertrag gegenüber `~/.codex/` bleibt strikt read-only:
WhisperM8 liest die Konfiguration, beschreibt dieses externe Verzeichnis aber
nie.

## Parent-Zuordnung

`$CLAUDE_SESSION_ID` ist kein Code-Vertrag. Als Laufzeitverhalten wurde am
2026-07-08 validiert, dass Claude Code sie in der Bash-Umgebung nicht
bereitstellt; WhisperM8 löst Parents deshalb zweistufig auf.

Wenn `--parent <session-id>` gesetzt ist, speichert der Job diese externe
Claude-Session-ID direkt. Ohne `--parent` speichert der CLI-Start die
Vorfahren-PID-Kette des Spawn-Prozesses. Beim App-Sync matcht
`AgentJobWorkspaceSync.matchParentPid` einen Kandidaten aus dieser Kette gegen
die `shellPids` laufender PTY-Controller. Ein Startzeit-Check verhindert, dass
später wiederverwendete PIDs dauerhaft falsch zugeordnet werden.

## UI-Projektion

`AgentJobRuntimeModel` ist nicht persistiert. Es hält Job-Snapshots,
aktive-Kinder-Zähler und lokale Übernahme-Marker, damit die UI sofort reagiert
und trotzdem beim nächsten Disk-Sync zur Wahrheit zurückkehrt. Die Sidebar
gruppiert `.subagentJob`-Sessions über
`subagentParentSessionID == parent.externalSessionID`. Aktive und fehlerhafte
Kinder bleiben sichtbar; fertige Kinder werden im Footer gezählt und
aufklappbar gemacht.

Die Hauptfläche rendert `SubagentJobDetailView`, solange
`AgentJobRuntimeModel.isTakenOver(session.id)` false ist. Nach der Übernahme
setzt `takeOverSubagentJob` den State auf `takenOver`, repariert
`externalSessionID`, `hasLaunchedInitialPrompt` und `subagentCwd`, markiert den
Job lokal als übernommen und startet die Session über den bestehenden
Codex-PTY-Pfad.

## Invarianten und Gotchas

- `state.json` ist die Job-Wahrheit; Decode-Fehler einzelner Jobs werden übersprungen, nicht als Workspace-Korruption behandelt.
- `spawning` und `running` gelten als aktiv. Eine vorhandene, tote Supervisor-PID wird best effort zu `failed` korrigiert; `spawning` ohne PID erst nach 30 Sekunden. `running` ohne `supervisorPid` bleibt dagegen unverändert `running`.
- Der Liveness-Anker `supervisorPid` nutzt `kill(pid, 0)`; bei PID-Reuse kann ein toter Job theoretisch für lebendig gehalten werden.
- `spawning` ohne PID ist kurz erlaubt; hängt es länger als 30 Sekunden, wird es als Spawn-Timeout markiert.
- Der Codex-Runner hat einen Idle-Watchdog: Kommen 1800 Sekunden keine stdout-Bytes, terminiert er den `codex`-Prozess per SIGTERM und der Job endet als `failed` mit `failureReason` `stalled: keine Events mehr vom codex-Prozess (Idle-Watchdog)`. Beliebige stdout-Daten spannen den Timer neu, auch ohne vollständiges oder parsebares Event.
- `send` nimmt `.claim.lock` und reserviert ruhende Jobs als `spawning`, bevor der Prompt geschrieben und der Supervisor gestartet wird.
- `takenOver` ist terminal und sperrt `agent send` dauerhaft; die App erlaubt Übernahme nur auf nicht aktiven Jobs.
- Ein Report mit `status: failure` kann bei State `done` trotzdem Exit-Code `2` ergeben.
- Das Laufzeitverhalten von `codex exec resume` wurde am 2026-07-08 validiert: `resume` akzeptiert keine `--sandbox`- und `--cd`-Flags; Sandbox wird per `-c sandbox_mode=...` gesetzt, das CWD über `Process.currentDirectoryURL`.
- Für `workspace-write` löst der Supervisor das gemeinsame Git-Verzeichnis per `git rev-parse --git-common-dir` auf und setzt es als `writable_roots`-Override, weil Commits sonst an `.git/index.lock` scheitern können.
- Generische `--config key=value`-Overrides werden nach den eingebauten Codex-Configs angehängt und können deshalb auch die eingebauten Werte übersteuern.
- In `AgentWorkspaceStore`-Mutationen laufen keine Subprozesse; Git-Branch-Lookups für neue Fallback-Projekte werden vor der Mutation berechnet.
- `events.jsonl` wird nicht für Workspace-Syncs beobachtet, weil laufende Turns viele Append-Events erzeugen.
- `agent rm` löscht das Job-Verzeichnis, lässt die Codex-Session unter `~/.codex/sessions/` aber bestehen.

## Test-Cluster

- `Tests/WhisperM8Tests/AgentCLIArgumentsTests.swift`, `AgentCLIArgumentsPreviewTests.swift` und `AgentCLICommandTests.swift` decken Parser, Exit-Code-Vertrag und CLI-Zustandskonflikte ab.
- `Tests/WhisperM8Tests/AgentJobStateTests.swift`, `AgentJobStoreTests.swift` und `AgentJobSupervisorTests.swift` decken State-Übergänge, Persistenz, Liveness und Supervisor-Finalisierung ab.
- `Tests/WhisperM8Tests/AgentJobDirectoryMonitorTests.swift` und `AgentJobWorkspaceSyncTests.swift` decken FSEvents-Filter, Sync-Merge und Parent-Auflösung ab.
- `Tests/WhisperM8Tests/ProcessAncestryTests.swift` deckt PID-Ketten und Parent-Matching ab.
- `Tests/WhisperM8Tests/SubAgentDiscoveryTests.swift` deckt Frontmatter-Discovery für Claude-Subagent-Definitionen ab.
- `Tests/WhisperM8Tests/AgentSidebarTests.swift` deckt Subagent-Kindgruppierung, sichtbare Kinder, Footer und Statusmengen ab.

## Keywords

config.toml, effektives Modell, Default-Effort
