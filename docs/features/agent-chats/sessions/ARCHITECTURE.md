---
status: aktiv
updated: 2026-07-09
---

# Sessions — Architektur

Die Session-Architektur trennt vier Ebenen: persistierter Workspace,
Indexing externer CLI-Transcripts, ephemerer Runtime-Status und
Transcript-Rendering. WhisperM8 besitzt die lokale Workspace-Wahrheit; Claude
und Codex besitzen ihre nativen Transcript-Dateien.

## Persistenz und Projektion

Der produktive Workspace liegt unter:

`~/Library/Application Support/WhisperM8/AgentSessions.json`

Der UI-Zustand liegt getrennt daneben:

`~/Library/Application Support/WhisperM8/agent-ui-state.json`

Der Index-Cache liegt ebenfalls im App-Support-Verzeichnis:

`~/Library/Application Support/WhisperM8/agent-session-index-cache.json`

`AgentSessionStore` ist nur die Fassade. Alle Instanzen mit derselben
Workspace-URL teilen sich über `AgentWorkspaceStoreRegistry` genau einen
`AgentWorkspaceStore`. Der Store lädt lazy einmal, hält den kanonischen
Workspace im Speicher, serialisiert Mutationen mit `NSLock`, normalisiert nach
jeder Änderung und persistiert für die Produktionsdatei debounced nach 0,5 s.
`createSession` flusht seine neue Session danach explizit; ein neues Projekt,
das allein über `upsertProject` entsteht, bleibt dagegen im 0,5-s-Debounce.

`AgentWorkspaceRepository` kapselt Disk-I/O, ISO-8601-Encoding, atomische
Writes und Backups bei Migration oder Decode-Fehler. `AgentWorkspaceUIModel`
ist die dünne `@Observable`-Projektion für SwiftUI: Facade-Mutationen melden
den neuen Workspace über `onWorkspaceChanged`; Views sollen nicht
`loadWorkspace()` als Refresh-Mechanismus verwenden.

Die Normalisierung kann Sessions oder Projekte entfernen. Konkret werden
Claude-Worktree-Projekte mitsamt Sessions entfernt, unresumable Claude-
Sessions ohne externe ID und ohne Initial-Prompt gepruned, abgeschlossene
Background-Stubs ohne `backgroundShortID` entfernt und alte automatisch
importierte Background-Sessions verworfen. Diese Regeln laufen beim
Initial-Load des Stores und nach Mutationen, weil die Registry
`AgentSessionStore.migratedWorkspace` als Normalizer injiziert.

Der UI-State ist bewusst ein Sidecar. Tabs, Pins, Fenster, Selektion,
Disclosure und ungelesene Subagent-Ergebnisse verändern nicht die Session-
Daten und können unabhängig migriert, gekappt und gepruned werden.

## Indexing

`AgentScanCoordinator` ist der MainActor-Singleton für Discovery-Scans. Er
startet auf Launch, Foreground, manuellem Refresh und FSEvents-Hinweis, lässt
immer nur einen Scan gleichzeitig laufen und nutzt 30 s Cooldown für
Lifecycle-Scans beziehungsweise 10 s für FSEvents-Scans. Der eigentliche
JSONL-Scan läuft detached; der Merge zurück in den Workspace passiert danach
auf dem MainActor mit der aktuellen Menge aktiver PTY-Sessions.

`AgentDirectoryEventMonitor` beobachtet `~/.claude/projects` und
`~/.codex/sessions` per FSEvents. Es filtert auf `.jsonl` und ignoriert
Transcripts, die bereits vom Runtime-Watcher als aktive In-App-Dateien
beobachtet werden. Danach debounced es den Scan-Request um 5 s.

`ClaudeSessionIndexer` enumeriert Claude-JSONL-Dateien unter
`~/.claude/projects`, überspringt `/subagents/`, liest einen begrenzten
Dateikopf und extrahiert Session-ID, CWD, Titel und Zeitstempel. `CodexSessionIndexer`
enumeriert `~/.codex/sessions`, liest die erste JSONL-Zeile und erwartet dort
ein externes beziehungsweise empirisch beobachtetes Codex-`session_meta`-
Schema mit ID, CWD, Timestamp und optionalem Modell. Der Code belegt diese
Erwartung und den Parser, nicht die Stabilität zukünftiger Codex-Versionen.
Beide Indexer verwenden `AgentSessionIndexCache` mit Provider,
standardisiertem Pfad, Dateigröße und mtime als Cache-Key.

