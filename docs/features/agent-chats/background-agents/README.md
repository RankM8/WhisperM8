---
status: aktiv
updated: 2026-07-09
---

# Background-Agents — claude --bg und Hook-Bridge

Claude-Background-Agents sind von Claude Code gehostete Hintergrund-Sessions.
WhisperM8 startet sie mit `claude --bg`, speichert die vom Claude-Supervisor
ausgegebene Short-ID und öffnet danach einen normalen Agent-Chat-Tab, der per
`claude attach <short-id>` an den laufenden Job andockt.

Die eigentliche Laufzeit liegt nicht in WhisperM8. Der Spawn-Prozess ist ein
kurzer Subprozess, der die Short-ID ausgibt und beendet wird; die Session
läuft danach im externen Claude-Supervisor weiter. WhisperM8 persistiert
dauerhaft die lokale Tab-Session, die Short-ID, ausgewählte Dispatch-Optionen
und den normalen `AgentChatStatus`; der Live-Runtime-Status aus Hooks,
Transkripten und Prozess-/Lifecycle-Signalen ist ephemer. Supervisor-State
nutzt WhisperM8 separat für Tails, Aktivitätsanzeige und Agent-View-Tracking,
nicht als Persistenzquelle des `AgentSessionRuntimeStatus`.

## Bedienung in der App

Der Startpfad beginnt im aktiven Projekt. Das Dispatch-Sheet nimmt einen
initialen Prompt, optional einen Claude-Sub-Agent und optional einen
Permission-Mode entgegen. Diese Sub-Agent-Auswahl meint Claude-Subagents aus
`~/.claude/agents/` und `<projekt>/.claude/agents/`: WhisperM8 entdeckt sie
read-only und gibt ihren Namen als `--agent <name>` an `claude --bg` weiter.
Nach dem Absenden legt WhisperM8 sofort eine lokale `.backgroundChat`-Session
an, öffnet den Tab und startet den Spawn im Hintergrund.

Bei erfolgreichem Spawn schreibt die App die Short-ID auf die Session und
startet den PTY-Tab über den bestehenden Session-Startpfad. Für den User sieht
der Tab dadurch wie ein normaler Claude-Chat aus, technisch läuft im PTY aber
`claude attach <short-id>`. Wenn der Spawn keine Short-ID liefert oder der
Subprozess fehlschlägt, löscht WhisperM8 die Stub-Session wieder, weil ein
Attach ohne Short-ID nicht möglich ist.

Background-Tabs zeigen im Header ein `BG`-Badge und die Short-ID. Das
Session-Menü bietet für Background-Sessions `Logs anzeigen`, `Stoppen`,
`Respawn` und `Vom Supervisor entfernen`. `Logs anzeigen` ruft einmalig
`claude logs <short-id>` auf und zeigt stdout plus stderr read-only im Sheet.
`Stoppen`, `Respawn` und `rm` laufen ebenfalls als einmalige Claude-CLI-
Subprozesse; bei `rm` räumt WhisperM8 zusätzlich den lokalen Tab-State auf.

Beim Öffnen des Fensters prüft WhisperM8 gespeicherte Background-Sessions mit
Short-ID einmal gegen den Claude-Supervisor. Erkennt `claude logs <short-id>`
eine unbekannte ID, archiviert die App die lokale Session, damit nicht
attachbare Tabs aus der Sidebar verschwinden.

## Dispatch-Troubleshooting

Claude Background-Agents setzen Claude Code mit Agent View voraus. Die externe
Claude-Code-Referenz nennt dafür Version 2.1.139 oder neuer; passend dazu
meldet `BackgroundAgentSpawner` eine nicht parsebare Short-ID als möglichen
Hinweis auf eine zu alte Claude-Code-Version.

