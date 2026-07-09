---
status: aktiv
updated: 2026-07-09
---

# Sessions — Store, Indexer, Runtime-Status, Transcripts

Eine Agent-Chat-Session ist der lokale WhisperM8-Eintrag für einen Claude-
oder Codex-Verlauf. Persistiert wird sie als `AgentChatSession` im Workspace;
die eigentliche Unterhaltung bleibt in den JSONL-Dateien der externen CLIs
unter `~/.claude/` oder `~/.codex/`.

## Was ist eine Session?

Eine Session gehört zu genau einem Provider: `claude` oder `codex`. Der
Provider bestimmt, welches CLI gestartet wird, wo Transcripts liegen und
welcher Transcript-Reader den Verlauf rendert. Die lokale Session-ID ist eine
WhisperM8-UUID; `externalSessionID` ist die ID des externen CLI-Verlaufs und
wird erst gesetzt, wenn Hook, Indexer oder Job-Sync sie kennen.

Die Session-Art steht in `AgentSessionKind`:

| Kind | Bedeutung |
|------|-----------|
| `chat` | Normaler interaktiver Claude- oder Codex-Chat im PTY. |
| `agentView` | Claude-Dashboard, für das WhisperM8 `claude agents` startet; kein eigener Chat-Verlauf. |
| `backgroundChat` | Einzelner Claude-Background-Agent, für den WhisperM8 `claude --bg` spawnt und per `claude attach <short-id>` anzeigt. |
| `subagentJob` | Headless Codex-Job aus `whisperm8 agent run`; zunächst keine PTY-Session, nach Übernahme normaler Codex-Resume-Pfad. |
| `terminal` | Normale Login-Shell im Projektverzeichnis; kein Agent-Transcript, keine Hook-Bridge, kein Auto-Naming. |

Legacy-Sessions ohne `kind` werden als `chat` behandelt. `backgroundChat`
ist ein Claude-Konzept, `subagentJob` ist ein Codex-Konzept, und `terminal`
nutzt den Provider nur als Schema-Platzhalter. Die Semantik der Claude-CLI-
Subcommands ist externes beziehungsweise empirisch beobachtetes Laufzeitverhalten;
der Code belegt, welche Kommandos WhisperM8 baut und welche Ausgabe es parst.

## Discovery und Indexing

WhisperM8 entdeckt externe Sessions, indem es die nativen Transcript-Bäume
der CLIs liest. Der Code erwartet Claude-Dateien unter
`~/.claude/projects/<encoded-cwd>/*.jsonl` und Codex-Dateien unter
`~/.codex/sessions/YYYY/MM/DD/*.jsonl`. Dieses Layout ist externes
beziehungsweise empirisch beobachtetes CLI-Laufzeitverhalten, keine von
WhisperM8 selbst beweisbare Garantie; WhisperM8 liest es read-only und
übernimmt daraus nur Session-ID, Arbeitsverzeichnis, Titel, Zeitstempel und
bei Codex das Modell.

Der Scan läuft beim App-Start, bei Foreground-Reaktivierung und nach
Filesystem-Events auf den externen Session-Verzeichnissen. `AgentScanCoordinator`
coalesced parallele Anfragen und nutzt einen Cooldown, damit häufiges
App-Wechseln nicht dauernd rekursiv scannt. `AgentDirectoryEventMonitor`
beobachtet die Claude- und Codex-Roots per FSEvents und triggert einen
debounced Scan, wenn neue externe JSONL-Dateien auftauchen.

Die Indexer arbeiten mit einem Cache über Dateipfad, Provider, mtime und
Größe. Unveränderte Dateien werden nicht erneut geparst. Claude liest nur
einen begrenzten Dateikopf mit maximal 200 Zeilen beziehungsweise 1 MB;
Codex liest für die Metadaten die erste Zeile mit maximal 256 KB. Beim Merge
legt WhisperM8 fehlende Projekte automatisch an, bindet frisch gestartete
lokale Sessions über Provider, CWD und Zeitfenster an externe IDs und
überspringt Codex-Threads, die bereits einem `subagentJob` gehören.

