# Concurrency-Findings Agent-Chats (Fable, zweite unabhängige Jagd)

> Auftrag: NSLock-Disziplin im WorkspaceStore, DispatchSource-Lifecycle,
> Timer/Debounce-Races, @Observable/@MainActor-Verletzungen, willTerminate-Flush
> vs. Debounce, PTY-Teardown. Reine Code-Analyse (kein Build/Test), Stand 2026-07-18.
>
> Geprüft und **ohne Befund**: NSLock-Disziplin der Mutation-Closures (alle
> Git-/Config-Lookups sind korrekt vor `mutate` gehoistet, `AgentSessionStore.swift:136-138,
> 717-734, 916-925`), Drain-/persistLock-Design des `AgentWorkspaceStore`
> (kein älterer Snapshot kann einen neueren Write überholen), FD-Lifecycle der
> `ClaudeHookBridge.Entry` (cancel-Handler und `deinit` schließen den FD nachweislich
> genau einmal, `ClaudeHookBridge.swift:43-47, 141-147`), FSEvents-Teardown beider
> Monitore, `AgentTranscriptCache`-Generation-Guards, `AgentWindowStore`-Debounce
> inkl. `flush()` in `applicationWillTerminate` (`WhisperM8App.swift:360`),
> Coalescing in `AgentJobWorkspaceSync` sowie der Generation-Guard des
> `AgentSessionRuntimeWatcher`.

---

## F1: PTY-Teardown wartet per `usleep` auf Output, den der blockierte Main-Thread gar nicht empfangen kann — Terminal-Snapshot verpasst systematisch den Exit-Output

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:775-797` (`terminate()`), `:393-401` (`captureAllSnapshotsForAppQuit()`), `:808-820` (`captureTerminalSnapshot()`); SwiftTerm `.build/checkouts/SwiftTerm/Sources/SwiftTerm/LocalProcess.swift:127-129, 148-150` und `Mac/MacLocalTerminalView.swift:86`

**Szenario (Auslöser → Wirkung):**
User schließt einen laufenden Chat-Tab (oder beendet die App). `terminate()` läuft auf dem MainActor: 2× Ctrl+C senden, dazwischen `usleep(80_000)` und `usleep(180_000)`, dann `flushPendingOutput()` + `captureTerminalSnapshot()`. Die Antwort-Bytes der TUI (Alternate-Screen-Exit, Resume-Hinweis `claude --resume …`) kommen aber über SwiftTerms `LocalProcess`, das Delegate-Daten **asynchron auf die Main-Queue** dispatcht — und die ist während der gesamten 260 ms in `usleep` blockiert. Die Exit-Bytes liegen beim Snapshot-Zeitpunkt als noch nicht ausgeführte Main-Queue-Blöcke vor; der Snapshot friert den Stand **vor** dem Ctrl+C ein (bei TUIs: den Normal-Buffer von vor dem Alternate-Screen). Weil `didCaptureSnapshot` danach `true` ist, ist der spätere `processTerminated`-Pfad ein No-op — der eigentlich gewollte Exit-Output landet nie im Snapshot. Zusätzlich blockiert `terminateAll()` (Stop-all/Menubar) den Main-Thread mit N×260 ms.

**Beweis:**
```swift
// AgentTerminalView.swift:779-793 (MainActor!)
if isRunning {
    terminal.send([0x03])
    usleep(80_000)
    terminal.send([0x03])
    usleep(180_000)
}
terminal.flushPendingOutput()
// … „nach dem Flush steht der komplette Exit-Output … im Normal-Buffer" …
captureTerminalSnapshot()
```
SwiftTerm liefert PTY-Bytes ausschließlich über die beim Init gewählte Queue — für `LocalProcessTerminalView` ist das die Main-Queue:
```swift
// LocalProcess.swift:127-129
self.dispatchQueue = dispatchQueue ?? DispatchQueue.main
// LocalProcess.swift:148-150 (Read-Handler → Delivery)
dispatchQueue.async { [weak self] in
    self?.drainReceivedData()   // → delegate?.dataReceived(slice:)
}
// MacLocalTerminalView.swift:86
process = LocalProcess (delegate: self)   // keine eigene Queue
```
Ein `dispatchQueue.async`-Block kann nicht laufen, solange der Main-Thread in `usleep` steckt; er läuft erst **nach** Rückkehr von `terminate()` — also nach dem Snapshot. `captureTerminalSnapshot()` setzt `didCaptureSnapshot = true` (`:809-810`), wodurch die zweite Capture-Chance in `processTerminated` (`:969-981`) entfällt. Identisches Muster im App-Quit-Pfad `captureAllSnapshotsForAppQuit()` (`:393-401`, gerufen aus `applicationShouldTerminate`, `WhisperM8App.swift:344-352`). Die JSONL-Flush-Absicht der Wartezeit funktioniert (das CLI schreibt selbst), die Snapshot-Absicht nicht.

**Fix-Vorschlag:**
Die Wartezeit nicht-blockierend machen: `terminate()` in eine async-Sequenz überführen (`try await Task.sleep` statt `usleep`), damit der Runloop die queued `dataReceived`-Blöcke zwischen Ctrl+C und Capture verarbeiten kann — oder den Snapshot erst im `processTerminated`-Callback (bzw. nach einem „keine neuen Bytes seit X ms"-Kriterium mit Timeout) ziehen und `didCaptureSnapshot` erst dort setzen. Für den App-Quit: `applicationShouldTerminate` mit `.terminateLater` + `reply(toApplicationShouldTerminate:)` nach async-Wartefenster.

**Konfidenz:** hoch (Delivery-Queue in der eingecheckten SwiftTerm-Quelle verifiziert; Verhalten folgt deterministisch aus dem GCD-Modell).

---

## F2: `onWorkspaceChanged` wird außerhalb des Locks gerufen — Out-of-order-Delivery kann der UI einen älteren Workspace-Stand unterschieben; die Callback-Property selbst ist unsynchronisiert

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:64, 139-148, 290-306`