Beim Merge übernimmt `AgentSessionStore.mergeIndexedSessions` die Indexdaten
in den Workspace. Neue Projekte entstehen automatisch aus dem CWD; Git-Branch-
Lookups werden vor der Store-Mutation berechnet. Bestehende Sessions werden
über Provider und `externalSessionID` aktualisiert. Lokale Sessions ohne
externe ID können über Provider, Projekt und ein enges Erstellzeitfenster
adoptiert werden. Codex-Threads, die einer `.subagentJob`-Session gehören,
werden ausgelassen, damit der normale Codex-Indexer keine Job-Sessions
dupliziert oder umhängt.

## Claude-Resume-Recovery

Vor einem Claude-Launch repariert `AgentSessionDetailView` den Resume-Zustand
konservativ. Agent View und Terminal brauchen keinen Repair. Für normale
Claude-Sessions mit `hasLaunchedInitialPrompt` und `externalSessionID` gilt
zuerst der Fast Path: existiert die erwartete `<id>.jsonl` am Claude-Pfad,
wird die gespeicherte ID verwendet und kein teurer Scan gestartet.

Fehlt die Datei, scannt der Slow Path mit `ClaudeSessionIndexer` und ruft
`AgentSessionStore.repairResumeStateBeforeLaunch` auf. Der Store filtert
indexierte Sessions auf denselben Provider und dasselbe kanonische Projekt,
behält die ID bei, wenn sie dort gefunden wird, bindet auf den besten
zeitnahen Ersatz neu oder setzt `externalSessionID`, `hasLaunchedInitialPrompt`,
`shouldLaunchOnOpen` und Status zurück. Danach prüft die View noch einmal die
physische Transcript-Datei. Fehlt sie weiterhin, startet WhisperM8 frisch im
selben Tab, damit kein blindes `claude --resume <dead-id>` an Claude geht.

Der noch vorhandene `ClaudeActiveSessionResolver` und der
Ambiguous-Rebind-Picker sind kein aktiver Produktionspfad: Die View besitzt
zwar weiterhin einen Consumer für `ambiguousRebindNotification`, im
Produktionscode existiert aber kein Producer dieser Notification mehr. Der
reale Launch-Pfad fragt daher keine Auswahl ab, sondern übernimmt automatisch
den besten Ersatz aus `repairResumeStateBeforeLaunch` oder setzt die Session
für einen frischen Start zurück.

## Runtime-Status

Der Live-Status wird zentral von `AgentSessionStatusCoordinator` geschrieben.
Fenster und Sidebar konsumieren den `AgentSessionRuntimeStatusStore`; andere
Komponenten melden nur Signale. Damit gibt es eine Single-Writer-Invariante
für `working`, `awaitingInput`, `idle`, `stopped` und `errored`.

Die interne Wahrheit des Koordinators ist `AgentSessionLifecycleState`.
`AgentSessionStateMachine` reduziert Prozess-, Hook- und Transcript-Signale
pur und erzeugt nur bei echten Übergängen Effekte wie Fertig- oder
Rückfrage-Notifications. `launching`, `ready` und `turnDone` mappen optisch
alle auf `idle`, damit ein frisch geöffneter Chat nicht als arbeitend pulsiert.

Für Claude mit aktiver Hook-Bridge sind Hooks die Status-Quelle. Die Bridge
schreibt pro lokaler Session ein temporäres Settings-File, lässt Claude Hook-
Events in ein App-Support-JSONL appendieren und beobachtet dieses Event-File
mit `DispatchSourceFileSystemObject`. Nach dem ersten Hook-Event ist die
Session hook-live; Transcript-Entscheidungen zu Arbeit oder Idle werden dann
ignoriert. Ausnahme: Transcript-Erkennung eines ESC-Abbruchs und
Turn-Fertig-Bookkeeping bleiben erlaubt, weil dafür nicht in jedem Fall ein
Hook kommt.

