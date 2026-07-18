# Concurrency-Audit Agent-Chats (Codex)

Stand: 2026-07-18. Geprüft wurden die Concurrency-Pfade in
`WhisperM8/Services/AgentChats/`, `AgentTerminalView` und `AgentWindowStore`
sowie unmittelbar beteiligte Aufrufer und die eingecheckte SwiftTerm-Version.
Die vier im Auftrag genannten Karten unter `01-subsysteme/` erschienen erst
während des Audits im gemeinsamen Workspace; sie wurden vor Abschluss
vollständig gelesen und gegen den Code verifiziert. Aufgenommen sind nur
Probleme mit einem konkreten Produktionspfad und einer nachvollziehbaren
Thread-/Task-Verschränkung.

## F1: MainActor-Wartezeit blockiert den PTY-Drain und friert einen veralteten Terminal-Snapshot ein

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:393-401, 775-820, 969-980`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:124-150`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:83-87`

**Szenario:** `terminate()` beziehungsweise der App-Quit-Pfad läuft auf dem
MainActor, sendet zweimal Ctrl+C und blockiert den Main-Thread dazwischen für
insgesamt 260 ms mit `usleep`. SwiftTerm liest die Exit-Bytes zwar auf seiner
Read-Queue, stellt `drainReceivedData()` aber asynchron auf die Main-Queue.
Diese Blöcke können erst nach den Sleeps laufen. WhisperM8 flusht anschließend
nur seinen nachgelagerten `TerminalFeedBatcher`, snapshotet den noch alten
SwiftTerm-Buffer und setzt `didCaptureSnapshot = true`. Später eintreffende
Exit-Bytes können dadurch nicht mehr vom `processTerminated`-Pfad gesichert
werden. Wirkung: Alternate-Screen-Exit, Schlussausgabe und Resume-Hinweis fehlen
im Snapshot; `terminateAll()` blockiert zusätzlich N × 260 ms.

**Beweis:**

```swift
// AgentTerminalView.swift
terminal.send([0x03])
usleep(80_000)
terminal.send([0x03])
usleep(180_000)
terminal.flushPendingOutput()
captureTerminalSnapshot()
```

```swift
// SwiftTerm/LocalProcess.swift
self.dispatchQueue = dispatchQueue ?? DispatchQueue.main
// ...
dispatchQueue.async { [weak self] in
    self?.drainReceivedData()
}
```

**Fix-Vorschlag:** Teardown als asynchrone, zweiphasige Sequenz ausführen
(`Task.sleep` statt `usleep`), damit der MainActor zwischen den Interrupts
SwiftTerms Drain abarbeiten kann. Den Snapshot erst nach Prozessende oder einer
expliziten „keine neuen Bytes“-Barriere mit Timeout ziehen und
`didCaptureSnapshot` erst dann setzen. Beim App-Quit
`applicationShouldTerminate` mit `.terminateLater` und anschließendem Reply
verwenden.

**Konfidenz:** hoch

## F2: Der UI-Composer kann den Supervisor-Status von `running` auf einen alten `spawning`-Snapshot zurücksetzen

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/SubagentJobDetailView.swift:461-503`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:136-142`; `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:77-87`; Gegenbeleg: `WhisperM8/CLI/AgentCLICommand.swift:521-534`

**Szenario:** Der Composer reserviert den Job unter `.claim.lock` als
`spawning` und startet den detachten Supervisor. Danach setzt der Parent die
PID über ein ungeschütztes `mutateState`. Liest dieser Pfad `spawning`, kann
der Child-Prozess anschließend unter dem Job-Lock `spawning → running`
schreiben. Der Parent renamt danach seinen alten vollständigen
`spawning`-Snapshot über die neue `state.json`. Beim Turn-Ende ist
`spawning → done` laut Guard-Tabelle unzulässig; ein erfolgreicher Turn endet
als Zustandskonflikt beziehungsweise bleibt inkonsistent. Der CLI-Pfad
dokumentiert genau dieses Race bereits und schützt denselben PID-Write korrekt.

**Beweis:**

```swift
// SubagentJobDetailView.swift
let pid = try AgentSupervisorLauncher().launchDetached(...)
try store.mutateState(shortId: shortId) { $0.supervisorPid = pid }
```

```swift
// AgentJobStore.swift
guard var state = readState(shortId: shortId) else { ... }
change(&state)
try writeState(state)
```

```swift
// AgentCLICommand.swift — korrekter Parallelpfad
try store.withExclusiveLock(shortId: shortId) {
    _ = try store.mutateState(shortId: shortId) { job in
        if job.state == .spawning, job.supervisorPid == nil {
            job.supervisorPid = pid
        }
    }
}
```

**Fix-Vorschlag:** Den Composer denselben zentralen
`launchDetachedSupervisor`-Pfad wie die CLI verwenden lassen. Mindestens muss
der PID-Write unter `withExclusiveLock` laufen und nur bei weiterhin
`state == .spawning && supervisorPid == nil` mutieren. Alle
Read-modify-write-Operationen auf `state.json` müssen denselben
prozessübergreifenden Lock-Vertrag einhalten.

**Konfidenz:** hoch

## F3: „Interaktiv übernehmen“ racet gegen den atomaren `agent send`-Claim

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/AgentChatsView+Subagents.swift:24-35`; `WhisperM8/CLI/AgentCLICommand.swift:178-186, 208-239`; `WhisperM8/Services/AgentChats/AgentJobStore.swift:148-180`

