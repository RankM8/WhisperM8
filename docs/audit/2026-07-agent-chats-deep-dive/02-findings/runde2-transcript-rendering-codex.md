# Runde 2: Transcript-Rendering und Timeline

Audit-Stand: 2026-07-18. Geprüft wurde der aktuelle Worktree einschließlich der Sliding-Window-Änderung aus `80cd1ca` und der Terminal-Snapshot-Änderungen aus `f448e02`/`a26d29f`. Die Analyse ist statisch; zur Drift-Gegenprobe wurden ausschließlich Event-Typen und Häufigkeiten vorhandener lokaler JSONL-Dateien ausgewertet, keine Inhalte.

## Zusammenfassung

- **Kritisch:** 0
- **Hoch:** 5
- **Mittel:** 3
- **Niedrig:** 1
- **Wichtigster Punkt:** Der Live-Subagent-Pfad liest bei bis zu 5 Updates pro Sekunde immer wieder das gesamte Tail, baut daraus die komplette Timeline in nicht abbrechbaren Detached Tasks neu und publiziert Ergebnisse ohne Generation-Guard. Bei langen Sessions vervielfacht das die Arbeit und erlaubt zugleich, dass ein älterer Build einen neueren Transcript-Stand überschreibt.

## F1: Vollständige, nicht abbrechbare Timeline-Rebuilds können sich stapeln und veralteten Stand publizieren

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Views/SubagentJobDetailView.swift:600-644`; `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:108-134`; `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:21-84`

**Szenario:** Ein aktiver Subagent schreibt in Bursts in sein Rollout. Nach 200 ms wird jeweils das komplette aktuelle Tail erneut gelesen und geparst. Jede neue Message ändert `rebuildTaskID`; SwiftUI bricht damit zwar den vorherigen `.task` ab, der darin gestartete `Task.detached` erbt diese Cancellation aber nicht. Bei einem langen, auf bis zu 32 MiB nachgeladenen Transcript können mehrere volle Parse- und Timeline-Läufe gleichzeitig laufen. Ein langsamer alter Lauf darf nach einem neueren fertig werden und `timeline` wieder auf einen älteren Stand setzen. Bei mehr als 10.000 Einträgen ist der Aufbau weiterhin O(n) pro Update, nicht inkrementell.

**Beweis:**

```swift
// SubagentJobDetailView.swift
private func scheduleTranscriptReload() {
    transcriptReloadTask?.cancel()
    transcriptReloadTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        if let url = cachedTranscriptURL {
            reloadTranscript(from: url)
        }
    }
}

private func reloadTranscript(from url: URL) {
    let tailBytes = transcriptTailBytes
    Task {
        let fresh = await Task.detached(priority: .utility) {
            CodexTranscriptReader.readTail(fileURL: url, tailBytes: tailBytes)
        }.value
        transcript = fresh
    }
}
```

```swift
// AgentTranscriptContainerView.swift
.task(id: rebuildTaskID) {
    await rebuildTimeline()
}

let built = await Task.detached(priority: .userInitiated) {
    TranscriptTimelineBuilder.build(from: transcript)
}.value
timeline = built
```

Weder der Transcript-Read noch der Timeline-Build besitzt eine Generation, einen Latest-wins-Check oder einen In-flight-Guard. `TranscriptTimelineBuilder.build` iteriert bei jedem Aufruf erneut über `transcript.messages`.

**Fix-Vorschlag:** Pro Transcript-URL genau einen seriellen Tail-Actor verwenden, der einen Byte-Offset und einen Restzeilenpuffer hält und nur neue vollständige JSONL-Zeilen parst. Während eines Reads eintreffende Events als Dirty-/Trailing-Edge markieren. Die Timeline entweder inkrementell um Messages erweitern oder Builds mit monotoner Generation versehen; vor jeder State-Zuweisung Session-ID, Tail-Generation und `Task.isCancelled` prüfen. Kein unstrukturierter Detached Task darf ohne diesen Latest-wins-Guard UI-State publizieren.

**Konfidenz:** sehr hoch

## F2: Das Sliding Window verwechselt ein rollendes Live-Tail mit Kopf-Wachstum und verliert den Lesepunkt

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:280-294`; `WhisperM8/Views/SubagentJobDetailView.swift:627-644`; `WhisperM8/Views/AgentChatTranscriptView.swift:94-115`; `WhisperM8/Views/Transcript/AgentTimelineView.swift:81-105`; `WhisperM8/Views/Transcript/TranscriptWindow.swift:53-92`

