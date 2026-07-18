# Performance-Findings (Fable, zweite unabhängige Jagd — SwiftUI-Schwerpunkt)

Audit-Datum: 2026-07-18 · Reine Code-Analyse (kein Build/Profiling). Fokus laut Auftrag:
Re-Render-Kaskaden, Main-Thread-I/O, JSONL-Reads, Prozess-Spawns in Hot-Paths, SwiftTerm-Streaming.
Referenz-Budgets: `WhisperM8/Services/Shared/PerformanceSignposts.swift` (`storeMutate` 30 ms,
`storeLoad` 15 ms, `sidebarStatusPoll` 100 ms, `chatTail` 100 ms, `gridStreamingFrame` 16,7 ms).

Positiv vorab (bewusst keine Findings): der Status-Pfad ist sauber per-Item entkoppelt
(`statusPublisher(for:)` + Equatable-Rows), der RuntimeWatcher ist stat-first/event-driven,
Transcript-Loads sind bounded (Tail-Reads, LRU-Cache, max. 2 parallel), Terminal-Streaming ist
über `TerminalFeedBatcher` gedrosselt und Login-Shell/`which` werden beim Launch off-main
geprewarmt. Die Findings unten sind die verbleibenden Lücken.

---

## F1: `mergeIndexedSessions` läuft O(m·n) auf dem MainActor unter dem prozessweiten Store-Lock

