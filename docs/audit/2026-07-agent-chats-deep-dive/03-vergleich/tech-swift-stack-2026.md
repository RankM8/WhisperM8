---
status: aktiv
updated: 2026-07-18
description: Technologiebewertung des Swift- und macOS-Stacks für WhisperM8 mit Fokus auf Concurrency, Prozessmanagement, Testing, Modularisierung und neue Apple-Frameworks.
description_long: Quellenbasierter Stand Juli 2026 mit einem schrittweisen Migrationspfad von Swift 5.9, einer Bewertung von swift-subprocess und Swift Testing sowie klar priorisierten Empfehlungen für macOS 14, 15 und 26.
---

# Swift-/macOS-Stack 2026: Technologiebewertung für WhisperM8

Stand: **18. Juli 2026**. Bewertungsbasis ist WhisperM8 als pure-SwiftPM-App mit `swift-tools-version: 5.9`, einem ausführbaren Produkt-Target, einem Test-Target, macOS 14+, rund 58k LOC, aktuell rund 1.400 XCTest-Methoden und mehreren Prozess- sowie PTY-Pfaden. Der Bericht bewertet nur Technologien, die für die bestätigten Audit-Befunde relevant sind; Preview- und Beta-APIs sind ausdrücklich markiert.

## Kurzfazit und Priorität

| Priorität | Empfehlung | Nutzen | Aufwand/Risiko |
|---|---|---|---|
| **P0** | **Auf Swift-6.3-Toolchain wechseln, zunächst im Swift-5-Sprachmodus mit Complete Concurrency Checking; danach Target für Target auf Swift 6.** | Der Compiler macht die bereits bestätigte `AudioRecorder`-Race-Klasse und weitere nicht-sendbare Übergaben sichtbar, bevor sie erneut als sporadische Crashes auftreten. | Mittel; Warnungsbereinigung und Isolation sind echte Architekturarbeit, aber schrittweise möglich. |
| **P1** | **Den Monolithen in wenige fachliche SwiftPM-Targets schneiden; `Process`- und Audio-Grenzen zuerst.** | Ermöglicht die Concurrency-Migration pro Modul, erzwingt Abhängigkeitsrichtungen und verkleinert Test-/Build-Änderungsradien. | Mittel bis hoch; Schnitt muss gemessen und darf nicht in viele Mikro-Targets ausarten. |
| **P1** | **Neue isolierte Unit-Tests mit Swift Testing schreiben, die rund 1.400 XCTests jedoch nicht massenhaft portieren.** | Sofortiger Gewinn durch parametrisierte Tests, bessere Diagnostik und echte Parallelität ohne Rewrite-Risiko. | Niedrig, sofern XCTest-Assertion-Helpers nicht unbemerkt in Swift-Testing-Tests verwendet werden. |
| **P2** | **`swift-subprocess` für einfache headless CLI-Aufrufe pilotieren, aber erst nach stabilem 1.0 breit übernehmen.** | Strukturierte Cancellation, Output-Streams und Teardown verbessern `git`-/`codex`-/`claude`-Jobs. | Mittel; 1.0 ist aktuell Beta und das Package ersetzt weder PTY noch einen dauerhaften Supervisor. |
| **P3** | **SpeechAnalyzer und Foundation Models nur als optionale macOS-26-Backends erproben.** | On-device-Transkription beziehungsweise kurze Auto-Naming-/Klassifikationsaufgaben können Cloud- und CLI-Kosten reduzieren. | Mittel; OS-, Hardware-, Sprach- und Modellverfügbarkeit erzwingen Fallbacks. |

**Explizit nicht empfohlen:** Deployment Target jetzt auf macOS 26 anheben, Swift 6.4/Xcode 27 Beta produktiv voraussetzen, alle XCTests migrieren, den PTY-Pfad durch `swift-subprocess` ersetzen, die Audio-Race-Klasse durch einen bloßen Framework-Wechsel „lösen“ oder Whisper/Codex/Claude vollständig durch Apples lokale Modelle ersetzen.

## 1. Swift-Sprache und Toolchain

### 1.1 Stabiler Stand im Juli 2026