`awaitingInput` kommt aus dedizierten Hook-Signalen: `PermissionRequest`,
`PreToolUse` mit `AskUserQuestion` oder `PreToolUse` mit `ExitPlanMode`.
Normale `Notification`-Events sind defensiv parsebar, aber keine Quelle für
`awaitingInput`, weil externe Claude-Notifications auch Idle-Hinweise sein
können.

Für Codex und für Claude ohne lebendige Hooks ist das Transcript Fallback.
`AgentSessionRuntimeWatcher` beobachtet pro aktiver Session die gefundene
Transcript-Datei. Wenn `agentEventDrivenWatchEnabled` aktiv ist, hängt pro
Datei eine `FileEventSource` auf `.write`, `.extend`, `.delete` und `.rename`.
Write-Events lösen debounced Polls aus; Delete/Rename nullt die URL und der
nächste Timer-Tick resolved neu. Der 1,5-s-Timer bleibt als Fallback für
URL-Resolution, verpasste Events und zeitbasierte Eskalation.

Der Watcher ist stat-first. Bei unverändertem mtime+size-Stat wird der letzte
geparste Event nur neu bewertet; ein Tail-Read von 64 KB passiert erst bei
geänderter Datei. `AgentTranscriptStatusDecider` bewertet das letzte
statusrelevante Event: laufende User-, Assistant- oder Tool-Events ergeben
`working`, echte Assistant-Stopps ergeben `idle` und optional `turnFinished`,
lange stille Aktivität wird nach dem Stall-Timeout auf `idle` heruntergestuft.

Subagent-Jobs gehen nicht durch den Runtime-Watcher. Für
`.subagentJob`-Sessions mappt der Status-Koordinator den `AgentJobState`
direkt: `spawning` und `running` zu `working`, `done` zu `idle`, `failed` zu
`errored`, `stopped` zu `stopped` und `takenOver` räumt den Job-Status, weil
danach der normale PTY-Pfad übernimmt.

## Benachrichtigungen und Töne

State-Machine-Effekte gelangen über `AgentSessionStatusCoordinator` zu den
Bausteinen in `AgentSessionNotifier.swift`. `AgentSessionUserNotification`
unterscheidet Turn-Ende, konkrete Rückfragegründe sowie erfolgreiche und
fehlgeschlagene Subagent-Jobs. `AgentNotificationThrottle` unterdrückt nur
dieselbe Art für dieselbe lokale Session innerhalb von zwei Sekunden; ein
Wechsel etwa von Rückfrage zu Turn-Ende wird nicht gedrosselt.

`UNAgentUserNotificationPoster` setzt Titel, optionalen Projektnamen, Body und
die lokale Session-ID, aber bewusst keinen `content.sound`. Rückfragen und
Subagent-Meldungen bleiben damit lautlos. Der konfigurierbare Completion-Sound
wird bei einem Turn-End-Effekt separat vom Status-Koordinator abgespielt; der
Terminal-Bell reagiert dagegen auf das Bell-Ereignis von SwiftTerm und besitzt
mit `isTerminalBellEnabled` eine eigene Präferenz.

`AppDelegate` setzt beim Launch den `UNUserNotificationCenterDelegate` und
fragt die Berechtigung für Alert und Sound an. Im Vordergrund präsentiert der
Delegate Banner und Listeneintrag. Beim Klick liest er die Session-ID aus
`userInfo` und routet über `WindowRequestCenter.requestSessionFocus` zum
richtigen Fenster und Tab.

## Transcripts

`AgentTranscriptLocator` lokalisiert native Transcript-Dateien. Claude-Pfade
werden aus CWD-Encoding und Session-ID gebildet; Codex-Pfade werden rekursiv
unter `~/.codex/sessions` gesucht und positiv gecacht. Negative Codex-Lookups
werden nicht gecacht, weil die Datei noch erscheinen kann.

`ClaudeTranscriptReader` streamt Claude-JSONL zeilenweise und rendert
`user`- und `assistant`-Einträge in `AgentChatTranscript`. Tool-Results,
Tool-Uses, Thinking-Blöcke und Bild-Platzhalter bleiben als semantische Blocks
erhalten; nicht anzeigbare Claude-Zeilen werden übersprungen.