**Szenario:** Die App liest für die Übernahme einen ruhenden Job und führt
`transition(.takenOver)` ohne `.claim.lock` aus. Parallel hält `agent send`
den Lock und schreibt `done → spawning` plus `pending-prompt.txt`. Hat die App
vorher noch `done` gelesen, kann sie danach ihren vollständigen alten Snapshot
als `takenOver` über `spawning` schreiben. Der bereits gestartete Supervisor
konsumiert den Prompt, darf aber `takenOver → running` nicht ausführen. Die UI
meldet erfolgreiche Übernahme, während ein Folge-Turn bereits reserviert war.
Bei umgekehrter Write-Reihenfolge kann ein alter `spawning`-Snapshot wiederum
die erfolgreiche Übernahme überschreiben.

**Beweis:**

```swift
// AgentChatsView+Subagents.swift
guard !state.isActive else { ... }
return .success(try jobStore.transition(shortId: shortId, to: .takenOver))
```

```swift
// AgentCLICommand.swift
claim = try store.withExclusiveLock(shortId: options.shortId) {
    AgentSendCLI.claim(store: store, options: options)
}
```

**Fix-Vorschlag:** Vorprüfung und `transition(.takenOver)` gemeinsam innerhalb
von `withExclusiveLock` ausführen. Der Lock muss für alle exklusiven
Job-Claims gelten, nicht nur für `send`. Danach ausschließlich den unter Lock
zurückgegebenen Snapshot für die UI-Übernahme verwenden.

**Konfidenz:** hoch

## F4: In-flight Hook-Reads liefern nach `stopTracking` oder Entry-Ersatz weiterhin alte Events

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:107-165, 184-215`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:143-158`; `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:155-171`

**Szenario:** Ein vnode-Handler oder der Initial-Drain startet einen detached
Read und hält den alten `Entry` über die `await`-Grenze. Während der Read läuft,
beendet der Prozess: `stopTracking` entfernt den Dictionary-Eintrag und
cancelt die DispatchSource, aber nicht den bereits laufenden Task. Nach dem
`await` prüft `handleFileEvent` weder, ob der Entry noch registriert ist, noch
eine Generation. Ein verspätetes `SessionStart` oder `UserPromptSubmit` wird
daher nach dem Stop zugestellt. Die State-Machine interpretiert genau diese
beiden Signale absichtlich als starke Lebenszeichen und belebt `.stopped` oder
`.errored` wieder. Beim Restart kann ein alter Entry außerdem eine alte externe
Session-ID in den neuen Lauf binden.

**Beweis:**

```swift
source.setEventHandler { [weak self, weak entry] in
    guard let self, let entry else { return }
    Task { @MainActor in
        await self.handleFileEvent(for: entry)
    }
}
```

