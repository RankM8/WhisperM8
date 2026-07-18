# Runde 2: Robustheits-Audit von CLI, Job-Supervisor und Codex-Runner

Stand: 2026-07-18. Analysiert wurden der aktuelle Code, die zugehörigen Unit-Tests
und der Subsystembericht `01-subsysteme/background-jobs.md`. Es wurden keine
`whisperm8 agent`-Befehle ausgeführt. F1 und F2 erklären die an 15 Jobs
beobachtete Reproduktion; F3 bis F11 sind zusätzliche, aus dem Code belegte
Robustheitslücken.

## F1: Der angeblich detachte Supervisor bleibt Teil des aufrufenden Prozessbaums

**Schweregrad:** kritisch

**Fundort:** `WhisperM8/CLI/AgentCLICommand.swift:143-146, 445-484, 515-534`;
`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-60`;
`WhisperM8/CLI/AgentSuperviseCommand.swift:14-30`;
`WhisperM8/CLI/CLIEntryPoint.swift:53-64, 91-96`;
`WhisperM8/Services/AgentChats/CodexExecRunner.swift:203-220, 274-286`

**Szenario:** `whisperm8 agent run --wait --json` startet einen Turn. Nach 300
Sekunden beendet ein äußerer Timeout den gesamten Nachfahrenbaum des Aufrufers
per SIGKILL. Obwohl `--wait` laut Hilfe nur Zuschauer ist, werden der
`agent-supervise`-Prozess und sein Codex-Kind mit erfasst. Der Job arbeitet nicht
weiter und kann später nicht mit `agent wait` zu Ende beobachtet werden.

**Beweis:** Auf Anwendungsebene ist `--wait` tatsächlich nur ein Poller:

```swift
// AgentCLICommand.swift:451-459
static func detachThenFollowAndEmit(...) async -> Int32 {
    if let launchError = launchDetachedSupervisor(...) { return launchError }
    // ...
    return await followAndEmit(store: store, shortId: shortId, json: json)
}
```

Der Launcher erzeugt den Supervisor jedoch als gewöhnliches direktes Kind und
meldet dessen PID sofort zurück:

```swift
// AgentSupervisorLauncher.swift:44-59
let process = Process()
process.executableURL = URL(fileURLWithPath: executablePath)
process.arguments = ["agent-supervise", shortId]
// ...
try process.run()
return process.processIdentifier
```

Erst nach `exec`, CLI-Dispatch und der Async-Bridge ruft das Kind selbst
`setsid()` auf; weder Ergebnis noch `errno` werden geprüft:

```swift
// AgentSuperviseCommand.swift:14-22
setsid()
signal(SIGHUP, SIG_IGN)
signal(SIGTERM, SIG_IGN)
```

`setsid()` erzeugt eine neue Session und eine eigene Prozessgruppe, ändert aber
nicht die PPID-Abstammung. Ein ancestry-/PPID-basierter Prozessbaum-Killer sieht
den Supervisor deshalb weiterhin als Nachfahren des Waiters; dessen normal
gespawntes Codex-Kind ist wiederum Nachfahre des Supervisors. SIGHUP-Ignorieren
schützt nur gegen Terminal-Hangup, nicht gegen das weder fang- noch ignorierbare
SIGKILL. Zusätzlich gibt es zwischen `Process.run()` und dem späteren `setsid()`
ein Startfenster, in dem selbst ein Kill der ursprünglichen Prozessgruppe das
Kind erreicht. Ein Ready-Handshake, der erfolgreiche Session-Trennung und die
endgültige Supervisor-Identität bestätigt, fehlt.

Wichtig ist die Abgrenzung: Ein reines `kill(-waiterPgrp, SIGKILL)` **nach**
erfolgreichem `setsid()` dürfte den Supervisor nicht treffen. Die beobachtete
Reproduktion passt daher zu rekursivem/snapshot-basiertem Töten der Nachfahren
oder zum frühen Pre-`setsid`-Fenster, nicht zu „Signalvererbung“.