`CodexTranscriptReader` rendert Texte aus `event_msg` und Tool-Aktivität aus
`response_item`. Dieses Mapping ist an externes beziehungsweise empirisch
beobachtetes Codex-JSONL-Laufzeitverhalten gebunden: Der Code implementiert
das aktuelle Schema, beweist aber nicht dessen künftige Stabilität.
Textduplikate aus Response-Items werden absichtlich nicht gerendert, während
`function_call`, `function_call_output`, `tool_search_call` und lesbare
Reasoning-Summaries als Blocks erscheinen.

`LineStream` liest vollständige Dateien chunkweise. `TranscriptTailReader`
liest begrenzte Dateiende-Fenster, verwirft eine angeschnittene Anfangszeile
und meldet `hasTruncatedHead`. Dadurch können UI und Kontext-Extraktion große
Transcripts benutzen, ohne Voll-Reads für kurze Ausschnitte zu erzwingen.

`BoundedJSONLReader` ist die leichte Indexer-Hilfe für begrenzte Präfix-Reads:
erste Zeile für Codex-Metadaten, mehrere Zeilen für Claude-Metadaten.
`AgentChatTailExtractor` baut kurze User/Assistant-Tails für die Diktat-
Pipeline; `.backgroundChat` geht dafür über den Claude-Supervisor-State,
`.agentView` nutzt den zuletzt aktiven Supervisor-Job als Heuristik und
`.terminal` liefert keinen Tail.

## Auto-Naming und Summaries

`AgentSessionAutoNamer` reagiert auf ein vom Status-Koordinator bestätigtes
Turn-Ende. Er respektiert `canAutoRenameTitle`, `lastTurnAt`, das
`alreadyAttempted`-Set, `inFlight` und die Preferences. Der Transcript-Excerpt
wird off-main über `AgentTranscriptLocator` und `AgentTranscriptExcerpt`
gebaut; der CLI-Aufruf läuft über `AgentTitleGenerator` mit
`LoginShellEnvironment.shared.processEnvironment()` und
`AgentCommandBuilder.commandPath(_:)`.

### Kurze Headless-CLI-Aufrufe

`AgentHeadlessCLI` kapselt kurze, nicht streamende Subprozesse. Er sammelt
stdout und stderr, liefert bei Exit-Code 0 stdout zurück und meldet sonst
`nonZeroExit` mit Exit-Code und stderr. Ein Watchdog beendet den Lauf nach dem
konfigurierten Timeout und schützt die Continuation gegen doppeltes Beenden.
Der Baustein wird vom Auto-Naming und von `CodexAgentPreflight` für
`codex --version` genutzt. `CodexExecRunner` verwendet ihn bewusst nicht, weil
lange JSONL-Ausgabe während des Laufs gestreamt werden muss.

`AgentSessionSummarizer` nutzt denselben Headless-CLI-Stil für Summaries. Ein
Digest aus Dateigröße und mtime verhindert Wiederholung für unveränderte
Transcripts. Automatische Trigger sind Session-Ende mit kurzem Debounce und
Startup-Reconciliation für offene Tabs; manuelle Refreshes können erzwingen.
`SummaryStartupPlanner` nimmt nur die beim letzten Lauf offenen Tabs, dedupliziert
sie, sortiert nach Aktivität, kappt standardmäßig auf sechs Kandidaten und
ignoriert Sessions älter als sieben Tage, Archive, Subagent-Jobs, Agent Views
und Background-Chats. `TranscriptTimelineBuilder` baut die deterministische
Runden-Projektion aus dem Tail-Transcript, und `TranscriptEvidenceExtractor`
liefert deterministische Fakten wie Commits, Testläufe und geänderte Dateien.
Das LLM bekommt diese Evidence fertig geliefert und antwortet nur im JSON-
Vertrag. Subagent-Report-Summaries umgehen den LLM-Pfad und werden direkt aus
`AgentReport` gemappt.

## Launch und Prompt-Routing

