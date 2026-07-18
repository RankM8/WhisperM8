---
status: aktiv
updated: 2026-07-18
description: Vergleich der Architektur-Muster großer Open-Source-macOS-Apps (CodeEdit, Ice, NetNewsWire, AeroSpace, Maccy) mit WhisperM8 — State-Management, Modularisierung, Persistenz, Testbarkeit.
---

# Architektur-Vergleich: Große Open-Source-macOS-Apps vs. WhisperM8

Teil des Agent-Chats-Deep-Dive-Audits (03-vergleich). Alle Angaben wurden am 2026-07-18 direkt aus den GitHub-Repos verifiziert (GitHub-API + Raw-Dateien); keine Projektbehauptung ist aus dem Gedächtnis übernommen.

## 1. Projektübersicht

| Projekt | Link | Sprache/Stack | Größe/Aktivität (Stand 2026-07-18) |
|---|---|---|---|
| **CodeEdit** | [github.com/CodeEditApp/CodeEdit](https://github.com/CodeEditApp/CodeEdit) | Swift, SwiftUI + AppKit-Inseln, `.xcodeproj` | 22 953★, letzter Push 2026-04-12 — aktiv, aber verlangsamt |
| **Ice** | [github.com/jordanbaird/Ice](https://github.com/jordanbaird/Ice) | Swift, SwiftUI + Combine (`ObservableObject`), `.xcodeproj`, macOS 14+ | 28 934★, letzter Push **2025-09-20** — seit ~10 Monaten ruhend (teilweise tot markieren) |
| **NetNewsWire** | [github.com/Ranchero-Software/NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | Swift (Swift 6.2 tools), **AppKit/UIKit** (bewusst kein SwiftUI im Kern), `.xcodeproj` + 17 lokale SwiftPM-Packages | 10 216★, letzter Push 2026-07-09 — sehr aktiv, seit 2002 gepflegt |
| **AeroSpace** | [github.com/nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace) | Swift, **pure SwiftPM** (Xcode-Projekt nur generierter App-Bundle-Launcher), kaum UI | 21 863★, letzter Push 2026-07-16 — sehr aktiv |
| **Maccy** | [github.com/p0deje/Maccy](https://github.com/p0deje/Maccy) | Swift, SwiftUI (seit 2.0), `.xcodeproj`, Unit- + UI-Tests | 20 765★, letzter Push 2026-07-15 — sehr aktiv |
| **Loop** | [github.com/MrKai77/Loop](https://github.com/MrKai77/Loop) | Swift, SwiftUI (Window-Manager) | 11 202★, letzter Push 2026-07-15 — aktiv (nicht tief analysiert) |
| *(Referenz)* **WhisperM8** | dieses Repo | Swift 5.9, SwiftUI, macOS 14+, **pure SwiftPM, EIN Target** | ~58k LOC eigene Sources, 1 300+ Tests |

Einordnung der Kandidaten: CodeEdit ist der größte SwiftUI-Vergleichsfall (IDE, viele Subsysteme). NetNewsWire ist der Goldstandard für Modularisierung und Persistenz-Disziplin, nutzt aber kein SwiftUI-State-Management. AeroSpace ist der einzige Kandidat mit demselben Build-Setup wie WhisperM8 (pure SwiftPM ohne echtes Xcode-Projekt) und deshalb für die Target-Frage am relevantesten. Ice ist architektonisch interessant (Manager-Konstellation), aber als Projekt faktisch eingeschlafen und **ohne einen einzigen Test** — eher Negativbeispiel.

## 2. Wie lösen die Projekte die Kernprobleme?

### 2.1 Store-/State-Management

**Ice — ein `AppState`-Gott als Manager-Konstellation.** `Ice/Main/AppState.swift` ist ein `@MainActor final class AppState: ObservableObject`, das ~10 `lazy` Manager hält (`MenuBarItemManager`, `SettingsManager`, `PermissionsManager`, …), die alle eine `weak`-Rückreferenz auf `appState` bekommen (`MenuBarAppearanceManager(appState: self)`). System-Events werden über Combine-Pipelines (`Publishers.Merge3(...).sink`) in `@Published`-Properties übersetzt. Konsequenz: jede Ansicht, die `AppState` beobachtet, hängt am gesamten Objektgraph; die zyklische Kopplung Manager↔AppState macht isoliertes Testen praktisch unmöglich — und es gibt tatsächlich kein Testtarget im Repo.

**CodeEdit — Singleton-`ObservableObject`s pro Subsystem + Mini-DI.** `Settings` ist ein Singleton-`ObservableObject` mit einem `@Published var preferences: SettingsData` (ein großes Codable-Struct); Zugriff über ein statisches KeyPath-Subscript `Settings[\.textEditing]`. Granularität ist damit grob: Jede Settings-Änderung invalidiert alle Settings-Beobachter. Daneben existiert ein minimaler DI-Ansatz: `CodeEdit/World.swift` (`var currentWorld = World(shellClient: .live())`, nach dem Pointfree-„How to Control the World"-Muster) — im Code aber kaum ausgebaut (nur `ShellClient`). Der Workspace-Zustand hängt an `NSDocument`-basierten Dokumenten (`Features/Documents`, `CEWorkspace`), also AppKit-Lifecycle statt reinem SwiftUI-State.

**NetNewsWire — kein SwiftUI-State-Framework, sondern Model-Objekte + NotificationCenter/Delegates.** Die Technote [CodingGuidelines.md](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md) legt die Prinzipien fest: alle Klassen `final`, keine Subklassen, Protokolle + Delegates statt Vererbung, „Giant objects with thousands of lines of code are to be avoided. Prefer multiple small objects." Die Account-Schicht ist über `AccountDelegate`-Protokolle erweiterbar statt über Subklassen (Technote [Accounts.markdown](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Accounts.markdown)). UI-Invalidierung läuft über Notifications und `CoalescingQueue` (siehe 2.3), nicht über Observation-Frameworks.

**AeroSpace — globaler Tree-State, Command-Pipeline statt Reactive-State.** Der gesamte Fenster-Zustand ist ein Baum (`Sources/AppBundle/tree/`), mutiert ausschließlich durch Commands (`Sources/AppBundle/command/`), die sowohl vom Server als auch von der CLI durch dieselbe Parsing-Schicht (`Sources/Common/cmdArgs/`) laufen ([dev-docs/architecture.md](https://github.com/nikitabobko/AeroSpace/blob/main/dev-docs/architecture.md)). Da es kaum UI gibt, gibt es kein Observation-Problem — interessant ist hier das Muster „ein einziger Mutationspfad für GUI und CLI", das WhisperM8 mit dem gemeinsamen Executable (GUI/CLI-Multiplex über `CLIEntryPoint`) bereits ähnlich lebt.

### 2.2 Modularisierung via SwiftPM

Das ist der Punkt, an dem sich die Projekte am stärksten unterscheiden — und WhisperM8 am weitesten vom Feld abweicht (EIN Target, 58k LOC, Ordner als reine Namenskonvention, weil „SwiftPM discovers sources recursively").

**NetNewsWire — 17 lokale SwiftPM-Packages im Monorepo.** Unter `Modules/` liegen eigenständige Packages: `Account`, `Articles`, `ArticlesDatabase`, `CloudKitSync`, `FeedFinder`, `RSCore`, `RSDatabase`, `RSParser`, `RSTree`, `RSWeb`, `Secrets`, `SyncDatabase`, `NewsBlur` u. a. `Modules/Account/Package.swift` deklariert seine Abhängigkeiten explizit als `.package(path: "../Articles")` etc. — die Abhängigkeitsrichtung ist damit **compilergeprüft**: `Articles` kann nicht versehentlich auf `Account` zugreifen. Die App-Targets (Mac, iOS) konsumieren die Packages. Nebeneffekt: Swift-6-Migration und Upcoming-Features (`.enableUpcomingFeature("NonisolatedNonsendingByDefault")`) werden **pro Modul** aktiviert statt Big-Bang.

**AeroSpace — Multi-Target in einem Package.swift (das WhisperM8-nächste Muster).** `Sources/` enthält fünf Targets: `AppBundle` (die gesamte App-Logik als Library), `Cli` (Client-Binary), `Common` (geteilter Code, v. a. Argument-Parsing), `AppBundleTests`, `PrivateApi`. Die [dev-docs/architecture.md](https://github.com/nikitabobko/AeroSpace/blob/main/dev-docs/development.md) begründet das explizit: „All code is pushed as much as possible to SPM ‚library' located in `../Sources/`" — das Xcode-Projekt ist nur ein generierter Launcher (via `project.yml`), weil SPM keine App-Bundles bauen kann. Ergebnis: `swift build`/`swift test` funktionieren pur, LSP funktioniert (SPM statt xcodeproj), und die Grenze App-Logik ↔ Entry-Point ist erzwungen.

**CodeEdit — Auslagerung wiederverwendbarer Teile in eigene Repos.** Das Haupt-Repo bleibt ein xcodeproj mit Feature-Ordnern (`CodeEdit/Features/` mit 26 Feature-Ordnern: `Editor`, `SourceControl`, `LSP`, `TerminalEmulator`, `Tasks`, …), aber die generischen Bausteine sind eigenständige SwiftPM-Packages mit eigener Release-Kadenz und eigenen Stars: `CodeEditSourceEditor` (705★), `CodeEditTextView` (179★), `CodeEditLanguages` (133★), `CodeEditKit` (Extension-API, 118★), `CodeEditSymbols`. Modularisierung also nicht als Schichtung, sondern als **Extraktion des Wiederverwendbaren**.

**Ice und Maccy — gar nicht.** Ein App-Target, Ordnerstruktur als Konvention (Ice: `MenuBar/`, `Settings/`, `Events/`, `Bridging/`, …). Bei Ice-Größe (Menübar-Tool) vertretbar; für 58k LOC wäre es das nicht.

### 2.3 Persistenz-Muster

**CodeEdit — Throttle statt Debounce, atomarer Write, aber ohne Terminate-Flush.** `Features/Settings/Models/Settings.swift`: `self.$preferences.throttle(for: 2, scheduler: RunLoop.main, latest: true).sink { try? self.savePreferences($0) }` → pretty-printed JSON mit `.atomic` nach `~/Library/Application Support/CodeEdit/settings.json`. Bemerkenswert: **kein sichtbarer willTerminate-Flush** — Änderungen aus den letzten ≤2 s können beim Quit verloren gehen, und Save-Fehler werden mit `try?` verschluckt. WhisperM8s Kombination (0,5 s Debounce + atomic + willTerminate-Flush + Equatable-Diff-Gate) ist hier strikt besser.

**NetNewsWire — Coalescing mit Deadline-Garantie + Dateisystem als Registry.** Zwei Muster stechen heraus:
1. [`RSCore/CoalescingQueue.swift`](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/RSCore/Sources/RSCore/CoalescingQueue.swift): dedupliziert Calls (target+selector), schiebt den Ausführungszeitpunkt bei jedem Add hinaus (`interval` 0,05 s) — **aber mit `maxInterval`**: Kommt der letzte Call länger als `maxInterval` (Default 2 s) nach dem ersten, wird sofort gefeuert. Ein reines Debounce kann unter Dauerlast unbegrenzt verhungern; NNW deckelt das. Zusätzlich existiert `performCallsImmediately()` als expliziter Flush.
2. Account-Persistenz ([Accounts.markdown](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Accounts.markdown)): Jeder Account ist **ein Ordner** unter `Application Support/NetNewsWire/Accounts/` mit vier Dateien (`Settings.plist`, `DB.sqlite3`, `FeedMetadata.plist`, `Subscriptions.opml`). „There is no separate list of accounts" — der `AccountManager` scannt beim Start die Ordner. Kein Index-File bedeutet: keine Index↔Daten-Drift, kein Migrations-Sonderfall für die Registry. Secrets liegen ausschließlich im Keychain, Artikel in SQLite (eigene `ArticlesDatabase`-Instanz pro Account). Die oberste Coding-Value ist explizit „**No data loss**" — vor „No crashes".

**Ice — UserDefaults pro Key.** `GeneralSettingsManager` lädt pro Property (`Defaults.ifPresent(key: .showIceIcon, assign: &showIceIcon)`) und schreibt via Combine-Beobachtung zurück; komplexe Typen als JSON-encodete Defaults-Werte. Für ein Settings-only-Tool okay, skaliert nicht auf strukturierte Workspaces — entspricht WhisperM8s Trennung „kleine Prefs in `AppPreferences`/UserDefaults, strukturierter Zustand als JSON-Dateien" nur zur Hälfte.

**Migrationen:** Kein untersuchtes Projekt hat ein formales Migrations-Framework für JSON/Plist-Zustand. NNW minimiert Migrationen strukturell (Dateisystem-Layout + SQLite-Schema pro Modul), CodeEdit decodiert defensiv (`try?` → Fallback auf `.init()`, d. h. **fehlerhafte Settings werden stillschweigend verworfen** — Datenverlust-Risiko). WhisperM8s Ansatz (Legacy-Felder im Modell behalten, z. B. Chat-ID in `OutputMode` nur noch für Migration; Keychain-Migration aus UserDefaults beim ersten Lesen) ist im Feldvergleich bereits überdurchschnittlich sorgfältig.

### 2.4 Testbarkeits-Strategien

| Projekt | Strategie | Befund |
|---|---|---|
| AeroSpace | Logik komplett in SPM-Library (`AppBundle`), Tests als eigenes Target `AppBundleTests`, `swift-test.sh`/`test.sh` ohne Xcode | Testbarkeit als Build-Architektur-Konsequenz |
| NetNewsWire | Tests pro Modul (jedes `Modules/*`-Package hat eigene Targets), dazu App-Testpläne (`NetNewsWire.xctestplan`, `NetNewsWire-CI.xctestplan`); Protokoll/Delegate-Design (`AccountDelegate`) als Seam | Modulgrenzen = Testgrenzen; kleine finale Objekte sind mockbar |
| CodeEdit | Ein Testtarget `CodeEditTests` + `CodeEditUITests`; `World`-DI als Ansatz, aber nur für `ShellClient` umgesetzt | Testbarkeit vorhanden, DI-Strategie halbherzig |
| Maccy | `MaccyTests` + `MaccyUITests` + `.xctestplan` | solide Grundausstattung |
| Ice | **Kein Testtarget im Repo** | System-API-lastig (CGWindow, Swizzling) — aber null Absicherung |

WhisperM8 (Closure-DI, kleine Protokolle, `ProcessRunner`-Spies, 1 300+ Tests in thematischen Dateien) liegt hier vor allen SwiftUI-Kandidaten und etwa gleichauf mit NNW — mit dem Unterschied, dass NNW/AeroSpace ihre Testgrenzen vom Compiler erzwingen lassen, während bei WhisperM8 ein einziges Target alles für alle Tests mitkompiliert.

## 3. Direkter Vergleich zu WhisperM8

### Was WhisperM8 besser macht

- **Persistenz-Robustheit:** Debounce 0,5 s + atomarer Write + willTerminate-Flush + Equatable-Diff-Gate + NSLock-serialisierte Mutationen (`AgentWorkspaceStore`) schlägt CodeEdits „Throttle 2 s ohne Flush, Fehler per `try?` verschluckt" deutlich; nur NNWs Disziplin ist vergleichbar.
- **State-Granularität:** Die Trennung dauerhafter Workspace (`AgentWorkspaceStore` hinter `AgentSessionStore`-Fassade) / UI-Sidecar (`agent-ui-state.json`, „UI churn never invalidates session data") / ephemerer Runtime-Status (`AgentSessionRuntimeStatusStore` mit per-Item `statusPublisher(for:)`) ist feiner als alles im Feld. Ice invalidiert am Gott-Objekt, CodeEdit am Settings-Monolith-Struct.
- **Modernes Observation:** `@Observable` (macOS 14) mit Projektionen (`AgentWorkspaceUIModel`) statt `ObservableObject`+`@Published`-Breitband-Invalidierung wie bei Ice/CodeEdit/Maccy-Teilen.
- **Test-Substanz:** 1 300+ Unit-Tests mit konsequenter Closure-DI; Ice hat null, CodeEdit und Maccy deutlich weniger Abdeckung der Kernlogik.
- **Performance-Kultur:** os_signpost-Budgets mit `perf_budget_exceeded`-Warnungen (`PerformanceSignposts.swift`) hat kein einziges Vergleichsprojekt institutionalisiert.
- **Read-only-Disziplin gegenüber Fremddaten** (`~/.claude/`, `~/.codex/` mit explizit dokumentierten Schreib-Ausnahmen) ist ein Vertrag, den man im Feld so nirgends findet.

### Was WhisperM8 schlechter macht

- **Keine erzwungenen Modulgrenzen:** EIN SwiftPM-Target bei 58k LOC. Die Ordner `Services/Dictation|AgentChats|Shared` sind Konvention; nichts hindert `Dictation` daran, in `AgentChats`-Interna zu greifen (und `AppState` hält bereits eine Brücke in Agent Chats). NNW prüft Schichtung per Compiler (17 Packages), AeroSpace per Targets. Folgeeffekte bei WhisperM8: jeder Build kompiliert alles, jeder Testlauf linkt alles, `internal`-Sichtbarkeit ist de facto global.
- **Debounce ohne Deadline:** Der 0,5-s-Save-Debounce hat (anders als NNWs `CoalescingQueue.maxInterval`) keine dokumentierte Obergrenze — unter Dauer-Mutation (z. B. Status-Sturm vieler Sessions) verschiebt sich der Save potenziell immer weiter; der Terminate-Flush fängt nur den Quit-Fall, nicht einen Crash unter Last.
- **Extension-Splitting statt Typ-Zerlegung:** `AgentChatsView` (~2 426 LOC nach Phase 2) und `RecordingCoordinator` wurden in `extension`-Dateien geteilt, wobei Logik dafür `internal` gemacht wurde. NNWs Guideline („prefer multiple small objects", Protokoll-Seams) und CodeEdits Feature-Ordner mit eigenen Typen sind hier die sauberere Richtung — Extensions teilen nur die Datei, nicht die Verantwortung, und blockieren später den Target-Split.
- **Singleton-Dichte:** `AppState.shared`, `AgentScanCoordinator` (Singleton), `WindowRequestCenter` (Singleton), `LoginShellEnvironment.shared` — strukturell näher an Ices Gott-Konstellation als an NNWs komponierten kleinen Objekten. Die Closure-DI in Tests mildert das, beseitigt es aber nicht.
- **Keine wiederverwendbaren Extraktionen:** Bausteine wie `TerminalLinkResolver`, `FileEventSource` oder `LoginShellEnvironment` wären nach CodeEdit-Muster extrahierbare Packages; heute sind sie an das App-Target gebunden.

## 4. Übertragbare Muster für WhisperM8 (priorisiert)

**P1 — Multi-Target im bestehenden Package.swift (AeroSpace-Muster).**
Kein Repo-Split, keine 17 Packages à la NNW — sondern 3–5 Targets in der vorhandenen `Package.swift`: zuerst `WhisperM8Shared` (Logger, LoginShellEnvironment, FileEventSource, KeychainManager, PerformanceSignposts — hat die wenigsten Abhängigkeiten), dann schrittweise `WhisperM8AgentChats`-Kern (Store/Repository/Indexer/Reader, pur und UI-frei) und `WhisperM8Dictation`. Das App-Target bleibt der dünne Rest. Gewinn: compilergeprüfte Abhängigkeitsrichtung, schnellere inkrementelle Builds und Testläufe (`swift test --filter` linkt nur das Modul), erzwungene API-Grenzen statt globalem `internal`. Vorarbeit nötig: Die `extension`-Splits (`RecordingCoordinator+X`, `AgentChatsView+X`) setzen `internal`-Sichtbarkeit voraus und müssen vor einem Split entweder im selben Target bleiben oder zu echten Typen werden. AeroSpace beweist, dass genau dieses Setup mit pure-SwiftPM + Launcher funktioniert.

**P2 — Deadline-bounded Debounce für den Workspace-Save (NNW-`CoalescingQueue`-Muster).**
Den 0,5-s-Debounce um ein `maxInterval` (z. B. 3–5 s) ergänzen: Liegt der letzte tatsächliche Save länger zurück, wird trotz anhaltender Mutationen sofort geschrieben. Kleiner Eingriff in den Persistenz-Pfad des `AgentWorkspaceStore`, eliminiert das theoretische Verhungern unter Status-Stürmen und deckt den Crash-unter-Last-Fall ab, den der willTerminate-Flush nicht erreicht. Plus: `performCallsImmediately()`-Äquivalent als expliziter, testbarer Flush-Einstieg existiert mit dem Terminate-Flush schon halb — nur die Deadline fehlt.

**P3 — „Kleine finale Objekte" als Refactoring-Leitlinie statt weiterer Extension-Splits (NNW-CodingGuidelines).**
Bei der nächsten Zerlegungswelle (REFACTORING-AUDIT Phase 3/4) Extensions nur noch als Übergangsschritt behandeln: Ziel sind eigenständige, `final`e Typen mit Protokoll-Seams (wie `TabSelectionResolver`/`TerminalLinkResolver` es bereits vorleben — dieses hauseigene Muster konsequent auf `AgentChatsView`-Belange ausweiten). Das ist zugleich die Voraussetzung für P1. NNWs Werte-Hierarchie („No data loss > No crashes > No other bugs > Fast performance > Developer productivity") als 10-Zeilen-Abschnitt in `docs/` bzw. CLAUDE.md festhalten — WhisperM8 lebt diese Prioritäten implizit, dokumentiert sie aber nicht.

**P4 — Dateisystem-als-Registry für `agent-jobs/` prüfen (NNW-Accounts-Muster).**
NNWs „there is no separate list of accounts" (Ordner-Scan statt Index-Datei) ist das robusteste Anti-Drift-Muster im Feld. WhisperM8 nutzt es bei `agent-jobs/<short-id>/` bereits teilweise; wo immer ein Index-File neben Ordnerdaten existiert (`agent-session-index-cache.json` ist als Cache okay, weil wegwerfbar), sollte der Grundsatz gelten: Index-Dateien müssen rekonstruierbar sein, nie zweite Wahrheit.

**P5 — Extraktion wiederverwendbarer Bausteine als eigene Packages (CodeEdit-Muster) — nur bei echtem Bedarf.**
`TerminalLinkResolver`, `FileEventSource` oder `LoginShellEnvironment` wären publizierbare Mini-Packages. Nutzen entsteht aber erst bei realer Wiederverwendung (z. B. in einem zweiten Tool); als Selbstzweck erzeugt es Release-Overhead. Niedrigste Priorität — erst nach P1, das die technische Grenze ohnehin schafft.

**Anti-Muster, die das Feld liefert (bewusst nicht übernehmen):**
- Ices `AppState`-Konstellation mit `weak`-Rückreferenzen aus jedem Manager: WhisperM8s Singleton-Dichte geht in dieselbe Richtung — bei neuen Services Konstruktor-Injektion statt `.shared`-Zugriff bevorzugen.
- CodeEdits `try?`-verschluckte Save-Fehler und Settings-Decode-Fallback auf Defaults (stiller Datenverlust bei korruptem JSON): WhisperM8 sollte bei Decode-Fehlern des Workspace weiterhin laut scheitern bzw. Backups anlegen, nie still neu initialisieren.

## Quellen

- CodeEdit: [Repo](https://github.com/CodeEditApp/CodeEdit), [Settings.swift](https://github.com/CodeEditApp/CodeEdit/blob/main/CodeEdit/Features/Settings/Models/Settings.swift), [World.swift](https://github.com/CodeEditApp/CodeEdit/blob/main/CodeEdit/World.swift), [Org-Packages](https://github.com/orgs/CodeEditApp/repositories)
- Ice: [Repo](https://github.com/jordanbaird/Ice), [AppState.swift](https://github.com/jordanbaird/Ice/blob/main/Ice/Main/AppState.swift), [GeneralSettingsManager.swift](https://github.com/jordanbaird/Ice/blob/main/Ice/Settings/SettingsManagers/GeneralSettingsManager.swift)
- NetNewsWire: [Repo](https://github.com/Ranchero-Software/NetNewsWire), [Technotes/Accounts.markdown](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/Accounts.markdown), [Technotes/CodingGuidelines.md](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md), [Modules/Account/Package.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/Account/Package.swift), [RSCore/CoalescingQueue.swift](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Modules/RSCore/Sources/RSCore/CoalescingQueue.swift)
- AeroSpace: [Repo](https://github.com/nikitabobko/AeroSpace), [dev-docs/architecture.md](https://github.com/nikitabobko/AeroSpace/blob/main/dev-docs/architecture.md), [dev-docs/development.md](https://github.com/nikitabobko/AeroSpace/blob/main/dev-docs/development.md)
- Maccy: [Repo](https://github.com/p0deje/Maccy) · Loop: [Repo](https://github.com/MrKai77/Loop)

## Keywords

Architektur-Vergleich, Open Source, CodeEdit, Ice, NetNewsWire, AeroSpace, Maccy,
SwiftPM-Targets, Modularisierung, lokale Packages, @Observable, ObservableObject,
CoalescingQueue, Debounce, maxInterval, atomare Writes, Persistenz, Migrationen,
Testbarkeit, Dependency Injection, World-Pattern, AccountDelegate, Technotes,
Manager-Konstellation, Singleton, Extension-Splitting, agent-jobs, Audit 03-vergleich.
