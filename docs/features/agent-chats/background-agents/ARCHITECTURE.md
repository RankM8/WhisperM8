---
status: aktiv
updated: 2026-07-09
---

# Background-Agents — Architektur

Die Background-Agent-Architektur trennt drei Ebenen: Claude Code hostet den
Job im externen Supervisor, WhisperM8 persistiert den lokalen Tab samt
Short-ID, und die Hook-Bridge liefert die Ereignisse, mit denen lokale Session
und externe Claude-Session zusammengeführt werden.

## Persistenz und externe Pfade

WhisperM8 speichert lokale Sessions weiterhin in
`~/Library/Application Support/WhisperM8/AgentSessions.json`. Für die Hook-
Bridge liegen pro lokaler Session eine Settings-Datei unter
`~/Library/Application Support/WhisperM8/claude-hooks/<uuid>.json` und eine
Event-Datei unter
`~/Library/Application Support/WhisperM8/claude-session-events/<uuid>.jsonl`.
Beide Dateien werden mit POSIX-0600 angelegt.

`ClaudeHookBridge.stopTracking` beendet nur DispatchSource, Timer und offene
File-Deskriptoren; Settings- und Event-Dateien bleiben bewusst auf Disk. Beim
App-Start ruft `WhisperM8App` den `AgentSessionRetentionService` mit den
aktuell lebenden lokalen Session-IDs auf. Dieser Retention-Job löscht
verwaiste Hook-Settings und Hook-Event-Dateien, deren UUID-Dateiname zu keiner
aktuellen Session mehr gehört.

Der Claude-Supervisor liegt außerhalb der App. `SupervisorJobReader` liest
Snapshots aus `~/.claude/jobs/<short-id>/state.json`; das Format ist ein
Claude-Implementation-Detail und wird deshalb tolerant geparst. Aus dem State
werden nur Short-ID, Name, Intent, CWD, Supervisor-State, `linkScanPath` und
`updatedAt` verwendet. `linkScanPath` ist der Weg zur Claude-JSONL, deren
mtime als Aktivitätsquelle dient.

Globale Claude-Hook-Settings unter `~/.claude/settings.json` und
`~/.claude/settings.local.json` werden von `ExternalClaudeHooksInspector` nur
gelesen. Die von WhisperM8 generierten Hook-Settings liegen im App-Support und
werden per `--settings <path>` an Claude übergeben. Abgegrenzt davon schreibt
`ClaudeThemeWriter` den `theme`-Key in `~/.claude/settings.json`, wenn die
Theme-Synchronisation aktiv ist.

## Spawn und Attach

`AgentChatsView+BackgroundAgents.dispatchBackgroundAgent` legt zuerst eine
lokale `.backgroundChat`-Session ohne Short-ID an. Dadurch erscheint der Tab
sofort in Sidebar und Tab-Leiste, bleibt aber bis zum erfolgreichen Spawn
pending. Vor dem Spawn fordert die View beim `AgentSessionStatusCoordinator`
einen Hook-Settings-Pfad an; wenn Hooks deaktiviert sind oder das Schreiben
fehlschlägt, läuft der Spawn ohne Hook-Bridge.

`BackgroundAgentSpawner.spawn` prüft, dass der übergebene Projektpfad
existiert, löst `claude` über `AgentCommandBuilder.commandPath` auf und
startet einen einmaligen Subprozess. Der Check unterscheidet nicht zwischen
Datei und Verzeichnis; das eigentliche CWD-Setzen passiert beim Prozessstart.
Die Argumente kommen aus
`AgentCommandBuilder.backgroundSpawnArguments`: `--settings` steht vor
`--bg`, danach folgen optional `--agent`, `--permission-mode`,
User-Extra-Argumente und der initiale Prompt. Der Prozess erhält das korrigierte
Login-Shell-Environment, `NO_COLOR=1`, `CLICOLOR=0`, geschlossene stdin-Pipes
und ein Timeout von 30 Sekunden.

Der Parser akzeptiert mehrere von Claude beobachtete stdout-Formen und entfernt
ANSI-Sequenzen vor der Token-Auswertung. Gültige Short-IDs sind 6 bis 16
Hex-Zeichen; geparst wird die erste Zeile, die mit `backgrounded` beginnt. Nach
erfolgreichem Spawn schreibt `AgentSessionStore.setBackgroundShortID` die ID
auf die lokale Session, markiert den initialen Prompt als gestartet und löst
`sessionActionRequest(.start)` aus.