```swift
func stopTracking(localSessionID: UUID) {
    guard let entry = entries.removeValue(forKey: localSessionID) else { return }
    cleanupEntry(entry)
}

private func handleFileEvent(for entry: Entry) async {
    let events = await Task.detached { store.readNewEvents(from: eventURL) }.value
    // Kein entries[entry.localSessionID] === entry / Generation-Guard
    for event in events { deliver(event, for: entry, now: now) }
}
```

**Fix-Vorschlag:** Jedem Entry eine monotone Generation geben und nach jeder
`await`-Grenze prüfen, dass der aktuelle Dictionary-Eintrag noch dieselbe
Generation/Identität hat. Den laufenden Drain-Task im Entry halten und beim
Cleanup canceln. `deliver` selbst sollte den Identitäts-Guard als letzte
Barriere wiederholen.

**Konfidenz:** hoch

## F5: Workspace-Callbacks können die `@Observable`-Projektion auf einen älteren Stand zurücksetzen

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:139-148, 290-305`; realer Background-Writer: `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:178-184`

**Szenario:** Der detached Icon-Resolver commitet Mutation A unter dem
Workspace-Lock, entsperrt und wird vor dem Callback pausiert. Der MainActor
commitet danach User-Mutation B und spiegelt B wegen des Main-Thread-Pfads
synchron in das UI-Modell. Anschließend ruft der Background-Thread Callback A;
dieser enqueut einen MainActor-Task, der die UI wieder auf A setzt. Der
kanonische Store und die Platte enthalten B, die UI bleibt aber bis zur
nächsten Mutation auf dem älteren Stand und kann etwa eine gerade gelöschte
Session oder einen alten Titel erneut anzeigen.

**Beweis:**

```swift
canonical = workspace
try persistLocked(workspace)
lock.unlock()
onWorkspaceChanged?(workspace)
```

```swift
if Thread.isMainThread {
    MainActor.assumeIsolated { self?.workspace = newValue }
} else {
    Task { @MainActor in self?.workspace = newValue }
}
```

```swift
Task.detached(priority: .utility) { [store] in
    try store.applyAutoResolvedProjectIcon(id: id, relativePath: resolved)
}
```

**Fix-Vorschlag:** Unter dem Store-Lock pro effektiver Mutation eine monotone
Revision vergeben und `(revision, workspace)` zustellen. Das MainActor-Modell
darf nur Revisionen größer als seine zuletzt angewandte Revision übernehmen.
Die Callback-Registrierung selbst über eine lock-geschützte Subscribe-API
statt über eine frei beschreibbare Property führen.

**Konfidenz:** hoch

## F6: Explizites PTY-Terminieren kann den einzigen Lifecycle-Cleanup-Callback wegcanceln

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:367-370, 775-797, 969-980`; `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:143-164`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:269-276, 513-523, 546-572`

**Szenario:** Beendet sich die TUI nicht während der zwei Ctrl+C-Wartefenster,
ruft WhisperM8 `terminal.terminate()` auf. SwiftTerm sendet SIGTERM und ruft
unmittelbar `childStopped()` auf; dabei wird der Process-DispatchSource
gecancelt. `terminate()` ruft den Delegate nicht selbst. WhisperM8 entfernt den
Controller direkt aus der Registry, führt `onTerminated` aber ausschließlich im
Delegate `processTerminated` aus. Ist das Exit-Event noch nicht zugestellt,
fällt damit der StatusCoordinator-Cleanup aus: Launch-Grace, RuntimeWatcher,
Hook-Bridge und Summarizer bleiben im alten Lifecycle. Ein konkreter Pfad ist
„Stop all“: Der Workspace wird zwar `.closed`, der Runtime-Status kann aber
weiter `.working` bleiben und alte File-Watches leben weiter.

**Beweis:**

```swift
// WhisperM8
terminal.terminate()
isRunning = false
// Kein onTerminated hier
```

```swift
// SwiftTerm
if shellPid != 0 { kill(shellPid, SIGTERM) }
childStopped() // cancelt childMonitor
```

```swift
// Einziger App-Callback
func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor in
        // ...
        self.onTerminated(exitCode)
    }
}
```

**Fix-Vorschlag:** Im Controller einen genau-einmal-Finalizer einführen, den
sowohl der explizite Terminate-Pfad als auch der spätere Delegate-Callback
aufrufen. Der Finalizer muss StatusCoordinator-Cleanup und `onTerminated`
ausführen und spätere Doppelcallbacks per Controller-/Launch-Generation
verwerfen.

**Konfidenz:** hoch für den fehlenden Callback-Pfad, mittel-hoch für die
sichtbare Auswirkung je nach Exit-Timing

## F7: `unwatch` setzt die RuntimeWatcher-Generation zurück, sodass ein alter Poll einen neuen Lauf akzeptiert

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:137-176, 191-199, 286-359`

