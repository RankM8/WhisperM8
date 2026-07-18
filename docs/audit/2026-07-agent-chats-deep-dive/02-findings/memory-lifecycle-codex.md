# Memory-/Lifecycle-Findings Agent-Chats (Codex)

Audit-Datum: 2026-07-18. Reine Code-Analyse der Verzeichnisse
`WhisperM8/Services/`, `WhisperM8/Views/` und `WhisperM8/Windows/`.
Der angeforderte Kartenordner `01-subsysteme/` war nicht vorhanden.

Geprüft und ohne Finding: Alle Vorkommen von
`NSEvent.addLocalMonitorForEvents` besitzen einen korrespondierenden
`removeMonitor`-Pfad (Agent-Chats-Shortcuts, Terminal-Scroll/Keyboard und
Recording-ESC). Es gibt im Prüfbereich keinen Global-Monitor. Der
`AgentTerminalLinkInterceptor` bildet keinen Delegate-Zyklus: Der Controller
hält den Interceptor stark, SwiftTerms `terminalDelegate` ist `weak`, der
Interceptor hält seine Basis ebenfalls `weak`, und sein Callback erfasst den
Controller mit `[weak self]`. Auch der Transcript-LRU, Markdown-Cache,
Terminal-Feed-Puffer und die einzelnen Terminal-Snapshots sind mengen- bzw.
größenbegrenzt.

---