Der anschließende PTY-Launch ist kein zweites `--bg`. Für
`.backgroundChat` baut `AgentCommandBuilder` `claude attach <short-id>` und
nutzt das normale Claude-Chat-Keyboard-Profil. Fehlt die Short-ID, wirft der
Builder einen `missingBackgroundShortID`-Fehler; Views behandeln solche
Sessions als nicht attachbar.

## Lifecycle

`BackgroundAgentLifecycle` ist ein dünner Wrapper um einmalige Claude-CLI-
Subprozesse. `logs`, `stop`, `respawn` und `remove` rufen jeweils
`claude <subcommand> <short-id>` mit 30 Sekunden Timeout auf. Nicht-null Exit-
Codes werden mit stdout/stderr in `LifecycleError.nonZeroExit` abgebildet.

Die View bindet diese Aktionen an das Session-Menü. `logs` lädt den Output in
ein read-only Sheet. `stop` und `respawn` verändern nur den externen
Supervisor-Job. `rm` ruft nach erfolgreichem `claude rm` zusätzlich
`forgetBackgroundSession` auf: ein laufender Attach-PTY wird terminiert, die
lokale Session wird archiviert, `backgroundShortID` wird gelöscht und offene
oder gepinnte Tabs werden bereinigt.

Der Startup-Healthcheck läuft pro Fenster-Lifetime einmal. Er nimmt alle nicht
archivierten `.backgroundChat`-Sessions mit Short-ID und ruft
`BackgroundAgentLifecycle.healthCheck` auf. Intern ist das ein kurzes
`claude logs <short-id>`; Exit 0 bedeutet `alive`, bekannte Fehlermarker wie
`unknown short id` oder `not found` bedeuten `unknown`, andere Fehler bleiben
`error`. Nur `unknown` führt zu lokalem Cleanup.

## Hook-Bridge und Status

`ClaudeHookSettingsBuilder` erzeugt ein Settings-Dict mit Command-Hooks für
`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest` und `Stop`. Jeder Hook hängt das
JSON aus stdin als Zeile an das Event-File. `Notification` wird nicht
registriert, weil Claude damit auch Idle-Pings melden kann; echte Permission-
Dialoge kommen über `PermissionRequest`.

`ClaudeHookBridge.prepareSettingsFile` legt Event- und Settings-Datei an,
löscht vorher ein altes Event-File derselben lokalen Session und schreibt die
Settings atomisch. `startTracking` setzt den Cursor des
`ClaudeHookEventStore` zurück, öffnet das Event-File read-only mit `O_EVTONLY`
und registriert eine `DispatchSource` für `.write`, `.extend`, `.delete` und
`.rename`. Beim Start werden bereits vorhandene Events einmalig gedraint, um
Rennen zwischen Spawn und Tracking abzudecken. Wenn innerhalb von fünf
Sekunden kein erstes Hook-Event ankommt, schreibt die Bridge einmalig
`binding_hook_silent` ins Log; das ist eine Diagnose für deaktivierte oder
nicht injizierte Hooks und startet keinen Polling-Fallback.

`ClaudeHookEventStore` liest nur neue Bytes seit dem letzten Cursor-Offset und
parst jede JSONL-Zeile in `ClaudeHookEvent`. Ungültige Zeilen werden ignoriert.
Die Bridge throttelt häufige Tool-Events, lässt aber `PreToolUse` mit
`AskUserQuestion` oder `ExitPlanMode` immer durch, weil diese Events die
einzige Quelle für Rückfragen und Plan-Freigaben sind.

`AgentSessionStatusCoordinator` ist der Single Writer für den Runtime-Status.
Bei `SessionStart` bindet er die externe `session_id` an die lokale Session,
aktualisiert den PTY-Controller und hängt den Transcript-Watcher neu an.
Sobald eine Session Hook-Events liefert, gelten Hooks für working/idle/
awaiting als primäre Statusquelle. Transcript-Entscheidungen bleiben für
stumme Hooks, ESC-Abbruch und Turn-Ende-Bookkeeping erhalten.