`AgentChatLaunchService` ist der kleine App-Flow für neue Codex-Chats aus
anderen WhisperM8-Funktionen. Es erstellt Projekt und Session, setzt Initial-
Prompt, Bilder und `shouldLaunchOnOpen` und fordert das Agent-Chats-Fenster an.

`AgentCommandBuilder` baut die tatsächlichen Prozess-Kommandos. Für Codex
unterscheidet er neue Sessions und `resume`, setzt Modell,
Reasoning-Effort, Service-Tier und optional Bildargumente. Für Claude baut er
normale Launches, Resume, Forks, `claude agents`, Background-`attach` und
separat die `claude --bg`-Spawn-Argumente. Für `.terminal` wird die
Login-Shell gestartet. CLI-Pfade werden nicht aus dem rohen GUI-Environment
genommen, sondern über `commandPath(_:)`, `which` mit korrigiertem
Login-Shell-Environment und Fallback-Verzeichnisse aufgelöst.

`AgentPromptRoutingService` routet Text in eine bereits existierende Session,
zum Beispiel einen Subagent-Report in den Parent-Chat. Es fokussiert die
Session, sendet sofort an ein laufendes PTY oder staged den Send mit
Retry-Schleife, bis der Terminal-Controller läuft und gestartet ist. Der
wichtige Gotcha: bestehende Resume-Sessions können nicht über
`initialPrompt` gefüttert werden, weil der Resume-Pfad diesen Wert ignoriert;
deshalb muss der Text als TUI-Eingabe injiziert werden.

## Projektdienste

`GitProjectStatus` ruft `/usr/bin/git` synchron auf und liefert Branch,
Dateianzahl sowie Add/Delete-Summen für die Projektanzeige. Die Zahlen haben
unterschiedliche Reichweite: `git status --porcelain` zählt staged, unstaged
und untracked Dateien; das verwendete `git diff --numstat` summiert nur
unstaged Zeilenänderungen an verfolgten Dateien. Bei ausschließlich staged
oder untracked Änderungen kann `changedFiles` daher positiv sein, während
`added` und `deleted` null bleiben.

`AgentProjectIconResolver` arbeitet ohne HTTP- oder DNS-Zugriff. Zuerst prüft
ein Quick-Probe gängige Web-Root-Pfade am Repo-Root und in Unterordnern erster
Ebene; deklarierte Icons aus Web-Manifests haben Vorrang. Der Fallback sammelt
Manifests und Bilder in einem Durchlauf, überspringt Dependencies und Caches,
bricht nach 20.000 Einträgen ab und steigt höchstens bis Scan-Tiefe vier ab.
Manifest-Größe und ein deterministisches Pfad-Scoring bevorzugen echte,
flache Brand-Icons und verwerfen Kandidaten unter Score 80.

Ein absoluter, vom User gewählter Icon-Pfad überstimmt den automatisch
gefundenen relativen Repo-Pfad. `AgentChatsView` scannt nur manuell angelegte,
noch nicht geprüfte Projekte ohne Override. Wird
`AgentProjectIconResolver.version` erhöht, setzt die Migration nur für
Projekte ohne manuelles Icon den Auto-Lookup zurück und stößt so einen
Neuscan mit der verbesserten Erkennung an.

## Scope-Abgrenzung

Diese Datei beschreibt nur den gemeinsamen Session-Kern. Die tieferen
Produktflächen liegen in den Nachbar-Dokus:
[Background-Agents](../background-agents/), [Sub-Agents](../sub-agents/),
[Codex-Exec](../codex-exec/) und [UI](../ui/). Background-Agents,
Subagent-Jobs, Codex-Reports und UI-State erscheinen hier nur als
Schnittstellen zum Session-Store, Status-Koordinator oder Transcript-System.

## Invarianten

