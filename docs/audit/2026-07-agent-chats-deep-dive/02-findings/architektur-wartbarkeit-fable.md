# Architektur- & Wartbarkeits-Audit (Finder: Fable)

**Datum:** 2026-07-18 · **Methode:** reine Code-Analyse (kein Build/Test) ·
**Umfang:** Gesamtprojekt — App 58 435 LOC / 275 Swift-Dateien, Tests 23 019 LOC,
EIN SwiftPM-Executable-Target (`Package.swift:27-55`).

> Hinweis: Die Subsystem-Karten unter `01-subsysteme/` waren zum Audit-Zeitpunkt
> **leer** (Verzeichnis existiert, keine Dateien) — alle Befunde sind direkt aus
> Code, Git-Historie und `docs/refactor/REFACTORING-AUDIT.md` abgeleitet.

---

## F1: AgentChatsView wächst nach dem Phase-2-Split ungebremst zurück; ViewModel-Extraktion steckt bei 5 Forwarding-Methoden

**Schweregrad:** hoch ·
**Fundort:** `WhisperM8/Views/AgentChatsView.swift` (3070 LOC), `WhisperM8/Views/AgentChatsViewModel.swift` (54 LOC)

**Szenario (Auslöser → Wirkung):** Neue Features (Grid, Subagents, Workspaces,
Sidebar-Resize, Tab-Strip-Messung) landen weiter in der Hauptdatei bzw. neuen
`extension`-Dateien derselben View → der 2026-06 mühsam erreichte Stand
(3684 → 2426 LOC) ist ohne Guardrail wieder verspielt; die View bleibt
untestbar, jede Änderung invalidiert einen ~360-Zeilen-Body.

**Beweis:**
- Historischer Stand vs. heute: `git show <rev-list --before=2026-06-29>:WhisperM8/Views/AgentChatsView.swift | wc -l` → **2430**; heute **3070** (+640 LOC netto, **62 Commits** auf die Datei seit 2026-06-28). Netto-Wachstum seit Audit-Datum per `git log --numstat`: `+640 AgentChatsView.swift`, dazu neue View-Extensions `+934 AgentChatsView+Grid.swift`, `+426 AgentChatsView+Workspaces.swift`.
- Die Hauptdatei hält **66** `@State`/`@AppStorage`/`@SceneStorage`-Properties (grep-Zählung), `var body` von Zeile 439–800, `hashboardSidebar` 1016–1271.
- Die in `docs/refactor/REFACTORING-AUDIT.md:134` als Phase-3-Ziel benannte „`AgentChatsViewModel`-Extraktion" existiert nur als Stub — `AgentChatsViewModel.swift:12-17`:
  ```swift
  @MainActor
  final class AgentChatsViewModel {
      private let store: AgentSessionStore
  ```
  mit exakt 5 Forwarding-Methoden (`renameSession`, `setSessionGroup`, `setSessionColor`, `renameProject`, `setProjectColor`) — gegen ~39 `func`-Definitionen allein in der Hauptdatei plus die Logik in 16 Extension-Dateien.

**Fix-Vorschlag:** (1) LOC-Budget als CI-/Review-Guardrail für `AgentChatsView.swift` (z. B. Fail > 2500 LOC, analog `PerfBudgets`-Philosophie). (2) ViewModel-Extraktion nach dem bestehenden S7-A-Muster fortsetzen — als Nächstes die reinen Store-Orchestrierungen aus `+SessionLifecycle`/`+ProjectManagement`; danach F3-Kandidaten. (3) Neue Feature-Flächen (Grid war der letzte Fall) von Anfang an mit eigenem Model-Typ statt als weitere `AgentChatsView`-Extension planen.

**Konfidenz:** hoch (Zahlen reproduzierbar aus Git/`wc`).

---

## F2: Schichtenverletzung — Terminal-Prozess-Lifecycle (`AgentTerminalRegistry`/`AgentTerminalController`) lebt in `Views/` und wird von 4 Services referenziert

**Schweregrad:** hoch ·
**Fundort:** `WhisperM8/Views/AgentTerminalView.swift:323` (Registry), `:614` (Controller); Referenzen aus `Services/`