**Fix-Vorschlag:** Den Spawn-Vertrag außerhalb des späteren Swift-Command-Bodys
garantieren. Für echte Unabhängigkeit von ancestry-basierten Killern sollte ein
außerhalb des Waiter-Baums laufender Broker den Job übernehmen, bevorzugt ein
launchd-/XPC-Service. Alternativ braucht es einen kleinen nativen
Daemonisierungs-Helper mit `fork` → `setsid` → zweitem `fork`/Reparenting; in
einem multithreaded Swift-Prozess dürfen zwischen `fork` und `exec` nur
async-signal-sichere Operationen laufen. Ein bloßes weiteres `setpgid` behebt
den PPID-Baum nicht, weil `setsid()` bereits eine eigene Prozessgruppe erzeugt.
Der Launcher darf erst nach einem Pipe-/Socket-Handshake Erfolg melden, der
Session, Prozessgruppe, endgültige PID und ein `launchToken` bestätigt. Codex
sollte zusätzlich eine jobeigene Prozessgruppe erhalten. Ein Integrationstest
muss wie der reale Timeout sämtliche Waiter-Nachfahren töten und anschließend
prüfen, dass ein neuer `agent wait` den vollständigen Report erhält.

**Konfidenz:** hoch für die fehlende Detach-Garantie und das Pre-`setsid`-Fenster;
mittel-hoch für den exakten externen Kill-Mechanismus, da dessen Implementierung
nicht im Repository liegt.

## F2: Transportende und Exit 0 gelten ohne Abschluss-Event oder Agentenantwort als Erfolg

**Schweregrad:** kritisch

**Fundort:** `WhisperM8/Services/AgentChats/CodexExecRunner.swift:39-51, 240-324, 410-414, 493-500`;
`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-120`;
`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:133-166`;
`WhisperM8/CLI/AgentCLICommand.swift:617-653`

**Szenario:** Beim Prozessbaum-Kill endet der von WhisperM8 beobachtete
Codex-Lauf, ohne Report, ohne `rawLastMessage` und ohne protokollarisch sauberen
Abschluss. Trotzdem landet der Job als `state=done`, `turns=1` und ohne
`failureReason`; `--wait --json` beziehungsweise ein späteres `status --json`
liefert Exit 0 und kein Feld, das den Abbruch sichtbar macht.

**Beweis:** Der Runner wartet nur auf drei Transportbedingungen und speichert
vom Prozessende ausschließlich `terminationStatus`:

```swift
// CodexExecRunner.swift:240-271
// stdout-EOF + stderr-EOF + Termination
let group = DispatchGroup()
// ...
process.terminationHandler = { proc in
    exitBox.code = proc.terminationStatus
    group.leave()
}
```

`terminationReason` wird verworfen. Das Ergebnis kann daher weder normalen Exit
noch `.uncaughtSignal` ausdrücken. Der Streamzustand merkt sich außerdem nur
Thread-ID und `turn.failed`; `turn.completed`, ein finales
`item.completed/agent_message` und selbst ein `error`-Event fallen in `default`:

```swift
// CodexExecRunner.swift:493-500
switch event {
case .threadStarted(let id) where threadID == nil: threadID = id
case .turnFailed(let message): turnFailedMessage = message ?? "turn.failed ohne Meldung"
default: break
}
```

Der Executor besitzt deshalb nur drei Negativkriterien. Wenn Watchdog und
`turn.failed` fehlen und der beobachtete Root-Prozess Status 0 meldet, folgt
bedingungslos `.done` — auch bei `lastMessage == nil`:

```swift
// CodexTurnExecutor.swift:100-119
guard result.exitCode == 0 else { return .failed(/* ... */) }
let report = result.lastMessage.flatMap(AgentReport.parse(lastMessage:))
return .done(
    report: report,
    rawLastMessage: result.lastMessage,
    threadID: result.threadID,
    duration: duration
)
```

`finalize` erhöht daraufhin `turns`, löscht den Fehler und setzt `.done`. Die
JSON-Ausgabe fügt `report`/`rawLastMessage` nur hinzu, wenn überhaupt eine letzte
Nachricht existiert:

