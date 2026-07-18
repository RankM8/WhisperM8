# Adversariale Verifikation — Verdicts (Phase 4)

**Datum:** 2026-07-18 · **Verfahren:** Cross-Model — die 16 wichtigsten Behauptungen aus
`02-findings/` wurden je einem unabhängigen Codex-Refuter (gpt-5.6-sol, effort xhigh,
read-only) mit dem expliziten Auftrag übergeben, sie zu **widerlegen**.

**Ergebnis: 16 von 16 Behauptungen BESTÄTIGT, 0 widerlegt.** Zwei Verdicts (C03, C16)
bestätigen den Kern, schränken aber Teilaussagen ein — die Einschränkungen sind unten
vermerkt und fließen in die Roadmap ein. Es gibt keine Fehlalarme in dieser Runde.

## Übersicht

| ID | Behauptung | Schwere | Datei | Quelle | Verdict |
|---|---|---|---|---|---|
| C01 | TOCTOU-Fenster zwischen Format-Query und `engine.start` → unfangbare NSException | kritisch | `Services/Dictation/AudioRecorder.swift` | crash-diktat-fable.md (F1) | **BESTÄTIGT** |
| C02 | `handleConfigurationChange` re-validiert nach `await` nicht — Zombie-Engine, Stale-Converter | hoch | `Services/Dictation/AudioRecorder.swift` | crash-diktat-fable.md (F2) | **BESTÄTIGT** |
| C03 | AudioRecorder läuft off-MainActor — Data Races auf Engine-State und `availableDevices` | mittel | `Services/Dictation/AudioRecorder.swift` | crash-diktat-fable.md (F3) | **BESTÄTIGT** (eingeschränkt) |
| C04 | `encodeClaudeCwd` weicht vom realen Claude-Encoding ab (Unicode + fehlende Truncation) | hoch | `Services/AgentChats/AgentSessionTranscript.swift` | claude-integration-fable.md (F1) | **BESTÄTIGT** |
| C05 | Headless-`claude -p`-Aufrufe verschmutzen Workspace — 495 Junk-Sessions unter Projekt `/` | hoch | `Services/AgentChats/AgentHeadlessCLI.swift` | claude-integration-fable.md (F2) | **BESTÄTIGT** |
| C06 | Account-Profile in Nicht-PTY-Spawn-Pfaden ignoriert — Background-Agents immer auf `main` | hoch | `Services/AgentChats/BackgroundAgentSpawner.swift` | claude-integration-fable.md (F3) | **BESTÄTIGT** |
| C07 | Indexer-Bind-Fallback kann fremde Sessions kapern; Merge kann Duplikat-Rows erzeugen | mittel | `Services/AgentChats/AgentSessionStore.swift` | claude-integration-fable.md (F4) | **BESTÄTIGT** |
| C08 | Background-Agent-Status bleibt für immer `working`, wenn der Supervisor-Daemon stirbt | mittel | `Services/AgentChats/AgentSessionStatusCoordinator.swift` | claude-integration-fable.md (F5) | **BESTÄTIGT** |
| C09 | Verlorene Session-Bindung → stiller Fresh-Start statt Resume bei Claude | mittel | `Services/AgentChats/AgentCommandBuilder.swift` | claude-integration-fable.md (F6) | **BESTÄTIGT** |
| C10 | PTY-Teardown blockiert mit `usleep` den Main-Thread — Snapshot verpasst den Exit-Output | hoch | `Views/AgentTerminalView.swift` | races-agentchats-fable.md (F1) | **BESTÄTIGT** |
| C11 | `onWorkspaceChanged` außerhalb des Locks ohne Ordnungsgarantie — UI kann älteren Stand erhalten | mittel | `Services/AgentChats/AgentWorkspaceStore.swift` | races-agentchats-fable.md (F2) | **BESTÄTIGT** |
| C12 | `mergeIndexedSessions` läuft O(m·n) auf dem MainActor unter dem prozessweiten Store-Lock | hoch | `Services/AgentChats/AgentSessionStore.swift` | performance-fable.md (F1) | **BESTÄTIGT** |
| C13 | Inspector spawnt drei git-Subprozesse synchron auf dem Main-Thread pro Projektwechsel | hoch | `Views/ProjectDetailPanel.swift` | performance-fable.md (F2) | **BESTÄTIGT** |
| C14 | `AgentWindowStore.mutate` nicht diff-gated — No-op-Mutationen re-rendern alle Fenster | mittel | `Services/AgentChats/AgentWindowStore.swift` | performance-fable.md (F4) | **BESTÄTIGT** |
| C15 | Jede Workspace-Invalidierung evaluiert den kompletten `AgentChatsView`-Body mit O(n)-Vollpässen | mittel | `Views/AgentChatsView.swift` | performance-fable.md (F3) | **BESTÄTIGT** |
| C16 | Diktat mit Codex-Kontext macht ungecachten rekursiven `~/.codex/sessions`-Walk, `stopRecording` wartet bis 1 s | mittel | `Services/AgentChats/CodexTranscriptReader.swift` | performance-fable.md (F6) | **BESTÄTIGT** (präzisiert) |

