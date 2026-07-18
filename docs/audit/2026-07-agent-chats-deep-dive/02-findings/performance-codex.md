# Performance-Audit: Agent Chats und Diktat-Hot-Paths

Statische Analyse auf Basis der Subsystemkarten und des aktuellen Swift-Codes. Kostenangaben sind Größenordnungen aus Kontrollfluss, Datenmengen und expliziten Timeouts; sie ersetzen keine Instruments-Messung. Maßstab sind insbesondere die vorhandenen Budgets von 300 ms für Stop→Transkription, 30/15/20 ms für Store-Mutation/Load/Save, 100 ms für Status-Polls und 150 ms für Context-Capture.

## Zusammenfassung

- **Kritisch:** 0
- **Hoch:** 11
- **Mittel:** 7
- **Niedrig:** 0
- **Größter Hebel:** Den Diktat-Stopp neu ordnen: Audio sofort schließen und die Transkription starten; Context-Capture, Clip-Finalisierung, Frame-Extraktion und Report-I/O dürfen diesen Übergang nicht serialisieren. Der aktuelle Pfad kann das 300-ms-Budget schon durch einen einzelnen expliziten 1-s-Wait und zusätzlich durch Video-/PNG-Arbeit mehrfach überschreiten.

## F1: Terminal-Stopp schläft garantiert 260 ms auf dem MainActor

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:613`, `WhisperM8/Views/AgentTerminalView.swift:775-819`, `WhisperM8/Views/AgentTerminalView.swift:377-381`

**Szenario:** Beim Schließen oder Archivieren eines laufenden Chats reagiert die Oberfläche mindestens 260 ms nicht. `terminateAll()` führt denselben Pfad seriell aus; zehn PTYs bedeuten damit mindestens 2,6 s Main-Thread-Blockade, bevor Buffer- und Dateiarbeit hinzukommt.

**Beweis:**

```swift
@MainActor
final class AgentTerminalController: NSObject, ObservableObject, Identifiable, ... {
    func terminate() {
        if isRunning {
            terminal.send([0x03])
            usleep(80_000)
            terminal.send([0x03])
            usleep(180_000)
        }
        ...
        captureTerminalSnapshot()
```

**Fix-Vorschlag:** Graceful Shutdown als asynchrone Zustandsmaschine mit `Task.sleep` oder Timern modellieren und auf Prozess-/PTY-Callbacks reagieren. Bei Bulk-Aktionen ein gemeinsames Grace-Fenster wie im App-Quit-Pfad verwenden. Nur die zwingende Terminal-Buffer-Kopie auf Main ausführen; String-Aufbereitung, JSON-Encoding und atomaren Snapshot-Write seriell off-main erledigen.

**Konfidenz:** sehr hoch

## F2: Stop→Transkription wartet vor dem Audio-Stopp bis zu eine Sekunde auf Kontext

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:244-329`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:82-96`

**Szenario:** Bei kurzen Diktaten oder langsamer Transcript-/Accessibility-Erfassung wartet der Stop-Pfad bis zu 1.000 ms, bevor `audioRecorder.stopRecording()` überhaupt aufgerufen wird. Das überschreitet das gesamte 300-ms-Budget bereits strukturell um Faktor 3,3; erst danach beginnt die Transkription.

**Beweis:**

```swift
if appState.isScreenClipRecording {
    await stopScreenClipAndAttach()
}
await waitForContextCapture(timeout: 1.0)
observeClipboardChange()
...
let audioURL = audioRecorder.stopRecording()
...
appState.isTranscribing = true
```

```swift
while contextCaptureTask != nil, Date() < deadline {
    try? await Task.sleep(for: .milliseconds(20))
}
```

**Fix-Vorschlag:** Audio und Timer unmittelbar nach dem Stop-Signal schließen, UI auf Transcribing setzen und den Upload starten. Context-Capture parallel abschließen und nur mit einem deutlich kleineren, fachlich begründeten Deadline-Fenster vor der optionalen Nachbearbeitung einsammeln; fehlenden Kontext nicht vor den Netzstart schalten.

**Konfidenz:** sehr hoch

## F3: Aktiver Screen-Clip serialisiert Writer-Finalisierung und fünf Frame-Decodes in den Stop-Pfad

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator.swift:275-278`, `WhisperM8/Services/Dictation/ManualScreenClipSession.swift:116-130`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:155-166`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:192-227`

**Szenario:** Beim Stoppen eines Diktats mit Screen-Clip wartet die App zuerst auf `SCStream`-Stop und `AVAssetWriter.finishWriting`, decodiert dann bis zu fünf Videoframes und encodiert/schreibt fünf PNGs. Bei langen oder hochauflösenden Clips sind mehrere hundert Millisekunden bis Sekunden plausibel, vollständig vor dem Audio-Stopp und damit innerhalb des 300-ms-Signposts.

**Beweis:**

```swift
let clip = try await session.stop(startedAt: startedAt)
let frames = try await extractVisualFrames(from: clip)
...
for index in 1...frameCount {
    let image = try generator.copyCGImage(at: time, actualTime: nil)
    ...
    try writePNG(image, to: fileURL)
}
```

**Fix-Vorschlag:** Clip-Session beim Stop nur atomar ablösen und Audio/Transkription sofort fortsetzen. Writer-Finalisierung, Frame-Seeking und PNG-Encoding auf einen dedizierten Worker verschieben. Falls visuelle Frames für Post-Processing zwingend sind, dort mit eigener Deadline warten und bei Überschreitung ohne Frames weiterarbeiten.

**Konfidenz:** sehr hoch

## F4: Accessibility- und Pasteboard-Erfassung blockieren den MainActor

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/Dictation/SelectedContextService.swift:8-18`, `WhisperM8/Services/Dictation/SelectedContextService.swift:42-96`, `WhisperM8/Services/Dictation/SelectedContextService.swift:123-142`, `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:18-22`

**Szenario:** Direkt nach Aufnahmebeginn läuft der Selected-Context-Capture auf dem MainActor. Zwei synchrone AX-IPC-Aufrufe können bei einem hängenden Zielprozess jeweils bis zum gesetzten 0,5-s-Messaging-Timeout laufen. Der Fallback snapshotet zusätzlich alle Pasteboard-Items und lädt alle Repräsentationen ohne Größenlimit. Das kann Overlay-Animation und die Verarbeitung des nächsten Hotkeys trotz paralleler Aufnahme für hunderte Millisekunden blockieren und das 150-ms-Context-Budget reißen.

**Beweis:**

```swift
@MainActor
func capture(from app: NSRunningApplication?) async -> SelectedContext {
    if let context = captureViaAccessibility(app: app) { ... }
    return await captureViaClipboard(app: app)
}
...
AXUIElementSetMessagingTimeout(appElement, 0.5)
AXUIElementCopyAttributeValue(...)
```

```swift
let items = pasteboard.pasteboardItems?.map { item in
    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
}
```

**Fix-Vorschlag:** AX-Zugriffe auf einen dedizierten seriellen Worker mit harter Gesamtdauer auslagern. Beim Pasteboard nur benötigte Typen und begrenzte Byte-Mengen sichern beziehungsweise Restore über Change-Count/Ownership modellieren, statt beliebig große Inhalte vollständig zu materialisieren.

**Konfidenz:** hoch

## F5: Codex-Transcript-Auflösung macht Vollbaum-Walks und entwertet Cache-Hits

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:32-54`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:89-97`, `WhisperM8/Services/AgentChats/AgentTranscriptCache.swift:54-65`, `WhisperM8/Services/AgentChats/AgentTranscriptCache.swift:169-196`, `WhisperM8/Services/Dictation/AgentChatTailExtractor.swift:77-85`

**Szenario:** Jeder Codex-Cache-Lookup löst zur Identity-Prüfung die Session-ID über einen rekursiven Walk von `~/.codex/sessions` auf. Auch ein Cache-Hit zahlt daher O(alle Rollout-Dateien); ein Miss läuft über `readTail(sessionID:)` ein zweites Mal durch den Baum. Mit jahrelanger Historie sind hunderte Millisekunden bis Sekunden plausibel. Derselbe Pfad liefert den Diktat-Chat-Tail, auf den F2 bis zu eine Sekunde wartet.

**Beweis:**

```swift
let enumerator = fileManager.enumerator(at: sessionsDirectory, ...)
for case let url as URL in enumerator where url.pathExtension == "jsonl" {
    if url.lastPathComponent.contains(sessionID) { return url }
}
```

```swift
let identity = Self.fileIdentity(for: key) // löst URL bereits auf
...
return CodexTranscriptReader.readTail(sessionID: externalSessionID, ...)
```

**Fix-Vorschlag:** Eine einzige zentrale Session-ID→URL-Map verwenden; der bereits vorhandene `AgentTranscriptLocator` besitzt dafür einen Cache. Die einmal aufgelöste URL durch Identity-Prüfung und Read reichen, negative Treffer kurz cachen und über Datei-/Index-Events invalidieren.

**Konfidenz:** sehr hoch

## F6: Index-Merge ist quadratisch und läuft auf MainActor unter dem Store-Lock

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:131-147`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:716-890`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:121-147`

**Szenario:** Launch-, Foreground- und FSEvent-Scans mergen bis zu 1.000 Sessions pro Provider. Für jeden Indexeintrag werden Projekte und Sessions linear gesucht; der Adoption-Fallback filtert nochmals alle Sessions. Bei 2.000×2.000 Einträgen entstehen grob Millionen Vergleiche, anschließend Normalisierung und Deep-Equality. Diese Arbeit läuft im `MainActor.run`, unter dem globalen Store-Lock und gegen ein 30-ms-Mutationsbudget.

**Beweis:**

```swift
await MainActor.run {
    try? store.mergeIndexedSessions(codex.sessions + claude.sessions)
}
```

```swift
for indexed in indexedSessions {
    let projectID = workspace.projects.first(where: { ... })?.id
    if let index = workspace.sessions.firstIndex(where: { ... }) { ... }
    let adoptionCandidates = workspace.sessions.indices.filter { ... }
}
```

**Fix-Vorschlag:** Vor dem Loop Dictionaries für Provider/External-ID, Projektpfad und ungebundene Kandidaten aufbauen. Den reinen Merge aus einem unveränderlichen Snapshot off-main berechnen und unter dem Lock nur generation-geprüft anwenden; Normalisierung nicht bei jeder Teilmutation erneut über den gesamten Workspace laufen lassen.

**Konfidenz:** sehr hoch

## F7: Live-Subagent-Transcript reparst bei jedem Append das gesamte Tail-Fenster

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Views/SubagentJobDetailView.swift:600-644`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:271-298`

**Szenario:** Ein vnode-Burst triggert nach 200 ms stets einen vollständigen Read, UTF-8-Split und JSON-Parse. Nach „Früheren Verlauf laden“ wächst das Fenster bis 32 MiB; bei fortlaufendem Output sind damit theoretisch bis zu 32 MiB × 5/s = 160 MiB/s Read- und Parse-Arbeit möglich. Die detached Reads werden nicht als In-flight-Task gehalten, sodass langsame Reads überlappen können.

**Beweis:**

```swift
transcriptTailBytes = min(transcriptTailBytes * 4, Self.maxTailBytes)
...
Task {
    let fresh = await Task.detached {
        CodexTranscriptReader.readTail(fileURL: url, tailBytes: tailBytes)
    }.value
    ...
}
```

**Fix-Vorschlag:** Einen echten inkrementellen Tailer mit Byte-Offset und Restzeilen-Puffer einsetzen. Nur neue vollständige Zeilen parsen; bei Truncate/Replace rebaselinen. Pro URL maximal einen Read zulassen und währenddessen eingehende Events über ein Dirty-/Trailing-Edge-Flag zusammenfassen.

**Konfidenz:** sehr hoch

## F8: Jeder Diktatlauf kopiert Reports und scannt bis zu 2 GiB synchron auf Main

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:112-140`, `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:273-330`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:72-188`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:218-260`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:371-427`, `WhisperM8/Services/Dictation/TranscriptRunReportStore.swift:537-550`

**Szenario:** Nach jeder Ausgabe ruft der `@MainActor`-Coordinator synchron `reportStore.save` auf. Dabei werden Clip-/Bildanhänge kopiert, JSON und Index atomar geschrieben und anschließend bei jedem Save alle Report-Verzeichnisse geladen sowie rekursiv vermessen. Nahe dem 500-Report-/2-GiB-Limit kann das die UI für hunderte Millisekunden bis Sekunden blockieren; ein Screenshot mit identischer Thumbnail-URL wird zudem zweimal kopiert.

**Beweis:**

```swift
appState?.lastTranscriptRunReport = try reportStore.save(draft)
...
let attachments = try draft.contextBundle.allAttachments.map { ... }
try data.write(to: reportURL(for: draft.id), options: .atomic)
try upsertIndexEntry(...)
runCleanupIfNeeded(policy: cleanupPolicy)
```

```swift
let candidates = directories.map { directory in
    (..., size: directorySize(directory))
}
```

**Fix-Vorschlag:** Report-Persistenz in einen seriellen I/O-Actor verschieben und im UI zunächst nur einen unveränderlichen Draft/Status veröffentlichen. Gesamtbytes inkrementell im Index führen, Cleanup amortisiert oder schwellenbasiert ausführen und identische Original-/Thumbnail-URLs deduplizieren.

**Konfidenz:** sehr hoch

## F9: Projektinspektor startet drei synchrone Git-Prozesse auf dem MainActor

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Views/ProjectDetailPanel.swift:105-108`, `WhisperM8/Views/ProjectDetailPanel.swift:126-132`, `WhisperM8/Services/AgentChats/GitProjectStatus.swift:13-45`

**Szenario:** Beim Erscheinen des Inspectors und bei jedem Projektwechsel werden Branch, Status und Diff über drei serielle `/usr/bin/git`-Spawns ermittelt. Ein Spawn kostet typischerweise mehrere bis zig Millisekunden; `git status`/`diff` kann in großen Repositories hunderte Millisekunden dauern. Da der SwiftUI-Callback MainActor-isoliert ist und `waitUntilExit()` synchron wartet, hängt der Fensteraufbau entsprechend.

**Beweis:**

```swift
.onAppear(perform: refreshGitStatus)
...
status = GitProjectStatus(path: project.path)
```

```swift
branch = Self.git(["-C", path, "branch", "--show-current"])
let porcelain = Self.git(["-C", path, "status", "--porcelain"])
let diff = Self.git(["-C", path, "diff", "--numstat"])
...
try process.run()
process.waitUntilExit()
```

**Fix-Vorschlag:** Statusabfrage detached/Utility ausführen, pro Projekt generation-geprüft und cancellable machen. Ergebnisse kurz nach Pfad+Repository-mtime cachen und benötigte Informationen soweit möglich in einem Git-Aufruf bündeln.

**Konfidenz:** sehr hoch

## F10: Agent-View-Keystrokes lösen wiederholt Vollscans aller Claude-Jobs aus

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:343-346`, `WhisperM8/Views/AgentChatsView.swift:864-890`, `WhisperM8/Services/AgentChats/ActiveBackgroundSessionTracker.swift:33-56`, `WhisperM8/Services/AgentChats/ActiveBackgroundSessionTracker.swift:99-169`, `WhisperM8/Services/AgentChats/SupervisorJobReader.swift:42-69`

**Szenario:** Jeder KeyDown im aktiven Agent-View ruft `nudge()` auf; das minimale Intervall beträgt 300 ms. Jeder akzeptierte Nudge liest und decodiert alle `~/.claude/jobs/*/state.json` und stat't die verlinkten JSONLs. Zusätzlich wird `lastRefreshAt` als `@Published` gesetzt, obwohl die Views es nicht lesen; weil der Tracker als `@StateObject` in der großen Root-View hängt, entstehen bis zu 3,3 vollständige Root-Invalidierungen pro Sekunde beim Tippen.

**Beweis:**

```swift
private let nudgeMinInterval: TimeInterval = 0.3
...
let result = Self.buildSnapshot(...)
...
self.lastRefreshAt = result.lastRefreshAt
```

```swift
let states = SupervisorJobReader.readAll(...)
```

**Fix-Vorschlag:** `lastRefreshAt` nicht publizieren oder den Tracker nur in einer kleinen Status-Subview beobachten. Keystrokes stärker trailing-edge-debouncen und Jobzustände event-/mtime-basiert inkrementell aktualisieren, statt jeden Job erneut zu decodieren.

**Konfidenz:** sehr hoch

## F11: Erstes Agent-Chats-Fenster lädt und migriert beide JSON-Stores synchron auf Main

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:49-50`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:246-250`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:283-292`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:23-47`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:36-65`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:45-110`

**Szenario:** Beim ersten Öffnen werden Workspace und UI-State in MainActor-Singletons synchron gelesen und decodiert. Der Workspace-Load läuft unter dem Store-Lock durch Migration/Pruning und kann bei Abweichung Backup plus vollständiges Encode/Atomic-Write ausführen. Der UI-State liest seine Datei im Canonicalization-Pfad ein zweites Mal und kann ebenfalls direkt schreiben. Bei einigen MiB und bis zu etwa 2.000 importierten Sessions ist eine klare Überschreitung des 15-ms-Loadbudgets und ein sichtbarer Fenster-Start-Hitch plausibel.

**Beweis:**

```swift
@MainActor
final class AgentWorkspaceUIModel {
    init(store: AgentWorkspaceStore = .shared) {
        self.workspace = store.read { $0 }
    }
}
```

```swift
let data = try Data(contentsOf: fileURL)
let workspace = try decoder.decode(AgentWorkspace.self, from: data)
if migrated != workspace {
    try backup(...)
    try save(migrated)
}
```

**Fix-Vorschlag:** Beide Stores vor der UI-Nutzung auf einer seriellen Utility-Ausführung laden oder das UI-Modell mit einem Loading-/leeren Snapshot initialisieren und den fertigen Snapshot einmal auf Main publizieren. Migration, Backup und Canonicalization ebenfalls off-main ausführen; dieselbe Datei pro Load nur einmal lesen.

**Konfidenz:** hoch

## F12: Index-Limits begrenzen nur das Ergebnis, nicht Walk, Stat und Cache-Write

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift:35-77`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:43-100`, `WhisperM8/Views/AgentSessionDetailView.swift:634-666`, `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:19-20`, `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:71-103`

**Szenario:** Beide Indexer traversieren und statten jede JSONL, sortieren erst danach und wenden dann `prefix(limit)` an. Beim Binden einer frischen Session wird dieser Vollscan mit `limit: 20` nach 0,25/0,5/1/2/4 s bis zu fünfmal wiederholt. Cache-Hits sparen Parsing, aber weder Walk noch `resourceValues`; der monolithische Cache kennt kein Pruning und wird nach Scans vollständig encodiert/atomar geschrieben. Bei zehntausenden Transcripts sind Sekunden an Hintergrund-I/O und SSD-/CPU-Konkurrenz plausibel.

**Beweis:**

```swift
for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
    let metadata = Self.metadata(for: fileURL)
    switch cache.lookup(...) { ... }
}
return sessions.sorted { ... }.prefix(limit).map { $0 }
```

```swift
let retryDelays = [0.25, 0.5, 1, 2, 4]
...
indexedSessionResult(limit: 20, cache: &cache)
```

**Fix-Vorschlag:** Den vorhandenen Hook-/FSEvent-Pfad zur Primärquelle machen und einen persistenten URL-/Session-ID-Index pflegen. Für Fallbacks neueste Datumsverzeichnisse oder einen mtime-Heap verwenden. Cache-Einträge nach erfolgreichem Vollscan über `seenKeys` prunen und nur bei Dirty-Revision schreiben.

**Konfidenz:** hoch

## F13: UI-State-Saves laufen auf Main und No-op-Mutationen schreiben trotzdem

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:36-47`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:901-938`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:113-125`, `WhisperM8/Views/AgentChatsView+RuntimeServices.swift:75-104`

**Szenario:** Jede Store-Mutation erhöht ohne Vorher/Nachher-Prüfung die Dirty-Revision und plant einen Save. `reconcileSelection` schreibt unter anderem Expansionen auch dann zurück, wenn der Wert bereits enthalten ist. Nach 400 ms encodiert und schreibt der `@MainActor`-Store den gesamten UI-State atomar; zugleich beobachten alle Fenster dieselbe `state`-Property. Das erzeugt unnötige Cross-Window-Re-Renders und kann das 20-ms-Savebudget auf langsamer Platte überschreiten.

**Beweis:**

```swift
private func mutate(_ block: (inout AgentUIState) -> Void) {
    block(&state)
    dirtyRevision &+= 1
    scheduleSave()
}
...
try persistence.saveUIState(state)
```

**Fix-Vorschlag:** Mutationen gegen einen Vorher-Snapshot diff-gaten; nur echte Änderungen publizieren und persistieren. Pro Fenster beobachtbare Slices statt eines globalen Aggregate-State bereitstellen. Beim Save einen Value-Snapshot samt Revision an einen seriellen I/O-Actor übergeben und Erfolg generation-geprüft quittieren.

**Konfidenz:** hoch

## F14: Flache Sidebar materialisiert alle Rows und erzeugt O(n²)-Reihenfolgen

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:1052-1115`, `WhisperM8/Views/AgentChatsView.swift:1172-1196`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:12-47`, `WhisperM8/Views/AgentChatsSidebarViews.swift:709-795`

**Szenario:** Die flache „Alle“-Ansicht verwendet `ScrollView` plus normales `VStack`, hat anders als Projektgruppen kein sichtbares 20er-Limit und baut alle Rows samt Drag-/Status-Modifier. Innerhalb jeder Row wird `flatSessions.map(\.id)` erneut erzeugt: 1.000 Sessions bedeuten rund eine Million UUID-Kopien pro betroffener Body-Auswertung. Jede materialisierte Row hängt zudem am selben `@Published statuses`-Dictionary; ein Statuswechsel durchläuft alle Subscriber, auch wenn `removeDuplicates` fremde Body-Updates erst danach stoppt.

**Beweis:**

```swift
VStack(alignment: .leading, spacing: 2) {
    ...
    ForEach(flatSessions) { session in
        flatRow(session, order: flatSessions.map(\.id), split: split)
    }
}
```

```swift
$statuses
    .map { $0[sessionID] }
    .removeDuplicates()
```

**Fix-Vorschlag:** Reihenfolge einmal vor dem `ForEach` berechnen und auch flat paginieren. Die non-lazy Drag-and-drop-Einschränkung in einer begrenzten Teilmenge isolieren oder auf eine virtualisierte AppKit-Liste wechseln. Status pro Session über eigene Subjects/kleine Observable-Objekte publizieren.

**Konfidenz:** sehr hoch

## F15: 1,5-s-Fallback erzeugt pro Session dauerhaft Task- und Stat-Fan-out

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:55-83`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:264-365`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:390-445`

**Szenario:** Solange Sessions gewacht werden, pollt ein Timer alle 1,5 s jede Session. `pollOne` erzeugt pro Session einen eigenen detached Task; auch bei aktivem vnode-Watcher und unveränderter Datei fällt mindestens Task-Scheduling plus `stat` an. 60 langlebige Sessions ergeben im Leerlauf ungefähr 40 Tasks und Stats pro Sekunde. Das einzelne 100-ms-Status-Poll-Budget erfasst die aggregierte Last nicht.

**Beweis:**

```swift
Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { ... }
...
for sessionID in watched.keys {
    pollOne(sessionID: sessionID)
}
...
let snapshot = await Task.detached(priority: .utility) {
    Self.pollSnapshot(...)
}.value
```

**Fix-Vorschlag:** Fällige Sessions in einem Utility-Batch pro Tick prüfen. Für vnode-aktive, hook-live oder lange idle Sessions adaptives Backoff verwenden; das 1,5-s-Intervall nur während zeitkritischer Status-Eskalationsfenster oder bei fehlender URL beibehalten.

**Konfidenz:** hoch

## F16: ScreenCaptureKit liefert native BGRA-Frames mit Queue-Tiefe fünf

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/Dictation/ManualScreenClipSession.swift:49-84`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:197-201`

**Szenario:** Der Clip-Pfad nimmt das Display in voller Pixelauflösung mit 12 fps, 32-Bit-BGRA und Queue-Tiefe fünf auf; erst die später extrahierten Standbilder werden auf 1600×1000 begrenzt. Bei 5K entsprechen fünf rohe Frames theoretisch rund 281 MiB Oberflächen und der Rohdatenstrom rund 675 MiB/s (5120×2880×4×12), zuzüglich Encoderflächen. Das ist während Diktat eine relevante Speicherbandbreiten-, CPU/GPU- und Pressure-Quelle.

**Beweis:**

```swift
let width = CGDisplayPixelsWide(target.display.displayID)
let height = CGDisplayPixelsHigh(target.display.displayID)
configuration.width = width
configuration.height = height
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.queueDepth = 5
```

**Fix-Vorschlag:** Bereits capture-seitig auf die für Kontext nötige Auflösung (z. B. 1920 oder 2560 Pixel Kantenlänge) skalieren, Queue-Tiefe auf 2–3 und Framerate auf 6–8 fps senken. Qualitäts-/Drucktests auf 5K/6K-Displays ergänzen.

**Konfidenz:** hoch für die Konfiguration, mittel für die tatsächlich gleichzeitig residente Speichermenge

## F17: Clipboard-Screenshots werden synchron auf Main dekodiert und als PNG geschrieben

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:57-104`, `WhisperM8/Services/Dictation/RecordingCoordinator+Clipboard.swift:130-151`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:33`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:104-127`, `WhisperM8/Services/Dictation/VisualContextCaptureService.swift:265-277`

**Szenario:** Der 500-ms-Clipboard-Monitor läuft auf Main und importiert neue Bilder über einen vollständig `@MainActor`-gebundenen Service. Ein großer Retina-Screenshot wird als `NSImage`/`CGImage` dekodiert, verlustfrei PNG-encodiert und atomar geschrieben. Das kann beim Aufnehmen für zig bis hunderte Millisekunden Hotkey-/Overlay-Reaktion blockieren und kurzfristig mehrere Pixelbuffer-Kopien halten.

**Beweis:**

```swift
@MainActor
final class VisualContextCaptureService {
    ...
    try writePNG(image, to: fileURL)
}
```

```swift
let representation = NSBitmapImageRep(cgImage: image)
let data = representation.representation(using: .png, properties: [:])
try data.write(to: url, options: .atomic)
```

**Fix-Vorschlag:** Auf Main nur Change-Count und eine begrenzte Rohdatenkopie sichern. Decode, Downscale, PNG-Encoding und Write in einem seriellen Worker erledigen; Pixel-/Byte-Limits sowie Cancellation beim Aufnahmeende vorsehen.

**Konfidenz:** hoch

## F18: Globaler Scroll-Monitor baut vor dem Event-Gating die komplette Tab-Map

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Views/AgentChatsView+Shortcuts.swift:350-388`, `WhisperM8/Views/AgentChatsView.swift:379-382`

**Szenario:** Der app-lokale Scroll-Event-Monitor jedes Agent-Chats-Fensters berechnet `headerTabs`, bevor geprüft wird, ob das Event über dem Tabstrip oder überhaupt im eigenen Fenster liegt. `headerTabs` baut dafür jedes Mal ein Dictionary über alle Workspace-Sessions. Bei Trackpad-Scroll mit deutlich über 60 Events/s entsteht O(Sessionzahl × Fenster × Eventrate) Main-Thread-Arbeit selbst beim Scrollen in Terminal oder Sidebar; große Historien können deshalb Scrollback ruckeln lassen.

**Beweis:**

```swift
let sessionsByID = Dictionary(uniqueKeysWithValues: workspace.sessions.map { ($0.id, $0) })
return openTabIDs.compactMap { sessionsByID[$0] }
```

Der Scroll-Handler greift auf `headerTabs` zu, bevor seine Hover-/Fenster-Guards das Event verwerfen.

**Fix-Vorschlag:** Zuerst `event.window`, Mausposition und Tabstrip-Frame prüfen; erst danach Tabdaten auflösen. Eine Session-ID→Session-Map beziehungsweise den fertigen Header-Tab-Slice pro Workspace-Revision cachen und den Event-Monitor an das konkrete Fenster statt app-weit binden.

**Konfidenz:** hoch