**Szenario:** Der User blättert in einem aktiven Subagent-Transcript nach oben. Jeder Live-Reload liest weiterhin nur die letzten `tailBytes`. Sobald die Datei wächst, wandert der Byte-Offset nach vorn: alte Messages fallen am Kopf aus dem geladenen Array, neue kommen am Ende hinzu. Die Views beobachten aber nur die Anzahl. Bei gleicher Anzahl passiert gar kein Window-Sync; bei kleinerer Anzahl wird hart ans Tail resettet; bei größerer Anzahl und geänderter erster ID wird der Vorgang fälschlich als **Prepend älterer Daten** behandelt. `updateForHeadGrowth` verschiebt daraufhin beide Indizes um das gesamte Zähler-Delta und blättert zusätzlich eine Batch nach oben. Der bisher sichtbare Anchor kann bereits aus dem Tail verschwunden sein; die Anzeige springt oder zeigt einen anderen Ausschnitt. Das dokumentierte Verhalten „während man oben liest bleibt die Position stabil“ gilt damit nur für ein im Speicher wirklich append-only wachsendes Array, nicht für den tatsächlichen Live-Reader.

**Beweis:**

```swift
// TranscriptTailReader
let size = try handle.seekToEnd()
let offset = UInt64(max(0, Int64(size) - Int64(tailBytes)))
try handle.seek(toOffset: offset)
let data = handle.readData(ofLength: tailBytes)
...
if offset > 0, !lines.isEmpty {
    lines.removeFirst()
}
```

```swift
// AgentChatTranscriptView; AgentTimelineView ist strukturgleich
.onChange(of: allMessages.count) { _, _ in
    syncWindow()
}
...
if messages.count < window.total {
    window.reset(total: messages.count)
} else if messages.count > window.total,
          let known = firstMessageID,
          known != messages.first?.id {
    window.updateForHeadGrowth(total: messages.count)
}
```

```swift
// TranscriptWindow
mutating func updateForHeadGrowth(total newTotal: Int) {
    let delta = newTotal - total
    start += delta
    end += delta
    total = newTotal
    pageUp()
}
```

Die Entscheidung kennt weder den tatsächlichen Prepend-Count noch die IDs des bisherigen sichtbaren Bereichs. Die vorhandenen Window-Tests simulieren reines Prepend bzw. reines Append, nicht den realen Mischfall „Head-Eviction + Tail-Append“.

**Fix-Vorschlag:** Live-Streaming und explizites History-Nachladen als getrennte Events modellieren. Beim Live-Pfad das bereits geladene Message-Array inkrementell erweitern, statt bei jedem Write ein rollendes Bytefenster zu ersetzen; für den Speicher ein unabhängiges Message-/Bytebudget verwenden. Beim Reconcile den sichtbaren Anchor per stabiler ID im neuen Array suchen und das Fenster relativ zu dieser ID setzen. Falls der Anchor wirklich evicted wurde, einen sichtbaren Hinweis statt eines stillen Tail-Resets anzeigen.

**Konfidenz:** sehr hoch

## F3: Verlorene Tool-Korrelations-IDs ordnen parallele Ergebnisse dem falschen Aufruf zu

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Models/AgentChatTranscript.swift:96-103`; `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:163-180, 204-220`; `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:151-170`; `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:98-99, 228-251`; `Tests/WhisperM8Tests/AgentTestSupport.swift:53-54`

**Szenario:** Claude oder Codex startet zwei Tools beziehungsweise Subagents parallel und die Ergebnisse treffen nicht in Aufrufreihenfolge ein. Beide Quellformate liefern dafür eine Korrelations-ID (`tool_use.id`/`tool_result.tool_use_id` bei Claude, `call_id` bei Codex). Das einheitliche Modell verwirft diese Felder. Die Timeline hängt Resultate stattdessen FIFO an den ältesten offenen Step. Bei der Reihenfolge Call A, Call B, Result B, Result A zeigt die UI Result B unter Call A und Result A unter Call B; Fehlerstatus, Subject und aufgeklappter Inhalt sind damit sachlich falsch.

**Beweis:**

```swift
// Das kanonische Modell hat keinen Korrelationsschlüssel.
enum AgentChatBlock: Equatable {
    case toolUse(name: String, input: String)
    case toolResult(content: String, isError: Bool)
}
```

```swift
// Ein echtes Codex-Fixture enthält denselben call_id auf Call und Output.
{"type":"function_call", ..., "call_id":"call_inBcNU2GxXHVmpmz10I4CFm7"}
{"type":"function_call_output", "call_id":"call_inBcNU2GxXHVmpmz10I4CFm7", ...}
```

```swift
// Der Reader liest name/arguments/output, aber keinen call_id.
case "function_call":
    let name = payload["name"] as? String ?? "tool"
    let input = payload["arguments"] as? String ?? ""
    ... blocks: [.toolUse(name: name, input: input)]