Zwei externe Gates schalten Agent View hart ab: `disableAgentView: true` in
Claude-Settings und die Environment-Variable
`CLAUDE_CODE_DISABLE_AGENT_VIEW=1`. In beiden Fällen sind nach Claude-Code-
Laufzeitverhalten `claude agents`, `claude --bg`, `/background` und der
Supervisor deaktiviert; WhisperM8 kann dann keinen Background-Agent spawnen.

Für `--permission-mode bypassPermissions` gilt ebenfalls ein externes
Claude-Code-Verhalten: Claude verlangt, dass der Modus mindestens einmal
interaktiv akzeptiert wurde. Das Dispatch-Sheet kann den Mode als
`backgroundPermissionMode` speichern und an `claude --bg` übergeben, ersetzt
aber diese Vorab-Akzeptanz nicht.

## Externe Laufzeit-Gotchas

Diese Punkte stammen aus der Claude-Agent-View-Referenz und beschreiben
externes Claude-Code-Laufzeitverhalten, nicht WhisperM8-eigene Persistenz:

- Sleep oder Shutdown stoppen lokale Background-Sessions; nach dem Aufwecken sind sie bei Claude als `Stopped` markiert und können per Attach, Peek, Reply oder `claude respawn --all` wiederbelebt werden.
- Eine fertige Session, die ungefähr eine Stunde unattached bleibt und nichts mehr tut, wird vom Claude-Supervisor gestoppt; das Transcript bleibt auf Disk und ein späteres Attach startet wieder einen Prozess.
- Background-Sessions schreiben in isolierten Claude-Worktrees unter `.claude/worktrees/`, sobald sie im Repository editieren; beim Löschen der Session entfernt Claude auch diese Worktree, daher müssen Änderungen vorher gemerged oder gepusht sein.

## Hook-Bridge

Die Hook-Bridge verbindet lokale WhisperM8-Sessions mit den echten
Claude-Session-IDs und Statusereignissen. Vor dem Spawn erzeugt WhisperM8 eine
temporäre Claude-Settings-Datei und ein leeres Event-JSONL im App-Support-
Verzeichnis. Der Spawn erhält diese Datei per `--settings <path>`, damit auch
die vom Supervisor gestartete Background-Session dieselben Hooks kennt.

Die generierten Hooks hängen Claude-Hook-Payloads als JSON-Zeilen an das
session-spezifische Event-File. WhisperM8 beobachtet dieses File per
`DispatchSource`, nicht per Polling. Sobald `SessionStart` eintrifft, bindet
der Status-Koordinator die externe `session_id` an die lokale Session und
aktualisiert den Transcript-Watcher. Weitere Hook-Events treiben den
Runtime-Status: `UserPromptSubmit`, Tool-Events und Tool-Fehler bedeuten
Aktivität, `PermissionRequest` und bestimmte `PreToolUse`-Tools markieren
`needs input`, `Stop` beendet einen Turn und `SessionEnd` beendet die
Background-Session, sofern der Reason kein In-Place-Wechsel ist.

Damit ersetzt die Bridge grobes Transcript-Polling für hook-live Claude-
Sessions bei working/idle/awaiting. Transcript-Heuristiken bleiben als
Fallback für stumme Hooks, deaktivierte Hooks und Bookkeeping erhalten; eine
bewusste Ausnahme ist `turnAborted`, weil ein ESC-Abbruch über das Transcript
erkannt wird und auch eine hook-live Session von `working` oder
`awaitingInput` zurück auf `ready` setzen kann.

## Externe Claude-Dateien

Für Background-Agents liest WhisperM8 externe Claude-Daten defensiv:
`~/.claude/jobs/<short-id>/state.json` liefert Supervisor-Snapshots und
`linkScanPath` zeigt auf die Claude-JSONL, aus der Tails und Aktivität gelesen
werden. Globale Hook-Settings unter `~/.claude/settings.json` und
`~/.claude/settings.local.json` werden nur inspiziert, damit die Settings-Seite
über potenziell doppelte Hooks warnen kann.

