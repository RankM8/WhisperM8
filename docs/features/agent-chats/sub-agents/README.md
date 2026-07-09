---
status: aktiv
updated: 2026-07-09
---

# Sub-Agents

Codex-Subagent-Jobs sind headless Codex-Aufträge, die über `whisperm8 agent`
gestartet und von WhisperM8 selbst beaufsichtigt werden. Ein Job hat eine
kurze ID, ein Arbeitsverzeichnis, einen persistierten Zustand und mindestens
einen Codex-Turn. Die App liest dieselben Dateien wie die CLI und stellt den
Job deshalb als normale Agent-Chat-Session dar, solange er nicht als
interaktiver Chat übernommen wurde.

## Was ist ein Job?

Ein Subagent-Job ist kein laufender PTY-Tab. Beim Start legt die CLI ein
Job-Verzeichnis unter `~/Library/Application Support/WhisperM8/agent-jobs/`
an, schreibt den Prompt als `pending-prompt.txt` und startet einen
Supervisor-Prozess. Dieser Supervisor fährt genau einen `codex exec`-Turn,
schreibt Codex-Events nach `events.jsonl`, übernimmt die Codex-Thread-ID aus
dem ersten `thread.started`-Event und beendet den Turn mit einem strukturierten
Report in `last-message.txt`.

Die App spiegelt diese Job-Verzeichnisse in `AgentSessions.json`. Dadurch
taucht ein Subagent in der Sidebar, der Tab-Leiste und in der normalen
Workspace-Persistenz auf, bleibt aber fachlich ein eigener Job mit
`state.json` als Wahrheit.

## Job-Lebenszyklus

| Zustand | Bedeutung |
|---------|-----------|
| `spawning` | Job ist angelegt, Prompt liegt bereit, Supervisor wird gestartet oder startet gerade. |
| `running` | Supervisor hat den Prompt konsumiert und ein `codex exec` läuft. |
| `done` | Der Turn ist technisch abgeschlossen; ein Report mit `status: failure` kann trotzdem den CLI-Exit-Code `2` ergeben. |
| `failed` | Supervisor, Codex-Run, Report-Schema oder Umgebung sind fehlgeschlagen. |
| `stopped` | Der laufende Turn wurde per SIGTERM sauber beendet. |
| `takenOver` | Der Job wurde dauerhaft als interaktiver Codex-Chat übernommen; `agent send` und der Job-Composer sind danach deaktiviert. |

Der normale Startpfad ist `spawning → running → done|failed|stopped`. Ein
Folge-Prompt über `send` reserviert ruhende Jobs atomar wieder als `spawning`
und startet einen weiteren Turn per `codex exec resume`. Die Übernahme ist
terminal: Sobald ein Job `takenOver` ist, zieht sich der Job-Supervisor zurück
und der Verlauf läuft über den normalen Codex-PTY-Resume-Pfad weiter.

## Bedienung per CLI

Die Detaildokumentation der CLI gehört nach `docs/features/cli/`; hier nur die
Subagent-Sicht:

| Befehl | Zweck |
|--------|-------|
| `whisperm8 agent run "<prompt>"` | Startet einen neuen Job, standardmäßig detached; mit `--wait` synchron, mit `--json` maschinenlesbar. |
| `whisperm8 agent send <id> "<prompt>"` | Startet einen Folge-Turn auf einem ruhenden Job; verweigert aktive oder übernommene Jobs. |
| `whisperm8 agent list` | Listet alle bekannten Jobs mit Short-ID, Status, Turn-Zahl, CWD und gekürztem Intent. |
| `whisperm8 agent status <id>` | Zeigt Zustand, Metriken und Report; `--json` liefert das State-Objekt plus Report. |
| `whisperm8 agent logs <id>` | Gibt die letzten Zeilen aus `events.jsonl` aus; `--tail N` steuert die Menge. |
| `whisperm8 agent stop <id>` | Sendet SIGTERM an den Supervisor eines aktiven Turns. |
| `whisperm8 agent rm <id>` | Löscht das Job-Verzeichnis; ein von WhisperM8 angelegter Worktree wird nur entfernt, wenn Git ihn sauber entfernen kann. |