- Mutation-Closures von `AgentWorkspaceStore` und `AgentSessionStore` führen keine Subprozesse und kein blockierendes I/O aus; Git-Branch-Lookups und ähnliche Arbeit werden vor der Mutation berechnet.
- `loadWorkspace()` ist ein synchroner Speicher-Read, aber kein UI-Refresh-Mechanismus; SwiftUI beobachtet `AgentWorkspaceUIModel`.
- UI-State bleibt in `agent-ui-state.json` getrennt von `AgentSessions.json`.
- Alles unter `~/.claude/` und `~/.codex/` wird als externes CLI-System gelesen; WhisperM8 löscht dort keine Transcripts.
- Vor Claude-Resume wird nie blind `claude --resume` gestartet, wenn die erwartete Transcript-Datei fehlt; der Repair-Pfad scannt, reboundet oder startet frisch.
- Der Ambiguous-Rebind-Picker hat keinen Produktions-Producer; Resume-Recovery entscheidet automatisch zwischen bestem Ersatz und Fresh Start.
- Hook-live Claude-Sessions verwenden Hooks als Status-Quelle; Transcript-Status ist nur Fallback oder Bookkeeping.
- Der Runtime-Watcher schreibt keinen Status direkt, sondern liefert Entscheidungen an den Status-Koordinator.
- `agentEventDrivenWatchEnabled` ist der Kill-Switch für vnode-basierte Transcript-Watches; Polling bleibt als Fallback bestehen.
- `AgentDirectoryEventMonitor` filtert aktuell beobachtete Transcript-Dateien heraus, damit aktive In-App-Sessions keine dauernden Discovery-Scans auslösen.
- Indexer-Merge überspringt Codex-Thread-IDs von `.subagentJob`-Sessions, damit Job-Sessions nicht dupliziert werden.
- Archivieren verändert nur den lokalen Workspace-Status; externe Transcripts bleiben bestehen.
- Retention entfernt nur verwaiste Hook-Settings und Hook-Event-Dateien im App-Support-Verzeichnis.
- Completion-Sound und Terminal-Bell sind getrennte Pfade; `UNAgentUserNotificationPoster` setzt selbst keinen Sound.
- `GitProjectStatus.changedFiles` und seine Add/Delete-Summen dürfen wegen der unterschiedlichen Git-Kommandos voneinander abweichen.
- Die automatische Icon-Suche bleibt lokal, begrenzt und überschreibt keinen manuellen Icon-Pfad.

## Schlüsseldateien