```swift
// AgentJobSupervisor.swift:139-143
job.turns += 1
job.failureReason = nil
job.supervisorPid = nil

// AgentCLICommand.swift:643
if state.state == .done, let lastMessage { /* report/rawLastMessage */ }
```

Damit erklärt der Code exakt die beobachtete leere Erfolgsform. Eine wichtige
Nuance bleibt: Ein **direkt** vom `Process` beobachteter SIGKILL wird von
Foundation normalerweise als `.uncaughtSignal` mit einem von null verschiedenen
Status gemeldet und würde den vorhandenen `exitCode != 0`-Zweig nehmen. Die
statische Analyse kann daher nicht belegen, warum der konkrete Baum-Kill dem
beobachteten Root-Prozess Status 0 ließ; möglich sind Kill-Reihenfolge oder ein
getöteter nachgelagerter Worker bei normal endendem Wrapper. Die fehlende
`terminationReason`-Auswertung verschlechtert die Diagnose, aber die
Falschklassifikation zu `.done` entsteht entscheidend dadurch, dass Status 0
ohne jedes `turn.completed`- oder Antwort-Indiz genügt.

**Fix-Vorschlag:** `CodexTurnResult` muss Prozessende als Summentyp modellieren,
etwa `.exited(code)` versus `.signaled(signal)`, und Signale stets mit
`failureReason` wie „codex exec durch SIGKILL (9) beendet“ abbilden. Der
Streamzustand muss mindestens `sawTurnCompleted`, `sawTurnFailed`,
`sawError` und `sawCompletedAgentMessage` erfassen. `.done` ist nur zulässig bei
normalem Exit 0 **und** vorhandenem `turn.completed`; für diesen Jobvertrag sollte
zusätzlich eine frische, nichtleere finale Agentenantwort beziehungsweise
`last-message.txt` verlangt werden. Andernfalls `.failed` mit den konkret
fehlenden Invarianten schreiben. Tests müssen Exit 0 ohne Events, nur
`thread.started`, Agentenantwort ohne `turn.completed`, `error` plus Exit 0 und
echte Signalbeendigung abdecken.

**Konfidenz:** hoch für die Erfolgs-Plausibilitätslücke und die Persistenzkette;
mittel für den nicht im Repo erklärbaren Status 0 des konkret getöteten
Codex-Prozessbaums.

## F3: PID-Reuse hält tote Jobs aktiv und kann `stop` gegen einen fremden Prozess richten

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobState.swift:60-62`;
`WhisperM8/Services/AgentChats/AgentJobStore.swift:38-52, 253-263`;
`WhisperM8/CLI/AgentCLICommand.swift:368-392`;
`WhisperM8/Views/SubagentJobDetailView.swift:541-548`

**Szenario:** Ein Supervisor stirbt, seine PID wird später an einen anderen
Prozess vergeben. `agent wait` hält den Job unbegrenzt für aktiv. Ein anschließendes
`agent stop` oder der Stop-Button sendet SIGTERM an den fremden Prozess und meldet
die Aktion dennoch als erfolgreich.

**Beweis:** Die vollständige Identitätsprüfung ist `kill(pid, 0)`:

```swift
// AgentJobStore.swift:50-52
self.livenessProbe = livenessProbe ?? { pid in
    kill(pid, 0) == 0 || errno == EPERM
}
```

Der Follow-Loop hat absichtlich kein Gesamt-Timeout und beendet sich nur bei
`!state.isActive`. Bei wiederverwendeter PID tritt dieser Fall nicht ein.
`stop` validiert weder Startzeit, Executable noch Token und ignoriert sogar den
Rückgabewert des Signals:

```swift
// AgentCLICommand.swift:381, 391-392
_ = killProcess(pid, SIGTERM)
// ...
return AgentCLIExit.ok
```

Dass ein besserer Schutz möglich ist, zeigt derselbe Codebestand beim
Parent-Matching: Dort wird die Prozessstartzeit gegen `job.createdAt` geprüft
(`AgentJobWorkspaceSync.swift:214-245`).

**Fix-Vorschlag:** Mit jeder Turn-Generation `supervisorPid`, Prozessstartzeit,
erwarteten Executable-Pfad und zufälliges `launchToken` persistieren. Liveness,
Orphan-Korrektur und Stop dürfen nur bei vollständiger Identitätsübereinstimmung
handeln. Signalfehler müssen den CLI-Exitcode und die UI beeinflussen; eine
Identitätsabweichung ist „Supervisor bereits weg“, niemals ein Ziel für `kill`.

**Konfidenz:** hoch — PID ist nachweislich der einzige Liveness- und Signalanker.

## F4: Eine veraltete Orphan-Korrektur kann einen bereits abgeschlossenen Turn überschreiben

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:133-180, 249-275`;
`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:133-166`