Die Exit-Codes sind Teil des Maschinenvertrags: `0` ok, `1` Usage-Fehler,
`2` Job fehlgeschlagen oder Report `failure`, `3` Zustandskonflikt und `4`
Umgebungsproblem.

## Darstellung in der App

Subagent-Jobs erscheinen als `AgentSessionKind.subagentJob` im Workspace. Wenn
die Parent-Session bekannt ist, rendert die Sidebar den Job eingerückt unter
dieser Claude-Session. Laufende und fehlgeschlagene Kinder bleiben direkt
sichtbar; fertige Kinder werden im Subagent-Footer gesammelt und können
aufgeklappt werden. Jobs ohne auffindbaren Parent werden als normale Rows im
Projekt-Fallback angezeigt.

Die Detailfläche rendert `SubagentJobDetailView` statt eines Terminals. Sie
zeigt den Auftrag, Status, Report, Metriken, Live-Transcript aus dem
Codex-Rollout-JSONL, einen Stop-Button für aktive Turns, einen Composer für
Folge-Prompts und einen Button zur interaktiven Übernahme. Nach der Übernahme
wechselt die App auf die normale `AgentSessionDetailView` mit PTY.

## Abgrenzung

**Claude Background-Agents** verwenden `claude --bg` und `claude attach`. Sie
werden vom Claude-Daemon verwaltet, in WhisperM8 als `backgroundChat`
dargestellt und über Claude-Hooks beobachtet. Codex-Subagents haben kein
externes Background-System: WhisperM8 ist Store, Supervisor und UI-Brücke.

**Codex-Exec** ist die niedrigere Integrationsschicht um `codex exec --json`,
Event-Parsing, Report-Schema, Sandbox-Argumente und Streaming. Ein
Subagent-Job benutzt diese Schicht, ergänzt aber Job-Persistenz,
Supervisor-Lifecycle, Workspace-Merge, Sidebar-Integration und Übernahme.

## Schlüsseldateien

- `WhisperM8/CLI/AgentCLICommand.swift` ist der Einstieg für `run`, `send`, `list`, `status`, `logs`, `stop` und `rm`.
- `WhisperM8/CLI/AgentCLIArguments.swift` definiert Parser, Optionen und Exit-Code-Vertrag für den `agent`-Namespace.
- `WhisperM8/CLI/AgentSuperviseCommand.swift` ist der interne Detach-Modus `agent-supervise <short-id>`.
- `WhisperM8/Services/AgentChats/AgentJobStore.swift` ist der Disk-Store für `state.json`, `events.jsonl`, `last-message.txt`, `pending-prompt.txt` und `supervisor.log`.
- `WhisperM8/Services/AgentChats/AgentJobState.swift` definiert den persistierten Zustand und die erlaubten Übergänge.
- `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift` fährt genau einen Codex-Turn und finalisiert den Job-Zustand.
- `WhisperM8/Views/SubagentJobDetailView.swift` rendert die Job-Detailansicht mit Report, Live-Transcript, Composer, Stop und Übernahme.
- `WhisperM8/Views/AgentChatsView+Subagents.swift` implementiert die dauerhafte Übernahme als interaktiven Codex-Chat.

## Keywords

Subagents, Sub-Agenten, Codex-Subagent, Codex-Job, headless Codex, WhisperM8
agent, Folge-Turn, Job nachsteuern, Job stoppen, Job übernehmen, interaktiver
Chat, Parent-Session, Sidebar-Kind, eingerückte Jobs, Agent-Report,
Codex-Report, `whisperm8 agent`, `agent run`, `agent send`, `agent list`,
`agent status`, `agent logs`, `agent stop`, `agent rm`, `AgentJobStore`,
`AgentJobState`, `AgentJobSupervisor`, `AgentSupervisorLauncher`,
`AgentJobDirectoryMonitor`, `AgentJobWorkspaceSync`, `AgentJobRuntimeModel`,
`SubagentJobDetailView`, `takeOverSubagentJob`, `SubAgentDiscovery`,
`ProcessAncestry`, `CodexTurnRequest`, `CodexExecRunner`,
`AgentSessionKind.subagentJob`, `takenOver`, `spawning`, `running`, `done`,
`failed`, `stopped`.