case "function_call_output":
    let output = extractFunctionOutput(payload["output"])
    ... blocks: [.toolResult(content: output, isError: ...)]
```

```swift
// Timeline-Merge
if let stepIndex = openToolStepIndices.first {
    openToolStepIndices.removeFirst()
    tool.result = content
    steps[stepIndex].kind = .tool(tool)
}
```

**Fix-Vorschlag:** `AgentChatBlock.toolUse` und `.toolResult` um eine optionale providerneutrale `correlationID` erweitern. Beide Reader müssen die nativen IDs erhalten. Der Builder führt offene Steps primär in einer Map nach ID und benutzt FIFO nur als expliziten Legacy-Fallback, wenn die Quelle wirklich keine ID liefert. Tests müssen absichtlich gegenläufige Result-Reihenfolge für Claude und Codex abdecken.

**Konfidenz:** sehr hoch

## F4: Aktuelle Codex-Eventtypen verschwinden vollständig und ohne Kompatibilitätssignal

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:95-107, 112-199`; `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:117-143, 160-183, 195-224`

**Szenario:** Eine neuere CLI schreibt einen bislang unbekannten Tool- oder Content-Typ. Beide Tail-Reader benutzen `compactMap`; unbekannte Outer-/Payload-/Chunk-Typen liefern `nil` oder werden per `break` verworfen. Es entsteht weder ein generischer Timeline-Block noch ein Unknown-Zähler oder Log. In einer read-only Gegenprobe mit der lokal installierten Codex-CLI 0.144.4 enthielten die letzten 30 Rollouts unter anderem 503 `custom_tool_call`, 503 `custom_tool_call_output`, 19 `image_generation_call`, 14 `web_search_call` und 3 `tool_search_output`; keiner dieser Typen wird vom Reader behandelt. Dadurch verschwinden komplette Tool-Ketten und die verbleibenden Texte werden einer scheinbar aktivitätslosen Runde zugeordnet.

**Beweis:**

```swift
let messages = lines
    .compactMap { line -> AgentChatMessage? in
        ...
        return parseEntry(obj)
    }
```

```swift
// Codex: nur zwei Outer-Typen und vier Response-Item-Typen.
switch outerType {
case "event_msg": ...
case "response_item": ...
default: return nil
}

switch payload["type"] as? String ?? "" {
case "function_call": ...
case "function_call_output": ...
case "tool_search_call": ...
case "reasoning": ...
default: return nil
}
```

```text
503 response_item/custom_tool_call
503 response_item/custom_tool_call_output
 19 response_item/image_generation_call
 14 response_item/web_search_call
  3 response_item/tool_search_output
```

Claude verhält sich strukturgleich: Top-Level wird nur `user`/`assistant` akzeptiert und unbekannte Content-Chunks werden still übersprungen. Die lokale Struktur-Gegenprobe zeigte beispielsweise bereits einen `document`-Chunk sowie Hauptsession-Systemereignisse wie `api_error`, `agents_killed` und `scheduled_task_fire`, die in der Transcript-Anzeige nicht repräsentiert werden.

**Fix-Vorschlag:** Provider-Adapter mit explizitem Compatibility-Result einführen: bekannte Typen semantisch mappen, unbekannte anzeigbare Payloads als gedeckelten `.unknown(providerType:summary:)`-Block erhalten und Typ-Zähler loggen. Die aktuellen Codex-Typen `custom_tool_call(_output)`, Image Generation, Web Search und Tool-Search-Output gezielt unter Erhalt ihrer Korrelations-ID abbilden. Anonymisierte Golden Fixtures pro unterstützter CLI-Version sowie ein Test „unknown bleibt sichtbar und bricht die Runde nicht“ ergänzen.

**Konfidenz:** sehr hoch