## Runtime-Status

Der dauerhafte Session-Zustand (`pending`, `running`, `closed`, `archived`)
ist Persistenzzustand. Der Live-Status (`working`, `awaitingInput`, `idle`,
`stopped`, `errored`) ist ephemer und lebt im `AgentSessionRuntimeStatusStore`.
Nach einem App-Neustart ist dieser Live-Status wieder unbekannt, bis ein
Prozess, Hook oder Watcher ihn neu liefert.

Für Claude-Sessions mit funktionierender Hook-Bridge sind Hooks die Source of
Truth. `SessionStart`, `UserPromptSubmit`, Tool-Hooks, `PermissionRequest`,
`Stop` und `SessionEnd` bewegen die State-Machine. Sobald für eine lokale
Session Hook-Events angekommen sind, ignoriert der Status-Koordinator
Transcript-Meinungen zu `working` oder `idle`; nur ESC-Abbrüche aus dem
Transcript und Turn-End-Bookkeeping dürfen noch durch.

Die wichtigsten Bedeutungen:

| Status | Bedeutung |
|--------|-----------|
| `working` | Ein Turn läuft: Prompt wurde gesendet, Tool-Aktivität läuft oder das Transcript zeigt laufende Aktivität. |
| `awaitingInput` | Claude wartet auf eine User-Entscheidung: Permission, `AskUserQuestion` oder `ExitPlanMode`. |
| `idle` | Prozess lebt, ist aber bereit oder ein Turn ist beendet. |
| `stopped` | Prozess wurde ohne Fehler beendet. |
| `errored` | Prozess wurde mit Fehler beendet. |

Für Codex und für Claude-Sessions ohne lebendige Hooks ist das Transcript der
Fallback. Der Runtime-Watcher beobachtet die Transcript-Datei event-driven mit
einer vnode-Source und hat zusätzlich einen 1,5-s-Poll-Fallback. Bei
unveränderter Datei wird zuerst nur `stat()` ausgewertet; ein 64-KB-Tail-Read
passiert erst, wenn mtime oder Größe wechseln. Der Kill-Switch
`agentEventDrivenWatchEnabled` deaktiviert den event-driven Pfad nach einem
App-Neustart; der Poll-Fallback bleibt.

## Benachrichtigungen

Die Bausteine in `AgentSessionNotifier.swift` formen Turn-Ende, Rückfragen
sowie erfolgreiche oder fehlgeschlagene Subagent-Jobs zu macOS-Bannern.
Gleiche Ereignisarten derselben Session werden innerhalb von zwei Sekunden
gedrosselt; verschiedene Arten bleiben getrennte Informationen. Rückfragen
und Subagent-Meldungen sind lautlos. Auch Turn-End-Banner enthalten keinen
Notification-Sound: Der konfigurierbare Completion-Sound läuft separat,
während der Terminal-Bell eine eigene, unabhängig schaltbare SwiftTerm-
Semantik bleibt.

Beim App-Start fragt WhisperM8 die Notification-Berechtigung an. Banner werden
auch im Vordergrund gezeigt; ein Klick liest die lokale Session-ID aus der
Notification und fokussiert über `WindowRequestCenter` das passende Fenster
und den passenden Tab.

## Transcripts

Geschlossene und laufende Chats werden aus den nativen JSONL-Dateien gerendert.
`ClaudeTranscriptReader` und `CodexTranscriptReader` übersetzen unterschiedliche
CLI-Schemas in das gemeinsame Modell `AgentChatTranscript` mit Messages und
Blocks für Text, Tool-Use, Tool-Result, Bilder und Thinking.