Der aktuelle stabile Upstream-Stand ist **Swift 6.3.3**; Swift 6.3 erschien am 24. März 2026. Apples stabile Xcode-26-Linie liefert Swift 6.3, während **Swift 6.4 zur Xcode-27-Beta-Linie gehört und für diese Planung experimentell ist** ([Swift 6.3 Release](https://www.swift.org/blog/swift-6.3-released/), [Swift-6.3.3-Ankündigung](https://forums.swift.org/t/announcing-swift-6-3-3/87888), [Xcode-Supportmatrix](https://developer.apple.com/support/xcode/)).

Für WhisperM8 bedeutet „Swift 6 übernehmen“ drei getrennte Entscheidungen:

1. **Compiler/Toolchain aktualisieren**: mit Swift 6.3 bauen.
2. **Package-Manifest aktualisieren**: später `swift-tools-version` anheben, wenn die verwendeten Manifest-APIs es verlangen.
3. **Swift-6-Sprachmodus aktivieren**: pro Target; erst dann werden vollständige Data-Race-Safety-Verstöße zu Fehlern.

Diese Trennung ist der zentrale Hebel gegen einen Big Bang. Apple und das Swift-Projekt unterstützen den Sprachmodus pro Target, ausdrücklich für eine schrittweise Migration ([Swift-6-Migrationsübersicht](https://www.swift.org/migration/), [Xcode-16-Release-Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)).

### 1.2 Was Strict Concurrency für die bestätigten Race-Bugs leistet

Der Audit-Befund am `AudioRecorder` passt genau zur Semantik aus SE-0338: Ein nicht actor-isoliertes `async`-Verfahren läuft auf dem generischen Executor; gleichzeitig vom Main Actor oder einem Audio-Callback gelesener beziehungsweise mutierter Zustand ist daher nicht automatisch serialisiert ([SE-0338](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md)). Swift-6-Data-Race-Safety prüft Actor-Isolation, `Sendable`-Grenzen und Transfers nicht-sendbarer Werte statisch. Damit werden unter anderem diese Muster sichtbar:

- mutable Recorder-/Engine-Referenzen, die zwischen Main Actor, generischem Executor und C-/Audio-Callback geteilt werden;
- `Task`, `Task.detached` oder `@Sendable`-Closures, die nicht-sendbaren Zustand capturen;
- Delegates, Completion-Handler und Prozessobjekte, deren Isolation nicht festgelegt ist;
- globale beziehungsweise statische mutable Zustände ohne Actor- oder Lock-Vertrag.

Strict Concurrency **repariert diese Fehler nicht automatisch**. `@unchecked Sendable`, `nonisolated(unsafe)` und wahllose `Task { @MainActor in ... }`-Brücken können Warnungen ruhigstellen und die Race weiterbestehen lassen. Ziel muss ein klarer Owner sein: UI-/Koordinationszustand auf `@MainActor`, ein eigener Actor für seriellen asynchronen Zustand oder ein dokumentierter Lock für synchrone Real-Time-/C-Callbacks. Region-based Isolation verbessert erlaubte Transfers nicht-sendbarer Werte, ändert aber nicht die Notwendigkeit eines eindeutigen Mutationspfads ([SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)).

Swift 6.2 führte zusätzlich „Approachable Concurrency“ ein. Besonders relevant ist die Option, nicht-isolierte `async`-Funktionen standardmäßig auf dem Actor des Callers auszuführen, statt implizit auf dem Concurrent Executor; die zugrunde liegende Sprachänderung ist SE-0461 ([Swift 6.2 Release](https://www.swift.org/blog/swift-6.2-released/), [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md), [Compiler-Dokumentation](https://docs.swift.org/compiler/documentation/diagnostics/nonisolated-nonsending-by-default/)). Das reduziert überraschende Hops bei neuem Code, ist aber **kein Ersatz für die explizite Korrektur des bestehenden Recorder-Lebenszyklus**.

### 1.3 Realistischer Migrationspfad von Swift 5.9

**Phase A — Compiler modernisieren, Verhalten noch nicht umstellen**

- Xcode/Swift auf die stabile 6.3-Linie aktualisieren und zunächst Swift-5-Sprachmodus beibehalten.
- Build und gesamte Testsuite als Baseline laufen lassen; neue Compilerdiagnosen separat erfassen.
- Nicht gleichzeitig Deployment Target, Prozessbibliothek und Testframework umstellen.

**Phase B — vollständige Prüfung im Swift-5-Modus einschalten**

- Im heutigen Tools-5.9-Manifest kann `StrictConcurrency` als experimentelles Feature pro Target aktiviert werden; alternativ lässt sich der Compiler mit `-strict-concurrency=complete` ansteuern. Bei neueren Manifesten steht das Feature als Upcoming Feature zur Verfügung. Die Diagnosen bleiben im Swift-5-Modus grundsätzlich ein Migrationsinstrument; im Swift-6-Modus werden relevante Verletzungen Fehler ([Data-Race-Safety aktivieren](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/)).
- Zuerst Warnungen in **einem klar begrenzten Modul** beheben. Der offizielle Leitfaden empfiehlt ausdrücklich eine modulweise Migration im Swift-5-Modus ([Migrationsstrategie](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/)).
- Die bestätigten Hotspots priorisieren: `AudioRecorder`/`RecordingCoordinator`, Callback-Brücken, Prozess-Supervisoren, Singleton-Stores und Test-Spies mit mutablem Zustand.

**Phase C — wenige Module schaffen und einzeln umstellen**

- Einen reinen Core-Target und einen Prozess-Target zuerst isolieren; dort Complete Checking auf null Warnungen bringen.
- Danach den jeweiligen Target auf `.swiftLanguageMode(.v6)` setzen, während App/UI vorübergehend im Swift-5-Modus bleibt. Der Sprachmodus ist Target-spezifisch, also genau für diese Staffelung vorgesehen ([Swift-6-Migrationsübersicht](https://www.swift.org/migration/)).
- Für die UI kann ab Swift 6.2 `defaultIsolation(MainActor.self)` sinnvoll sein. Das sollte nur im UI-/App-Target gelten, nicht pauschal in Audio-, Prozess- oder Parsing-Modulen, weil es sonst fehlende Isolation verdecken und unnötige Hops erzeugen kann ([SwiftPM `defaultIsolation`](https://docs.swift.org/swiftpm/documentation/packagedescription/swiftsetting/defaultisolation%28_%3A_%3A%29/)).

**Phase D — Root-App zuletzt auf Swift 6**

- Sobald Leaf-/Service-Module sauber sind, Agent Chats, Dictation und zuletzt Composition/UI umstellen.
- Temporäre Unsafe-Ausnahmen als begründete, suchbare Schulden behandeln und mit Tests sowie Eigentümer-/Threading-Kommentar versehen; keine globale Abschaltung.

Diese Reihenfolge liefert bereits in Phase B Erkenntnisgewinn für die Race-Bugs. Sie ist deutlich risikoärmer als erst alle Typen mit `Sendable` zu annotieren und anschließend zu prüfen, welche Annotationen wahr sind.

### 1.4 Span, Ownership und Strict Memory Safety

`borrowing`, `consuming`, explizites `consume`, nicht kopierbare Typen und der `package`-Access-Level kamen bereits in Swift 5.9; Swift 6.2 ergänzte `Span` für bounds-geprüften, nicht-ownenden Zugriff auf zusammenhängenden Speicher sowie opt-in Strict Memory Safety ([Swift 5.9 Release](https://www.swift.org/blog/swift-5.9-released/), [Swift 6.2 Release](https://www.swift.org/blog/swift-6.2-released/), [SE-0456](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-span-access-shared-contiguous-storage.md)).

Für WhisperM8 ist die Priorität niedrig:

- **Relevant als spätere Optimierung** an einer klar vermessenen CoreAudio-/C-Puffergrenze: `Span` kann Pointer-plus-Länge sicherer ausdrücken; Ownership kann unnötige Kopien großer Audio-Puffer sichtbar machen.
- **Nicht relevant als Lösung der aktuellen Race-Klasse**: Diese Features regeln Lebensdauer, Aliasing und Kopien, nicht die Serialisierung konkurrierender Mutationen.
- **Nicht jetzt adoptieren** als breites Refactoring. Zuerst Isolation korrigieren, anschließend mit Instruments Kopien beziehungsweise Puffer-Hotspots nachweisen. Strict Memory Safety für den gesamten App-Target wäre derzeit Aufwand ohne proportionalen Nutzen.

### 1.5 Deployment Target: 14 behalten, nicht auf 15 oder 26 springen

**Empfehlung: macOS 14 als Minimum vorerst behalten.** Die stabile Xcode-26-Linie kann weiterhin deutlich ältere macOS-Ziele deployen; ein Compiler-Upgrade auf Swift 6.3 erzwingt daher keinen OS-Sprung ([Xcode-Supportmatrix](https://developer.apple.com/support/xcode/)).

- **14 → 15:** liefert für die in diesem Audit relevanten Technologien keinen entscheidenden Unlock. Swift Concurrency, Swift Testing und `swift-subprocess` sind Toolchain-/Package-Themen, keine Begründung, Nutzer auszuschließen.
- **14/15 → 26:** würde SpeechAnalyzer und Foundation Models vereinfachen, ist aber für zwei optionale Backends unverhältnismäßig. Beide lassen sich mit Availability Guards und Fallback anbieten.
- **Später neu bewerten:** anhand realer Nutzertelemetrie, Supportaufwand und sobald ein Kernfeature tatsächlich macOS 26 erfordert. Nicht nur wegen einer bequemeren API-Verfügbarkeit erhöhen.

## 2. Prozessmanagement: `swift-subprocess`

### 2.1 Status und API

[`swift-subprocess`](https://github.com/swiftlang/swift-subprocess) ist das offizielle Swift-Projekt-Package für Subprozesse. Stand 18. Juli 2026 ist **0.5.x die letzte stabile Reihe; 1.0.0-beta.1 ist ein Pre-Release** und beschreibt die für 1.0 vorgesehene, noch final geprüfte API. Die 0.5-Reihe setzt Swift 6.2 voraus; die 1.0-Beta enthält bereits Verhaltens- und API-Änderungen, weshalb eine produktionsweite Einführung vor finalem 1.0 nicht ratsam ist ([Releases](https://github.com/swiftlang/swift-subprocess/releases)).

Das Package bietet im Kern:

- asynchrones `run` mit ausführbarem Pfad/Namen, Argumenten, Arbeitsverzeichnis und kontrollierter Umgebung;
- gesammelte Ausgabe oder `AsyncSequence`-Streams für stdout/stderr sowie einen asynchronen stdin-Writer;
- typisierten Exit-Status und einen Ausführungs-Handle für länger laufende Prozesse;
- Cancellation-/Teardown-Sequenzen, beispielsweise erst terminieren, warten und danach hart beenden;
- Unix-Plattformoptionen wie Prozessgruppe und neue Session sowie macOS-spezifische Pre-Spawn-Konfiguration;
- Ein-/Ausgabe über File Descriptors neben Pipes ([README/API-Beispiele](https://github.com/swiftlang/swift-subprocess/blob/main/README.md), [Package-Dokumentation](https://swiftpackageindex.com/swiftlang/swift-subprocess/documentation)).

Unter Unix basiert die Implementierung auf Spawn-Primitiven und bietet damit einen strukturierteren Swift-Concurrency-Lebenszyklus als frei verteilte `Foundation.Process`-Callbacks. Sie nimmt WhisperM8 aber nicht die Verantwortung für Login-Shell-Environment, absolute Command-Auflösung, Prozessgruppen und die Semantik „Wer besitzt wen?“ ab.

### 2.2 Wo es WhisperM8 konkret verbessert

**Guter Fit:** kurze und mittellange headless-Aufrufe wie `git`, `codex exec`, `claude -p`, Versions-/Capability-Probes, Indexer-Hilfsprozesse und andere Commands, bei denen WhisperM8 Pipes liest und auf Exit wartet. Hier ersetzen strukturierte Streams und Cancellation einen Teil der selbstgebauten Kombination aus `Process`, Pipe-Handlern, Continuations und Timer-Teardown.

**Voraussichtlicher Gewinn:**

- einheitlicher Start-/Wait-/Cancel-Vertrag statt leicht unterschiedlicher Wrapper;
- weniger Gefahr, Pipe-Ausgabe nicht vollständig zu drainieren oder eine Continuation mehrfach fortzusetzen;
- explizite Teardown-Sequenz statt verteilt gesetzter `terminationHandler` und nachträglicher Kill-Timer;
- bessere Komposition mit `Task`-Cancellation und Swift-6-Isolationsprüfung.

Die 1.0-Beta adressiert genau typische Fehlerklassen dieses Audits: Teardown läuft nun auch, wenn der `run`-Body wirft; Unix-Teardown kann optional die ganze Prozessgruppe einschließlich abschließendem `SIGKILL` treffen; außerdem wurden Double-Reap-, Spawn-Zombie- und Pipe-Hang-Fehler korrigiert. Das ist starke Evidenz für den Nutzen einer zentral gepflegten Library, zugleich aber ein Grund, die finale 1.0 abzuwarten: Diese Korrekturen sind Teil des aktuellen Pre-Releases ([1.0-Beta-Release-Notes](https://github.com/swiftlang/swift-subprocess/releases/tag/1.0.0-beta.1)).

**Kein automatischer Gewinn:**

- Eine `ProcessGroupID` oder neue Session ist nur dann korrekt, wenn sie **vor dem Exec/Spawn** und mit klarer Ownership gesetzt wird; sie heilt nicht den im Audit beschriebenen zu späten `setsid()`-Ansatz.
- Das Package garantiert nicht, dass ein beliebiger Kindprozess seine eigenen Enkel sauber terminiert, und es macht aus einem GUI-Prozess keinen robusten dauerhaften Job-Supervisor.
- Ein Login-Shell-kompatibles Environment und `AgentCommandBuilder.commandPath(_:)` bleiben WhisperM8-Vertrag; nie das rohe `ProcessInfo`-Environment durchreichen.

### 2.3 PTY, Zombies und dauerhafte Jobs

Die dokumentierte Oberfläche unterstützt File Descriptors und Pre-Spawn-Konfiguration, enthält aber **keine first-class PTY-/Terminal-Abstraktion**. Daraus folgt: Ein manuell geöffnetes PTY ließe sich wahrscheinlich anbinden, doch `swift-subprocess` ersetzt nicht die Terminalemulation, Window-Size-/Signal-Weitergabe und Session-Integration von SwiftTerm. Das ist eine Schlussfolgerung aus der veröffentlichten API-Oberfläche, keine behauptete technische Unmöglichkeit ([README](https://github.com/swiftlang/swift-subprocess/blob/main/README.md), [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).

Für WhisperM8 daher:

- **SwiftTerm/den vorhandenen PTY-Pfad behalten** für interaktive Codex-/Claude-Terminals.
- `swift-subprocess` nur für nicht-interaktive Jobs hinter einer eigenen kleinen `ProcessRunner`-Schnittstelle einsetzen.
- Für langlebige Jobs mit Überleben unabhängig vom GUI-Lifecycle einen **launchd-/XPC- oder expliziten Helper-Prozess** prüfen. `launchd` ist Apples Supervisor und besitzt Restart-/KeepAlive-/Session-Semantik; das ist eine andere Problemklasse als „Command starten und awaiten“ ([Daemons and Services Programming Guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)).
- Für Sonderfälle, die exakte Session-, Prozessgruppen- oder PTY-Kontrolle benötigen, ist ein enger `posix_spawn`-/POSIX-Adapter ehrlicher als ein immer größerer `Foundation.Process`-Wrapper ([`posix_spawn(3)`](https://keith.github.io/xcode-man-pages/posix_spawn.3.html)).

Zombies verhindert keine API magisch: Der Elternprozess muss Exit/Wait zuverlässig konsumieren. `swift-subprocess` macht dieses Ownership-Modell für strukturierte Tasks leichter, aber abgekoppelte/detached Prozesse verlangen weiterhin einen klaren Reaper beziehungsweise externen Supervisor.

### 2.4 Einführungsempfehlung

1. **Jetzt:** alle einfachen `Foundation.Process`-Nutzungen inventarisieren und hinter dem vorhandenen Closure-/Protokoll-DI-Muster konsolidieren; PTY, Kurzjob und dauerhafter Supervisor als drei Kategorien behandeln.
2. **Nach Swift-6.2/6.3-Toolchain:** einen nicht kritischen, nicht interaktiven Command mit exakt gepinnter Subprocess-Version als Spike umsetzen und Cancellation, große stdout/stderr-Mengen, Kindprozessbaum und App-Quit testen.
3. **Nach stabilem 1.0:** headless Commands inkrementell migrieren, wenn der Spike messbar weniger eigener Lifecycle-Code benötigt.
4. **Nicht adoptieren:** 1.0-Beta als sofortigen Ersatz aller 18 derzeitigen `Process()`-Stellen; kein PTY-Rewrite und kein Vertrauen darauf, dass die Library den Supervisor-Befund allein löst.

Alternativen sind damit nicht „eine andere allumfassende Library“, sondern passend zur Klasse: konsolidierter `Foundation.Process`-Adapter kurzfristig, `swift-subprocess` für strukturierte Kurzjobs, SwiftTerm/POSIX für PTY und launchd/XPC für echte Dauerhaftigkeit.

## 3. Testing: Swift Testing und XCTest

### 3.1 Reife im Juli 2026

Swift Testing ist seit Xcode 16 Bestandteil der Apple-Toolchain und wird aktiv weiterentwickelt. Es unterstützt `@Test`, `#expect`, `#require`, Traits, Tags, parametrisierte Tests, async/throws, Attachments und Exit-Tests; Swift 6.3 ergänzte unter anderem Warning Issues, Test-Cancellation und Bild-Attachments ([Apple Testing](https://developer.apple.com/documentation/testing), [WWDC24: Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/), [Swift 6.3 Release](https://www.swift.org/blog/swift-6.3-released/)). Für neue reine Unit-Tests ist es Mitte 2026 reif.

XCTest bleibt erforderlich beziehungsweise sinnvoll für:

- UI-Automation mit `XCUIApplication`/XCUIAutomation;
- bestehende Performance-/Metric-Infrastruktur, die nicht gleichwertig portiert ist;
- unverändert stabile Legacy-Suiten und spezielle XCTest-Integrationen. Apple empfiehlt Swift Testing für neue Unit-Tests, führt XCTest aber ausdrücklich weiter für UI-Tests ([Xcode Testing](https://developer.apple.com/documentation/xcode/testing), [XCTest](https://developer.apple.com/documentation/xctest)).

### 3.2 Parallelisierung ist Nutzen und Migrationsfalle

Swift-Testing-Tests laufen standardmäßig parallel, während XCTest-Methoden einer Suite traditionell sequenziell laufen. Eine Suite kann mit `.serialized` serialisiert werden; das serialisiert jedoch nur innerhalb dieser Suite, nicht automatisch andere Suiten, die denselben globalen Zustand berühren ([Apple-Migrationsleitfaden](https://developer.apple.com/documentation/testing/migratingfromxctest), [Parallelization](https://developer.apple.com/documentation/testing/parallelization)).

Für WhisperM8 ist das besonders relevant, weil Tests UserDefaults, Dateisystem, Singleton-Stores, Prozess-Spies oder globale Environment-Zustände teilen können. Deshalb gilt:

- neue Tests bekommen pro Test ein temporäres Verzeichnis, eine eigene Store-Instanz und injizierte Closures;
- globale mutierbare Test-Helpers werden vermieden oder actor-/lock-isoliert;
- `.serialized` ist eine gezielte Übergangshilfe, kein Ersatz für Isolation;
- ein globales `--no-parallel` ist höchstens ein temporärer Diagnosemodus.

Parallelisierung wird damit gleichzeitig zum Race-Detektor für die Testarchitektur. Sie sollte bewusst aktiviert bleiben, sobald die betroffenen Suiten isoliert sind.

### 3.3 Koexistenz und die Interoperabilitätsfalle vor Swift 6.4

XCTest und Swift Testing können im selben Test-Target und sogar derselben Datei koexistieren. Das ermöglicht eine inkrementelle Migration ohne neues Test-Bundle ([Apple: Migrating from XCTest](https://developer.apple.com/documentation/testing/migratingfromxctest), [Adding tests](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project)).

Wichtig ist aber der aktuelle Randfall: Bei Toolchains **vor Swift 6.4** ist die Cross-Framework-Interoperabilität standardmäßig `none`. Eine `XCTAssert…`-Assertion, die indirekt aus einem Swift-Testing-Test aufgerufen wird, kann daher vom anderen Framework nicht als Fehler übernommen werden; umgekehrt gilt dasselbe für Swift-Testing-Issues in XCTest. Swift 6.4 führt begrenzte beziehungsweise vollständige Interoperabilitätsmodi ein, ist im Juli 2026 aber Teil der Xcode-27-Beta ([Apple-Migrationsleitfaden](https://developer.apple.com/documentation/testing/migratingfromxctest), [WWDC26: Migrate to Swift Testing](https://developer.apple.com/videos/play/wwdc2026/267/)).

Konsequenz: Neue Swift-Testing-Tests dürfen bis zur stabilen Swift-6.4-Einführung **keine bestehenden Helpers wiederverwenden, die intern XCTest-Assertions ausführen**, sofern diese nicht in reine Rückgabewerte/`throws` umgebaut wurden. Sonst drohen grüne False Positives.

### 3.4 Strategie für rund 1.400 bestehende Tests

**Neue Tests direkt in Swift Testing schreiben**, wenn sie pure Logik, async Workflows, State Machines, Parser, Stores oder den neuen Prozess-Adapter prüfen. Besonders lohnend sind:

- tabellarische/parametrisierte Fälle statt vieler fast identischer XCTest-Methoden;
- `#require` für Vorbedingungen und `#expect` für mehrere Diagnosen pro Fall;
- Exit-Tests für bewusst abstürzende/terminierende Prozess- und Invariant-Pfade;
- Tags für Dictation, Agent Chats, Process und Regression.

**Bestehende XCTests behalten.** Eine Massenmigration von rund 1.400 Methoden produziert viel Diff, wenig zusätzliche Fehlerfindung und neue Parallelitätsflakiness. Portieren nur, wenn eine Suite ohnehin stark geändert wird, von Parametrisierung substanziell profitiert oder XCTest den neuen Testfall deutlich erschwert.

**Nicht adoptieren:** mechanisches Search/Replace von `XCTAssert` zu `#expect`, gemeinsame Assertion-Helpers ohne Interop-Audit oder das Abschalten der gesamten Parallelität, damit globale Testzustände unangetastet bleiben können.

## 4. Modularisierung großer SwiftPM-Apps

### 4.1 Empfohlener Schnitt

Ein SwiftPM-Target ist eine Modulgrenze mit expliziten Abhängigkeiten. Für WhisperM8 ist ein Multi-Target-Setup im bestehenden Package sinnvoller als 17 lokale Packages oder ein Repo-Split ([SwiftPM `Target`](https://developer.apple.com/documentation/packagedescription/target)). Ein tragfähiges Zielbild ist:

```text
WhisperM8Core           Modelle, Parser, pure Utilities
    ↑          ↑
WhisperM8Process        Environment, Command-Auflösung, Headless Runner
    ↑          ↑
WhisperM8Dictation      Capture-/Transkriptions-Pipeline
WhisperM8AgentChats     Stores, Indexer, Sessions, Jobs
    ↑          ↑
WhisperM8               dünne App-/SwiftUI-Komposition
```

Die Pfeile stehen für „wird von oben konsumiert“; konkrete Abhängigkeiten sollten azyklisch und so klein wie möglich bleiben. Test-Targets folgen den fachlichen Modulen. `Shared` darf dabei nicht als neue Ablage für beliebige App-Abhängigkeiten weiterleben.

**Reihenfolge:**

1. pure Modelle/Parser/Utilities als Leaf-Modul;
2. headless Prozessabstraktion samt Environment-/Command-Vertrag;
3. Agent-Chats-Kern und Dictation-Kern;
4. UI-Komposition zuletzt.

Der Schnitt unterstützt direkt die Swift-6-Migration: Complete Checking und Sprachmodus werden zuerst in kleinen Leaf-Modulen aktiviert. Große `extension`-Dateien bleiben zunächst im selben Target oder werden vor dem Verschieben zu echten, injizierbaren Typen.

### 4.2 Sichtbarkeit: `package` statt `@_spi`

Der mit Swift 5.9 eingeführte `package`-Access-Level ist für mehrere Targets desselben Packages gedacht: enger als `public`, aber targetübergreifend innerhalb des Packages sichtbar ([SE-0386](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md), [Swift 5.9 Release](https://www.swift.org/blog/swift-5.9-released/)). Empfehlung:

- `internal` als Default innerhalb eines Targets;
- `package` für bewusst geteilte App-Interna;
- `public` nur für eine echte externe API oder technisch notwendige Executable-Grenzen;
- **kein `@_spi` als Architekturwerkzeug**: Das Unterstrich-Attribut ist keine stabile öffentliche Sprachgarantie und umgeht die klare Package-Grenze.

### 4.3 Buildzeit: messen, nicht versprechen

Module können inkrementelle Rebuilds verkleinern und parallele Kompilierung ermöglichen; sie verursachen aber auch Modul-Emission, zusätzliche Imports und Abhängigkeitsarbeit. Apples Build-Engineering-Hinweise betonen, dass mehr Module nicht automatisch schnellere Builds bedeuten und unnötige Imports beziehungsweise ungünstige Abhängigkeitsgraphen selbst Kosten erzeugen ([WWDC24: Demystify explicitly built modules](https://developer.apple.com/videos/play/wwdc2024/10171/), [WWDC26 Swift Group Lab](https://developer.apple.com/videos/play/wwdc2026/8001/)).

Darum vor und nach jedem Schnitt messen:

- Clean `swift build`;
- inkrementeller Build nach Änderung einer Leaf-Datei und einer UI-Datei;
- gezielter und voller `swift test`;
- Modul- und Importgraph.

Nicht mehr als wenige fachlich stabile Targets in der ersten Welle. Ein Target pro Ordner oder View wäre Mikro-Modularisierung mit hohem API- und Build-Overhead.

### 4.4 Reale Vorbilder

**AeroSpace** ist der naheliegendste pure-SwiftPM-Vergleich: Das Package trennt unter anderem `Common`, App-Bundle-Logik, CLI und private API in mehrere Targets; die Architektur dokumentiert eine gemeinsame Command-/Parsing-Schicht für App und CLI ([AeroSpace `Package.swift`](https://github.com/nikitabobko/AeroSpace/blob/main/Package.swift), [AeroSpace Architecture](https://github.com/nikitabobko/AeroSpace/blob/main/dev-docs/architecture.md)). Es belegt die Machbarkeit des Setups, nicht automatisch den exakten WhisperM8-Schnitt.

**NetNewsWire** nutzt zahlreiche lokale SwiftPM-Module für Accounts, Artikel, Datenbanken, Parser und Sync. Das zeigt den langfristigen Wert compilergeprüfter Subsystemgrenzen, wäre als sofortiges Ziel für WhisperM8 aber zu granular ([NetNewsWire Modules](https://github.com/Ranchero-Software/NetNewsWire/tree/main/Modules)).

**CodeEdit** extrahiert generische Editor-Komponenten als Packages, hält die App-Schichtung selbst aber im Xcode-Projekt. Für WhisperM8 ist das erst relevant, wenn ein Baustein wirklich außerhalb der App wiederverwendet wird; Extraktion in separate Repos ist keine Voraussetzung für gute interne Modulgrenzen ([CodeEdit](https://github.com/CodeEditApp/CodeEdit)).

## 5. Relevante Apple-Frameworks aus WWDC 2025/2026

### 5.1 Audioaufnahme: kein Framework-Sprung repariert die Race-Klasse

Für macOS 14/15 gibt es keine neue AVAudioEngine-API aus WWDC 2025, die die bestätigte Race-Klasse aus Engine-Rekonfiguration, Tap-/Callback-Lebenszyklus und konkurrierendem Stop automatisch beseitigt. `AVAudioEngine` bleibt Apples flexible Audio-Graph-API; die WWDC25-Neuerungen zu Audioaufnahme konzentrieren sich vor allem auf iOS/iPadOS-Aufnahmerouting, AirPods und räumliche Aufnahme ([AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine), [WWDC25: Enhance your app’s audio recording capabilities](https://developer.apple.com/videos/play/wwdc2025/251/)).

Optionen nüchtern bewertet:

- **`AVAudioRecorder`: nicht übernehmen** als pauschalen Ersatz. Es vereinfacht Datei-Aufnahme und Metering, bietet aber nicht denselben Graph-/Tap-/Konvertierungsgrad für ausgewählte Geräte und Streaming-Pipelines ([AVAudioRecorder](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)).
- **`AVCaptureSession` + `AVCaptureAudioDataOutput`: begrenzter Spike.** Die API liefert Sample Buffers auf einer festgelegten Delegate-Queue und könnte den Capture-Teil stärker kapseln. Sie beseitigt jedoch weder shared mutable state noch Device-Change-/Stop-Races; diese müssen weiterhin durch Queue-/Actor-Ownership gelöst und auf WhisperM8s Geräteanforderungen getestet werden ([AVCaptureAudioDataOutput](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput)).
- **CoreAudio/AUHAL: nur bei nachgewiesenem Bedarf.** Mehr Kontrolle kann Gerätewechsel und Callback-Besitz expliziter machen, erhöht aber C-/Pointer-/Real-Time-Komplexität. Erst nach einer isolierten Reproduktion und einem Prototyp gegen die aktuelle Engine bewerten ([Core Audio](https://developer.apple.com/documentation/coreaudio)).

Die im WWDC26-Zeitraum dokumentierten Speech-Capture-Helfer wie `CaptureInputSequenceProvider` sind im Juli 2026 ausdrücklich **Beta** und damit kein Bestandteil der stabilen 14/15/26-Basis ([Speech Updates](https://developer.apple.com/documentation/updates/speech), [`CaptureInputSequenceProvider.provider`](https://developer.apple.com/documentation/speech/captureinputsequenceprovider/provider%28from%3Ain%3Acompatiblewith%3Apriority%3A%29)). **Nicht adoptieren**, bis API und zugehörige OS-/Xcode-Linie stabil sind und ein Deployment-/Backdeployment-Plan existiert.

Die P0-Maßnahme bleibt daher: aktuellen Capture-Lebenszyklus mit einem einzigen Owner serialisieren, C-/Audio-Callback minimal halten, Stop/Reconfigure idempotent machen und unter Strict Concurrency plus Stress-Tests absichern. Ein alternativer Backend-Spike kommt erst danach.

### 5.2 SpeechAnalyzer/SpeechTranscriber als Whisper-Alternative

Das mit macOS 26 verfügbare Speech-Framework-Design verwendet einen `SpeechAnalyzer` mit Analysemodulen und asynchronen Ergebnisfolgen; `SpeechTranscriber` stellt On-Device-Transkription bereit, einschließlich Verwaltung benötigter Modell-Assets und Abfrage unterstützter Locales ([SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), [WWDC25: Bring advanced speech-to-text to your app](https://developer.apple.com/videos/play/wwdc2025/277/)).

**Nutzen für WhisperM8:** ein optionaler lokaler Provider ohne Groq-Netzwerkpfad, potenziell geringere Latenz und bessere Privacy auf unterstützten Systemen. Der sinnvollste erste Versuch ist **Transkription bereits aufgezeichneter Dateien**: Er verändert den riskanten Capture-Pfad nicht und erlaubt einen fairen A/B-Test gegen Whisper/Groq.

**Grenzen:**

- nur macOS 26 und nur bei zur Laufzeit unterstützter Sprache/Modellverfügbarkeit;
- Qualität, Fachvokabular, Sprachen, Interpunktion, Partial Results, Latenz und Energiebedarf müssen mit einem WhisperM8-Korpus gemessen werden;
- der Analyzer löst die AudioRecorder-Race nicht, wenn ihm weiterhin Buffers aus derselben fehlerhaften Capture-Lifecycle-Logik zugeführt werden;
- kein Anlass, Whisper/Groq zu entfernen: Fallback bleibt für ältere Systeme, nicht unterstützte Locales und Qualitätsfälle.

**Empfehlung P3:** macOS-26-only Provider-Prototyp hinter der bestehenden Transkriptionsabstraktion, zunächst Offline-Dateien, Feature Flag und Benchmark. **Nicht adoptieren:** SpeechAnalyzer als alleinigen Provider oder Deployment Target 26 nur für diese API.

### 5.3 Foundation Models für lokale Kurz-Tasks

Das Foundation Models Framework stellt auf macOS 26 das On-Device-Sprachmodell von Apple Intelligence über `SystemLanguageModel` und Sessions bereit. Apps müssen die Verfügbarkeit zur Laufzeit prüfen; sie hängt unter anderem von Gerät, Apple-Intelligence-Konfiguration und Modellzustand ab ([SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel), [Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)). Apple Intelligence auf dem Mac setzt Apple Silicon voraus ([Apple Intelligence requirements](https://support.apple.com/en-us/121115)).

**Guter Fit:** Auto-Naming von Chats/Jobs, kurze Labels, Klassifikation, strukturierte Extraktion aus kurzem Kontext und knappe Zusammenfassungen. Apple positioniert das Modell genau für Aufgaben wie Zusammenfassung, Extraktion und Klassifikation, nicht als allgemeine Wissensdatenbank oder Ersatz für große Reasoning-Modelle ([WWDC25: Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/)).

**Kein Fit:** Codex-/Claude-Code-Reasoning, lange Transkripte, Repository-weite Aufgaben, aktuelles Weltwissen oder ein zwingender Startpfad. Der Kontext ist begrenzt, die Modellausgabe ist nicht deterministisch und Apple weist darauf hin, Prompts nach Systemmodell-Updates neu zu testen ([Generating content](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models), [Foundation Models Updates](https://developer.apple.com/documentation/updates/foundationmodels)).

**Empfehlung P3:** optionaler `@available(macOS 26, *)`-Backend für Auto-Naming und kurze Metadatenaufgaben, mit Availability-Check, Timeout, Qualitäts-Eval und bestehendem deterministischem/CLI-/Cloud-Fallback. So kann WhisperM8 einen `claude -p`-Spawn für triviale Aufgaben vermeiden, ohne Funktionalität von Apple-Intelligence-Verfügbarkeit abhängig zu machen.

Die auf WWDC26 gezeigten Foundation-Models-Erweiterungen gehören überwiegend zu macOS 27/Xcode 27 Beta und sind hier nur Beobachtungsposten ([WWDC26: What’s new in Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/)). **Nicht adoptieren:** Beta-APIs, Systemmodell als Codex-/Claude-Ersatz oder ein OS-26-Minimum nur für Auto-Naming.

## 6. Empfohlene Roadmap

### Jetzt bis nächste stabile Release-Welle

1. Swift-6.3-Toolchain im Swift-5-Modus etablieren und vollständige Concurrency-Diagnosen sammeln.
2. Recorder-/Callback-Ownership zuerst reparieren; Unsafe-Annotationen nur als begründete Ausnahme.
3. Multi-Target-Schnitt mit Core und Process beginnen; Clean-/Incremental-Buildzeiten vor und nach dem Schnitt messen.
4. Neue pure Unit-Tests mit Swift Testing schreiben, vorhandene XCTest-Suite unverändert weiterbetreiben und Assertion-Helpers trennen.
5. Headless-, PTY- und Supervisor-Prozesse inventarisieren und in getrennte Verträge überführen.

### Nach stabilem `swift-subprocess` 1.0

1. Einen einfachen headless Command migrieren und Teardown-/Output-/Cancellation-Stresstests durchführen.
2. Nur erfolgreiche Kategorien schrittweise übernehmen; SwiftTerm-PTY und dauerhafte Jobs unverändert separat behandeln.
3. Modul für Modul in den Swift-6-Sprachmodus schalten.

### Optional für macOS 26

1. SpeechTranscriber mit aufgezeichneten Dateien gegen Whisper/Groq benchmarken.
2. Foundation Models für Auto-Naming/kurze Metadaten hinter Feature Flag testen.
3. Beide als optionale Provider mit Fallback ausliefern; Deployment Target 14 beibehalten.

## 7. Entscheidungen: übernehmen, beobachten, verwerfen

| Technologie | Entscheidung Juli 2026 | Begründung |
|---|---|---|
| Swift-6.3-Toolchain | **Übernehmen** | Stabil; vollständige Concurrency-Diagnostik adressiert bestätigte Bugs. |
| Swift-6-Sprachmodus | **Schrittweise übernehmen** | Pro Target nach Warnungsbereinigung, nicht als Big Bang. |
| Swift 6.4 / Xcode 27 | **Beobachten** | Beta; Testing-Interop attraktiv, aber keine Produktionsbasis. |
| Span/Ownership-Breiteinsatz | **Nicht übernehmen** | Kein Fix für Races; nur nachgewiesene Puffer-Hotspots. |
| macOS 14 Minimum | **Beibehalten** | Kein relevanter Swift-/Testing-Nutzen durch Anhebung auf 15; 26-Features sind optional kapselbar. |
| `swift-subprocess` 1.0 Beta | **Pilotieren, nicht breit übernehmen** | Gute API für headless Jobs, aber Pre-Release und kein PTY/Supervisor. |
| Swift Testing für Neutests | **Übernehmen** | Reif für Unit-Tests; bessere Parametrisierung/Parallelität. |
| Massenmigration von XCTest | **Verwerfen** | Hoher Diff-/Flake-Aufwand ohne proportionalen Nutzen. |
| 4–5 SwiftPM-Targets | **Übernehmen** | Compilergrenzen und gestaffelte Concurrency-Migration; Wirkung messen. |
| `@_spi` für interne Module | **Verwerfen** | `package` ist die stabile passende Sprachfunktion. |
| `AVAudioRecorder` als Ersatz | **Verwerfen** | Zu wenig Kontrolle; behebt Ownership-Race nicht. |
| SpeechAnalyzer | **macOS-26-Pilot** | Lokaler Provider mit OS-/Locale-Fallback, zunächst Datei-A/B-Test. |
| Foundation Models | **macOS-26-Pilot** | Geeignet für kurze lokale Tasks, nicht für Agent-/Code-Reasoning. |
| WWDC26/macOS-27-Beta-APIs | **Beobachten** | Außerhalb der unterstützten 14/15/26-Matrix. |

## Quellenindex

### Swift und Concurrency

- [Swift 6.3 Released](https://www.swift.org/blog/swift-6.3-released/)
- [Swift 6.3.3 Announcement](https://forums.swift.org/t/announcing-swift-6-3-3/87888)
- [Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)
- [Swift 6 Migration](https://www.swift.org/migration/)
- [Enabling Complete Concurrency Checking](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/)
- [Migration Strategy](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/)
- [SE-0338: Clarify execution of non-actor-isolated async functions](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md)
- [SE-0414: Region based isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- [SE-0461: `nonisolated(nonsending)` by default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
- [SE-0456: `Span`-providing properties](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-span-access-shared-contiguous-storage.md)
- [Xcode support matrix](https://developer.apple.com/support/xcode/)

### Prozesse und Tests

- [`swift-subprocess`](https://github.com/swiftlang/swift-subprocess)
- [`swift-subprocess` Releases](https://github.com/swiftlang/swift-subprocess/releases)
- [Swift Testing](https://developer.apple.com/documentation/testing)
- [Migrating from XCTest](https://developer.apple.com/documentation/testing/migratingfromxctest)
- [Parallelization](https://developer.apple.com/documentation/testing/parallelization)
- [WWDC26: Migrate to Swift Testing](https://developer.apple.com/videos/play/wwdc2026/267/)

### SwiftPM und Vorbilder

- [SwiftPM Target](https://developer.apple.com/documentation/packagedescription/target)
- [SE-0386: `package` access modifier](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0386-package-access-modifier.md)
- [AeroSpace Package.swift](https://github.com/nikitabobko/AeroSpace/blob/main/Package.swift)
- [AeroSpace Architecture](https://github.com/nikitabobko/AeroSpace/blob/main/dev-docs/architecture.md)
- [NetNewsWire Modules](https://github.com/Ranchero-Software/NetNewsWire/tree/main/Modules)
- [CodeEdit](https://github.com/CodeEditApp/CodeEdit)

### Apple-Frameworks

- [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [AVCaptureAudioDataOutput](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [WWDC25: Bring advanced speech-to-text to your app](https://developer.apple.com/videos/play/wwdc2025/277/)
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [WWDC25: Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/)