## F5: Eine vorhandene, aber unlesbare Snapshot-Datei blockiert den Transcript-Fallback

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:70-105`; `WhisperM8/Views/AgentSessionDetailView.swift:204-225, 255-260`; `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:49-58, 74-83`

**Szenario:** Eine Snapshot-Datei ist korrupt, leer, nur teilweise geschrieben oder stammt von einer neueren Header-Version. `load` liefert korrekt `nil`; `hasSnapshot` meldet wegen der bloßen Dateiexistenz aber `true`. Im globalen Terminal-Modus wird deshalb der JSONL-Load aufgeschoben. Nach dem asynchronen Decode setzt die View `terminalSnapshot = nil`; der Container fällt auf Chat zurück, aber es gibt keinen Trigger, der jetzt `loadTranscriptIfNeeded()` nachholt. Der User sieht den Empty-State statt des vorhandenen Transcripts. Der echte Missing-File-Fall funktioniert, der Decode-Failure-Fall nicht.

**Beweis:**

```swift
func hasSnapshot(sessionID: UUID) -> Bool {
    fileManager.fileExists(atPath: fileURL(sessionID: sessionID).path)
}

func load(sessionID: UUID) -> TerminalSnapshot? {
    guard let data = try? Data(contentsOf: ...),
          ...,
          header.version == Self.currentVersion,
          ... else { return nil }
}
```

```swift
private var transcriptLoadIsDeferred: Bool {
    transcriptViewMode == ...terminal.rawValue
        && TerminalSnapshotStore.shared.hasSnapshot(sessionID: session.id)
}

guard !transcriptLoadIsDeferred || cachedTranscript != nil else {
    isLoadingTranscript = false
    return
}
```

Der Container löst einen gespeicherten Terminal-Modus bei `terminalSnapshot == nil` zwar zu `.chat` auf, die Detail-View beobachtet diese Snapshot-Änderung jedoch nicht zum Nachladen des Transcripts.

**Fix-Vorschlag:** Die erfolgreiche `load`-Antwort zur einzigen Wahrheit der Weiche machen. Transcript-Loading erst nach abgeschlossenem Snapshot-Load deferieren; bei `nil` sofort den JSONL-Fallback starten. Ungültige Sidecars optional quarantänisieren oder löschen, damit der Fehler nicht bei jedem Mount wiederkehrt. Einen Integrationstest für „Datei existiert + unbekannte Version + gültiges Transcript“ ergänzen.

**Konfidenz:** sehr hoch

## F6: Der Snapshot wird vor dem tatsächlichen Prozessende eingefroren und später nicht mehr korrigiert

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:385-400, 775-819, 969-979`

**Szenario:** Beim expliziten Stop oder App-Quit braucht Claude/Codex länger als die fest verdrahteten 260 ms, um Alternate Screen zu verlassen, den Resume-Hinweis auszugeben und den letzten JSONL-Flush abzuschließen. WhisperM8 kopiert den Normal-Buffer nach der Wartezeit, **bevor** `terminal.terminate()` beziehungsweise ein bestätigtes `processTerminated` erfolgt. `didCaptureSnapshot` wird dabei schon vor der Buffer-Validierung gesetzt. Trifft danach noch finaler PTY-Output ein, ist der spätere `processTerminated`-Capture ein No-op. Snapshot und Transcript können deshalb am Ende auseinanderlaufen; insbesondere der laut Kommentar garantierte Resume-Hinweis kann fehlen.

**Beweis:**

```swift
func terminate() {
    if isRunning {
        terminal.send([0x03])
        usleep(80_000)
        terminal.send([0x03])
        usleep(180_000)
    }
    terminal.flushPendingOutput()
    captureTerminalSnapshot()   // vor Prozessende
    terminal.terminate()
}
```

```swift
private func captureTerminalSnapshot() {
    guard hasStarted, !didCaptureSnapshot else { return }
    didCaptureSnapshot = true
    let data = terminal.getTerminal().getBufferAsData(kind: .normal)
    ...
}

func processTerminated(...) {
    ...
    self.captureTerminalSnapshot() // wegen didCaptureSnapshot ggf. No-op
}
```

Der App-Quit-Pfad verwendet dieselben zwei Interrupts und dieselbe feste Gesamtwartezeit, bevor er alle Snapshots erfasst.