**Szenario:** Für eine Session läuft Poll A mit Generation 1 in einem detached
Task. `markTerminated` entfernt `watched[sessionID]`, lässt aber
`pollingSessionIDs`, geplante Tasks und die Generation außerhalb des Eintrags
nicht bestehen. Wird dieselbe lokale Session-ID schnell neu gestartet, erzeugt
`watch` einen frischen `WatchedSession`, erhöht dessen Generation ebenfalls von
0 auf 1 und unterdrückt den Sofort-Poll wegen des noch laufenden A. A kehrt
zurück; der reine Gleichheits-Guard `1 == 1` besteht fälschlich. Der alte
Snapshot schreibt URL, Stat und letztes Event in den neuen Eintrag und liefert
eine alte Statusentscheidung an den neuen Lifecycle.

**Beweis:**

```swift
func markTerminated(sessionID: UUID) {
    detachEventSource(sessionID: sessionID)
    watched.removeValue(forKey: sessionID)
}
```

```swift
var entry = watched[sessionID] ?? WatchedSession(... generation: 0)
entry.generation += 1
watched[sessionID] = entry
pollOne(sessionID: sessionID)
```

```swift
guard current.generation == snapshotGeneration else { return }
current.transcriptURL = snapshot.transcriptURL
// ...
self.onDecision?(sessionID, decision)
```

**Fix-Vorschlag:** Die Watch-Generation pro Session außerhalb von `watched`
monoton weiterführen oder pro Watch-Instanz einen eindeutigen Token verwenden.
Bei `unwatch`/`markTerminated` alle Pending-Sets bereinigen und laufende Polls
per Token invalidieren; der Completion-Pfad muss Token und aktuelle
Entry-Identität prüfen.

**Konfidenz:** mittel-hoch

## F8: Parallele Hook-Drains schützen den Cursor, aber nicht die Zustellreihenfolge

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:135-165, 202-215`; `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:56-106`

**Szenario:** Initial-Drain und vnode-Handler können mehrere detached Reads
starten. Der NSLock im EventStore serialisiert Datei und Cursor: Task A liest
den älteren Batch und gibt den Lock frei; nach einem Append liest Task B den
neueren Batch. Die Fortsetzungen zum MainActor sind jedoch nicht an diese
Lock-Reihenfolge gekoppelt. B kann zuerst liefern, danach A. So kann etwa ein
neueres `Stop` vor einem älteren `UserPromptSubmit` ankommen und der finale
Status wieder `.working` statt `turnDone` werden, bis ein weiteres Event die
Reihenfolge zufällig korrigiert.

**Beweis:**

```swift
// Pro Kernel-Event ein eigener Task
Task { @MainActor in
    await self.handleFileEvent(for: entry)
}

// Separater Initial-Drain
Task { @MainActor [weak self, weak entry, store] in
    let initialEvents = await Task.detached {
        store.readNewEvents(from: eventURL)
    }.value
    // direkte Zustellung
}
```

**Fix-Vorschlag:** Pro Entry exakt einen Drain zulassen. Trifft währenddessen
ein Event ein, nur `pendingDrain = true` setzen und nach Abschluss erneut
lesen. Damit folgen Read, Cursor-Fortschritt und Zustellung derselben seriellen
Entry-Pipeline; das Trailing-Edge-Muster existiert bereits im RuntimeWatcher.

**Konfidenz:** mittel-hoch

## F9: Der `willTerminate`-Flush ist keine Quiescence-Barriere gegen spätere Background-Mutationen

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:81-87, 189-204, 254-273`; realer Producer: `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:178-184`