## Einzelbewertungen

### C01 — TOCTOU-Fenster beim Engine-Start (kritisch, BESTÄTIGT)

Der Refuter bestätigt: `AudioRecorder.swift:107-120` speichert nur einen einmal validierten
Format-Snapshot; derselbe Snapshot geht ohne erneute Abfrage an `installTap` (`:155`, intern
`:372`) und `engine.start` (`:158-170`). `AudioFormatDecision.swift:22-27` prüft lediglich
`sampleRate > 0` und `channelCount > 0` — der Fix `90c4fab` schützt also vor 0-Hz-/0-Kanal-Formaten,
nicht vor dem Wechsel zwischen zwei *gültigen* Formaten (typisch: A2DP→HFP-Switch bei
Bluetooth, den der Aufnahmestart selbst auslöst). Die vorhandenen Guards schließen das
Fenster nicht. Das ist die wahrscheinlichste Ursache des gemeldeten Voll-Absturzes beim
Transkriptionsstart, weil die resultierende AVFoundation-Assertion eine unfangbare
ObjC-NSException ist.

### C02 — Keine Re-Validierung nach await in `handleConfigurationChange` (hoch, BESTÄTIGT)

Bestätigt: Der Handler bindet die alte Engine nur im Eintritts-Guard und prüft nach den
Suspension-Points weder `isRecording` noch `self.engine === engine` erneut
(`AudioRecorder.swift:254, 271, 278-288`). Der Refuter belegt zusätzlich einen erreichbaren
Auslösepfad: Während des 300-ms-Sleeps kann ESC den Abbruchpfad auslösen
(`RecordingCoordinator+UI.swift:35-42`), der die alte Engine stoppt und `isRestarting`
zurücksetzt (`AudioRecorder.swift:182-204`) — danach arbeitet der aufgewachte Handler auf
einer verwaisten Engine weiter (Zombie-Restart, Stale-Converter-Überschreibung, im
schlimmsten Fall Format-Mismatch-Exception im Realtime-Audio-Thread).

### C03 — AudioRecorder off-MainActor (mittel, BESTÄTIGT mit Einschränkung)

Der Kern hält: `AudioRecorder` ist nicht actor-isoliert (`AudioRecorder.swift:5-6`), sodass
`startRecording()` nach SE-0338 auf dem globalen Executor läuft; `Package.swift` aktiviert
keine abweichende Default-Isolation. **Einschränkung des Refuters:** Der behauptete
Engine-State-Race Start↔Stop ist im heutigen Ablauf nicht erreichbar, weil während des
Starts `isProcessing = true` und `appState.isRecording = false` gelten und Stop/Cancel an
ihren Guards scheitern (`RecordingCoordinator.swift:115, 163, 182`). Bestehen bleiben die
unsynchronisierten Reads von `AudioDeviceManager.availableDevices` gegen Main-Thread-Writes
sowie die off-main mutierten `@Observable`-Properties — reale, TSan-sichtbare Races, aber
mit geringerer Crash-Wahrscheinlichkeit als C01/C02. Konsequenz: Isolation aufräumen, aber
als Härtung, nicht als primärer Crash-Fix.