**Fix-Vorschlag:** Graceful Termination als asynchrone Zustandsmaschine an `processTerminated` koppeln. Den finalen Snapshot primär dort erfassen; nur bei Ablauf einer klaren Deadline einen als „vor Prozessende“ markierten Fallback schreiben. `didCaptureSnapshot` erst nach erfolgreichem Save setzen und einen vorläufigen Snapshot beim echten Prozessende ersetzen dürfen. Beim App-Quit, soweit AppKit Zeit gibt, eine kurze Terminate-Later-Phase statt eines synchronen Blind-Sleeps verwenden.

**Konfidenz:** hoch

## F7: Codex-`phase` geht im Merge verloren und Commentary kann als finale Antwort erscheinen

**Schweregrad:** mittel

**Fundort:** `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:117-136`; `WhisperM8/Models/AgentChatTranscript.swift:29-39, 96-109`; `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:109-145, 255-263`; `Tests/WhisperM8Tests/AgentTestSupport.swift:50, 59`

**Szenario:** Codex schreibt `agent_message` mit `phase: commentary` oder `phase: final_answer`. Der Reader kennt das Feld laut eigenem Header-Kommentar, liest es aber nicht in das gemeinsame Modell. Der Builder unterscheidet stattdessen heuristisch: Assistant-Text wird nur dann zur Note degradiert, wenn **danach ein Thinking-/Tool-Block** folgt. Kommt nach dem letzten Tool-Ergebnis noch ein Commentary-Status und danach die finale Antwort, bleiben beide Texte in `provisionalAnswers` und werden als zwei finale Antworten gerendert. Damit geht ein vorhandenes semantisches Feld beim Codex→AgentChatTranscript-Merge verloren.

**Beweis:**

```swift
// Fixture
{"type":"agent_message", "message":"Ich lese gezielt ...", "phase":"commentary"}
{"type":"agent_message", "message":"{\"status\":\"success\"...}", "phase":"final_answer"}
```

```swift
case "agent_message":
    guard let message = payload["message"] as? String, !message.isEmpty else { return nil }
    return AgentChatMessage(
        id: UUID(), role: .assistant, timestamp: timestamp,
        blocks: [.text(message)]
    )
```

```swift
case .text(let text):
    provisionalAnswers.append(TranscriptAnswer(...))
case .thinking, .toolUse:
    demoteProvisionalAnswersToNotes()
```

`AgentChatMessage` und `AgentChatBlock.text` besitzen keinen Platz für die Phase. Die Zeitstempel und die JSONL-Dateireihenfolge bleiben dagegen erhalten; das belegte Problem ist der Semantikverlust, nicht eine nachträgliche Sortierung.

**Fix-Vorschlag:** Assistant-Text im kanonischen Modell um eine optionale Semantik (`commentary`, `finalAnswer`, `unknown`) erweitern. Codex `phase` direkt abbilden; Claude kann mangels gleichwertigem Feld `unknown` verwenden und weiterhin heuristisch klassifiziert werden. Der Builder muss Commentary unabhängig von nachfolgender Tool-Aktivität als Note behandeln.

**Konfidenz:** sehr hoch

## F8: Das Topologie-Budget deckelt Runden und Steps, aber nicht die immer sichtbaren Antworten einer Runde

**Schweregrad:** hoch

**Fundort:** `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:109-145, 197-223`; `WhisperM8/Views/Transcript/AgentTimelineView.swift:23-44`; `WhisperM8/Views/Transcript/TimelineRoundView.swift:27-60`; `WhisperM8/Views/Transcript/TranscriptRenderSupport.swift:11-35`

**Szenario:** Eine lange autonome Runde erzeugt sehr viele Assistant-Textblöcke, zum Beispiel viele Codex-Commentary-Events nach dem letzten Tool-Step oder eine Provider-Message mit vielen Text-Chunks. Das Sliding Window begrenzt nur die Zahl der **Runden** auf 160. Steps werden erst im aufgeklappten Zustand auf 400 begrenzt; `round.answers` wird dagegen immer vollständig mit einem `TranscriptMarkdownView` pro Antwort materialisiert. Eine einzige sichtbare Runde kann somit tausende Antwort-Subtrees erzeugen, jeder mit bis zu 200 Markdown-Blöcken. Der Topologie-Deckel aus `80cd1ca` ist daher keine harte Obergrenze für den Render-Baum und kann die ursprüngliche Layout-Explosion in einem einzelnen Turn wieder zulassen.