**Szenario:** Ein Leser lädt `state=running`. Während er pausiert, finalisiert
der Supervisor den Job korrekt als `done` und beendet sich. Danach prüft der
Leser die inzwischen tote PID und schreibt aus seinem alten Vollsnapshot
`failed`. Das löscht den neueren `done`-Stand samt Turnzähler und Metriken. Das
gleiche Muster kann einen gerade neu geclaimten Folge-Turn überschreiben.

**Beweis:** `readCorrected` reicht einen zuvor gelesenen Snapshot an eine
ungesperrte Best-effort-Korrektur weiter:

```swift
// AgentJobStore.swift:249-263
func readCorrected(shortId: String) -> AgentJobState? {
    readState(shortId: shortId).map(correctIfOrphaned)
}
// ...
var corrected = state
corrected.state = .failed
corrected.failureReason = "supervisor died (pid \(pid) nicht mehr vorhanden)"
try? writeState(corrected)
```

`writeState` ersetzt atomar die Datei, aber Atomarität verhindert nur halbe JSONs;
sie verhindert keinen Lost Update. `mutateState` und `transition` sind ebenfalls
ungesperrte Read-modify-write-Operationen. Nur einzelne Aufrufer legen explizit
`withExclusiveLock` darum.

**Fix-Vorschlag:** Orphan-Korrektur, alle Supervisor-Finalisierungen und Claims
unter denselben Job-Lock legen. Innerhalb des Locks frisch lesen und nur dann
korrigieren, wenn Zustand, PID, Prozessstartzeit und `turnGeneration` noch exakt
dem geprüften Snapshot entsprechen. Langfristig sollte der Store bedingte
CAS-Updates statt frei verwendbarer Vollsnapshot-RMW-Methoden anbieten.

**Konfidenz:** hoch — das Interleaving folgt direkt aus dem ungesperrten Lesen,
Liveness-Test und Vollsnapshot-Write.

## F5: Der UI-Composer kann `running` wieder auf `spawning` zurückschreiben

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/SubagentJobDetailView.swift:461-503`;
`WhisperM8/CLI/AgentCLICommand.swift:515-534`;
`WhisperM8/Services/AgentChats/AgentJobStore.swift:133-159`;
`WhisperM8/Services/AgentChats/AgentJobState.swift:130-149`

**Szenario:** Der UI-Composer reserviert einen Folge-Turn auf `spawning` und
startet den Supervisor. Das Kind schreibt unter Lock bereits `running`. Der
Composer führt danach sein ungesperrtes Read-modify-write für die PID aus und
kann dabei den älteren `spawning`-Snapshot über `running` schreiben. Nach einem
erfolgreichen Codex-Turn ist `spawning → done` verboten; der Supervisor kann den
Abschluss nicht persistieren.

**Beweis:** Der UI-Pfad schreibt die PID ohne den Lock und ohne Zustands-Guard:

```swift
// SubagentJobDetailView.swift:492-496
let pid = try AgentSupervisorLauncher().launchDetached(/* ... */)
try store.mutateState(shortId: shortId) { $0.supervisorPid = pid }
```

Der CLI-Pfad enthält wegen genau dieses Rennens bereits den korrekteren Guard:

```swift
// AgentCLICommand.swift:528-533
try store.withExclusiveLock(shortId: shortId) {
    _ = try store.mutateState(shortId: shortId) { job in
        if job.state == .spawning, job.supervisorPid == nil { job.supervisorPid = pid }
    }
}
```

**Fix-Vorschlag:** CLI und UI müssen denselben `claimAndLaunch`-Dienst verwenden;
View-Code darf den Store nicht separat mutieren. PID-Persistenz unter Job-Lock,
nur für die erwartete Generation und nur solange noch kein Supervisor seine
eigene PID eingetragen hat. Ein kontrolliert interleavter Test sollte das Kind
zwischen Parent-Read und Parent-Write auf `running` schalten.

**Konfidenz:** hoch — die Drift zwischen beiden Produktionspfaden ist explizit
im Code sichtbar.

## F6: `takenOver` ist weder gegen `send` serialisiert noch als Transaktion recoverbar

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/AgentChatsView+Subagents.swift:19-74`;
`WhisperM8/Views/SubagentJobDetailView.swift:146-153`;
`WhisperM8/Services/AgentChats/AgentJobState.swift:130-149`;
`WhisperM8/CLI/AgentCLICommand.swift:178-239`;
`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:61-91`