Die `AgentSessionStateMachine` bildet Hook-Events auf Zustände ab:
`UserPromptSubmit` und Tool-Aktivität führen zu `working`,
`PermissionRequest` führt zu `awaitingInput(.permission)`,
`PreToolUse` mit `AskUserQuestion` zu `awaitingInput(.question)` und
`PreToolUse` mit `ExitPlanMode` zu `awaitingInput(.planApproval)`.
`Stop` erzeugt den Turn-Completed-Effekt; `SessionEnd` beendet die Session,
außer der Reason ist `clear`, `resume` oder `compact`.

Bei Background-Sessions beendet das Ende des Attach-PTYs nicht den Agenten.
`sessionTerminated` ignoriert Prozessende für `.backgroundChat`; das echte Ende
kommt aus dem `SessionEnd`-Hook oder aus einer Lifecycle-Aktion gegen den
Supervisor.

## Supervisor-Snapshots und aktive Sessions

`SupervisorJobReader.readAll` scannt `~/.claude/jobs/`, überspringt Dateien
und ungültige Job-Verzeichnisse und liefert nur parsebare States mit CWD.
`mostRecentlyActive` wählt innerhalb eines Recency-Windows den Job mit der
neuesten mtime seiner `linkScanPath`-JSONL und fällt auf `updatedAt` zurück,
wenn die JSONL nicht zugreifbar ist.

`ActiveBackgroundSessionTracker` nutzt diese Logik für die Claude Agents View.
Der Tracker läuft nur nach `start()`, pollt standardmäßig alle fünf Sekunden
und nimmt nur Aktivität der letzten 60 Sekunden. `nudge()` erlaubt einen
rate-limitierten Sofort-Refresh bei User-Aktivität in der TUI. Die konkrete
Header- und Sidebar-Darstellung dieser Daten gehört zur UI-Dokumentation unter
`../ui/`.

`ClaudeActiveSessionResolver` ist keine Background-Polling-Schleife mehr und
hat im Produktionscode keinen Aufrufer. Die pure Entscheidungslogik bleibt nur
für Tests erhalten und kann dort zwischen `unchanged`, eindeutigem `rebind`
oder `ambiguous` entscheiden. Der aktive Resume-Recovery-Pfad in
`AgentSessionDetailView` wählt dagegen selbst einen Ersatz oder startet frisch.

## Startup-Abgrenzungen

`SummaryStartupPlanner` schließt `.backgroundChat` aus dem
Startup-Summary-Plan aus, weil Background-Tabs kein direktes normales
Chat-Transcript für diesen Pfad liefern. Die übrigen Summary-Startup-Regeln
gehören zur Sessions-Dokumentation.

`ClaudeThemeWriter` ist keine Background-Agent-Persistenz. Er ist hier nur als
Abgrenzung relevant, weil er der getrennte Codepfad ist, der den Claude-Theme-
Key in `~/.claude/settings.json` synchronisiert.

## Invarianten und Gotchas

- Die Short-ID ist die lokale Brücke zum Claude-Supervisor; ohne Short-ID ist ein Background-Tab nicht attachbar.
- `claude --bg` ist ein einmaliger Spawn-Subprozess; der laufende Agent wird vom externen Claude-Supervisor gehostet.
- Hook-Settings müssen bereits beim `--bg`-Spawn injiziert werden, weil die Background-Session die Settings vom Supervisor erbt.
- Die Hook-Bridge ist event-driven über `DispatchSource`; es gibt keinen Fallback-Polling-Loop für Hook-Dateien.
- `stopTracking` löscht Hook-Dateien nicht sofort; verwaiste Dateien werden beim App-Start durch `AgentSessionRetentionService.prune` gegen das Live-Session-Set entfernt.
- Hooks können deaktiviert sein oder stumm bleiben; nach fünf Sekunden ohne erstes Hook-Event loggt die Bridge einmalig `binding_hook_silent`, die Session läuft aber weiter und Status sowie Rückfragen sind gröber.
- `Notification` ist nicht Teil der registrierten Hook-Events, weil es auch Idle-Notifications erzeugen kann.
- `PermissionRequest`, `AskUserQuestion` und `ExitPlanMode` sind die expliziten Quellen für `awaitingInput`.
- Tool-Events werden gedrosselt, aber awaiting-relevante Tool-Events werden nie gedrosselt.
- Der Attach-PTY ist nur ein Fenster in den Supervisor-Job; sein Exit beendet den Background-Agent nicht.
- `SessionEnd` mit `clear`, `resume` oder `compact` wird als In-Place-Wechsel behandelt, nicht als Prozessende.
- Der Supervisor-State unter `~/.claude/jobs/` ist ein externes, defensiv geparstes Claude-Implementation-Detail.
- Reine TUI-Navigation in `claude agents` ist nicht detektierbar; der aktive Background-Job wird über JSONL-Schreibaktivität angenähert.
- `ExternalClaudeHooksInspector` meldet Überschneidungen mit User-Hooks, verändert aber keine User-Settings.
- `ClaudeThemeWriter` ist nur eine Abgrenzung zur Background-Agent-Persistenz; Details der globalen Theme-Synchronisation gehören nicht in diesen Feature-Bereich.