**Beweis:**

```swift
// Builder: jeder trailing Text wird eigene Answer.
case .text(let text):
    provisionalAnswers.append(TranscriptAnswer(...))
...
return TranscriptRound(
    ...,
    answers: provisionalAnswers,
    ...
)
```

```swift
// TimelineRoundView: kein prefix-/Budget-Limit.
ForEach(round.answers) { answer in
    if let report = TimelineReportView.parseIfReport(answer.text) {
        TimelineReportView(report: report)
    } else {
        TranscriptMarkdownView(text: answer.text)
    }
}
```

`TranscriptRenderLimits` begrenzt Zeichen, Markdown-Blöcke, Listen, Tabellen, Roh-Blöcke und aufgeklappte Steps, definiert aber kein `maxAnswersPerRound`. Auch Prompt-Attachments werden ohne Anzahlbudget iteriert.

**Fix-Vorschlag:** Ein echtes Node-Budget pro Runde einführen. Benachbarte Assistant-Texte gleicher Phase vor dem Rendering zusammenfassen; nur eine begrenzte Anzahl Antworten sofort zeigen und den Rest hinter einer expliziten, ebenfalls gedeckelten Aufklappung anbieten. Attachments analog begrenzen. Einen Regressionstest mit einer Runde und mehreren tausend Answer-Blöcken ergänzen; die Assertion sollte eine berechenbare maximale Zahl materialisierter Subviews beziehungsweise Render-Items prüfen.

**Konfidenz:** hoch

## F9: Jeder laufende Parent-Chip betreibt einen eigenen 30-Hz-Animationstakt

**Schweregrad:** niedrig

**Fundort:** `WhisperM8/Views/AgentChatsSidebarViews.swift:529-560, 597-604`; `WhisperM8/Views/AgentChatsView.swift:1052-1115`

**Szenario:** Viele Parent-Chats haben gleichzeitig laufende Subagents. Für jeden Parent instanziiert `SubagentChildrenChip` einen eigenen `SubagentRoad`, und jeder Road enthält einen eigenen `TimelineView(.animation(minimumInterval: 1/30))`. Die Chat-Liste liegt in einem normalen `VStack` innerhalb der `ScrollView`, nicht in einem `LazyVStack`; damit bleiben auch außerhalb des Viewports materialisierte Chips Teil des View-Baums. Bei 30 laufenden Parents entstehen dauerhaft bis zu 30 unabhängige 30-Hz-Invalidierungsquellen für eine reine 2×7-Pixel-Opacity-Animation. Die gemeinsame Wandzeit verhindert Phasendrift, teilt aber nicht den SwiftUI-Taktgeber.

**Beweis:**

```swift
struct SubagentRoad: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) { ... }
        }
    }
}
```

```swift
if runningChildCount > 0 {
    SubagentRoad(barCount: min(runningChildCount, 6))
}
```

```swift
ScrollView {
    ...
    VStack(alignment: .leading, spacing: 2) {
```

Die vorhandenen `SubagentRoadWaveTests` prüfen Wertebereich und Phasenrichtung der reinen Opacity-Funktion, nicht Zahl oder Lebensdauer der Timeline-Scheduler.

**Fix-Vorschlag:** Einen einzigen, gedrosselten Phasenwert auf Sidebar-Ebene erzeugen und an sichtbare Roads durchreichen, oder die Zeilen wirklich lazy materialisieren. Für die kleine Opacity-Welle reichen 12–15 Hz beziehungsweise eine systemseitig pausierbare Symbol-/Keyframe-Animation. Mit Instruments die Sidebar-Invalidierungen bei 1, 10 und 30 aktiven Parent-Chips messen.

**Konfidenz:** mittel

## Verifikation

Die vorhandenen relevanten Tests wurden mit temporärem Modulcache ausgeführt:

```text
swift test --disable-sandbox --filter 'Transcript(Window|TimelineBuilder|RenderSupport|Reader)|TerminalSnapshotStore|SubagentRoadWave'
65 Tests, 0 Fehler
```

Die grüne Suite bestätigt die implementierten Einzelinvarianten, enthält aber keine Tests für rollende Live-Tails, gegenläufige Tool-Resultate, unbekannte anzeigbare Eventtypen, Snapshot-Decode-Fallback, Latest-wins bei überlappenden Builds oder Antwort-Topologie innerhalb einer einzelnen Runde.