Die Hook-Bridge verändert diese externen Claude-Settings nicht. Ihre
generierten Settings- und Event-Dateien liegen unter
`~/Library/Application Support/WhisperM8/`. Separat davon synchronisiert
`ClaudeThemeWriter` den Claude-Theme-Key in `~/.claude/settings.json`; diese
Theme-Synchronisation ist keine Background-Agent-Persistenz.

## Abgrenzung zu Codex-Sub-Agents

Codex-Sub-Agents unter [../sub-agents/](../sub-agents/) sind WhisperM8-eigene
headless Codex-Jobs. Dort erzeugt WhisperM8 das Job-Verzeichnis, startet den
Supervisor-Prozess, schreibt `state.json`, sammelt `codex exec --json`-Events
und kann Folge-Turns über `whisperm8 agent send` fahren.

Claude-Background-Agents benutzen dagegen das externe Background-System von
Claude Code. WhisperM8 startet nur `claude --bg`, speichert die Short-ID,
attached per `claude attach` und beobachtet Status über Hook-Events und
Supervisor-Dateien.

## Schlüsseldateien

- `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift` orchestriert Dispatch, Short-ID-Persistenz, Attach-Start, Lifecycle-Aktionen, Logs und Startup-Healthcheck für Background-Tabs.
- `WhisperM8/Views/BackgroundDispatchModal.swift` stellt Prompt, Sub-Agent-Auswahl und Permission-Mode für den Start eines neuen Background-Agent bereit.
- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift` startet `claude --bg`, injiziert optional `--settings`, parst die Short-ID und kapselt Timeout- und Prozessfehler.
- `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift` kapselt `claude logs`, `stop`, `respawn`, `rm` und den Short-ID-Healthcheck.
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` baut sowohl die `claude --bg`-Argumente als auch den späteren `claude attach <short-id>`-PTY-Launch.
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift` schreibt Hook-Settings, überwacht Event-Dateien per `DispatchSource` und liefert Hook-Events an den Status-Koordinator.
- `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift` erzeugt die temporäre Claude-Settings-JSON mit den von WhisperM8 getrackten Hook-Events.
- `WhisperM8/Services/AgentChats/SupervisorJobReader.swift` liest `~/.claude/jobs/<short-id>/state.json` defensiv und findet die zuletzt aktive Supervisor-Session.

## Keywords

Background-Agent, Hintergrund-Agent, Claude Background Agent, Claude
Hintergrund-Session, Claude Supervisor, Claude Daemon, `claude --bg`, `claude
agents`, Agent View, `claude attach`, `claude logs`, `claude stop`, `claude
respawn`, `claude rm`, Short-ID, Background-Short-ID, Hook-Bridge, Claude
Hooks, SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, PermissionRequest, Stop, needs input, wartet auf Eingabe,
Berechtigungsdialog, Plan-Freigabe, AskUserQuestion, ExitPlanMode,
event-driven, DispatchSource, kein Polling, `disableAgentView`,
`CLAUDE_CODE_DISABLE_AGENT_VIEW`, `bypassPermissions`,
`AgentSessionKind.backgroundChat`, `BackgroundDispatchRequest`,
`BackgroundDispatchModal`, `backgroundPermissionMode`,
`BackgroundAgentSpawner`, `BackgroundAgentLifecycle`, `SupervisorJobReader`,
`ClaudeHookBridge`, `ClaudeHookEventStore`, `ClaudeHookSettingsBuilder`,
`ClaudeHookPaths`, `AgentSessionStatusCoordinator`,
`AgentSessionStateMachine`, `ActiveBackgroundSessionTracker`,
`ClaudeActiveSessionResolver`, `ExternalClaudeHooksInspector`,
`ClaudeThemeWriter`, Startup-Healthcheck, `HealthCheck`, verwaist, orphan,
Zombie-Tab, `binding_hook_silent`.