**Szenario (Auslöser → Wirkung):** Die Datei `AgentTerminalView.swift` (1155 LOC)
bündelt **9 Typen** — darunter die app-weite Prozess-Registry und den
PTY-Controller (Spawn/Terminate/Snapshot), also klaren Service-Code. Die
Service-Schicht greift **aufwärts** in `Views/`:

```
WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:57:
    AgentTerminalRegistry.shared.controller(for: sessionID)?.updateExternalSessionID(externalID)
WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:50:
    AgentTerminalRegistry.shared.activeSessionIDs
WhisperM8/Services/AgentChats/AgentPromptRoutingService.swift:36:
    self.controllerResolver = controllerResolver ?? { AgentTerminalRegistry.shared.controller(for: $0) }
WhisperM8/Services/AgentChats/AgentPromptRoutingService.swift:111:
    extension AgentTerminalController: PromptRoutableTerminal {}
WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:120:
    for controller in AgentTerminalRegistry.shared.runningControllers {
```

Im Ein-Target-Build kompiliert das, aber: (a) die dokumentierte Ordner-Architektur
(„Services/ → drei Subfolder", CLAUDE.md) ist damit faktisch zyklisch
(Views ⇄ Services), (b) jede spätere Target-Trennung (siehe Abschnitt
„Modularisierung") ist blockiert, (c) Prozess-Lifecycle-Tests hängen an einer
Datei voller AppKit-/SwiftTerm-View-Code.

**Beweis:** Typliste der Datei (`grep`): `QuietableTerminalView` (21), `TerminalScrollGuard` (209), `AgentTerminalRegistry` (323, `static let shared` bei 327), `TerminalKeyboardProfile` (416), `TerminalShortcut` (437), `TerminalKeyboardShortcutHandler` (544), `AgentTerminalController` (614, inkl. `func start()` 749 / `func terminate()` 775 / Snapshot-Capture 808), `AgentTerminalView: NSViewRepresentable` (984), `AgentTerminalContainerView` (1019).

**Fix-Vorschlag:** `AgentTerminalRegistry`, `AgentTerminalController`, `TerminalKeyboardProfile/Shortcut` nach `Services/AgentChats/` verschieben (SwiftPM-Ordnerumzüge sind laut REFACTORING-AUDIT-Erkenntnis #2 build-neutral); in `Views/` verbleiben `AgentTerminalView`, Container, ScrollGuard, LinkInterceptor. Die Services referenzieren die Registry ohnehin schon über Closures-Seams (`controllerResolver`, `terminalExternalIDUpdater`) — der Move ändert keine Aufrufer-Semantik.

**Konfidenz:** hoch.

---

## F3: Geschäftslogik mit Fehler-Policy lebt in View-Extensions statt in testbaren Typen (Background-Dispatch, Index-Pipeline)

**Schweregrad:** hoch ·
**Fundort:** `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:43-130`, `WhisperM8/Views/AgentChatsView+RuntimeServices.swift:107-156`

**Szenario (Auslöser → Wirkung):** `dispatchBackgroundAgent` ist ein
vollständiger Use-Case (Stub-Session anlegen → Hook-Settings vorbereiten →
Spawn → Short-ID persistieren → Attach; im Fehlerfall differenzierte
Rollback-Policy). Diese Policy ist Review-relevant — der Code zitiert selbst
„Review-Befund 2026-07-13":

```swift
// AgentChatsView+BackgroundAgents.swift:104-113
let spawnDefinitelyFailed: Bool
switch error as? BackgroundAgentSpawner.SpawnError {
case .timedOut?, .shortIDNotFound?:
    spawnDefinitelyFailed = false
...
if spawnDefinitelyFailed {
    try? store.deleteSession(id: session.id)
```

— aber als View-Extension-Methode mit `@State`-Zugriffen (`spawningBackgroundSessions`, `openTabIDs`, `errorMessage`) ist sie unit-untestbar; Regressionen in genau dieser Policy fallen erst in manueller QA auf. Gleiches Muster in `refreshSessionsInBackground` (`+RuntimeServices.swift:107`): die komplette Index-Pipeline (Task-Cancel, `Task.detached` mit `CodexSessionIndexer`/`ClaudeSessionIndexer`/`AgentSessionIndexCacheStore`, Merge, Auto-Naming-Trigger) wird von der View orchestriert.

**Beweis:** s. Zitate; `AgentChatsView+RuntimeServices.swift:129-135` instanziiert Indexer + Cache-Store direkt im View-Task:
```swift
let cacheStore = AgentSessionIndexCacheStore()
var cache = cacheStore.load()
let codex = CodexSessionIndexer().indexedSessionResult(cache: &cache)
let claude = ClaudeSessionIndexer().indexedSessionResult(cache: &cache)
```

**Fix-Vorschlag:** Beide Abläufe in Service-Typen mit Closure-DI heben (Projekt-Konvention): `BackgroundAgentDispatchService` (Input: Projekt+Request, Output: Events/Result — die View mappt nur noch auf `@State`) und ein `AgentIndexRefreshService` (besitzt Task-Lifecycle + Cache; `AgentScanCoordinator` wäre der natürliche Ort, er triggert heute schon Scans). Fehler-Policies (`spawnDefinitelyFailed`, Dedup) als pure Funktionen testen.

**Konfidenz:** hoch.

---

## F4: Singleton-Mesh gewachsen statt abgebaut — 29 `static let shared` (Audit 2026-06: „16"), dazu mutable `AppPreferences.shared` als versteckte Abhängigkeit bis in Store-Signaturen

**Schweregrad:** mittel ·
**Fundort:** projektweit; exemplarisch `WhisperM8/Support/AppPreferences.swift:4`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:521-522, 733-734, 913-914`

**Szenario (Auslöser → Wirkung):** Jeder neue Runtime-Baustein wird als
Singleton angelegt (`AgentJobRuntimeModel.shared`, `AgentJobWorkspaceSync.shared`,
`TerminalSnapshotStore.shared`, `AgentSessionStatusCoordinator.shared`,
`CodexGlobalConfigReader.shared`, …). Views bridgen Singletons in `@State`
(`AgentChatsView.swift:68 @State var windowStore = AgentWindowStore.shared`,
`:130 jobRuntimeModel = AgentJobRuntimeModel.shared`), Services greifen sie in
Default-Argumenten und Methodenrümpfen. Wirkung: Tests brauchen
Ersatz-Verdrahtung pro Singleton, Init-Reihenfolge/Ownership sind implizit, und
das Phase-4-Ziel des eigenen Refactoring-Audits („Singleton-Injektion an den
Wurzeln", `REFACTORING-AUDIT.md:146,570-571`) entfernt sich.

**Beweis:**
- `grep -rn "static let shared|static var shared" WhisperM8` → **29** Deklarationen; ~**299** App-eigene `.shared`-Referenzen (nach Abzug von `NSWorkspace/FileManager/URLSession` etc.).
- `AppPreferences.swift:4`: `static var shared = AppPreferences()` — global **mutierbar**, 66 Referenzen allein aus `Services/`+`Models/`.
- Store-API mit Singleton-Default-Argumenten, `AgentSessionStore.swift:913-914`:
  ```swift
  codexConfigDefaults: CodexGlobalConfigDefaults = CodexGlobalConfigReader.shared.defaults(),
  fallbackModelRaw: String = AppPreferences.shared.resolvedCodexDefaultModelRaw()
  ```
  und im Rumpf `:733-734` (`mergeIndexedSessions` liest `AppPreferences.shared` direkt, hier ohne injizierbaren Seam).

**Fix-Vorschlag:** Keine Voll-Sanierung nötig — aber (1) Neuzugänge-Stopp: neue Services bekommen Init-Injektion, `\.shared` nur an der Composition-Root (`WhisperM8App`); (2) die zwei schlimmsten Leser (`AppPreferences.shared` in `AgentSessionStore.mergeIndexedSessions`, `AgentStatusPreferences.current()`) auf die bereits existierenden Provider-Closure-Muster umstellen (Vorbild: `AgentStatusPreferences` als Seam, `AgentSessionStatusCoordinator.swift:3-22`); (3) `AppPreferences` auf `static let` + injizierte Overrides, statt globalem `var`.

**Konfidenz:** hoch (Zählungen), Bewertung mittel (bewusste Trade-offs sind teils dokumentiert, z. B. Koordinator-Singleton-Kommentar `AgentSessionStatusCoordinator.swift:32-35`).

---

## F5: `AgentSessionStore` ist keine Facade mehr — Merge-/Repair-Domänenlogik (~500 LOC) akkumuliert im Store; der 2026-06 als Quick-Win beschlossene UI-State-Split ist weiter offen

**Schweregrad:** mittel ·
**Fundort:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift` (1264 LOC; +425 netto seit 2026-06-28)

**Szenario (Auslöser → Wirkung):** Die als „duenne Facade über AgentWorkspaceStore"
konzipierte Datei (der Kern `AgentWorkspaceStore.swift` hat nur 337 LOC) trägt
inzwischen die komplette Abgleich-Domäne: `mergeIndexedSessions` (Z. 716–908,
~190 LOC eine Methode: Worktree-Filter, Root-Dedup-Policy `chosenByKey`
Z. 756 ff., Projekt-Autoanlage, Branch-Enrichment), `mergeSubagentJobs`
(Z. 909–1043: Job-Adoption, Parent-Auflösung, Config-Fallbacks),
`bindLatestIndexedSession` (598), `repairResumeStateBeforeLaunch` (651). Jede
Policy-Änderung mutiert eine 1264-LOC-Datei, deren Kommentar-Regeln („Mutation
closures must never run subprocesses") jeder neue Merge-Autor kennen muss.
Zusätzlich liegt das UI-State-Sidecar-I/O immer noch hier (Z. 29–127,
`loadUIState`/`saveUIState`/`defaultUIStateFileURL`) — als **Quick-Win
„Aufwand low" seit 2026-06-27 in `REFACTORING-AUDIT.md:159-160` beschlossen
und nie umgesetzt** (auch bei `:123` als „noch offen" gelistet).

**Beweis:** Methodenliste per grep (Zeilennummern oben); `AgentSessionStore.swift:45`:
```swift
func loadUIState() -> AgentUIState {
```
mit direktem `FileManager`/`JSONDecoder`-I/O bis Z. 127 — die einzige Disk-I/O-Stelle der Datei, exakt wie im Audit-Doc beschrieben.

**Fix-Vorschlag:** (1) `AgentUIStateStore` endlich extrahieren (Plan liegt fertig in `REFACTORING-AUDIT.md:160`, inkl. Init-Signatur). (2) Merge-Policies als pure Planner kapseln: `WorkspaceMergePlan.make(indexed:current:branches:) -> [Mutation]`, Store wendet nur noch an — dieselbe Technik, die bei `TabSelectionResolver`/`TabGroupReorder` bereits erfolgreich ist; die bestehenden `AgentSessionStoreTests` (1120 LOC) tragen die Umstellung.

**Konfidenz:** hoch.

---

## F6: Claude-/Codex-Duplikation im Indexer: identischer ~50-LOC-Scan-Loop, dreifach dupliziertes Datums-Parsing

**Schweregrad:** mittel ·
**Fundort:** `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:69-113` vs. `CodexSessionIndexer.swift:35-79`

**Szenario (Auslöser → Wirkung):** Beide Indexer wiederholen denselben Ablauf
Zeile für Zeile — Enumerator mit identischen Resource-Keys, `jsonl`-Filter,
Metadata-Guard, Cache-`lookup` mit identischem hit/miss/skip-Stats-Handling,
`parseSession`-Fallunterscheidung, `sorted/prefix(limit)`. Ein Fix in einem
Loop (z. B. das Subagents-Skip `ClaudeSessionIndexer.swift:70` oder eine
Cache-Semantik-Änderung) muss manuell in den zweiten übertragen werden —
klassische Drift-Quelle für genau die Sorte Bugs, die der „Duplikat-Schutz
(Review-Befund 2026-07-13)" in `AgentSessionStore.swift:750` schon einmal
nachträglich flicken musste.

**Beweis:** Beispiel des identischen Blocks (beide Dateien wortgleich bis auf `.claude`/`.codex`):
```swift
switch cache.lookup(provider: .codex, fileURL: fileURL, metadata: metadata) {
case let .hit(cached):
    stats.cacheHits += 1
    if let cached { sessions.append(cached) } else { stats.skippedFiles += 1 }
    continue
case .miss: break
}
```
(`CodexSessionIndexer.swift:51-62` ≙ `ClaudeSessionIndexer.swift:79-90`). Dazu `parseDate` dreifach: `CodexSessionIndexer.swift:130-136`, `ClaudeTranscriptReader.swift:257`, `CodexTranscriptReader.swift:234` — jeweils inkl. Neu-Instanziierung von `ISO8601DateFormatter` **pro Aufruf** (Formatter-Erzeugung ist teuer; im Indexer läuft das pro geparster Datei).

**Fix-Vorschlag:** Generischer `JSONLSessionScanner` (Verzeichnisse + `parse: (URL, FileMetadata, inout Stats) -> IndexedAgentSession?` injiziert); beide Indexer schrumpfen auf ihre `parseSession`-Funktion. `ISO8601`-Parsing als `enum AgentDateParsing` mit `static let`-Formattern nach `Services/Shared/`. Zum Vergleich: die Transcript-Reader machen es bereits richtig (gemeinsamer `TranscriptTailReader`/`BoundedJSONLReader`, nur Format-Parsing getrennt).

**Konfidenz:** hoch.

---

## F7: `docs/refactor/REFACTORING-AUDIT.md` ist drei Wochen und ~28 000 LOC hinter dem Ist-Stand — halbe Codebase unbewertet, Status-Angaben teils falsch

**Schweregrad:** mittel ·
**Fundort:** `docs/refactor/REFACTORING-AUDIT.md` (updated: 2026-06-27)

**Szenario (Auslöser → Wirkung):** CLAUDE.md verweist auf das Dokument als
„Full roadmap + status" — wer danach priorisiert, arbeitet mit falschen Zahlen
und übersieht die größten heutigen Hotspots komplett.

**Beweis (Abgleich Ist ↔ Doc):**
- **Kennzahlen:** Doc `:20` „~30.736 LOC in 115 Swift-Dateien" — Ist: **58 435 LOC / 275 Dateien** (App ohne Tests), **201 Commits** seit 2026-06-28.
- **Ganz fehlende Subsysteme** (alle nach dem Audit entstanden, kein einziger Treffer für `grep -i "grid\|AgentJob\|AgentWindowStore\|AgentCLICommand"` im Doc): Grid-Workspace (`AgentChatsView+Grid.swift` 934 LOC, `AgentGridWorkspace`, `WorkspaceSlotOps`, `GridSplitResolver` …), Subagent-Jobs (10 `AgentJob*`-Dateien inkl. `AgentJobSupervisor`, `AgentJobWorkspaceSync`), CLI-Hälfte (`CLI/AgentCLICommand.swift` 778 LOC, `AgentSuperviseCommand`), `AgentWindowStore` (955 LOC, zentrale SSoT!), `ClaudeAccountProfiles` (508), `TerminalSnapshotStore`, `CodexExecRunner` (576).
- **Erledigt, aber nicht nachgetragen:** „AgentGitBranchReader" steht unter „Nach Phase 2 verschoben" (`:83`) — existiert längst als `Services/AgentChats/GitBranchReader.swift` (Datei-Read statt Spawn, `AgentSessionStore.swift:1084-1089`). C4-Kontextmenü-Dedup (`:81`) ist als `AgentChatsView+SessionMenus.swift` (`sessionContextMenu`, Z. 27) umgesetzt.
- **Offen, aber ohne Fortschritts-Vermerk:** AgentUIStateStore (s. F5), `AgentTerminalView`-Split (`:123` „noch offen" — Datei heute 1155 LOC, s. F2), `AgentChatsViewModel` (`:134` — 54-LOC-Stub, s. F1). Die Singleton-Zählung „16 globale Singletons" (`:570`) ist auf 29 gewachsen (s. F4).

**Fix-Vorschlag:** Kein Neuschreiben des 602-Zeilen-Dokuments — ein „Stand 2026-07"-Abschnitt: Kennzahlen aktualisieren, erledigte Items abhaken (GitBranchReader, C4), die 5 neuen Subsysteme mit je 1-Zeilen-Bewertung aufnehmen, und die Roadmap-Phase-2/3-Restliste gegen F1/F2/F5 dieses Audits konsolidieren.

**Konfidenz:** hoch (alle Deltas per grep/git verifiziert).

---

## F8: PhpStorm-Launch doppelt implementiert — `AgentChatsView.openInPhpStorm` repliziert den bestehenden `PhpStormLauncher`

**Schweregrad:** niedrig ·
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:2760-2790` vs. `WhisperM8/Services/Shared/PhpStormLauncher.swift:8-49`

**Szenario (Auslöser → Wirkung):** Beide Stellen enthalten dieselbe
zweistufige Logik (gebündeltes CLI-Binary `Contents/MacOS/phpstorm` starten,
sonst `NSWorkspace.open(withApplicationAt:)`) samt identischem Begründungs-Kommentar.
Der Terminal-Link-Pfad nutzt bereits den Shared-Typ
(`AgentTerminalView.swift:937: if !PhpStormLauncher.open(path: url.path)`),
der Projekt-öffnen-Pfad nicht — Verhaltens-Drift ist schon da: die
View-Variante meldet Fehler via `errorMessage`-Alert, der Launcher gibt nur
`Bool` zurück und schluckt den `NSWorkspace`-Fehler.

**Beweis:** `AgentChatsView.swift:2765-2771`:
```swift
if FileManager.default.isExecutableFile(atPath: binaryURL.path) {
    let process = Process()
    process.executableURL = binaryURL
    process.arguments = [path]
```
≙ `PhpStormLauncher.swift:33-37` (wortgleich). Das ist zugleich der **einzige `Process()`-Spawn in `Views/`** außerhalb des Terminal-Codes.

**Fix-Vorschlag:** `openInPhpStorm` auf `PhpStormLauncher.open(path:)` umstellen; wenn die Fehlermeldung erhalten bleiben soll, dem Launcher eine `Result`-/Throws-Variante geben.

**Konfidenz:** hoch.

---

## F9: `AgentChatSession` als flaches Struct mit kind-diskriminierten Optional-Clustern — Invarianten nur per Konvention

**Schweregrad:** niedrig ·
**Fundort:** `WhisperM8/Models/AgentChat.swift:225` ff.

**Szenario (Auslöser → Wirkung):** Die Session trägt 31 Stored-Properties,
davon mehrere nur für je einen `kind` gültige Cluster: `backgroundShortID`/
`backgroundSubAgent`/`backgroundPermissionMode` (nur `.backgroundChat`),
`subagentJobShortID`/`subagentParentSessionID`/`subagentCwd` (nur
`.subagentJob`), `claudeProfileName` (nur Provider `.claude`). Nichts hindert
Code daran, z. B. einer `.chat`-Session eine `subagentJobShortID` zu geben —
die Merge-Logik in F5 muss solche Kombinationen defensiv behandeln
(`isSubagentJob`-Filter, Orphan-Cleanups `removeOrphanBackgroundSessions`
`AgentSessionStore.swift:1144`).

**Beweis:** Property-Block `AgentChat.swift:226-256` (Auszug):
```swift
var kind: AgentSessionKind?
var backgroundShortID: String?
var backgroundSubAgent: String?
...
var subagentJobShortID: String?
var subagentParentSessionID: String?
```
plus abgeleitete Guards `isBackgroundChat`/`isSubagentJob` etc.

**Fix-Vorschlag:** Kein Sum-Type-Umbau (Codable-Migrationen wären teuer) — aber die Cluster in eingebettete optionale Structs heben (`var background: BackgroundInfo?`, `var subagentJob: SubagentJobInfo?`, Codable-kompatibel via Custom-Keys oder Migrationsschritt im vorhandenen `migratedWorkspace`, `AgentSessionStore.swift:1170`). Kurzfristig genügt ein Validierungs-Assert im `upsertSession`-Pfad.

**Konfidenz:** mittel (Problem real, Nutzen/Kosten des Fixes abwägbar).

---

## Bewertung: Modularisierung in mehrere SwiftPM-Targets

**Lohnt sie? Ja — aber erst nach F2, und in genau zwei Schritten, nicht als Big-Bang.**

**Ausgangslage:** Ein Executable-Target (`Package.swift:27`) mit 275 Dateien;
ein Test-Target, das das Executable importiert. Konsequenzen heute: (a) jeder
`swift test`-Lauf kompiliert die komplette App inkl. aller Views neu, wenn sich
irgendeine Datei ändert — bei 58k LOC + SwiftUI-Macros der teuerste Posten im
Feedback-Loop; (b) es gibt **keine compilergeprüften Schichtgrenzen**, weshalb
F2 (Services→Views) unbemerkt entstehen konnte; (c) `internal` ist praktisch
bedeutungslos (ein Modul = alles sichtbar), was die Split-Technik
„private→internal heben" (REFACTORING-AUDIT-Erkenntnis #1) zwar leicht macht,
aber jede Kapselung aufgibt.

**Harte Randbedingung:** Der CLI-Symlink-Trick verlangt **ein** signiertes
Binary (`CLIEntryPoint.swift:9-12`: „Der CLI-Symlink zeigt auf dasselbe,
identisch signierte App-Binary — dadurch liest die CLI denselben
Keychain-Eintrag … ohne erneuten macOS-Prompt"). Das schließt mehrere
*Executables* aus, aber nicht mehrere *Library-Targets* — das eine Executable
linkt sie alle statisch, Bundle/Signing/Makefile bleiben unverändert.

**Empfohlener Schnitt (inkrementell, jeder Schritt einzeln shipbar):**

1. **`WhisperM8Foundation`** (risikoarm, sofort): `Services/Shared/` minus AppKit-lastige Teile + `Logger`, `LoginShellEnvironment`, `FileEventSource`, `PerformanceSignposts`, `SemanticVersion`, `BoundedJSONLReader`. Keine Abhängigkeit auf App-Code — per grep hängt dieser Code heute schon an nichts Höherem.
2. **`AgentChatsKit`** (der eigentliche Gewinn): `Services/AgentChats/` + `Models/AgentChat*`/`AgentUIState`/`AgentGridWorkspace` + die bereits puren View-Logik-Typen (`TabSelectionResolver`, `TabReorderGeometry`, `GridSplitResolver`, `TerminalLinkResolver`, `SidebarWidthResolver` — alle View-frei und getestet). **Voraussetzung: F2** (Terminal-Registry/Controller raus aus `Views/`) und Entkopplung von `AppPreferences` (F4-Seams). Danach erzwingt der Compiler die Schichtung, und die ~60 % der Tests, die Agent-Chats-Logik testen, kompilieren ohne SwiftUI-App.
3. **Optional später:** `DictationKit` (RecordingCoordinator-Cluster; koppelt an `AppState`/Overlay — erst nach der im Audit-Doc Phase 4 genannten Protokoll-Entkopplung sinnvoll) und `WhisperM8CLI` als Library (CLIRuntime, AgentCLICommand), die das Executable weiter multiplext.

**Nicht empfohlen:** Views in ein eigenes Target zu ziehen (SwiftUI-Previews,
`internal`-Extension-Splits der God-Views und `@testable`-Bedarf machen das
teuer bei geringem Nutzen) oder ein Schnitt entlang „Claude vs. Codex" (die
Provider teilen Modell und Stores, s. F6 — Trennlinie ist die Schicht, nicht
der Provider).

**Konfidenz:** mittel-hoch (Schnitt-Analyse aus Import-/Referenz-Struktur; Build-Zeit-Gewinn nicht gemessen, da Builds im Audit untersagt).

---

## Zusammenfassung

| Schweregrad | Anzahl | Findings |
|---|---|---|
| kritisch | 0 | — |
| hoch | 3 | F1, F2, F3 |
| mittel | 4 | F4, F5, F6, F7 |
| niedrig | 2 | F8, F9 |

Reihenfolge-Empfehlung: F2 (Move, build-neutral) → F5-UI-State + F3-Extraktionen → F7 (Doc-Sync) → Modularisierungs-Schritt 1–2; F1-Guardrail parallel ab sofort.