**Szenario:** Erstens können ein CLI-`send` und die interaktive Übernahme
gleichzeitig denselben ruhenden Job sehen und konkurrierende Vollsnapshots
schreiben; Prompt/Supervisor und interaktives PTY laufen dann gegeneinander.
Zweitens erlaubt die UI die Übernahme eines fehlgeschlagenen oder gestoppten Jobs
ohne `codexThreadID`; der anschließende Resume ist unstartbar, `takenOver` aber
terminal. Drittens wird der Disk-State vor dem Workspace-Update umgestellt. Wirft
`updateSession`, bleibt der Job dauerhaft übernommen, obwohl die Session nicht
startfähig ist.

**Beweis:** `send` nimmt den Job-Lock, der Takeover-Pfad nicht:

```swift
// AgentChatsView+Subagents.swift:25-35
guard let state = jobStore.readCorrected(shortId: shortId) else { /* ... */ }
guard !state.isActive else { /* ... */ }
return .success(try jobStore.transition(shortId: shortId, to: .takenOver))
```

Die UI deaktiviert den Button nur für aktiv, nil oder bereits übernommen; eine
Thread-ID ist kein Guard. Nach der irreversiblen Transition folgt erst
`store.updateSession`, dessen Catch keinen Rollback ausführt. Die Zustandstabelle
kennt aus `.takenOver` bewusst keinen Rückweg. Zusätzlich konsumiert ein
Supervisor `pending-prompt.txt` bereits vor seinem gesperrten
`spawning → running`-Guard (`AgentJobSupervisor.swift:67-87`); bei einem
Takeover-Rennen kann der Prompt deshalb verschwinden, obwohl der Turn abgelehnt
wird.

**Fix-Vorschlag:** Übernahme vorab auf nichtleere Thread-ID, gültiges CWD und
startfähige Resume-Parameter prüfen. `send` und Takeover müssen denselben Lock
und dieselbe Generation-CAS verwenden. Workspace-Änderung und Disk-State als
zweiphasige, wiederholbare Operation modellieren, etwa `takeoverPending` mit
Recovery; erst nach erfolgreicher Session-Persistenz terminal auf `takenOver`
committen. Prompt-Claim und atomare Umbenennung der Pending-Datei gehören in
dieselbe gesperrte Supervisor-Transaktion.

**Konfidenz:** hoch — Lock-Asymmetrie, fehlender Thread-Guard und fehlender
Rollback sind direkte Produktionspfade.

## F7: Ein frühes Stop-Signal kann verloren gehen und der Turn dennoch `done` werden

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-57, 133-166`;
`WhisperM8/Services/AgentChats/CodexExecRunner.swift:274-286, 327-335`;
`WhisperM8/CLI/AgentSuperviseCommand.swift:20-30`

**Szenario:** `agent stop` trifft den Supervisor nach Installation seiner
SIGTERM-Quelle, aber bevor `CodexExecRunner` den gestarteten Prozess in
`self.process` veröffentlicht. `stopRequested` wird zwar gesetzt,
`runner.terminate()` ist aber ein No-op. Der Turn läuft danach vollständig und
wird bei Erfolg als `done` gespeichert.

**Beweis:** Der Stop ist nur im Supervisor sticky, nicht im Runner:

```swift
// AgentJobSupervisor.swift:46-51
stopRequested = true
runner.terminate()