## Schlüsseldateien

- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift` kapselt Spawn-Prozess, Environment, Timeout und Short-ID-Parsing für `claude --bg`.
- `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift` kapselt Logs, Stop, Respawn, Remove und Healthcheck gegen die Claude-CLI.
- `WhisperM8/Services/AgentChats/SupervisorJobReader.swift` liest und klassifiziert Supervisor-State aus `~/.claude/jobs/<short-id>/state.json`.
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift` verwaltet Hook-Settings, Event-Dateien, DispatchSource-Tracking, Silence-Diagnostik und Event-Auslieferung.
- `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift` tailt Hook-JSONL-Dateien cursorbasiert und parst `ClaudeHookEvent`.
- `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift` erzeugt die temporäre Settings-JSON und die Append-Commands für alle getrackten Hook-Events.
- `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift` entfernt verwaiste Hook-Settings und Event-Dateien beim App-Start.
- `WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift` liest globale Claude-Settings read-only und findet Hooks auf denselben Events wie WhisperM8.
- `WhisperM8/Services/AgentChats/ActiveBackgroundSessionTracker.swift` pollt Supervisor-Snapshots für die zuletzt aktive Background-Session in der Agents View.
- `WhisperM8/Services/AgentChats/ClaudeActiveSessionTracker.swift` enthält die pure Rebind-Entscheidung für externe Claude-Session-IDs ohne laufenden Poller.
- `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift` plant Startup-Summaries und schließt Background-Chats von dieser Verarbeitung aus.
- `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift` ist der getrennte Theme-Sync-Pfad und grenzt Background-Agent-Daten von globaler Claude-Settings-Mutation ab.
- `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift` verbindet UI-Aktionen mit Spawn, Hook-Start, Lifecycle, Logs, lokalem Cleanup und Startup-Healthcheck.
- `WhisperM8/Views/BackgroundDispatchModal.swift` sammelt Prompt, optionalen Sub-Agent und Permission-Mode für den Background-Dispatch.
- `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift` konsumiert Hook-Events, bindet `session_id`, steuert Runtime-Status und ignoriert Attach-PTY-Exits für Background-Sessions.
- `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift` übersetzt Hook-, Transcript- und Prozesssignale in Lifecycle-State, Runtime-Status und Notifications.
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` baut die zentrale `claude --bg`-Argv und den späteren `claude attach <short-id>`-PTY-Launch.

## Test-Cluster

- `Tests/WhisperM8Tests/BackgroundAgentSpawnerTests.swift` deckt Short-ID-Parsing, Spawn-Argumente, Fehlerfälle und Prozess-Runner-Seams ab.
- `Tests/WhisperM8Tests/BackgroundAgentLifecycleTests.swift` deckt Lifecycle-Subcommands, Fehler-Mapping und Healthcheck-Klassifikation ab.
- `Tests/WhisperM8Tests/SupervisorJobReaderTests.swift` deckt `state.json`-Parsing, ISO-Datumswerte und Aktivitätsauswahl ab.
- `Tests/WhisperM8Tests/ClaudeHookBridgeTests.swift` deckt Settings-Erzeugung, Event-Parsing, Dispatch-Entscheidungen und Statussignale der Hook-Bridge ab.
- `Tests/WhisperM8Tests/ExternalClaudeHooksInspectorTests.swift` deckt read-only Hook-Settings-Inspektion und Command-Preview ab.
- `Tests/WhisperM8Tests/ClaudeActiveSessionResolverTests.swift` deckt Rebind-, Unchanged- und Ambiguous-Entscheidungen für externe Claude-Session-IDs ab.