**Szenario:** Der detached Icon-Resolver durchsucht beim Quit noch ein Repo.
Der Main-Thread erhält `willTerminate`, cancelt das aktuelle Debounce-WorkItem
und wartet mit `flushQueue.sync`, bis der bisherige Stand geschrieben ist.
Danach gibt es weder ein `terminating`-Flag noch eine Producer-Barriere. Der
Icon-Task beendet seine Suche erst anschließend, mutiert den Workspace und
setzt `dirty = true` samt neuem 0,5-s-WorkItem. AppKit kann den Prozess vor
dessen Ausführung beenden. Wirkung: der letzte Auto-Icon-/Lookup-Stand geht
verloren und muss beim nächsten Start erneut ermittelt werden.

**Beweis:**

```swift
private func flushSync(reason: String) {
    pendingFlush?.cancel()
    flushQueue.sync { drain(reason: reason) }
}
```

```swift
// Eine spätere Mutation darf weiter rearmen
dirty = true
flushQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
```

**Fix-Vorschlag:** Im frühen Terminate-Hook zuerst Background-Producer
canceln/abwarten und erst danach final flushen. Ergänzend einen Store-Lifecycle
`running → quiescing` unter dem Lock einführen; post-quiesce Mutationen müssen
entweder synchron in den finalen Barrier-Flush eingehen oder abgewiesen werden.

**Konfidenz:** hoch

## F10: Zwei unabhängige Index-Läufe überschreiben gegenseitig ihren Cache-Snapshot

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:127-148`; `WhisperM8/Views/AgentChatsView+RuntimeServices.swift:107-140`; `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:71-103`

**Szenario:** Ein FSEvent-/Foreground-Scan im globalen Coordinator und ein
manueller View-Refresh können gleichzeitig jeweils
`load → indexieren → save` auf `agent-session-index-cache.json` ausführen. Das
`inFlight`-Coalescing des Coordinators kennt den View-Task nicht. Beide Writes
sind einzeln atomar, aber der zuletzt beendete Lauf ersetzt die komplette Datei
mit seinem früher geladenen Snapshot und entfernt so Cache-Einträge des
anderen. Folge sind unnötige erneute JSONL-Parses und konkurrierende Vollscans;
die Workspace-Daten selbst bleiben durch den zentralen Store geschützt.

**Beweis:**

```swift
// AgentScanCoordinator
let cacheStore = AgentSessionIndexCacheStore()
var cache = cacheStore.load()
// ... Indexer ...
cacheStore.save(cache)
```

```swift
// AgentChatsView+RuntimeServices — unabhängiger Detached-Task
let cacheStore = AgentSessionIndexCacheStore()
var cache = cacheStore.load()
// ... Indexer ...
cacheStore.save(cache)
```

**Fix-Vorschlag:** Alle produktiven Index-Läufe durch den
`AgentScanCoordinator` routen. Alternativ den CacheStore als prozessweiten
Actor/serialisierten Dienst ausführen und beim Save mit dem aktuellen
Disk-Stand mergen.

**Konfidenz:** hoch

## F11: Ein abgebrochener Background-Tracker-Refresh kann den Handle eines neueren Tasks löschen

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/AgentChats/ActiveBackgroundSessionTracker.swift:67-93, 116-138`; produktiver Start/Stop-Pfad: `WhisperM8/Views/AgentChatsView.swift:872-890`

**Szenario:** Refresh A liest detached. Ein schneller Tabwechsel weg von und
wieder zu `.agentView` ruft `stop()` und `start()` auf: A wird gecancelt,
`refreshTask` auf `nil` gesetzt und Refresh B gespeichert. Wenn A danach auf den MainActor
zurückkehrt, schlägt sein Cancellation-Guard an, setzt aber unconditionally
`self.refreshTask = nil` und löscht damit den Handle von B. Der nächste
Keystroke-`nudge()` darf nun Refresh C parallel zu B starten. Hat B bereits
einen älteren Disk-Snapshot gelesen, aber C kehrt zuerst zurück, schreibt C den
neueren Stand und B danach wieder den älteren in `currentSession`. Die Anzeige
bleibt bis zum nächsten Poll falsch.

**Beweis:**

```swift
func stop() {
    refreshTask?.cancel()
    refreshTask = nil
}
```