// CodexExecRunner.swift:329-334
let process = self.process
guard let process, process.isRunning else { return }
process.terminate()
```

Nach `process.run()` wird ein früher Stop beim Publizieren von `self.process`
nicht erneut geprüft. `finalize` wertet `wasStopRequested` nur im
`.failed`-Zweig aus; ein `.done`-Outcome bleibt `.done`. Der vorhandene Test
wartet vor `requestStop()` 500 ms und deckt dieses Fenster nicht ab
(`AgentJobSupervisorTests.swift:149-168`).

**Fix-Vorschlag:** Cancel/Stop-Zustand und Prozesspublikation unter demselben
Lock im Runner verwalten. Ist Stop bereits angefordert, muss der Prozess direkt
beim Publizieren terminiert werden; idealerweise erhält `run` ein explizites
Cancellation-Token. Defense-in-depth: `finalize` darf bei gesetztem Stop-Flag
kein `.done` persistieren, sofern der Stop nicht nach einem bereits bewiesenen
`turn.completed` eingetroffen ist.

**Konfidenz:** hoch — es gibt keinen Pfad, der den frühen Stop nach
Prozesspublikation erneut anwendet.

## F8: Watchdog und Stop beenden weder zuverlässig den Prozessbaum noch messen sie echte Event-Idle-Zeit

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/CodexExecRunner.swift:33-36, 223-238, 240-310, 327-335, 433-449`

**Szenario:** Ein Codex-/MCP-/Browser-Kind ignoriert SIGTERM oder hält geerbte
stdout-/stderr-Pipes offen. Der Watchdog sendet einmal SIGTERM nur an den
direkten Codex-Prozess; der Supervisor wartet weiter auf Prozessende und beide
EOFs, `agent wait` hängt. Umgekehrt kann ein defekter Prozess durch beliebige
stdout-Bytes ohne gültiges JSON-Event den Watchdog endlos zurücksetzen. Echte
Aktivität ausschließlich auf stderr setzt ihn dagegen nicht zurück und kann
einen Fehlalarm erzeugen.

**Beweis:** Der Timer hat weder Gruppensignal noch Eskalation:

```swift
// CodexExecRunner.swift:229-233
self?.markStalled()
if process?.isRunning == true {
    process?.terminate()
}
```

Der Abschluss wartet zwingend auf stdout-EOF, stderr-EOF und Termination. Ein
Nachfahre mit geerbtem Pipe-FD blockiert daher `group.notify`. Gleichzeitig
definiert der Kommentar Idle als „kein Event“, der Code spannt den Timer aber bei
jeder Byte-Aktivität neu:

```swift
// CodexExecRunner.swift:446-449
if !data.isEmpty {
    watchdog?.schedule(deadline: .now() + idleTimeout)
}
```

stderr wird drainiert, berührt den Timer jedoch nicht.

**Fix-Vorschlag:** Codex beim Spawn atomar in eine eigene, identifizierte
Prozessgruppe legen. Stop/Watchdog senden SIGTERM an die ganze Gruppe, warten
eine begrenzte Grace-Frist und eskalieren dann mit SIGKILL; danach FDs schließen
und den Ausgang eindeutig als `stopped` beziehungsweise `failed/stalled`
persistieren. Idle anhand der letzten erfolgreich geparsten Protokollaktivität
mit monotoner Uhr messen; falls stderr als Aktivität zählen soll, diese Policy
explizit definieren. Tests brauchen einen SIGTERM-resistenten Nachfahren mit
offenem Pipe-FD sowie ungültige stdout-Heartbeats.

**Konfidenz:** hoch — Ziel-PID, fehlende Eskalation, EOF-Barriere und Byte-Reset
sind direkt aus dem Runner ersichtlich.