Große Dateien werden gestreamt oder nur als Tail gelesen. Der Voll-Reader
verwendet `LineStream`, damit mehrstellige MB-Dateien nicht vollständig in
einen String geladen werden. Tail-Verbraucher wie Diktat-Kontext,
Summary-Erzeugung und UI-Nachladen nutzen begrenzte Fenster und markieren,
ob vor dem Fenster weiterer Verlauf liegt.

`agentView` hat kein eigenes Transcript. Für Diktat-Kontext wird dort
heuristisch der zuletzt aktive Claude-Supervisor-Job verwendet, sofern er im
Recency-Fenster liegt. `terminal` liefert keinen Transcript-Kontext.

## Scope

Diese Seite dokumentiert den gemeinsamen Session-Kern: Store, Indexing,
Runtime-Status und Transcript-Zugriff. Details zu einzelnen Nachbarflächen
liegen in den jeweiligen Feature-Dokus: [Background-Agents](../background-agents/),
[Sub-Agents](../sub-agents/), [Codex-Exec](../codex-exec/) und
[UI](../ui/). Die Sessions-Doku nennt diese Systeme nur dort, wo ihre Daten
oder Statussignale in den Session-Kern einfließen.

## Auto-Naming und Summaries

Auto-Naming läuft nach dem ersten erkannten Turn-Ende, wenn die Session einen
auto-generierten Titel hat, eine externe Session-ID besitzt, noch keinen
`lastTurnAt`-Stempel hat und Auto-Rename in den Preferences aktiv ist. Der
Auto-Namer baut aus einem begrenzten Transcript-Kopf einen kurzen Excerpt und
fragt das passende CLI headless nach einem Titel. Manuell umbenannte Sessions
werden nicht überschrieben.

`AgentHeadlessCLI` ist dafür der gemeinsame Kurzprozess-Baustein: Er liefert
stdout bei Erfolg und vereinheitlicht Timeout, Exit-Code und stderr-Fehler.
Neben dem Auto-Naming verwendet ihn `CodexAgentPreflight` für
`codex --version`; lang laufendes, streamendes `codex exec` gehört nicht zu
diesem Runner.

Summaries werden in `AgentSessionSummary` auf der Session persistiert. Für
normale Chats erzeugt `AgentSessionSummarizer` nach Session-Ende, beim
Startup-Abgleich offener Tabs oder auf manuellen Refresh eine Zusammenfassung
über das passende CLI. Ein Digest aus Dateigröße und mtime verhindert
unnötige Läufe für unveränderte Transcripts. Subagent-Jobs werden anders
behandelt: Ihre Summary kommt direkt aus dem strukturierten `AgentReport`,
nicht aus einem LLM-Summary-Lauf.

## Projektstatus und Projekt-Icons

`GitProjectStatus` liefert Branch und zwei bewusst unterschiedlich breite
Arbeitsbaum-Sichten: `changedFiles` zählt `git status --porcelain` und umfasst
damit staged, unstaged sowie untracked Dateien. `added` und `deleted` summieren
dagegen `git diff --numstat`, also nur unstaged Zeilenänderungen an verfolgten
Dateien; reine staged oder untracked Änderungen erscheinen dort nicht.

`AgentProjectIconResolver` sucht ausschließlich lokal. Eine schnelle Probe
gängiger Web-Root- und Monorepo-Orte bevorzugt deklarierte Manifest-Icons;
danach folgt ein manifest-first Vollscan mit Pruning, Tiefen- und Mengenlimit
und einem Score gegen dekorative oder tief verschachtelte Bilder. Ein manuell
gewähltes Icon hat Vorrang. Steigt die Resolver-Version, werden nur Projekte
ohne manuellen Override erneut zur Auto-Erkennung freigegeben.

## Archiv und Retention

Archivieren ist eine User-Aktion auf der lokalen Session. Sie setzt den
Status auf `archived` und schreibt `archivedAt`; Wiederherstellen setzt die
Session auf `closed` zurück und entfernt den Archivzeitpunkt. Die externen
Claude- oder Codex-Transcripts werden dabei nicht gelöscht.