```swift
refreshTask = Task { @MainActor [weak self] in
    let result = await Task.detached { Self.buildSnapshot(...) }.value
    guard let self, !Task.isCancelled, self.isRunning else {
        self?.refreshTask = nil // kann bereits Task B gehören
        return
    }
    self.currentSession = result.currentSession
    self.refreshTask = nil
}
```

**Fix-Vorschlag:** Pro Refresh eine Generation oder Task-ID erfassen und im
Completion-Pfad nur dann State sowie `refreshTask` ändern, wenn der aktuelle
Handle noch zu dieser Generation gehört. Alternativ Refreshes wie im
JobWorkspaceSync mit `isRefreshing + pendingRefresh` strikt serialisieren.

**Konfidenz:** hoch

## F12: Ein nach natürlichem Exit wiederverwendeter PID kann beim Terminal-Restart einen fremden Prozess treffen

**Schweregrad:** kritisch

**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:352-369, 775-795, 969-980`; `WhisperM8/Views/AgentSessionDetailView.swift:563-565`; `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:269-277, 365-370, 546-572`

**Szenario:** Ein Terminalprozess beendet sich selbst. SwiftTerm wartet ihn im
Process-Monitor mit `waitpid` ab, setzt `running = false`, lässt `shellPid` aber
auf dem alten Zahlenwert stehen. WhisperM8 markiert daraufhin den Controller
als beendet, behält ihn jedoch in der Registry. Wird dieser PID vom System
zwischenzeitlich an einen anderen Prozess vergeben und der Benutzer startet
die Session neu, ruft `restartTerminal()` zuerst die Registry-Terminierung des
alten Controllers auf. Dessen `isRunning == false` überspringt lediglich die
beiden Ctrl+C; `terminal.terminate()` läuft trotzdem und sendet `SIGTERM` an
den veralteten, inzwischen fremden PID. Wirkung: Ein nicht zu WhisperM8
gehörender Prozess wird beendet.

**Beweis:**

```swift
// SwiftTerm: Natürlicher Exit wartet das Kind ab, invalidiert shellPid aber nicht.
func processTerminated () {
    var n: Int32 = 0
    waitpid (shellPid, &n, WNOHANG)
    delegate?.processTerminated(self, exitCode: n)
    childStopped()
}

func childStopped(cancelProcessMonitor: Bool = true) {
    running = false
    // kein shellPid = 0
}
```

```swift
// WhisperM8: Nur Ctrl+C ist durch isRunning geschützt.
func terminate() {
    if isRunning { /* Ctrl+C */ }
    // ...
    terminal.terminate()
    isRunning = false
}
```

```swift
// SwiftTerm: Der stehen gebliebene PID wird ungeprüft signalisiert.
if shellPid != 0 {
    kill(shellPid, SIGTERM)
}
```

**Fix-Vorschlag:** SwiftTerm muss `shellPid` unmittelbar nach erfolgreichem
Reaping atomar invalidieren und `terminate()` darf nur einen nachweislich noch
zum aktuellen Prozesslauf gehörenden PID signalisieren. Zusätzlich sollte die
Registry einen natürlich beendeten Controller beim Restart ohne erneuten
Prozess-Kill entfernen. Eine Laufgeneration pro Controller verhindert, dass
Callbacks oder PIDs eines vorherigen Starts auf den neuen Lauf wirken.

**Konfidenz:** hoch

## Zusammenfassung

- Kritisch: 1
- Hoch: 4
- Mittel: 4
- Niedrig: 3

Das gefährlichste Race ist F12: Nach einem natürlichen Terminal-Exit bleibt
der abgewartete PID in SwiftTerm gespeichert. Bei PID-Wiederverwendung kann ein
späterer Session-Restart dadurch `SIGTERM` an einen fremden Prozess senden.

Ohne Befund blieben insbesondere die Lock-Reihenfolge
`persistLock → workspace lock`, Registry-Erzeugung des WorkspaceStores,
`AgentWindowStore`-Debounce/Retry auf dem MainActor, atomare Einzelwrites von
`AgentSessions.json` und `agent-ui-state.json` sowie der cancel/rename-Pfad des
gemeinsamen `FileEventSource`. Dort wurde kein konkreter Deadlock, ungeordneter
zweiter Produktionswriter oder falscher Publisher-Thread nachgewiesen.