## F9: Artefakt-Schreibfehler werden verschluckt und können einen nicht resumierbaren `done`-Job erzeugen

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:192-225`;
`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:190-222`;
`WhisperM8/Services/AgentChats/CodexExecRunner.swift:313-324`;
`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:100-119`

**Szenario:** Die Platte ist voll, das Job-Verzeichnis verliert Schreibrechte
oder wird während eines Turns teilweise entfernt. Event-Appends und die frühe
Thread-ID-Persistenz schlagen fehl, ohne den Turn zu beeinflussen. Endet der
beobachtete Codex-Prozess mit Status 0, kann der Supervisor trotzdem `.done`
schreiben: `events.jsonl` ist unvollständig, `codexThreadID` fehlt und ein
Folge-`send` ist unmöglich. Fehlt auch die letzte Nachricht, greift zusätzlich
F2.

**Beweis:** Der Store verwirft alle Fehler beim Event-Write:

```swift
// AgentJobStore.swift:195-201
if let handle = FileHandle(forWritingAtPath: url.path) {
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
} else {
    try? data.write(to: url)
}
```

Auch die wichtigste Crash-Sicherheitsinformation wird best effort geschrieben:

```swift
// AgentJobSupervisor.swift:211-216
_ = try? store.mutateState(shortId: shortId) { job in
    if job.codexThreadID == nil { job.codexThreadID = threadID }
}
```

Der im `.done`-Outcome vorhandene `threadID` wird in `finalize` nicht als
Fallback persistiert. Außerdem wird `last-message.txt` vor einem Folge-Turn
nicht entfernt oder generationsgebunden; stirbt der neue Turn vor seinem Write,
kann der Runner den Report des vorherigen Turns als aktuellen einlesen.

**Fix-Vorschlag:** Sink-Methoden müssen Fehler liefern oder einen sticky
Persistenzfehler sammeln, den der Executor vor `.done` prüft. Finalize soll die
Thread-ID aus dem Outcome nochmals unter Generation-CAS persistieren. Pro Turn
einen eindeutigen Artefaktpfad verwenden oder alte Last-Message vor Start sicher
archivieren und Freshness/Generation prüfen. Ein Turn darf erst `done` werden,
wenn State, Abschluss-Event und erforderliche Artefakte dauerhaft geschrieben
sind; Tests sollten EACCES/ENOENT und einen injizierbaren ENOSPC-Writer abdecken.

**Konfidenz:** hoch für den verschluckten Fehler und die fehlende Thread-ID-
Rückfallpersistenz; mittel-hoch für das genaue Verhalten einer externen Codex-
Version bei fehlgeschlagenem `--output-last-message`-Write.

## F10: Persistenzfehler lassen `agent wait` Zustand und Exitcode widersprüchlich ausgeben

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:111-130, 229-275`;
`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:133-166`;
`WhisperM8/CLI/AgentCLICommand.swift:263-267, 469-484, 564-573`

**Szenario:** Der terminale `state.json`-Write scheitert wegen voller Platte,
fehlendem Verzeichnis oder Berechtigungsfehler. Der alte Snapshot bleibt
`running`; der Supervisor beendet sich. `readCorrected` erzeugt beim nächsten
Wait-Poll lokal `.failed`, kann auch diese Korrektur aber nicht persistieren.
`followAndEmit` beendet sich anhand des lokalen `.failed`, während `emitFinal`
die rohe alte Datei erneut liest und JSON mit `state=running` ausgibt. Der
Prozess liefert gleichzeitig Exitcode 2. Ist das Verzeichnis unlesbar oder weg,
wird derselbe Fall als „Job nicht gefunden“/Umgebungsfehler dargestellt.

**Beweis:** Die Orphan-Korrektur ignoriert ihren Write-Fehler, gibt das lokal
korrigierte Objekt aber trotzdem zurück:

```swift
// AgentJobStore.swift:259-263
var corrected = state
corrected.state = .failed
corrected.failureReason = "supervisor died (pid \(pid) nicht mehr vorhanden)"
try? writeState(corrected)
return corrected
```

Der Follow-Pfad verwendet anschließend zwei verschiedene Snapshots:

```swift
// AgentCLICommand.swift:479-481
if !state.isActive {
    emitFinal(store: store, shortId: shortId, json: json) // liest raw erneut
    return AgentJobOutput.exitCode(for: state, lastMessage: store.readLastMessage(...))
}
```