**Schweregrad:** hoch
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:716–890` (Merge-Loop: 786, 803, 823–847), Aufrufer `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:138–146`
**Konfidenz:** hoch (Codepfad eindeutig; Dauer geschätzt, nicht gemessen)

**Szenario (Auslöser → Wirkung):** Jeder Indexer-Scan (App-Start, jede Foreground-Reaktivierung
mit 30 s Cooldown, FSEvents mit 10 s Cooldown) endet in `MainActor.run { … store.mergeIndexedSessions(codex.sessions + claude.sessions) }`.
Der Merge iteriert über bis zu 2 000 indizierte Sessions (Limit 1 000 pro Provider) und macht
**pro** indizierter Session lineare Scans über alle Workspace-Sessions — auf dem Main Thread,
innerhalb von `mutateWorkspace` (= unter dem NSLock des `AgentWorkspaceStore`, Budget
`store.mutate` = 30 ms). Bei einem gewachsenen Workspace (Indexer importiert die komplette
externe Historie) sind das Millionen String-Vergleiche pro Scan → spürbarer Main-Thread-Hänger
genau in dem Moment, in dem der User per Cmd-Tab zur App zurückkehrt. Parallel blockiert der
Lock alle anderen Store-Zugriffe (UI-Reads, Watcher-Bookkeeping).

**Beweis:**

`AgentScanCoordinator.swift:138–143` — der Merge läuft explizit auf dem MainActor:
```swift
await MainActor.run {
    let coordinator = AgentScanCoordinator.shared
    let activeSessionIDs = coordinator.activeSessionIDsProvider()
    let store = AgentSessionStore()
    try? store.markStaleRunningSessionsClosed(excluding: activeSessionIDs)
    try? store.mergeIndexedSessions(codex.sessions + claude.sessions)
```

`AgentSessionStore.swift:803` — linearer Scan pro indizierter Session (1. Pass):
```swift
if let index = workspace.sessions.firstIndex(where: { $0.provider == indexed.provider && $0.externalSessionID == indexed.externalSessionID }) {
```

`AgentSessionStore.swift:823–831` — Fallback-Pass filtert NOCHMAL alle Sessions pro Kandidat:
```swift
} else if let index = workspace.sessions.indices
    .filter({ idx in
        let candidate = workspace.sessions[idx]
        return candidate.provider == indexed.provider
```

Zusätzlich baut die Duplikat-Erkennung (`AgentSessionStore.swift:765`) pro Duplikat-Key erneut
`workspace.sessions.first(where:)`. Dazu kommt pro Mutation der Equatable-Diff des gesamten
Workspace (`AgentWorkspaceStore.swift:124/134: let before = workspace … workspace != before`).

**Fix-Vorschlag:** Vor dem Loop einmalig `Dictionary`-Indizes bauen
(`[provider|externalSessionID: Int]` und pro Projekt eine Liste ungebundener Adoptionskandidaten)
→ O(m+n). Zusätzlich prüfen, ob der Merge (reine Datenarbeit) wirklich MainActor braucht — die
Facade ist synchron-throws und laut P1-Architektur von Detached-Tasks aus aufrufbar; nur
`activeSessionIDsProvider()` braucht den MainActor-Hop.

---

## F2: Inspector-Panel spawnt drei `git`-Subprozesse synchron auf dem Main Thread

**Schweregrad:** hoch (nur bei sichtbarem Inspector; dann bei jedem Projektwechsel)
**Fundort:** `WhisperM8/Views/ProjectDetailPanel.swift:105–132`, `WhisperM8/Services/AgentChats/GitProjectStatus.swift:13–50`
**Konfidenz:** hoch

**Szenario:** Ist der Inspector eingeblendet (`agentChatsInspectorVisible`), führt
`refreshGitStatus()` bei `onAppear` und bei **jedem** `project?.path`-Wechsel
`GitProjectStatus(path:)` aus — direkt im View-Update. Da `selectedProjectID` der
Session-Selektion folgt (`AgentChatsView.swift:713–716`), triggert jeder Klick auf einen Chat
eines anderen Projekts drei serielle `Process`-Spawns mit `waitUntilExit()`:
`git branch --show-current`, `git status --porcelain`, `git diff --numstat`. Auf großen Repos
(oder kaltem FS-Cache) blockiert das den Main Thread für hunderte Millisekunden bis Sekunden —
der Tab-/Selektionwechsel „hängt".

**Beweis:**

`ProjectDetailPanel.swift:126–132` — synchron im View-Kontext, kein Task:
```swift
private func refreshGitStatus() {
    guard let project else {
        status = nil
        return
    }
    status = GitProjectStatus(path: project.path)
}
```
mit `ProjectDetailPanel.swift:105–108`:
```swift
.onAppear(perform: refreshGitStatus)
.onChange(of: project?.path) { _, _ in
    refreshGitStatus()
}
```

`GitProjectStatus.swift:42–43` — blockierender Spawn (×3 pro Init):
```swift
try process.run()
process.waitUntilExit()
```

Das steht im direkten Widerspruch zur eigenen Regel in `AgentSessionStore.swift:1084–1086`
(„ein Subprozess mit `waitUntilExit()` fror dort die UI sichtbar ein" — Begründung für
`GitBranchReader` als Datei-Read).

**Fix-Vorschlag:** `GitProjectStatus` in `Task.detached(priority:.userInitiated)` erheben und
Ergebnis via `@State` nachreichen (Muster `AgentResourceSummaryButton.refresh()`,
`AgentResourceSummaryButton.swift:92–103`); Branch weiterhin über den billigen
`GitBranchReader` (Datei-Read) beziehen.

---

## F3: Jede Workspace-/Store-Invalidierung evaluiert den kompletten AgentChatsView-Body — mit mehreren O(n)-Vollpässen über alle Sessions pro Eval und pro Fenster

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:283–307`; `WhisperM8/Views/AgentChatsView.swift:379–382, 384–388, 415–437, 677, 727–737, 1052–1113`
**Konfidenz:** hoch (Mechanik), mittel (praktische Größenordnung — hängt an der Workspace-Größe)

**Szenario:** `AgentWorkspaceUIModel` publiziert den GESAMTEN Workspace als eine einzige
@Observable-Property (`AgentWorkspaceStore.swift:288: private(set) var workspace`).
Observation trackt property-genau — d. h. jede Mutation irgendwo (Turn-Ende → `recordTurnEnded`,
AutoNamer-Titel, Scan-Merge inkl. bloßer `lastActivityAt`-Bumps externer Sessions, Job-Sync)
invalidiert den Body **jedes** offenen Agent-Chats-Fensters komplett. Ein Body-Eval ist dabei
nicht billig, weil mehrere computed Properties Vollpässe über `workspace.sessions` machen und
mehrfach pro Eval aufgerufen werden:

- `headerTabs` baut bei **jedem Zugriff** ein Dictionary über alle Sessions
  (`AgentChatsView.swift:380: Dictionary(workspace.sessions.map { ($0.id, $0) } …)`) und wird
  pro Body-Eval ~8× ausgewertet (Zeilen 385, 387, 2022, 2075, 2079, 2122, 2190, 2245) —
  zusätzlich über `selectedSession` (385–388), das selbst mehrfach gelesen wird.
- `runningResourceDescriptors` (415–437) macht pro Session einen linearen
  `workspace.projects.first(where:)` → O(n·p) pro Eval.
- `.onChange(of: workspace)` (727) erzwingt pro Body-Eval einen **Deep-Equatable-Vergleich des
  gesamten Workspace** (alle Sessions inkl. Strings/Dates); `.onChange(of: workspace.projects.map(\.id))`
  (677) baut pro Eval ein weiteres Array.
- Der Sidebar-Model-Builder (1052–1113) macht pro Eval 4–5 weitere gefilterte/sortierte
  Vollpässe (`subagentChildren`, `sessionsByProject`, `flatSessions`, `pinnedSessions`).

Da der Indexer die komplette externe Historie importiert (Limit 1 000 Sessions **pro Provider**,
`ClaudeSessionIndexer.swift:17`), wächst `workspace.sessions` auf tausende Einträge, obwohl die
Sidebar nur `isManuallyCreated`-Sessions zeigt. Multipliziert mit der Body-Eval-Frequenz (auch
jede `AgentWindowStore`-/`terminalRegistry`-/`jobRuntimeModel`-Änderung evaluiert den Body, siehe
F4) entsteht messbarer Dauer-Overhead; sichtbar als Dichte der `sidebar.bodyEval.chats`-Events
(`AgentChatsView.swift:440`).

**Beweis:** siehe Zitate oben; zentrale Stelle `AgentChatsView.swift:379–382`:
```swift
var headerTabs: [AgentChatSession] {
    let byID = Dictionary(workspace.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return openTabIDs.compactMap { byID[$0] }.filter { $0.status != .archived }
}
```

**Fix-Vorschlag:** (a) `headerTabs`/`selectedSession` einmal am Body-Anfang binden (`let`) statt
computed-mehrfach; (b) das Sessions-Dictionary im `AgentWorkspaceUIModel` als abgeleiteten,
mitgepflegten Index anbieten; (c) `.onChange(of: workspace)` auf einen billigen Fingerprint
umstellen (z. B. Zähler/Revision im UIModel hochzählen) statt Deep-Compare des Value-Types;
(d) langfristig die UI-Projektion splitten (Sessions-Liste vs. Projekte vs. Meta), damit nicht
jede Mutation jedes Fenster invalidiert.

---

## F4: `AgentWindowStore.mutate` ist nicht diff-gated — No-op-Mutationen re-rendern alle Fenster und planen Disk-Saves

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:894–905, 766–782`; Trigger `WhisperM8/Views/AgentChatsView+RuntimeServices.swift:86–94`, `WhisperM8/Views/AgentChatsView.swift:727–737`
**Konfidenz:** hoch

**Szenario:** Zentrale Mutations-Primitive ohne Änderungs-Check:
```swift
// AgentWindowStore.swift:901–905
private func mutate(_ block: (inout AgentUIState) -> Void) {
    block(&state)
    dirtyRevision += 1
    scheduleSave()
}
```
Observation vergleicht keine Werte — jedes Schreiben von `state` (auch wertgleich) invalidiert
alle Views, die `state` lesen (= alle Fenster, Tab-Strips, Sidebar-Brücken), und
`dirtyRevision += 1` plant einen JSON-Encode+Write von `agent-ui-state.json` (400 ms Debounce).

Solche No-op-Mutationen passieren systematisch: `reconcileSelection()` läuft bei **jedem**
Workspace-Change (`AgentChatsView.swift:736`) und ruft dabei unconditional
```swift
// AgentChatsView+RuntimeServices.swift:92–94
if let selectedProjectID {
    expandedProjectIDs.insert(selectedProjectID)
}
```
— die Bridge (`AgentChatsView.swift:92–95`) feuert den Setter auch, wenn das Projekt schon
expandiert ist, und `setExpandedProjectIDs` (`AgentWindowStore.swift:780–782`) schreibt
ungeprüft. Gleiches Muster: `selectedProjectID = session.projectID` in
`onChange(of: selectedSessionID)` (`AgentChatsView.swift:713–716`) bei unverändertem Wert →
`updateWindow` → `upsertWindow` inkl. `normalizedWindows`-Pass. Ergebnis: jeder
Workspace-Change zieht zusätzlich eine UI-State-„Änderung" samt Save-Zyklus und einer zweiten
Re-Render-Welle über alle Fenster nach sich — obwohl sich am UI-State nichts geändert hat.
(Kontrast: `prune(workspace:)` ist korrekt gated, `AgentWindowStore.swift:854–861:
guard pruned != state else { return }`.)

**Fix-Vorschlag:** In `mutate` den Vorher/Nachher-Vergleich einbauen
(`AgentUIState` ist Equatable — Muster `prune`): nur bei echter Änderung `state` zurückschreiben,
`dirtyRevision` erhöhen und `scheduleSave()` rufen. Alternativ mindestens die bekannten
Hot-Caller absichern (`setExpandedProjectIDs`, `setSelectedProject`, `setOpenTabIDs` mit
Gleichheits-Guard wie `expandProject`, Zeile 787–789).

---

## F5: Ein app-weiter `scrollWheel`-Monitor pro Terminal-Controller — O(K) Handler mit Hit-Tests pro Scroll-Event

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:218–224 (Monitor-Install), 243–265 (Handler), 304–319 (Hit-Test)`
**Konfidenz:** hoch (Mechanik), mittel (Kostenanteil ohne Profiling)

**Szenario:** Jeder `AgentTerminalController` installiert einen eigenen
`NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` (`TerminalScrollGuard`, Zeile 220).
Lokale Monitore sind app-weit: **jedes** Scroll-Event der App durchläuft alle K Monitore. Der
Handler prüft zwar zuerst `event.window === window` (billig), aber für alle Controller, deren
Terminal im selben Fenster hängt — im 3×3-Grid also bis zu 9 —, läuft pro Event ein voller
`window.contentView?.hitTest(...)` samt Superview-Walk (`isEventTargetingTerminal`,
Zeile 304–319). Trackpad-Scrollen liefert >100 Events/s → im Grid hunderte Hit-Tests pro
Sekunde auf dem Main Thread, zusätzlich zum eigentlichen Scroll-Handling; das konkurriert direkt
mit dem `grid.streamingFrame`-Budget (16,7 ms). Analog installiert
`TerminalKeyboardShortcutHandler` (Zeile 563) einen `keyDown`-Monitor pro Controller (dort ist
der Guard mit `firstResponder === terminal` billig — nur der Fan-out bleibt O(K)).

**Beweis:** `AgentTerminalView.swift:218–224`:
```swift
init(attachedTo terminalView: LocalProcessTerminalView) {
    self.terminalView = terminalView
    self.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
```
und Zeile 309–310 im Pro-Event-Pfad:
```swift
let pointInWindow = event.locationInWindow
guard let hitView = window.contentView?.hitTest(pointInWindow) else { return false }
```

**Fix-Vorschlag:** EINEN geteilten Scroll-Monitor (z. B. an der `AgentTerminalRegistry`), der pro
Event genau einen Hit-Test macht und dann den getroffenen Controller auflöst (Terminal-View →
Controller-Lookup); alternativ im Guard zuerst den billigen `isCurrentBufferAlternate`-Check bzw.
`firstResponder`-Check vorziehen, denn nur Alt-Buffer-Terminals brauchen das Verschlucken.

---

## F6: Recording-Start mit Codex-Chat-Kontext macht einen ungecachten rekursiven `~/.codex/sessions`-Walk — und `stopRecording` wartet darauf

**Schweregrad:** mittel
**Fundort:** `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:36–54, 90–93`; Kette: `WhisperM8/Services/AgentChats/AgentChatTailExtractor.swift:84` → `WhisperM8/Services/Dictation/RecordingCoordinator+Context.swift:26–35` → `WhisperM8/Services/Dictation/RecordingCoordinator.swift:282`
**Konfidenz:** hoch

**Szenario:** Beim Diktat-Start mit aktivem Codex-Chat holt der Kontext-Capture den Chat-Tail via
`CodexTranscriptReader.readTail(sessionID:)` → `transcriptURL(forSessionID:)`. Diese Methode
enumeriert **bei jedem Aufruf** rekursiv den kompletten `~/.codex/sessions`-Baum
(Jahres-/Monats-/Tagesordner, wächst unbegrenzt) — ausdrücklich ungecacht:
```swift
// CodexTranscriptReader.swift:34–35
/// … wir scannen kurz alle Files und finden den match.
/// Resultat wird nicht gecached weil das nur on-demand passiert.
```
Der Read läuft zwar off-main (`RecordingCoordinator+Context.swift:28: Task.detached`), aber
`stopRecording()` blockiert die Pipeline bis zu 1 s darauf
(`RecordingCoordinator.swift:282: await waitForContextCapture(timeout: 1.0)`): Bei kurzen
Diktaten verzögert ein langsamer Walk (kalter FS-Cache, tausende Rollout-Files) den Start der
Transkription um bis zur vollen Timeout-Sekunde — das `chatTail`-Budget liegt bei 100 ms.
Pikant: ein fertiger, NSCache-gestützter Locator für exakt dieses Problem existiert bereits
(`AgentSessionTranscript.swift:422–459, locateCodex` inkl. `codexPathCache`), wird hier aber
nicht benutzt.

**Fix-Vorschlag:** `CodexTranscriptReader.transcriptURL` auf `AgentTranscriptLocator.locate(provider:.codex,…)`
umstellen (oder den `codexPathCache` teilen). Damit ist der Walk pro Session-ID einmalig.

---

## F7: `ISO8601DateFormatter` wird pro JSONL-Zeile neu allokiert — in allen vier Parsern

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:209–214` (Aufruf pro Zeile: 136), `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift:130–134`, `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:257–262` (Aufrufe: 147, 196), `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:234–238` (Aufruf: 114)
**Konfidenz:** hoch

**Szenario:** Alle Zeilen-Parser rufen `parseDate` pro geparster JSONL-Zeile, und `parseDate`
erzeugt pro Aufruf 1–2 frische `ISO8601DateFormatter` (Erzeugung ist bekannt teuer — interner
ICU-Setup):
```swift
// ClaudeTranscriptReader.swift:257–262
private static func parseDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}
```
Wirkung: Ein 512-KB-Tail-Load (Default der Transcript-View) enthält typischerweise tausende
Zeilen → tausende Formatter-Allokationen pro Chat-Öffnung; „Früheren Verlauf laden" bis 8 MB
multipliziert das. Beim Indexer-Scan (bis 200 Zeilen × Cache-Miss-Files, `ClaudeSessionIndexer.swift:107`)
und beim 1-MB-Summarizer-Tail (`AgentSessionSummarizer.swift:262–266`) dasselbe. Alles off-main,
aber es verlängert sichtbar die Ladezeiten (Spinner der Transcript-View) und kostet Energie.

**Fix-Vorschlag:** Zwei `static let`-Formatter (mit/ohne `withFractionalSeconds`) pro Reader —
`ISO8601DateFormatter` ist seit macOS 10.13/Swift-Foundation thread-safe; alternativ
`Date(string, strategy: .iso8601)`-Parsing einmalig konfiguriert.

---

## F8: Flache Sidebar-Liste ohne Cap: O(n²)-`order`-Arrays pro Row, ungegatete `PinnedSessionRow`, non-lazy VStack

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:1115 (VStack), 1173–1196 (flat-ForEach), 1186 + 1137 (order-Arrays), 1405–1430 (flatRow)`; `WhisperM8/Views/AgentChatsSidebarViews.swift:929–1053` (PinnedSessionRow ohne Equatable); `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:251–266` (kein Limit)
**Konfidenz:** hoch

**Szenario:** Im Layout „flach" rendert die Sidebar `flatSessions` komplett (kein
`visibleSessionLimit`-Pendant zur gruppierten Ansicht, das dort non-lazy explizit „bezahlbar"
hält — `AgentChatsSidebarViews.swift:193–196`). Pro Row wird dabei
`order: flatSessions.map(\.id)` materialisiert (Zeile 1186) → O(n²) Array-Kopien pro Body-Eval;
dazu pro Row ein linearer `workspace.projects.first { … }` (Zeile 1412). Die verwendete
`PinnedSessionRow` hat — anders als `SessionListButton` (`AgentChatsSidebarViews.swift:905–924`
+ `.equatable()` an den Aufrufstellen 283/315) — **keine** Equatable-Conformance und kein
`.equatable()`: jede der häufigen Body-Evals (F3/F4) durchläuft alle flachen Rows inkl.
onReceive-Resubscription. Der Container ist ein nicht-lazy `VStack` (Zeile 1115, bewusst wegen
des LazyVStack+draggable-Freezes), was ohne Cap bei vielen manuell erstellten Chats teuer wird.

**Fix-Vorschlag:** (a) `flatSessions.map(\.id)` EINMAL vor dem ForEach binden und
durchreichen; (b) `PinnedSessionRow` das `SessionListButton`-Equatable-Muster geben (Test-Pendant
zu `SessionListButtonEquatableTests`); (c) der flachen Liste dasselbe „N weitere anzeigen"-Limit
wie den Projektgruppen geben.

---

## F9: Erst-Load des Workspace (Multi-MB-JSON-Decode + Migration) läuft synchron auf dem Main Thread beim ersten Fensteraufbau

**Schweregrad:** niedrig
**Fundort:** `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:290–291, 246–252`; `WhisperM8/Services/AgentChats/AgentWindowStore.swift:61–66`
**Konfidenz:** hoch (Mechanik), mittel (Dauer)

**Szenario (Auslöser → Wirkung):** `AgentWorkspaceUIModel.shared` wird beim ersten
`AgentChatsView`-Init erzeugt (`AgentChatsView.swift:49: @State private var workspaceModel = AgentWorkspaceUIModel.shared`);
sein Init macht `self.workspace = store.read { $0 }` (`AgentWorkspaceStore.swift:291`), was beim
allerersten Zugriff `loadInitial()` unter dem Lock ausführt (`loadedLocked()`, Zeile 246–252):
Datei-Read + JSON-Decode der kompletten `AgentSessions.json` + Migrations-Normalisierung —
synchron auf dem Main Thread, im Fenster-Aufbau. Der eigene Kommentar beziffert das Encode-
Pendant derselben Datei auf „3-MB-Encode, 50–200 ms" (`AgentWorkspaceStore.swift:178–181`);
Decode liegt in derselben Größenordnung, das `store.load`-Budget beträgt 15 ms. Gleiches Muster:
`AgentWindowStore.init` lädt `agent-ui-state.json` synchron (`AgentWindowStore.swift:63`).
Wirkung: einmaliger Launch-/Fenster-Öffnen-Hänger, der mit der Workspace-Größe wächst.

**Fix-Vorschlag:** Initial-Load beim App-Start off-main vorwärmen (analog zum
LoginShell-Prewarm in `WhisperM8App.swift:275–279` — ein `Task.detached { _ = AgentSessionStore().loadWorkspace() }`
VOR dem ersten Fensteraufbau würde `canonical` bereits füllen; der Retention-Task in
`WhisperM8App.swift:257–261` tut das faktisch schon, läuft aber mit `.background`-Priorität und
ohne garantierte Reihenfolge zum Fensteraufbau — Race, wer zuerst kommt), alternativ das
UIModel mit leerem Workspace starten und den Load asynchron nachreichen.

---

## Zusammenfassung

| Schweregrad | Anzahl | Findings |
|---|---|---|
| kritisch | 0 | — |
| hoch | 2 | F1 (Scan-Merge O(m·n) auf Main), F2 (git-Spawns im Inspector) |
| mittel | 4 | F3 (Body-Eval O(Workspace) × Fenster), F4 (WindowStore ohne Diff-Gate), F5 (Scroll-Monitor pro Terminal), F6 (Codex-Walk im Diktat-Pfad) |
| niedrig | 3 | F7 (Formatter pro Zeile), F8 (flache Liste O(n²)/ungegated), F9 (Erst-Load auf Main) |

Die Findings F3+F4 verstärken sich gegenseitig: F4 erzeugt die überflüssigen Invalidierungen,
F3 macht jede davon teuer — zusammen sind sie die wahrscheinlichste Ursache für diffuse
Träge der Agent-Chats-UI bei großen Workspaces.