**Szenario (Auslöser → Wirkung):**
Zwei Mutationen aus verschiedenen Threads: Thread B (z. B. ein künftiger/wieder eingeführter Detached-Aufrufer — der Store wirbt explizit damit, „aus Detached-Tasks (Scan/Index/Retention)" nutzbar zu sein, `:17-19`) mutiert zu Stand W1, verlässt den Lock und wird **vor** dem Callback-Aufruf descheduled. Der MainActor mutiert danach zu W2 und spiegelt W2 synchron in `AgentWorkspaceUIModel` (`Thread.isMainThread`-Pfad, `:293-299`). Erst jetzt ruft Thread B `onWorkspaceChanged(W1)` → `Task { @MainActor }` setzt `workspace = W1`. Die UI zeigt den **älteren** Stand (W2s Änderung fehlt) bis zur nächsten beliebigen Mutation; die Disk bleibt korrekt (canonical ist W2). Zweites Problem: `onWorkspaceChanged` ist eine ungeschützte `var` auf einer `@unchecked Sendable`-Klasse — das Setzen in `AgentWorkspaceUIModel.init` (`:292`) gegen ein paralleles Lesen in `mutate` (`:147`) ist ein Data Race im Sinne des Swift-Memory-Models. Drittens: zwischen `store.read { $0 }` (`:291`) und dem Setzen des Callbacks ist ein Mutationsfenster, dessen Änderung die UI nie erreicht.

**Beweis:**
```swift
// AgentWorkspaceStore.swift:139-148
canonical = workspace
do { try persistLocked(workspace) } catch { … }
lock.unlock()
onWorkspaceChanged?(workspace)   // ← außerhalb des Locks, keine Ordnungs-Garantie
```
```swift
// AgentWorkspaceStore.swift:300-304 (Nicht-Main-Pfad)
Task { @MainActor in
    self?.workspace = newValue   // ← „last Task wins", nicht „neuester Stand wins"
}
```
Heute rufen faktisch alle Produktions-Mutatoren auf dem MainActor (Scan-Merge via `MainActor.run`, `AgentScanCoordinator.swift:138-147`; View-Refresh im MainActor-`Task`, `AgentChatsView+RuntimeServices.swift:113-140`; StatusCoordinator/AutoNamer/JobSync sind `@MainActor`) — dort serialisiert der Actor die Callbacks korrekt. Das Race ist damit **latent**, aber der dokumentierte Vertrag des Stores (thread-frei nutzbar) deckt es nicht ab, und der Off-Main-Pfad in `AgentWorkspaceUIModel` (`:300-304`) existiert genau für diesen Fall — ohne Ordnungsschutz.

**Fix-Vorschlag:**
Unter dem Lock eine monoton steigende Revisionsnummer pro effektiver Mutation ziehen und `(revision, workspace)` an den Callback geben; `AgentWorkspaceUIModel` verwirft Stände mit `revision <= lastApplied`. `onWorkspaceChanged` beim Setzen/Lesen über den bestehenden Lock (oder `OSAllocatedUnfairLock`) schützen; alternativ die Zustellung generell über eine serielle Queue in Lock-Reihenfolge fahren.

**Konfidenz:** hoch für den Mechanismus (Code-Pfad eindeutig), mittel für das heutige Auftreten (derzeit keine Off-Main-Mutatoren gefunden).

---

## F3: ClaudeHookBridge — Initial-Drain und Event-Handler lesen konkurrierend über denselben Cursor; die Zustellreihenfolge über Task-Grenzen ist nicht garantiert

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:135-140, 155-165, 202-216`; `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:56-106`

**Szenario (Auslöser → Wirkung):**
`startTracking` startet einen Initial-Drain-`Task` (`:155-165`); praktisch gleichzeitig feuert die frische DispatchSource ihr erstes `.write`-Event → `handleFileEvent` startet einen zweiten `Task` (`:135-140`). Beide lesen via `Task.detached` über `ClaudeHookEventStore.readNewEvents` — der NSLock (`ClaudeHookEventStore.swift:56-57, 61-63`) serialisiert die Reads korrekt (keine Duplikate/Verluste), aber **wer zuerst den Lock bekommt, ist unbestimmt**, und die anschließende Zustellung auf dem MainActor folgt der Task-Completion-Reihenfolge, nicht der Datei-Reihenfolge. Bei mehr als zwei gleichzeitig anhängigen Reads (Burst: mehrere vnode-Events + Initial-Drain) kann so z. B. das `SessionStart`-Binding nach einem späteren `PreToolUse` desselben Bursts verarbeitet werden — das externe-ID-Binding (`AgentSessionStatusCoordinator.bindExternalSessionID`) verzögert sich um einen Batch, und die State-Machine sieht Signale in leicht verdrehter Folge.

**Beweis:**
```swift
// ClaudeHookBridge.swift:135-140 — pro Kernel-Event ein eigener Task
source.setEventHandler { [weak self, weak entry] in
    guard let self, let entry else { return }
    Task { @MainActor in
        await self.handleFileEvent(for: entry)   // → Task.detached { store.readNewEvents(…) }
    }
}
// ClaudeHookBridge.swift:155-158 — paralleler Initial-Drain, gleicher Cursor
Task { @MainActor [weak self, weak entry, store] in
    let initialEvents = await Task.detached(priority: .utility) {
        store.readNewEvents(from: eventURL)
    }.value
```
Es gibt keinen Mechanismus, der die Batch-Zustellung in Cursor-Reihenfolge erzwingt (kein in-flight-Coalescing wie `pendingRepoll` im RuntimeWatcher).

**Fix-Vorschlag:**
Reads pro Entry serialisieren mit Trailing-Edge statt paralleler Tasks — exakt das Muster, das `AgentSessionRuntimeWatcher.scheduleEventPoll`/`pendingRepoll` (`AgentSessionRuntimeWatcher.swift:245-260`) bereits implementiert: läuft ein Read, nur ein „nochmal lesen"-Flag setzen; der laufende Read fasst nach.

**Konfidenz:** mittel (Mechanismus sicher; praktische Fehlordnung erfordert unglückliches Scheduling und hat begrenzte Folgen, da jedes Event `hookLiveSessions` setzt und das Binding beim nächsten Batch nachzieht).

---

## F4: Drei unkoordinierte Load→Index→Save-Pfade auf `agent-session-index-cache.json` — das Scan-Coalescing des Coordinators greift nur für seinen eigenen Pfad

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:131-137`; `WhisperM8/Views/AgentChatsView+RuntimeServices.swift:122-130`; `WhisperM8/Views/AgentSessionDetailView.swift:410, 644`; `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:71-103`

**Szenario (Auslöser → Wirkung):**
`AgentScanCoordinator.startScan` (FSEvent/Foreground) und `refreshSessionsInBackground` (manueller Sidebar-Refresh) sowie zwei Stellen in `AgentSessionDetailView` machen jeweils unabhängig `cacheStore.load()` → Indexing → `cacheStore.save(cache)` in eigenen `Task.detached`. Das `inFlight`-Coalescing des Coordinators (`:78-100`) kennt die anderen Pfade nicht. Laufen zwei Pfade parallel (z. B. FSEvent-Scan + User klickt „Aktualisieren"), überschreibt der letzte `save` die Cache-Einträge des anderen (klassisches Read-Modify-Write auf Dateiebene; der Write selbst ist `.atomic`, also keine Korruption). Folge: verlorene mtime/size-Einträge → der nächste Scan re-parst unnötig große JSONL-Dateien; außerdem laufen zwei vollständige `~/.claude`/`~/.codex`-Walks gleichzeitig.

**Beweis:**
```swift
// AgentScanCoordinator.swift:131-137
Task.detached(priority: .utility) { [reason] in
    let cacheStore = AgentSessionIndexCacheStore()
    var cache = cacheStore.load()
    …
    cacheStore.save(cache)
// AgentChatsView+RuntimeServices.swift:122-128 — identisches Muster, kein gemeinsames Gate
let result = Task.detached(priority: .utility) {
    …
    let cacheStore = AgentSessionIndexCacheStore()
    var cache = cacheStore.load()
    …
    cacheStore.save(cache)
```
`AgentSessionIndexCacheStore` (`AgentSessionIndexer.swift:71-103`) hat keinerlei prozessinterne Synchronisation. Der Workspace-Merge selbst ist unkritisch (Store-Lock + Idempotenz).

**Fix-Vorschlag:**
Alle Index-Läufe durch den `AgentScanCoordinator` routen (der View-Refresh ruft `requestScan(reason: .manual)` statt eines eigenen Detached-Blocks) oder den Cache-Store prozessweit als Singleton hinter einen Lock/Actor legen und beim Save mit dem Disk-Stand mergen.

**Konfidenz:** hoch (Pfad-Duplikation und fehlendes Gate direkt belegbar; Auswirkung nur Performance).

---

## F5: `AgentScanCoordinator.requestScan` — `pendingReason ?? reason` degradiert einen manuellen Scan-Request; der Nachhol-Scan läuft dann in den Cooldown

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:78-100, 151-159`

**Szenario (Auslöser → Wirkung):**
Ein FSEvent-getriggerter Scan läuft (`inFlight == true`), dessen FSEvent-Nachzügler hat bereits `pendingReason = .fsEvent` gesetzt. Jetzt klickt der User „Aktualisieren" → `requestScan(.manual)` landet im `inFlight`-Zweig: `pendingReason = pendingReason ?? reason` behält `.fsEvent`, der Manual-Intent (Cooldown-Bypass, `:89`) ist verloren. `markScanCompleted` holt danach `requestScan(.fsEvent)` nach — das fällt mit `elapsed ≈ 0 < fsEventCooldown (10 s)` in den Cooldown-Pfad und wird auf ~10 s später verschoben. Der User-Klick wirkt im schlechtesten Fall erst nach dem Cooldown statt sofort.

**Beweis:**
```swift
// AgentScanCoordinator.swift:85
pendingReason = pendingReason ?? reason   // .manual wird von .fsEvent „geschluckt"
// :89-97 — der Nachhol-Request ist dann kein .manual mehr:
if reason != .manual, let last = lastCompletedAt {
    …
    if elapsed < limit { … scheduleCooldownRetry(after: limit - elapsed) … }
```

**Fix-Vorschlag:**
`pendingReason` als Prioritäts-Merge statt First-wins: `pendingReason = max(pendingReason, reason)` mit einer Reason-Priorität (`manual > fsEvent > foreground/launch`), sodass ein späterer Manual-Request den gemerkten Grund aufwertet.

**Konfidenz:** hoch (rein aus dem Code ableitbar; Auswirkung auf einen ~10-s-Verzug begrenzt).

---

## F6: Snapshot-Löschung läuft async auf einer Utility-Queue, Snapshot-Save synchron auf Main — Löschen einer laufenden Session kann eine Snapshot-Datei-Leiche hinterlassen

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:458-474, 494-500`; `WhisperM8/Views/AgentTerminalView.swift:808-820`

**Szenario (Auslöser → Wirkung):**
User löscht eine noch laufende Session: `deleteSession` entfernt sie aus dem Workspace und dispatcht `TerminalSnapshotStore.shared.delete(sessionID:)` **asynchron** auf `DispatchQueue.global(qos: .utility)`. Der zugehörige Teardown (`AgentTerminalRegistry.terminate` → `captureTerminalSnapshot` → `TerminalSnapshotStore.shared.save`) läuft **synchron auf Main**. Je nach Scheduling läuft das Utility-`delete` vor dem Main-`save` — die frisch geschriebene Snapshot-Datei einer nicht mehr existenten Session bleibt liegen. Zusätzlich greifen `save` (Main) und `delete` (Utility) unsynchronisiert auf denselben Pfad zu (`TerminalSnapshotStore` hat keine interne Synchronisation; die Writes selbst sind `.atomic`, daher keine Korruption).

**Beweis:**
```swift
// AgentSessionStore.swift:471-474
DispatchQueue.global(qos: .utility).async {
    TerminalSnapshotStore.shared.delete(sessionID: id)
}
// AgentTerminalView.swift:817-819 — Kommentar begründet den SYNCHRONEN Save:
// "Synchron (≤ ~300 KB, atomar): die Detail-View prüft direkt nach
//  onTerminated auf den Snapshot …"
TerminalSnapshotStore.shared.save(sessionID: sessionID, text: text)
```
Abgefedert wird das Ergebnis (nicht das Race) durch den Retention-Job beim nächsten App-Start (`WhisperM8App.swift:256-262`, `prune(liveLocalSessionIDs:)` räumt verwaiste Snapshots).

**Fix-Vorschlag:**
Beide Operationen auf dieselbe serielle Utility-Queue legen (Save darf dafür synchron auf diese Queue warten, um die Detail-View-Garantie zu behalten), oder im Delete-Pfad die Registry-Terminierung abwarten und erst danach löschen.

**Konfidenz:** mittel (Fensterbreite klein, Folge nur eine Datei-Leiche mit Selbstheilung; Race-Mechanismus eindeutig).