`readState` faltet Data-I/O-Fehler und Decode-Fehler per `try?` auf `nil`.
`readAllCorrected` faltet sogar jeden `contentsOfDirectory`-Fehler auf `[]`,
worauf `agent list` erfolgreich „Keine Jobs vorhanden“ meldet.

**Fix-Vorschlag:** Store-Reads als typisierte `Result`-Werte modellieren und
ENOENT, EACCES, ENOSPC sowie Decode-Fehler unterscheiden. `wait` muss genau den
Snapshot emittieren, aus dem es den Exitcode ableitet. Fehlgeschlagene
Orphan-Persistenz ist ein sichtbarer Recovery-/I/O-Fehler, nicht stiller Erfolg;
begrenzter Retry mit Backoff und ein außerhalb des einzelnen Job-Verzeichnisses
liegendes Recovery-Journal sind sinnvoll. Die vorhandene Temp-plus-`rename`-
Ersetzung schützt weiterhin gegen halbe JSON-Dateien, ersetzt aber diese
Fehlersemantik nicht.

**Konfidenz:** hoch für den Kontrollfluss und die widersprüchliche Ausgabe;
mittel für die konkrete ENOSPC-Ausprägung ohne Fault-Injection-Test.

## F11: Ein hart gestorbener Supervisor bleibt in der laufenden App ohne neuen File-Event sichtbar `running`

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentJobDirectoryMonitor.swift:30-39, 42-103`;
`WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:38-89`;
`WhisperM8/Services/AgentChats/AgentJobStore.swift:229-275`

**Szenario:** Der Supervisor stirbt per SIGKILL und kann `state.json` nicht mehr
aktualisieren. Die bereits laufende App erhält keinen relevanten FSEvent und
führt keine periodische Liveness-Korrektur aus. Der Job bleibt in Sidebar und
Detailansicht auf unbestimmte Zeit `running`, bis ein Foreground-/Launch-Trigger
oder ein anderes beobachtetes Dateiereignis zufällig einen Vollsync anstößt.
Ein separat gestartetes `agent wait` korrigiert denselben Job dagegen durch sein
Polling zeitnah.

**Beweis:** Der Directory-Monitor akzeptiert ausschließlich diese Dateinamen:

```swift
// AgentJobDirectoryMonitor.swift:36-39
return paths.contains { path in
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name == "state.json" || name == "last-message.txt"
}
```

Ein harter Prozessabbruch schreibt keine davon. Der Workspace-Sync wird
eventgetrieben sowie bei Launch/Foreground angefordert; ein Timer für aktive
Supervisor-PIDs existiert nicht. Die Orphan-Korrektur im Store hilft erst, wenn
ein solcher Sync tatsächlich liest.

**Fix-Vorschlag:** Für aktive Jobs einen langsamen periodischen Liveness-Tick
oder eine Prozessende-Quelle einführen. Die Prüfung muss die in F3 geforderte
PID-Identität und die in F4 geforderte Generation-CAS verwenden. Nach einer
Korrektur den Runtime-Snapshot unmittelbar aktualisieren und den Persistenzfehler
gegebenenfalls sichtbar machen.

**Konfidenz:** hoch — ohne Dateischreibereignis gibt es im laufenden Monitor
keinen zeitgebundenen Trigger.

## Priorisierte Fix-Reihenfolge

1. Erfolgskriterium härten: Signalart plus `turn.completed` und frische finale
   Ausgabe als zwingende Invarianten; damit wird der beobachtete Abbruch sichtbar.
2. Supervisor über einen außerhalb des Waiter-Baums liegenden Broker starten und
   den Detach per Handshake bestätigen.
3. Jobidentität (`launchToken`, Generation, PID-Startzeit) einführen und sämtliche
   State-Updates, Orphan-Korrekturen, `send` und Takeover per Lock/CAS serialisieren.
4. Codex-Prozessgruppe mit TERM→KILL-Eskalation verwalten und Stop sticky machen.
5. Artefakt-/State-I/O fehlertransparent und Wait-Ausgabe snapshot-konsistent
   machen; danach periodische App-Liveness ergänzen.