- `WhisperM8/Models/AgentChat.swift` definiert die persistierten Session-Felder, Provider, Kinds, Runtime-Status und Summary-Struktur.
- `WhisperM8/Models/AgentChatTranscript.swift` definiert Messages, Blocks und stabile IDs für gerenderte Transcripts.
- `WhisperM8/Models/AgentUIState.swift` definiert den getrennten Sidecar-State für Agent-Chat-Fenster, Tabs und Pins.
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift` ist die Workspace-Fassade für Projekte, Sessions, Archivierung, Merge, Subagent-Sync, Titel und Summary-Writes.
- `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift` implementiert den registrierten, lock-serialisierten In-Memory-Kern und `AgentWorkspaceUIModel`.
- `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift` kapselt Workspace-Load, Save, Migration und Backups auf Disk.
- `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift` definiert Indexresultate, Statistiken und den mtime+size-Cache.
- `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift` indexiert Claude-Transcript-Metadaten aus dem Projektbaum.
- `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift` indexiert Codex-Transcript-Metadaten aus dem Session-Baum.
- `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift` coalesced Discovery-Scans, setzt Cooldowns und merged Ergebnisse in den Store.
- `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift` beobachtet externe Transcript-Roots per FSEvents und triggert debounced Scans.
- `WhisperM8/Views/AgentSessionDetailView.swift` führt vor Claude-Resume den Fast-Path-Dateicheck, den Scan-Rebind und den Fresh-Start-Guard aus.
- `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift` reduziert Status-Signale pur zu Lifecycle-Zustand und Effekten.
- `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift` besitzt den Runtime-Status, konsumiert Hooks, Transcript-Entscheidungen und Prozess-Lifecycle und stößt Notifications, Auto-Naming und Summary-Trigger an.
- `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift` definiert Notification-Inhalt, UN-Poster und Zwei-Sekunden-Throttle.
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift` beobachtet Claude-Hook-Event-Dateien und liefert Status- sowie Binding-Events an den Koordinator.
- `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift` liest neue Hook-JSONL-Zeilen cursorbasiert und parst sie in `ClaudeHookEvent`.
- `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift` erzeugt die temporären Claude-Settings-Dateien, die WhisperM8-Hooks in ein Event-File schreiben lassen.
- `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift` beobachtet aktive Transcript-Dateien mit vnode-Events, Poll-Fallback, stat-first-Cache und Tail-Reads.
- `WhisperM8/Services/Shared/FileEventSource.swift` kapselt die vnode-DispatchSource für einzelne Dateien.
- `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift` enthält Transcript-Event-Parser, Status-Decider, Locator und Präsenzprüfung.
- `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift` streamt Claude-JSONL in das gemeinsame Transcript-Modell.
- `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift` streamt Codex-JSONL in das gemeinsame Transcript-Modell.
- `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift` liefert begrenzte Präfix-Reads für Indexing.
- `WhisperM8/Services/AgentChats/AgentChatTailExtractor.swift` extrahiert kurze Conversation-Tails für Diktat-Kontext.
- `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift` erzeugt automatische Titel aus begrenzten Transcript-Excerpts.
- `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift` kapselt Timeout, Exit-Code, stderr und genau-einmalige Completion kurzer CLI-Läufe.
- `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift` erzeugt Chat-Summaries, prüft Digest-Staleness und mappt Subagent-Reports.
- `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift` plant Startup-Summaries nur für frische offene Tabs und schließt Archive, Subagent-Jobs, Agent Views und Background-Chats aus.
- `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift` baut die verlustfreie Runden-Projektion aus Transcript-Messages.
- `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift` extrahiert deterministische Commit-, Test- und Datei-Fakten für Summary-Prompts.
- `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift` räumt verwaiste Claude-Hook-Dateien im App-Support-Verzeichnis.
- `WhisperM8/Services/AgentChats/GitProjectStatus.swift` liefert den kompakten Branch- und Arbeitsbaumstatus für Projekte.
- `WhisperM8/Services/AgentChats/AgentProjectIconResolver.swift` löst Repo-Icons lokal über Quick-Probe, Manifest und begrenztes Scoring auf.
- `WhisperM8/Services/AgentChats/AgentChatLaunchService.swift` erstellt neue Codex-Chat-Sessions aus App-Flows.
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` baut CLI-Argumente und löst Claude-, Codex- und Shell-Binaries über das korrigierte Login-Shell-Environment auf.
- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift` spawnt `claude --bg` und parst die Short-ID aus dem externen Claude-Output.
- `WhisperM8/Services/AgentChats/AgentPromptRoutingService.swift` fokussiert Ziel-Sessions und injiziert gestaged Prompt-Text in laufende PTYs.

## Test-Cluster

- `Tests/WhisperM8Tests/AgentSessionStoreTests.swift`, `AgentWorkspaceStoreTests.swift`, `AgentSessionModelTests.swift` und `AgentUIStateTests.swift` decken Workspace-Persistenz, Migration, UI-State-Sidecar und Modellsemantik ab.
- `Tests/WhisperM8Tests/AgentSessionIndexerTests.swift` deckt Claude/Codex-Indexing, Cache-Verhalten und Merge-Annahmen ab.
- `Tests/WhisperM8Tests/AgentSessionRuntimeWatcherTests.swift`, `AgentTranscriptStatusTests.swift`, `AgentSessionEventWatchTests.swift`, `AgentSessionStateMachineTests.swift` und `AgentSessionStatusCoordinatorTests.swift` decken Runtime-Watcher, File-Events, Status-Decider, Reducer und Koordinator ab.
- `Tests/WhisperM8Tests/AgentTranscriptReaderTests.swift`, `AgentTranscriptUtilityTests.swift` und `AgentChatTailExtractorTests.swift` decken Transcript-Parsing, Tail-Reads, Retention und Kontext-Tails ab.
- `Tests/WhisperM8Tests/AgentSessionAutoNamerTests.swift` und `AgentSessionSummarizerTests.swift` decken Titel- und Summary-Erzeugung mit Guards, Digest und DI ab.
- `Tests/WhisperM8Tests/AgentCommandBuilderTests.swift` und `AgentPromptRoutingServiceTests.swift` decken Launch-Argumente, Binary-Auflösung und Prompt-Routing ab.