### C04 — `encodeClaudeCwd` falsches Encoding (hoch, BESTÄTIGT)

Bestätigt und empirisch gegen das installierte Binary geprüft: `encodeClaudeCwd` lässt
Unicode-Zeichen durch (`AgentSessionTranscript.swift:320-331`), während Claude 2.1.214
nachweislich nur ASCII-Alphanumerik behält, bei 200 Zeichen kürzt und einen Base36-Hash
anhängt. Der Runtime-Watcher deaktiviert den rettenden Glob-Fallback ausdrücklich
(`AgentSessionRuntimeWatcher.swift:372-385`). Konkretes Szenario im realen Bestand:
`/Users/giulianocosta/repos/Abhörschutz` → WhisperM8 sucht `…-Abhörschutz`, Claude schreibt
`…-Abh-rschutz` — Transcript wird nie gefunden, Statusableitung und `moveTranscript` beim
Account-Umzug laufen ins Leere (`--resume` nach Umzug: „No conversation found").

### C05 — Headless-Junk-Sessions (hoch, BESTÄTIGT)

Bestätigt im Kern: Auto-Namer und Summarizer starten Claude mit `-p` ohne
`--no-session-persistence` (`AgentSessionAutoNamer.swift:139-146`,
`AgentSessionSummarizer.swift:32-39`); `AgentHeadlessCLI` setzt kein `currentDirectoryURL`
(`AgentHeadlessCLI.swift:28-37`), der Kindprozess erbt das App-cwd. Der Indexer filtert
Print-/Headless-Sessions nicht (`ClaudeSessionIndexer.swift:67-97, 125-169`), der Merge legt
sie als Chats an. Empirisch belegt: 356 Junk-JSONLs unter `~/.claude/projects/-`, 495 von
2161 Workspace-Sessions (23 %) hängen am Phantom-Projekt `/`. Selbstverstärkend, weil Scans
über Junk-Sessions weitere Headless-Calls auslösen können.

### C06 — Account-Profile in Nicht-PTY-Pfaden ignoriert (hoch, BESTÄTIGT)

Bestätigt: Der Produktionspfad ruft `ProcessRunner.run` ohne Environment-Parameter auf
(`BackgroundAgentSpawner.swift:107-112, 223-230`); `DefaultProcessRunner` nutzt
ausschließlich `LoginShellEnvironment.processEnvironment()` (`:255-258`), das
`CLAUDE_CONFIG_DIR` gezielt entfernt (`LoginShellEnvironment.swift:110-119`). Der
Background-Stub wird ohne `claudeProfileName` erstellt
(`AgentChatsView+BackgroundAgents.swift:47-59`). Folge: `--bg`-Spawn, Attach, Logs/Stop/
Respawn und Health-Check laufen bei aktivem Nicht-main-Profil trotzdem immer unter dem
main-Account — falsches Abo/Quota, Jobs im falschen Config-Root.

### C07 — Bind-Fallback kann kapern, Merge kann Duplikate erzeugen (mittel, BESTÄTIGT)

Bestätigt: Der Fallback begrenzt Kandidaten nur nach unten (`createdAt >= -5 s`, keine
Obergrenze) und bindet ohne globalen Belegtheitscheck (`AgentSessionStore.swift:604-636`;
`AgentSessionDetailView.swift:650-682`). Konkretes Szenario: Zwei fast gleichzeitig
gestartete Tabs im selben Projekt sehen beide Rollouts; beide wählen den mit der jüngsten
`lastActivityAt` — zwei lokale Sessions binden dieselbe externe ID, ein Verlauf verwaist.
Zusätzlich kann der FSEvent-Merge außerhalb des ±5-s-Fensters eine zweite Row mit derselben
`externalSessionID` anlegen; eine nachträgliche Row-Deduplizierung existiert nicht.

### C08 — Background-Status hängt für immer auf `working` (mittel, BESTÄTIGT)

Bestätigt mit konkretem Szenario: Nach `UserPromptSubmit` steht die Background-Session auf
`.working` (`AgentSessionStatusCoordinator.swift:204-214`;
`AgentSessionStateMachine.swift:195-196`); stirbt Job oder Daemon hart (kill -9, Reboot),
feuert kein `SessionEnd`-Hook, und der Attach-PTY-Exit wird für Background-Sessions bewusst
verworfen (`AgentSessionStatusCoordinator.swift:143-153`). Der gespeicherte Working-Status
pulsiert für die restliche App-Laufzeit weiter; der einmalige Startup-Health-Check
korrigiert das nicht. Es fehlt eine Reconciliation gegen `~/.claude/jobs/<id>/state.json`
bzw. `claude agents --json`.

### C09 — Stiller Fresh-Start statt Resume (mittel, BESTÄTIGT)

Bestätigt inkl. Erreichbarkeit des Zustands: Nach erfolgreichem Prozessstart setzt
`AgentSessionDetailView.swift:583-600` `hasLaunchedInitialPrompt = true` und startet die
ID-Bindung; deren fünf Versuche enden nach 7,75 s ohne Fehlerzustand bei Misserfolg
(`:626-696`). `AgentCommandBuilder.swift:302-345` setzt für Claude `--resume` nur bei
vorhandener ID und unterdrückt bei `hasLaunchedInitialPrompt` auch den Initial-Prompt —
Ergebnis ist ein kommentarlos leerer neuer Chat statt des erwarteten Resumes. (Codex
behandelt denselben Zustand korrekt als Fehler.) Eintrittswahrscheinlichkeit steigt durch
C04/C07.

### C10 — `usleep`-Teardown verpasst den Exit-Output (hoch, BESTÄTIGT)

Bestätigt gegen die eingecheckte SwiftTerm-Quelle: `AgentTerminalController` ist
`@MainActor` (`AgentTerminalView.swift:613-614`); `terminate()` schläft synchron insgesamt
260 ms und capturt danach (`:775-794`), während SwiftTerm PTY-Daten asynchron auf die
Main-Queue zustellt (`LocalProcess.swift:124-150, 330-337`). Die Antwort-Bytes auf die
Ctrl+C liegen zum Snapshot-Zeitpunkt als noch nicht ausgeführte Main-Queue-Blöcke vor —
der Terminal-Snapshot friert systematisch den Stand *vor* dem Exit ein, und
`didCaptureSnapshot` verhindert die zweite Chance. Zusätzlich blockiert `terminateAll()`
den Main-Thread mit N×260 ms.

### C11 — `onWorkspaceChanged` ohne Ordnungsgarantie (mittel, BESTÄTIGT)

Bestätigt: `mutate` veröffentlicht `canonical` unter dem Lock, entsperrt aber vor dem
Callback (`AgentWorkspaceStore.swift:121, 139, 146-147`) — Callbacks können entgegen der
Mutationsreihenfolge eintreffen, und der Nicht-Main-Pfad des `AgentWorkspaceUIModel`
(„last Task wins") schützt nicht davor, dass die UI einen älteren Workspace-Stand anzeigt.
Der Refuter belegt einen realen Off-Main-Mutator: Die Icon-Erkennung beim View-Start läuft
als `Task.detached` und mutiert den Workspace (`AgentChatsView.swift:647, 656` →
`+ProjectManagement`). Disk-Stand bleibt korrekt; betroffen ist die UI-Konsistenz.

### C12 — Merge O(m·n) auf dem MainActor unter Store-Lock (hoch, BESTÄTIGT)

Bestätigt: Der Scan-Coordinator führt beide Indexer detached aus, wechselt für
`markStaleRunningSessionsClosed` und `mergeIndexedSessions` aber vollständig auf den
MainActor (`AgentScanCoordinator.swift:60, 78, 131, 138`). Beide Indexer liefern je bis zu
1000 Sessions (`CodexSessionIndexer.swift:13, 76`; `ClaudeSessionIndexer.swift:22, 49`);
pro indizierter Session laufen lineare Scans über alle Workspace-Sessions — Millionen
String-Vergleiche pro Scan auf dem Main-Thread, unter dem prozessweiten NSLock
(Budget `store.mutate` = 30 ms). Trifft genau den Moment der Foreground-Reaktivierung.

### C13 — Drei synchrone git-Spawns im Inspector (hoch, BESTÄTIGT)

Bestätigt: Bei sichtbarem Inspector rufen `onAppear` und `onChange(of: project?.path)` ohne
Task, Debounce oder Cache direkt `refreshGitStatus()` → `GitProjectStatus(path:)` auf
(`ProjectDetailPanel.swift:105-108, 126-131`); das führt zwingend drei serielle
`/usr/bin/git`-Aufrufe mit `waitUntilExit()` auf dem Main-Thread aus. Jeder Klick auf einen
Chat eines anderen Projekts hängt damit den Selektionswechsel — im Widerspruch zur eigenen
Projekt-Regel, die `GitBranchReader` genau deshalb als Datei-Read gebaut hat.

### C14 — `AgentWindowStore.mutate` ohne Diff-Gate (mittel, BESTÄTIGT)

Bestätigt: `mutate` schreibt immer in den beobachtbaren `state`, erhöht immer
`dirtyRevision` und plant immer einen Save (`AgentWindowStore.swift:901-905` →
`performSave` `:917-938` → unbedingtes JSON-Encoding + atomisches Schreiben). Alle Fenster
teilen denselben Store (`AgentChatsView.swift:65-103`) — auch wertgleiche Mutationen
(z. B. `reconcileSelection()` bei jedem Workspace-Change) invalidieren alle Fenster und
erzeugen überflüssige `agent-ui-state.json`-Schreibzyklen. Verstärkt C15 direkt.

### C15 — Body-Vollevaluation pro Workspace-Invalidierung (mittel, BESTÄTIGT)

Bestätigt: Alle Fenster lesen dieselbe einzige `@Observable`-Property `workspace` des
geteilten `AgentWorkspaceUIModel` (`AgentChatsView.swift:49-50`;
`AgentWorkspaceStore.swift:283-303`); nach dem Equatable-Gate wird stets der Gesamtwert
publiziert. Jedes Turn-Ende (`recordTurnEnded`, `lastActivityAt`-Bump) invalidiert damit
den kompletten Body jedes Fensters, der pro Eval mehrere O(n)-Vollpässe über tausende
importierte Sessions macht (`headerTabs`-Dictionary ~8× pro Eval, Deep-Equatable-Vergleich
in `.onChange(of: workspace)`, Sidebar-Builder-Pässe). Zusammen mit C14 die
wahrscheinlichste Ursache diffuser UI-Trägheit bei großen Workspaces.

### C16 — Ungecachter Codex-Sessions-Walk im Diktatpfad (mittel, BESTÄTIGT mit Präzisierung)

Bestätigt mit einer Präzisierung: `transcriptURL` erzeugt bei jedem Aufruf einen
ungecachten rekursiven Enumerator über `~/.codex/sessions`
(`CodexTranscriptReader.swift:36-48`); wegen des sofortigen Returns beim Treffer ist die
Formulierung „kompletter Baum bei jedem Aufruf" wörtlich zu stark — bei fehlendem oder spät
gefundenem Match wird aber der (fast) ganze, unbegrenzte Baum durchlaufen. Der Diktatpfad
reicht bei aktivem Codex-Chat real bis in diesen Walk, und `stopRecording()` wartet bis zu
1 s darauf (`RecordingCoordinator.swift:282`) — gegen ein `chatTail`-Budget von 100 ms.
Ein fertiger NSCache-gestützter Locator existiert bereits (`AgentSessionTranscript.swift:422-459`)
und wird hier schlicht nicht benutzt.

## Konsequenz

Alle 16 verifizierten Behauptungen tragen. Die Priorisierung übernimmt
[`../05-roadmap/refactor-roadmap.md`](../05-roadmap/refactor-roadmap.md); die beiden
Einschränkungen (C03: Engine-Race nicht erreichbar → Härtung statt Crash-Fix; C16:
Walk bricht bei Treffer ab → trotzdem unbounded im Miss-Fall) sind dort eingearbeitet.