Beim App-Start räumt `AgentSessionRetentionService` verwaiste Hook-Settings
und Hook-Event-Dateien im App-Support-Verzeichnis auf. Die Retention betrifft
nicht die externen CLI-Transcripts. Fehlen Transcripts abgeschlossener,
manuell angelegter Sessions später auf Disk, markiert die Präsenzprüfung
diese Sessions konservativ als tote Zeiger, statt sie still zu entfernen.

## Schlüsseldateien

- `WhisperM8/Models/AgentChat.swift` definiert Provider, Session-Kinds, persistierte Sessions, Runtime-Status und Summary-Felder.
- `WhisperM8/Models/AgentChatTranscript.swift` definiert das providerübergreifende Transcript-Modell mit stabilen Message-IDs.
- `WhisperM8/Models/AgentUIState.swift` definiert den getrennten UI-State-Sidecar für Tabs, Fenster, Pins und Selektion.
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift` ist die synchrone Fassade für Workspace-Mutationen, Session-Merge, Archivierung, Auto-Titel und Summary-Writes.
- `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift` ist der registrierte In-Memory-Kern mit Lock, Normalisierung, Debounce-Persistenz und SwiftUI-Projektion.
- `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift` definiert Index-Ergebnis, Statistiken und den mtime+size-Cache.
- `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift` liest Claude-JSONL-Metadaten aus `~/.claude/projects`.
- `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift` liest Codex-JSONL-Metadaten aus `~/.codex/sessions`.
- `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift` koordiniert Launch-, Foreground-, manuelle und FSEvents-Scans mit Cooldown.
- `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift` beobachtet externe Session-Verzeichnisse und triggert Scan-Requests.
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift` beobachtet Claude-Hook-Event-Dateien und liefert Status- sowie Binding-Events an den Koordinator.
- `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift` liest neue Hook-JSONL-Zeilen cursorbasiert und parst sie in `ClaudeHookEvent`.
- `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift` erzeugt die temporären Claude-Settings-Dateien, die WhisperM8-Hooks in ein Event-File schreiben lassen.
- `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift` ist der Single Writer für Live-Status, Notifications, Hook-Signale und Transcript-Entscheidungen.
- `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift` baut und drosselt Turn-Ende-, Rückfrage- und Subagent-Banner; der Poster hinterlegt die lokale Session-ID fürs Klick-Routing.
- `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift` beobachtet aktive Transcript-Dateien event-driven und per Poll-Fallback.
- `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift` enthält Status-Parser, Status-Decider, Transcript-Locator und Präsenzprüfung.
- `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift` rendert Claude-JSONL in `AgentChatTranscript`.
- `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift` rendert Codex-JSONL in `AgentChatTranscript`.
- `WhisperM8/Services/AgentChats/BoundedJSONLReader.swift` liest begrenzte Datei-Präfixe für schnelles Indexing.
- `WhisperM8/Services/AgentChats/AgentChatTailExtractor.swift` baut kurze Conversation-Tails für Diktat-Kontext.
- `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift` erzeugt automatische Session-Titel aus Transcript-Excerpts.
- `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift` ist der gemeinsame Timeout-, Exit-Code- und stderr-Runner für kurze Headless-CLI-Aufrufe.
- `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift` erzeugt und persistiert Chat-Summaries mit Digest-Guard.
- `WhisperM8/Services/AgentChats/SummaryStartupPlanner.swift` begrenzt Startup-Summary-Kandidaten auf frische offene Tabs.
- `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift` baut aus Transcripts die deterministische Runden-Projektion für Summaries.
- `WhisperM8/Services/AgentChats/TranscriptEvidenceExtractor.swift` extrahiert deterministische Fakten wie Commits, Tests und geänderte Dateien für Summaries.
- `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift` entfernt verwaiste Hook-Dateien im App-Support-Verzeichnis.
- `WhisperM8/Services/AgentChats/GitProjectStatus.swift` liest Branch, Dateianzahl und unstaged Numstat-Summen eines Projekts.
- `WhisperM8/Services/AgentChats/AgentProjectIconResolver.swift` findet lokal und begrenzt ein geeignetes Repo-Icon.
- `WhisperM8/Services/AgentChats/AgentChatLaunchService.swift` erzeugt neue Codex-Chat-Sessions aus App-Flows.
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift` baut Claude-, Codex-, Background-, Agent-View- und Terminal-Launch-Kommandos.
- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift` spawnt `claude --bg` und parst die Short-ID aus dem externen Claude-Output.
- `WhisperM8/Services/AgentChats/AgentPromptRoutingService.swift` routet Text in bestehende Sessions und staged Sends bis das PTY bereit ist.