## F1: Geschlossene Agent-Fenster bilden starke Rückreferenzen auf ihr eigenes NSWindow

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/AgentChatsWindowAccessor.swift:79-116`;
`WhisperM8/Views/AgentChatsView.swift:233-240, 494-500, 681-701`

**Szenario:** Jedes Agent-Chats-Fenster enthält den
`AgentChatsWindowAccessor.Coordinator` in seinem SwiftUI-/Hosting-View-Baum.
Der Coordinator hält dasselbe Fenster in `observedWindow` stark. Zusätzlich
schreibt die Root-View das Fenster stark in `@State hostWindow`. Beim Schließen
werden zwar die NSEvent-Monitore entfernt und der Fenster-State bereinigt, aber
weder `observedWindow` noch `hostWindow` werden genullt. Damit bleiben nach dem
roten X bzw. nach einem leeren Sekundärfenster das `NSWindow`, sein kompletter
Hosting-/SwiftUI-Baum, View-State (unter anderem Transcript-/Sheet-State) und
die drei NotificationCenter-Observer des Accessors erreichbar. Bei wiederholtem
Öffnen und Schließen von Sekundärfenstern wächst dieser Bestand pro Fenster;
spürbar wird er durch mehrere weiterlebende komplette SwiftUI-Bäume und deren
Render-/Transcript-Zustände.

**Beweis:** Der konkrete Zyklus ist
`NSWindow -> contentView/Hosting-Graph -> Coordinator -> observedWindow -> NSWindow`.
Parallel existiert
`NSWindow -> Hosting-Graph -> @State(hostWindow) -> NSWindow`.

```swift
// AgentChatsWindowAccessor.swift:79-91
final class Coordinator {
    private var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func observe(window: NSWindow, ...) {
        guard observedWindow !== window else { return }
        removeObservers()
        observedWindow = window
```

```swift
// AgentChatsView.swift:494-500
.background(AgentChatsWindowAccessor(
    onResolve: { hostWindow = $0 },
    onWillClose: { windowStore.handleWindowWillClose(windowID) },
```

Der einzige Null-Schreibpfad des Coordinators liegt in `removeObservers()` und
wird bei Fensterwechsel bzw. `deinit` aufgerufen. Der
`willCloseNotification`-Handler ruft dagegen nur `onWillClose()` auf; ein
`dismantleNSView` fehlt. Auch `.onDisappear` entfernt nur Tasks/Monitore und
setzt `hostWindow` nicht auf `nil`.

**Fix-Vorschlag:** `observedWindow` als `weak` deklarieren. Zusätzlich in einem
`static dismantleNSView` des Accessors die Observer explizit entfernen und im
`willClose`-Pfad den Coordinator lösen. In `AgentChatsView` beim
`onWillClose`/`onDisappear` `hostWindow = nil` setzen. Beide Rückreferenzen
müssen gebrochen werden; nur eine davon zu korrigieren lässt den zweiten Zyklus
bestehen.

**Konfidenz:** hoch (beide starken Kanten und die fehlenden Null-Schreibpfade
sind im Code direkt sichtbar; die genaue Speichergröße pro Fenster hängt vom
aktuellen View-State ab).

---

## F2: Die globale Terminal-Registry behält natürlich beendete Controller dauerhaft

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:323-370, 969-981`;
`WhisperM8/Views/AgentChatsView+Tabs.swift:78-96, 120-160`;
`WhisperM8/Views/AgentChatsView+ProjectManagement.swift:52-65`

**Szenario:** Beendet sich Claude, Codex oder ein Shell-Terminal selbst
(Ctrl+C, `exit`, CLI-Ende), setzt `processTerminated` den Controller nur auf
`isRunning = false`. Der Singleton `AgentTerminalRegistry.shared` behält ihn
weiter im Dictionary. Schließt der User danach den Tab, archiviert die Session
oder löscht ein Projekt, wird `terminate(sessionID:)` nur für noch laufende
Controller aufgerufen. Der bereits beendete Controller bleibt deshalb auch
nach Entfernung aller UI-/Workspace-Referenzen in der Registry. Pro solcher
Session akkumuliert ein kompletter `AgentTerminalController` mit
`QuietableTerminalView`, SwiftTerm-Buffern, Prozess-/Delegate-Objekten,
Link-Interceptor und Theme-Observer. Nach vielen natürlich beendeten und
anschließend geschlossenen/gelöschten Chats wächst der Prozessspeicher monoton;
das ist das größte belegte Speicherleck dieses Audits.

**Beweis:** Der Singleton ist die langlebige Wurzel:

```swift
// AgentTerminalView.swift:323-369
final class AgentTerminalRegistry: ObservableObject {
    static let shared = AgentTerminalRegistry()
    @Published private var controllers: [UUID: AgentTerminalController] = [:]

    func terminate(sessionID: UUID) {
        controllers[sessionID]?.terminate()
        controllers[sessionID] = nil
    }
}
```

Beim Selbst-Exit fehlt die Entfernung aus diesem Dictionary:

```swift
// AgentTerminalView.swift:969-980
func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor in
        self.exitCode = exitCode
        self.isRunning = false
        self.terminal.flushPendingOutput()
        self.captureTerminalSnapshot()
        self.releaseEventMonitors()
        self.onTerminated(exitCode)
    }
}
```

Und die späteren UI-Cleanup-Pfade überspringen gerade diesen Fall:

```swift
// AgentChatsView+Tabs.swift:148-151
if terminalRegistry.controller(for: session.id)?.isRunning == true {
    terminalRegistry.terminate(sessionID: session.id)
}
```

`closeTab(_:)` selbst entfernt ausschließlich die Tab-ID. Derselbe
`isRunning == true`-Guard steht vor Terminal-Session-, Archiv- und
Projekt-Löschung.

**Fix-Vorschlag:** Lifecycle und UI-Besitz trennen. Die Registry braucht eine
explizite `removeController(sessionID:)`-/`releaseEndedController`-Operation,
die keinen Prozess mehr terminiert, aber den Eintrag entfernt. Sie muss bei
Tab-/Archiv-/Session-/Projekt-Entfernung unabhängig von `isRunning` laufen.
Falls Scrollback nach einem Selbst-Exit noch im offenen Tab sichtbar bleiben
soll, den Controller bis zum Tab-Close behalten, dann jedoch sicher entfernen;
für die Offline-Anzeige existiert bereits `TerminalSnapshotStore`.

**Konfidenz:** hoch (Singleton-Wurzel, starke Dictionary-Kante und sämtliche
relevanten Remove-Guards sind eindeutig).

---

## F3: Beendete Background-Sessions behalten Hook-DispatchSource und Dateideskriptor

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:143-165, 204-225`;
`WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:24-47, 107-189`;
`WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:52-57, 97-99, 139-145`;
`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:86-95, 175-212`

**Szenario:** Für jede Background-Session mit Hooks legt die globale
Status-Infrastruktur einen `ClaudeHookBridge.Entry` an. Dieser hält einen
`DispatchSourceFileSystemObject` und einen offenen `O_EVTONLY`-FD. Bei
interaktiven Sessions ruft `sessionTerminated` `stopTracking` auf. Für
Background-Sessions kehrt dieselbe Methode jedoch vor dem Cleanup zurück; auch
ein endgültiges `SessionEnd` stoppt absichtlich nur den Transcript-Watcher und
lässt die Hook-Bridge aktiv. Selbst der User-Pfad `agent rm`/„vergessen“
archiviert nur die Session. Somit bleiben pro beendeter oder entfernter
Background-Session ein Entry, DispatchSource und FD bis zum App-Ende bestehen.
Nach genügend Jobs erreicht der Prozess das FD-Limit; ab dann schlagen neue
Hook-Watches in `open(..., O_EVTONLY)` fehl. Zusätzlich bleibt auch bei normal
gestoppten Sessions je eine Cursor-URL im `ClaudeHookEventStore`, weil
`stopTracking` den Cursor nicht entfernt.

**Beweis:** Der FD ist eindeutig an die Lebensdauer des Entry gebunden:

```swift
// ClaudeHookBridge.swift:27-46
private final class Entry {
    var fileDescriptor: Int32 = -1
    var source: DispatchSourceFileSystemObject?

    deinit {
        source?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
        silenceTimer?.invalidate()
    }
}
```

Die langlebige Bridge hält den Entry in `entries`, und Background-Ende entfernt
ihn auf keinem Pfad:

```swift
// AgentSessionStatusCoordinator.swift:143-158
func sessionTerminated(sessionID: UUID, exitCode: Int32?) {
    cancelLaunchGrace(sessionID: sessionID)
    if isBackgroundSession(sessionID) {
        return
    }
    ...
    hookBridge.stopTracking(localSessionID: sessionID)
}
```

```swift
// AgentSessionStatusCoordinator.swift:216-225
if event.hookEventName == .sessionEnd,
   states[localID] == .stopped,
   isBackgroundSession(localID) {
    watcher.markTerminated(sessionID: localID)
}
```

`stopTracking` ist die einzige Produktions-Aufrufstelle, die
`entries.removeValue` ausführt. Der Cursor verbleibt separat, da
`resetCursor(for:)` nur beim nächsten `startTracking` derselben lokalen UUID
aufgerufen wird.

**Fix-Vorschlag:** „Attach-PTY beendet“ und „Background-Job endgültig beendet“
als getrennte Lifecycle-Signale modellieren. Beim endgültigen `SessionEnd`
(und zwingend bei `rm`/Forget) `hookBridge.stopTracking` aufrufen; nur bei
nachweislich in-place fortsetzenden Reasons re-armen. `stopTracking` sollte
außerdem `store.resetCursor(for: entry.eventFileURL)` ausführen. Ein
`stopAll()`/`deinit` der Bridge ist als Sicherheitsnetz sinnvoll, ersetzt aber
nicht den per-Session-Cleanup im langlebigen Singleton.

**Konfidenz:** hoch (nur eine Remove-Stelle existiert; die Background-Pfade
umgehen sie explizit, und Entry→Source/FD ist direkt belegt).

---

## F4: Der persistente Session-Index-Cache kennt keine Eviction für verschwundene Dateien

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:19-69, 71-103`;
`WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:127-136`

**Szenario:** Jeder Scan lädt den gesamten JSON-Cache in ein Dictionary, ergänzt
oder ersetzt Einträge für aktuell gefundene Transcript-Dateien und schreibt das
gesamte Dictionary zurück. Es gibt weder eine Mengen-/Altersgrenze noch einen
Abgleich, der Cache-Keys für inzwischen gelöschte, verschobene oder durch
Profiländerungen nicht mehr erreichbare Dateien entfernt. Über Monate wächst
`agent-session-index-cache.json` daher mit jeder jemals gesehenen Claude-/Codex-
JSONL. Das ist dauerhaftes Disk-Wachstum und zugleich wiederkehrendes
Arbeitsspeicherwachstum: Bei jedem Foreground-/FSEvents-/manuellen Scan werden
alle historischen Keys samt `IndexedAgentSession` decodiert, gehalten und
erneut encodiert. Spürbar wird es als steigender Scan-Peak und längere
Load/Save-Zeit bei großer bzw. churnender externer Transcript-Historie.

**Beweis:** Die Cache-API kann nur lesen und setzen:

```swift
// AgentSessionIndexer.swift:19-41
struct AgentSessionIndexCache {
    private var entries: [String: Entry] = [:]

    subscript(provider: AgentProvider, fileURL: URL, metadata: FileMetadata)
        -> IndexedAgentSession? {
        ...
        set {
            let cacheKey = Self.cacheKey(provider: provider, fileURL: fileURL)
            entries[cacheKey] = Entry(...)
        }
    }
}
```

Der Scan lädt und speichert dieselbe wachsende Instanz unverändert zurück:

```swift
// AgentScanCoordinator.swift:131-136
let cacheStore = AgentSessionIndexCacheStore()
var cache = cacheStore.load()
let codex = CodexSessionIndexer().indexedSessionResult(cache: &cache)
let claude = ClaudeSessionIndexer().indexedSessionResult(cache: &cache)
cacheStore.save(cache)
```

Im gesamten Prüfbereich existiert keine Remove-/Prune-/Evict-Operation für
`AgentSessionIndexCache.entries`.

**Fix-Vorschlag:** Während eines vollständigen Scan-Laufs die tatsächlich
gesehenen Cache-Keys sammeln und danach `entries` auf diese Menge reduzieren.
Zusätzlich eine harte Obergrenze bzw. TTL als Korruptions-/Churn-Schutz
einführen. Weil beide Provider denselben Cache nacheinander befüllen, darf das
Pruning erst nach beiden Indexern erfolgen oder muss providerweise mit jeweils
vollständiger Seen-Menge arbeiten.

**Konfidenz:** hoch (fehlende Eviction ist vollständig per API- und
Aufrufer-Suche belegt; die konkrete Wachstumsrate hängt von der externen
Transcript-Fluktuation ab).

---

## F5: Session-spezifische Metadaten in globalen Diensten werden bei Löschung nicht bereinigt

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:36-69, 258-267`;
`WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:13-52`;
`WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:228-244, 332-348`;
`WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:122-138, 183-193`;
`WhisperM8/Services/AgentChats/AgentSessionNotifier.swift:75-90`;
`WhisperM8/Services/AgentChats/AgentSessionStore.swift:453-501`

**Szenario:** Mehrere App-weite Singletons führen Tabellen nach lokaler
Session-UUID: Lifecycle-States, Runtime-Statuses, Notification-Throttle,
Auto-Namer-`alreadyAttempted` und Summary-Debounce-Tasks. Die Workspace-
Löschpfade entfernen die Session und ihren Terminal-Snapshot, benachrichtigen
diese Runtime-Dienste aber nicht. Dadurch bleiben UUIDs und kleine Statuswerte
für gelöschte Sessions bis zum Prozessende erhalten. Besonders eindeutig hält
`AgentSessionSummarizer.shared.terminationTasks` nach Ablauf weiterhin den
fertigen `Task`-Handle pro beendeter Session. Der Einzelposten ist klein; bei
einer sehr langen App-Laufzeit mit vielen erstellten und wieder gelöschten
Sessions wächst der Bestand dennoch monoton.

**Beweis:** Die globalen Wurzeln und wachsenden Tabellen sind explizit:

```swift
// AgentSessionStatusCoordinator.swift:37, 60-62
static let shared = AgentSessionStatusCoordinator()
private(set) var states: [UUID: AgentSessionLifecycleState] = [:]
private var notificationThrottle = AgentNotificationThrottle()
private var launchGraceTasks: [UUID: Task<Void, Never>] = [:]
```

```swift
// AgentSessionSummarizer.swift:123, 137, 185-192
static let shared = AgentSessionSummarizer()
private var terminationTasks: [UUID: Task<Void, Never>] = [:]

terminationTasks[sessionID] = Task { [weak self] in
    try? await Task.sleep(for: .seconds(5))
    guard !Task.isCancelled else { return }
    self?.requestSummary(sessionID: sessionID, force: false, reason: "session-end")
}
```

Nach Ausführung fehlt `terminationTasks[sessionID] = nil`. Analog werden
`states[sessionID]`, `statusStore.statuses[sessionID]`,
`notificationThrottle.lastPosted[sessionID]` und
`autoNamer.alreadyAttempted` nur gesetzt bzw. laufzeitbedingt aktualisiert.
`deleteSession`/`deleteProject` entfernen dagegen ausschließlich Workspace-
Entities und Snapshot-Dateien; ein Runtime-GC-Aufruf fehlt.

**Fix-Vorschlag:** Im Status-Koordinator eine zentrale
`forgetSession(_:)`-Operation ergänzen, die Watcher/Hook-Tracking stoppt,
Grace-Tasks cancelt sowie State, Runtime-Status, Throttle- und Auto-Namer-
Marker entfernt. Die Session-/Projekt-Löschpfade müssen sie mit allen
betroffenen UUIDs aufrufen. Der Summarizer sollte seinen Task-Eintrag mit einem
deferierten, generationssicheren Remove nach Ablauf/Cancellation entfernen.
Alternativ kann ein periodischer GC alle Runtime-Keys gegen die aktuellen
Workspace-IDs schneiden.

**Konfidenz:** hoch für die monotone Key-Retention und den fehlenden Cleanup;
mittel für die praktische Auswirkung, da die Werte pro Session klein sind.