## Keywords

Sessions, Agent-Sessions, Agent Chats, Chat-Verlauf, Session-Store,
Workspace-Store, Indexer, externe Sessions, Claude-Sessions, Codex-Sessions,
Transcript, JSONL, Live-Status, Laufzeitstatus, arbeitet, wartet auf Eingabe,
idle, archivieren, Archiv, Retention, Auto-Naming, automatische Titel,
Zusammenfassung, Summary, Background-Agent, Subagent-Job, Agent View,
Terminal-Session, Hook-Bridge, Event-Watcher, Poll-Fallback,
Benachrichtigung, Notification, Banner, Turn-Ende, Rückfrage,
Completion-Sound, Terminal-Bell, Klick-Routing, Foreground-Banner,
`AgentChatSession`, `AgentProvider`, `AgentSessionKind`, `backgroundChat`,
`subagentJob`, `AgentSessionStore`, `AgentWorkspaceStore`,
`AgentWorkspaceStoreRegistry`, `AgentWorkspaceRepository`,
`AgentWorkspaceUIModel`, `AgentSessionIndexCache`, `ClaudeSessionIndexer`,
`CodexSessionIndexer`, `AgentScanCoordinator`, `AgentDirectoryEventMonitor`,
`AgentSessionStatusCoordinator`, `AgentSessionStateMachine`,
`AgentSessionRuntimeWatcher`, `AgentSessionRuntimeStatusStore`,
`AgentTranscriptStatusDecider`, `AgentTranscriptLocator`,
`ClaudeTranscriptReader`, `CodexTranscriptReader`, `BoundedJSONLReader`,
`AgentChatTailExtractor`, `AgentSessionAutoNamer`, `AgentTitleGenerator`,
`AgentTranscriptExcerpt`, `AgentHeadlessCLI`, `AgentHeadlessCLIError`,
`AgentSessionSummarizer`, `SummaryStartupPlanner`,
`TranscriptTimelineBuilder`, `TranscriptEvidenceExtractor`,
`AgentSessionRetentionService`, `AgentChatLaunchService`,
`AgentSessionNotifier.swift`, `AgentSessionUserNotification`,
`AgentNotificationThrottle`, `UNAgentUserNotificationPoster`,
`CodexAgentPreflight`,
`GitProjectStatus`, `AgentProjectIconResolver`, Projektstatus, Projekt-Icon,
Manifest-Icon, Quick-Probe, Icon-Scoring, manueller Icon-Override,
`AgentCommandBuilder`, `BackgroundAgentSpawner`, `AgentPromptRoutingService`,
`ClaudeHookBridge`, `ClaudeHookEventStore`, `ClaudeHookSettingsBuilder`,
`repairResumeStateBeforeLaunch`, `AgentResumeRepairResult`,
`ClaudeActiveSessionResolver`, Ambiguous-Rebind-Picker, Resume-Recovery,
`agentEventDrivenWatchEnabled`, `working`, `awaitingInput`, `idle`,
`stopped`, `errored`.
