---
status: roh
updated: 2026-10-17
description: Workflow B, B3 macOS-Engineering + Terminal — Vergleich mit anderen Projekten und Rahmenbedingungen (aus der strukturierten Agent-Rückgabe erzeugt).
---

# B3 macOS-Engineering + Terminal

## Kurzfazit

B3 abgeschlossen, Stand 17.10.2026; ausschließlich Code/Dokumentation gelesen, keine Builds, Tests oder Änderungen. Gemäß Subagent-Vorgabe keine Berichtsdatei geschrieben; Inhalt unten direkt zur Übernahme. Vorgesehener Zielpfad: /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/03-vergleich/B3-macos-engineering.md. Kurzfazit: Den nativen Stack behalten; Prozess-Lifecycle, dauerhafte Diagnostik und explizite Persistenzgarantien vor großem Architekturumbau priorisieren. Verifiziert: 99.413 Swift-Zeilen im App-Verzeichnis; fünf genannte Dateigrößen stimmen; 47 exakt als „static let shared“ deklarierte Instanzen; 23 direkte „let/var … = Process()“-Konstruktionen statt 26 tatsächlicher Spawns. Rohzählungen ersetzen keine Aufrufpfadprüfung. Wichtige Juli-Korrekturen: Save-Debounce besitzt bereits eine 2-s-Deadline; Terminal-Snapshots wurden entfernt; swift-subprocess ist inzwischen final 1.0.2; SwiftTerm bietet mit v1.99.0 einen API-brechenden Übergang zu 2.0. Ice bleibt auf dem Default-Branch seit September 2025 unverändert, obwohl Repository-pushed_at Oktober 2026 meldet. Was WhisperM8 bereits gut macht: getrennter Workspace/UI-/Runtime-Zustand, Closure-DI, Generation-Backups, eigener Stall-Watchdog, CLOEXEC-Härtung und SIGPIPE-Schutz. Offen bleiben echte Laufzeitmessungen, Direct-Distribution-MetricKit-Zustellung und die produktseitige Definition von „kein Datenverlust“ bei gepufferten Änderungen.

## Untersuchte Projekte und Quellen

| Name | URL | Lizenz | Geprüft über | Relevanz |
|---|---|---|---|---|
| Ghostty | https://github.com/ghostty-org/ghostty | MIT | code | Default-Branch e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110, Commit 16.10.2026. README, Swift-App-Lifecycle, Xcode-Targets und offizielles Swift-VT-XCFramework-Beispiel gelesen. Referenz für native UI mit abgegrenzter Engine; kein Beleg für einen modularen SwiftPM-App-Kern oder gemessene Buildzeitgewinne. |
| CodeEdit | https://github.com/CodeEditApp/CodeEdit | MIT | code | Default-Branch fa2aebd86373211c78626074b53ab75010767575, Commit 18.08.2026. Settings, World, ShellClient, Terminal-Coordinator und Package-Produkte im Xcode-Projekt gelesen. Nützlich für Komponentenextraktion und AppKit-Bridging; grobe Settings-Invalidierung und globales World sind keine Zielarchitektur. |
| Ice | https://github.com/jordanbaird/Ice | GPL-3.0; zusätzliche Rechteangaben bei Codeübernahme gesondert prüfen | code | Default-Branch 11edd39115f3f43a83ae114b5348df6a0e1741cf, Commit 20.09.2025; pushed_at 06.10.2026 beweist keine Wiederaufnahme auf main. AppState und Projektbaum gelesen. Gegenbeispiel für breit weitergereichtes objectWillChange und Manager-Rückreferenzen; Muster analysieren, keinen GPL-Code ungeprüft übernehmen. |
| iTerm2 | https://github.com/gnachman/iTerm2 | GPL-2.0 laut Repository; Drittkomponenten können abweichen | doku | Repository am 17.10.2026 aktiv. Primäre Architekturbeschreibung in AGENTS.md und Lizenz gelesen: App → Window/Tab → Session → Emulation → Rendering. Keine eigenständige Verifikation aktueller Rendering-Performance oder sämtlicher Threading-Details. |
| SwiftTerm | https://github.com/migueldeicaza/SwiftTerm | MIT | code | Release v1.99.0 vom 08.10.2026, weitere Aktivität 15.10.2026. Release-Notes, Package.swift, 1→2-Migrationsleitfaden und TerminalIOPipeline gelesen. Neue Queue-/Snapshot-Grenzen und Selection-Fixes sind für WhisperM8 unmittelbarer relevant als ein Engine-Wechsel. |
| swift-subprocess | https://github.com/swiftlang/swift-subprocess | Nicht separat verifiziert | code | Finales Release 1.0.2 vom 16.10.2026. Release-Metadaten, README und getaggtes Package.swift gelesen: Swift-6.2-Tools, Swift-6-Sprachmodus im Package, macOS 13+. Kandidat hinter eigenem Headless-Runner; kein automatischer Ersatz für SwiftTerms PTY-Pfad. |
| GRDB.swift | https://github.com/groue/GRDB.swift | MIT | code | Repository-Aktivität 29.09.2026. README, Migrationsdokumentation und DatabaseMigrator-Code gelesen. Referenz für transaktionale Schemaentwicklung und explizite SQLite-Zugriffsschicht, nicht Beleg einer notwendigen Sofortmigration. |
| Sentry Cocoa | https://github.com/getsentry/sentry-cocoa | MIT für das SDK; nicht auf Server-/Hostingprodukte übertragen | code | Repository-Aktivität 17.10.2026. README, Options.swift und HTTP-Transport gelesen. Belegt Upload-/Cache-Verhalten sowie Filtermöglichkeiten; „Open Source“ oder „Self-hosted“ bedeutet nicht „ohne Datenübertragung“. |
| Apple / Swift-Migrationsleitfaden | https://developer.apple.com/videos/play/wwdc2024/10169/ | — | doku | Primärquellen gelesen: WWDC zu Swift-6-Migration, Observation, Modul-Builds, Logging, SwiftData und neuem MetricKit 2026; zusätzlich Swift-Migrationsleitfaden im Quellrepository und lokale MetricKit-SDK-Header. Neue API-Verfügbarkeit und tatsächliche Zustellung auf Brew-Builds sind getrennte Fragen. |

## Antworten auf die Fragestellungen

### 1. Modulschnitt: Lohnt sich die Aufteilung in mehrere SwiftPM-Targets, und in welcher Reihenfolge?

**Konfidenz:** hoch

Ja, primär für compilergeprüfte Abhängigkeitsrichtung, kleinere Testoberflächen und getrennte Concurrency-Migration – nicht wegen einer magischen LOC-Grenze. WhisperM8 hat einen großen Swift-App-Target plus ObjCExceptionBridge und Testtarget; „genau ein Target“ aus Juli ist daher nur als „ein fachlicher App-Target“ korrekt. Die fünf genannten Dateien wurden mit 3.816/1.726/1.604/1.485/1.358 Zeilen bestätigt.

Ghostty trennt Swift/AppKit-Lifecycle von der Zig-Engine über GhosttyKit.xcframework, nicht über zahlreiche SwiftPM-App-Targets. CodeEdit extrahiert generische Editor-Komponenten als Package-Produkte, bleibt selbst eine Xcode-App mit Feature-Ordnern. Daraus folgt weder eine übertragbare Buildzeitersparnis in Sekunden noch ein vollständiger Bauplan für WhisperM8.

Vorschlag: (1) WhisperM8Core mit reinen Modellen, Parsern und Entscheidern; (2) WhisperM8Process mit Environment-Policy, Binary-Auflösung und Headless-Runner; (3) AgentChatsCore für Store/Indexer/Transcript-Lesen sowie DictationCore für die Pipeline, beide abhängig von Core und bei Bedarf Process; (4) UI und App-Komposition zuletzt. AppKit-/PTY-Adapter zunächst im App-Target lassen. Diktat→Chat-Kontext über ein kleines Wertmodell/Protokoll statt gegenseitiger Feature-Imports. Bestehende Extensions müssen im selben Target bleiben oder in eigenständige Typen überführt werden.

Korrektur der Juli-Analyse: Ein Target-Split garantiert weder schnellere Builds noch dass „swift test --filter“ nur ein Modul linkt. Filter wählen Tests; der Buildgraph bestimmt Kompilierung und Linking. Vorher/nachher Clean-, UI-Edit-, Core-Edit- und Testzeiten messen. Aufwand L, etappenweise; kein pauschaler Launch-Blocker.

Quellen: https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/macos/Ghostty.xcodeproj/project.pbxproj, https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/CodeEdit.xcodeproj/project.pbxproj, https://developer.apple.com/videos/play/wwdc2024/10171/, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Package.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/swiftui-architektur.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/tech-swift-stack-2026.md

### 2. Swift 6 strict concurrency: Wie schrittweise migrieren, insbesondere Process/PTY/FileHandle/DispatchSource?

**Konfidenz:** hoch

Compiler-Version, swift-tools-version und Sprachmodus getrennt behandeln. Das vorhandene 5.9-Manifest besitzt keine explizite Strict-Concurrency-Aktivierung; ein Swift-6.2-Compiler allein schaltet den App-Code nicht auf Swift-6-Sicherheit um. Apples Verfahren: pro Target Complete Checking zunächst als Warnungen, Isolation korrigieren, dann Swift-6-Sprachmodus. Für 5.9/5.10-Tools nennt der offizielle Guide enableExperimentalFeature("StrictConcurrency"), für 6.x-Tools im Swift-5-Modus enableUpcomingFeature("StrictConcurrency"). Beim späteren Manifest-Bump noch nicht migrierte Targets explizit auf .v5 halten.

Für WhisperM8 zuerst Diagnostik-Baseline aufnehmen und kleine reine Typen migrieren, parallel UI-Eigentümerschaft mit MainActor ausdrücken. Apple demonstriert ausdrücklich auch UI-first; Leaf-first ist hier eine Empfehlung, keine allgemeine Swift-Regel. Kein pauschales MainActor für Store, Parser und Prozess-I/O.

Grenzfälle: Readability-/Termination-Callbacks haben nicht automatisch UI-Isolation; nur kopierte Werte in den MainActor schicken. Prozessende und EOF sind unterschiedliche Ereignisse. Cancellation, Timeout und Exit können gleichzeitig eintreten: Continuation exakt einmal fortsetzen, Handler abbauen und Deskriptoren eindeutig besitzen. DispatchSource.cancel ist kein synchrones Close; FD-Freigabe in den CancelHandler und Rotation/Rearm gegen alte Events absichern. Ein async-Wrapper macht blockierendes waitUntilExit nicht nichtblockierend. Weder MainActor noch kooperativen Executor durch Semaphore-Brücken blockieren.

Bestehend gut: FileEventSource öffnet mit O_CLOEXEC und schließt den eingefangenen FD im CancelHandler. AgentWorkspaceStore ist bewusst lock-geschützt und @unchecked Sendable; das ist gezielt zu auditieren, nicht reflexartig in einen Actor umzuschreiben. @unchecked Sendable, @preconcurrency und assumeIsolated nur mit dokumentierter Invariante, nicht als Warnungsunterdrückung. Aufwand L.

Quellen: https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/EnableDataRaceSafety.md, https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/IncrementalAdoption.md, https://developer.apple.com/videos/play/wwdc2024/10169/, https://github.com/migueldeicaza/SwiftTerm/blob/v1.99.0/Sources/SwiftTerm/Documentation.docc/MigratingFrom1To2.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/FileEventSource.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift

### 3. State-Management: Observation, ObservableObject, Re-Render-Kontrolle und God-Views?

**Konfidenz:** hoch

Observation verfolgt während body gelesene Properties; eine Änderung anderer Properties muss diese View nicht invalidieren. Computed Properties zählen über ihre tatsächlichen Zugriffe. Es ist aber weder automatische Thread-Sicherheit noch ein Heilmittel für eine View, die einen riesigen Workspace-Wert und zahlreiche globale Dienste liest.

Ghosttys App verwendet weiter ObservableObject mit @Published für App-/Config-Lifecycle und eine native Surface-Brücke. CodeEdits Settings veröffentlicht ein großes preferences-Struct. Ice reicht objectWillChange mehrerer Manager an AppState weiter. Diese Codebefunde widerlegen die Annahme, große Referenzapps seien durchgehend auf Observation migriert; besonders Ices breite Weiterleitung ist kein übertragbares Vorbild.

WhisperM8 ist mit dauerhaftem Workspace, separatem UI-Sidecar, ephemerem Runtime-Status und gezielten Row-Abonnements bereits feiner aufgestellt. Beibehalten. Gleichzeitig veröffentlicht AgentWorkspaceUIModel den ganzen workspace-Wert; wie viele Bodies dadurch neu auswerten, muss gemessen werden. Die 3.816-zeilige AgentChatsView trotz vieler Extensions zeigt weiter zu viele Verantwortlichkeiten.

Empfehlung: Sidebar-, Tab-/Grid- und Inspector-Hosts mit schmalen Inputs; fensterbezogene Commands/Lifecycle-Koordinatoren als echte Typen; teure Fakten außerhalb von body/contextMenu vorberechnen. PTY-View-Identität stabil halten, damit State-Zerlegung keine Terminals neu erzeugt. Status-Ticks dürfen nicht das gesamte Grid neu auswerten; dies als Performance-Regressionsfall prüfen. Nicht alle ObservableObject-Typen rein kosmetisch migrieren. Aufwand L, mit bereits vorhandenen reinen Resolvern als Muster.

Quellen: https://developer.apple.com/videos/play/wwdc2023/10149/, https://developer.apple.com/videos/play/wwdc2023/10160/, https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/macos/Sources/Ghostty/Ghostty.App.swift, https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/CodeEdit/Features/Settings/Models/Settings.swift, https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Main/AppState.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/AgentChatsView.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift

### 4. Singletons versus Abhängigkeitsinjektion ohne Framework: Was skaliert?

**Konfidenz:** hoch

Nicht die Zahl shared entscheidet, sondern versteckte Abhängigkeiten, Lebensdauer und isolierte Testbarkeit. 47 exakt als static let shared deklarierte Instanzen sind im App-Verzeichnis bestätigt; die grobe Vorgabe „~50“ stimmt. Ein prozessweiter Socket-Server oder eine Store-Registry kann legitim sein; ein Fachservice, der intern fünf weitere Singletons aufruft, ist schwerer kontrollierbar.

Ghostty erzeugt seine App-Laufzeit explizit und nutzt einen schwachen Delegate für Surface-Auflösung. CodeEdit besitzt World mit ShellClient, aber currentWorld ist ein veränderliches Global: eine Test-Seam, keine automatische Isolation paralleler Tests. Ice verbindet Manager über AppState-Rückreferenzen und breite Änderungsweitergabe. iTerm2 dokumentiert getrennte Lifecycle-Schichten sowie Delegates/Closures statt Zyklen. Keines dieser Muster rechtfertigt einen DI-Framework-Wechsel.

WhisperM8s bestehende Closures und kleine Protokolle beibehalten. Im App-Einstieg einen expliziten, bei Bedarf lazy komponierten Service-Graph erstellen. Pro Feature kleine Dependencies-Werte mit .live-Default; Zeit, Dateisystem, Prozessausführung und externe Events injizieren. Fenster- und Session-Lebensdauer nicht in denselben globalen Container pressen. Neue Fachlogik ohne .shared-Zugriffe; alte shared-Einstiege vorerst als Kompatibilitätsfassade behalten. Keine globale Test-Umschaltung als Ersatz für Instanz-Injektion.

Das ist eine inkrementelle Maßnahme M pro priorisiertem Subsystem, kein Alles-oder-nichts-Abbau von 47 Instanzen.

Quellen: https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/macos/Sources/Ghostty/Ghostty.App.swift, https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/CodeEdit/World.swift, https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Main/AppState.swift, https://github.com/gnachman/iTerm2/blob/master/AGENTS.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/swiftui-architektur.md

### 5. Persistenz: Eigener JSON-Store oder SwiftData/GRDB/SQLite?

**Konfidenz:** hoch

JSON ist für einen moderaten Workspace mit einem Schreiber weiterhin vertretbar. Der aktuelle Code besitzt bereits Lock-serialisierte Mutationen, Diff-Gating, Utility-Queue, atomaren Dateiaustausch, drei Generation-Backups und Terminate-Flush. Wichtigste Juli-Korrektur: firstDirtyAt und maxDebounceLatency = 2.0 begrenzen bereits das erneute Aufschieben des Saves. Die alte Empfehlung „Deadline ergänzen“ ist erledigt. Diese Deadline garantiert allerdings nicht, dass unter Queue-/I/O-Last nach exakt zwei Sekunden alles dauerhaft gespeichert ist.

Ein atomarer Austausch schützt vor einer halb geschriebenen Datei, nicht vor Verlust noch gepufferter Änderungen, und ist keine belegte Stromausfall-Durabilität. flush(reason:) bestätigt nur das Einreihen; der Code dokumentiert das SIGKILL-Fenster ausdrücklich. Externe Transkripte rekonstruieren nicht sämtliche Tab-, Namens-, Konto- oder Background-Bindungsdaten. Damit muss „kein Datenverlust“ aus W5 fachlich präzisiert werden.

SwiftData bietet VersionedSchema/SchemaMigrationPlan sowie leichte und eigene Migrationen. Das erspart nicht die Prüfung aller Altversionen und bringt ein anderes Modell-/Context-Lifecycle mit. GRDB bietet explizite SQL-Transaktionen und transaktionale, versionierte Migrationen; DatabasePool unterstützt WAL mit parallelen Lesern, DatabaseQueue ist der einfachere Start. Keine Variante macht uncommittete Änderungen crashfest.

Empfehlung: vor Launch JSON behalten, Schema-/Zukunftsversionen und Recovery sichtbar machen, kritische Aktionen mit Persistenzbestätigung versehen. Erst bei gemessenen Voll-Encode-/Query-Kosten oder notwendiger Mehrdatei-Transaktion GRDB hinter das vorhandene Repository setzen. Migration: unverändertes JSON-Backup, einmaliger transaktionaler Import, IDs/Anzahlen/Invarianten prüfen, erst danach umschalten; keine dauerhaften Dual-Writes. Aufwand M für Härtung, L–XL für DB-Migration.

Quellen: https://github.com/groue/GRDB.swift/blob/master/README.md, https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md, https://github.com/groue/GRDB.swift/blob/master/GRDB/Migration/DatabaseMigrator.swift, https://developer.apple.com/videos/play/wwdc2023/10195/, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/swiftui-architektur.md

### 6. Crash-Reporting und Telemetrie ohne eigenen Server: Was ist datenschutzfreundlich?

**Konfidenz:** mittel

Für den Launch empfiehlt sich lokale Diagnose statt automatischer Telemetrie: MetricKit-Diagnosen lokal speichern, gezielt gefilterte eigene OSLog-Einträge exportieren, Export-Inhalt anzeigen und erst durch den Nutzer weitergeben lassen. Pro Release Git-Commit, Build, Architektur und Binary-UUID samt passenden dSYMs archivieren. Ohne Symbols ist auch ein guter Crashreport häufig kaum handlungsfähig.

Die gelesenen MetricKit-SDK-Header erlauben MXMetricManager und Diagnose-Payloads ab macOS 12 und warnen vor nicht garantierter Zustellung. Juli bleibt deshalb richtig: Ein signierter/notarisierter, über Brew verteilter Build muss außerhalb des Debuggers einen kontrollierten Fixture-Crash bis zur Symbolisierung nachweisen. Die API-Verfügbarkeit beweist keine zuverlässige Zustellung auf jeder Maschine. Neu seit WWDC26 ist eine Swift-native MetricManager-/AsyncSequence-API; deren genaue Deployment-Verfügbarkeit wurde hier nicht abschließend verifiziert. Sie darf nicht ungeprüft die macOS-14-Baseline ersetzen.

Neue relevante Korrektur für WhisperM8: Logger.info behauptet im Kommentar dauerhafte Persistenz durch .info. Apples Logging-Dokumentation garantiert das nicht; info wird überwiegend nicht persistiert. Seltene forensisch notwendige Ereignisse passend als notice/error protokollieren. Logger.info/debug markieren außerdem einen bereits zusammengebauten String vollständig public; sensible Werte können danach nicht mehr einzeln redigiert werden. Strukturierte Logger-Aufrufe und Inhalts-Allowlist statt blindem Voll-Log-Export.

Sentry ist optional später sinnvoll, aber sein HTTP-Transport speichert und versendet Envelopes. Erst nach Zustimmung initialisieren; Replay, Screenshots, automatische Performance-/Session-Erfassung und sensible Breadcrumbs bewusst deaktivieren bzw. filtern. Nicht als „serverlos und ohne Datenabfluss“ darstellen. KSCrash aus Juli nur neu bewerten, falls Systemdiagnose die Abnahme nicht besteht; keinen zweiten Crashhandler ungeprüft stapeln. Aufwand M.

Quellen: https://developer.apple.com/videos/play/wwdc2020/10168/, https://developer.apple.com/videos/play/wwdc2026/222/, https://developer.apple.com/documentation/metrickit/monitoring-app-performance-with-metrickit, https://github.com/getsentry/sentry-cocoa/blob/main/Sources/Swift/Options.swift, https://github.com/getsentry/sentry-cocoa/blob/main/Sources/Sentry/SentryHttpTransport.m, /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/MetricKit.framework/Versions/A/Headers/MXMetricManager.h, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/Logger.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/tech-observability-secrets.md

### 7. Terminal-Rendering: SwiftTerm versus libghostty-Einbettung, Stand Oktober 2026?

**Konfidenz:** hoch

Swift kann libghostty heute tatsächlich verwenden: Im offiziellen Ghostty-Repository existiert example/swift-vt-xcframework mit SwiftPM-binaryTarget und funktionsfähigem C-API-Aufrufbeispiel. Es erstellt einen VT-Terminalzustand, speist Sequenzen ein und exportiert Plaintext. Das ist ausdrücklich kein fertiger SwiftUI-/AppKit-Terminal-View. Ghosttys eigene Swift-App nutzt die breitere GhosttyKit-C-Brücke mit Surface-, Clipboard- und Lifecycle-Callbacks. Der aktuelle README sagt weiter: keine libghostty-Versionstags, API-Signaturen im Fluss. Fazit: Swift-Einbettbarkeit ja; stabil versioniertes Drop-in-Produkt als SwiftTerm-Ersatz nein.

Wichtiger neuer Befund: SwiftTerm v1.99.0 vom 08.10.2026 ist laut Release-Text der API-brechende Übergang zu 2.0. Der Code besitzt eine begrenzte zweistufige PTY-Gather-/Parse-Pipeline. Der Migrationsleitfaden entfernt rohe TerminalView→Terminal-Zugriffe zugunsten kopierter Snapshots und Commands, ändert die Default-Callback-Queue bei nil auf eine private serielle Queue und beschreibt directDelivery. Selection-Erhalt wurde mit PR 661 upstream bearbeitet. Ob dies WhisperM8s zwei Fork-Patches vollständig ersetzt, wurde nicht durch Tests bewiesen.

Empfehlung: bestehenden v1.15-Fork für Launch stabil halten; zuerst isolierten SwiftTerm-Upgrade-Vergleich durchführen, nicht blind auf latest springen. Abnahme umfasst Scroll-Lock, Selection während Streaming, Paste/Send-Guard, ClipboardRead-Verweigerung, Links, IME/CJK, Accessibility, Multi-Pane-Last, Resize und Teardown. Metal bleibt bis A/B-Messung opt-in. libghostty nur bei versionierter API und belastbarem Performance-/Qualitätsvorteil erneut entscheiden; ADR bleibt maßgeblich.

Juli-Korrektur: Empfehlungen zum Ausbau von TerminalSnapshotStore sind überholt; die aktuelle Vollhistorie kommt aus JSONL/TextKit-2-Transkripten. Aufwand M für Spike, L für eventuelles SwiftTerm-Upgrade, XL für Engine-Wechsel.

Quellen: https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/README.md, https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/example/swift-vt-xcframework/Package.swift, https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/example/swift-vt-xcframework/Sources/main.swift, https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.99.0, https://github.com/migueldeicaza/SwiftTerm/blob/v1.99.0/Sources/SwiftTerm/TerminalIOPipeline.swift, https://github.com/migueldeicaza/SwiftTerm/blob/v1.99.0/Sources/SwiftTerm/Documentation.docc/MigratingFrom1To2.md, https://github.com/migueldeicaza/SwiftTerm/pull/661, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Package.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/adr/0001-kein-stack-wechsel.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/tech-terminal-persistenz.md, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/terminal-pty.md

### 8. Prozess-Spawning aus GUI-Apps: PATH, Login-Shell-Environment, Pipes, posix_spawn und close-on-exec?

**Konfidenz:** hoch

Ein zentraler Spawn-Vertrag sollte Binary-Pfad, argv, cwd, Environment-Policy, I/O-Limits, Timeout/Cancellation und Exit-Reaping festlegen. Headless-Tools mit absolutem Binary und getrenntem argv starten; keine aus Nutzerdaten zusammengesetzte Shell-Zeichenkette. stdout und stderr gleichzeitig drainen, stdin schließen, wenn fertig; Ausgabe-/Puffergrößen begrenzen. Prozessende und EOF getrennt erwarten. TERM/COLORTERM nur passend zum Terminal-Kontext setzen. PTY benötigt zusätzlich controlling terminal, termios, Resize sowie definierte Signal-/Prozessgruppen-Ownership.

WhisperM8 hat bereits gute Grundlagen: gecachter Login-PATH mit Homebrew-/~/.local/bin-Fallback, explizites Strippen fremder Konto-Stempel, O_CLOEXEC für File-Watches und Lock, FD_CLOEXEC für Serververbindungen sowie SIGPIPE-Schutz ohne dauerhaft vererbtes SIG_IGN. Apples posix_spawn-Vertrag bestätigt: offene FDs bleiben ohne close-on-exec oder passende File-Actions im Kind erhalten. Ein Wechsel von Process zu posix_spawn allein löst weder Descriptor- noch Lifecycle-Probleme.

Konkrete statische Schwachstelle: queryLoginShellPath wartet vor dem Lesen von stdout auf Prozessende, legt stderr ebenfalls auf eine ungelesene Pipe und besitzt kein Zeitlimit. Eine .zprofile mit ausreichend Ausgabe kann den Pipe-Puffer füllen; Kind und Eltern warten dann gegenseitig. Das wurde am Code nachvollzogen, nicht zur Laufzeit provoziert. PATH-Probe off-main, mit parallel drainierten Streams, Zeit-/Ausgabelimit und garantiertem Fallback implementieren. Shell-Startup ist beliebiger Nutzercode, nicht garantiert eine kurze Abfrage.

Environment getrennt behandeln: minimale Allowlist für interne Hilfsprozesse und Proxy; interaktive Agent-Shells dürfen bewusst freigegebene Nutzer-/Toolvariablen brauchen. Keine globale Allowlist, die unbemerkt MCP-/Entwicklerumgebungen zerstört. Neu gegenüber Juli ist swift-subprocess final 1.0.2 mit Swift-6.2-/macOS-13-Basis: geeigneter Pilot hinter dem Headless-Runner, kein Anlass den PTY-Pfad umzubauen. Aufwand M, Lifecycle-Tests erforderlich.

Quellen: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html, https://github.com/swiftlang/swift-subprocess/releases/tag/1.0.2, https://github.com/swiftlang/swift-subprocess/blob/1.0.2/Package.swift, https://github.com/swiftlang/swift-subprocess/blob/main/README.md, https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/CodeEdit/Utils/ShellClient/Models/ShellClient.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/LoginShellEnvironment.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/FileEventSource.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/SigpipeGuard.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentControlServer.swift

## Übertragbar auf WhisperM8

### B3-R01 · PATH-Probe und Headless-Prozesse gegen Blockaden härten

*Priorität hoch · Aufwand M · Features F-AC-02, F-DIK-09, F-APP-01, F-APP-08 · Entscheidung E5/E6*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/LoginShellEnvironment.swift stdout/stderr während der Laufzeit drainen, Timeout und Ausgabegrenzen einführen, gecachten Fallback sicherstellen und Main-Thread-Aufrufe verhindern. Anschließend Headless-Spawns schrittweise hinter einen gemeinsamen Runner ziehen; swift-subprocess 1.0.2 als Pilot prüfen. Tests für laute Shell-Profile, hängende Kinder, frühes Exit/EPIPE, Cancellation und geerbte FDs.

**Begründung:** Die aktuelle Wait-before-read-Reihenfolge kann bei genügend Startup-Ausgabe deadlocken; ein fehlendes Zeitlimit kann einen kalten Start unbeschränkt verzögern. Das gefährdet Kernwege unabhängig davon, ob die aufrufende Funktion async heißt.

Quellen: https://github.com/swiftlang/swift-subprocess/releases/tag/1.0.2, https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/LoginShellEnvironment.swift

### B3-R02 · Forensische Logs wirklich dauerhaft und inhaltsarm machen

*Priorität hoch · Aufwand S · Features F-APP-08, F-DEV-01 · Entscheidung E6*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/Logger.swift die Annahme „info ist persistent“ korrigieren. Seltene unverzichtbare Lifecycle-/Crash-Vorläufer gezielt auf notice/error heben; public-Gesamtstrings durch strukturierte Aufrufe mit einzelner Privacy-Klassifizierung ersetzen. Export nur eigener, erlaubter Ereignistypen und mit Vorschau.

**Begründung:** Apples dokumentiertes Verhalten widerspricht der Persistenzannahme im Code. Vollständig public markierte zusammengesetzte Meldungen verhindern nachträgliche feldweise Redigierung. Keine Aussage, dass damit bereits ein konkretes Secret-Leak bewiesen wäre.

Quellen: https://developer.apple.com/videos/play/wwdc2020/10168/, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/Shared/Logger.swift

### B3-R03 · Lokale Diagnose und Symbolisierungs-Abnahme vorsehen

*Priorität hoch · Aufwand M · Features F-APP-08, F-DEV-01, F-AC-09 · Entscheidung E4/E6*

MetricKit hinter einem lokalen Diagnose-Service integrieren; begrenzte Retention, keine Prompts/Audio/Transkripte/Environment-Dumps. Passende dSYMs und UUID-Manifest je Release archivieren. Einen signierten/notarisierten Brew-Build außerhalb des Debuggers gezielt abstürzen lassen und Empfang, Export sowie Symbolisierung nachweisen. Falls Zustellung unzureichend ist, separaten lokalen Recorder evaluieren; Sentry erst nach eigener Opt-in-Entscheidung.

**Begründung:** Ohne verifizierte Zustellung und Symbols ist „Crash-Reporting vorhanden“ kein belastbarer Supportweg. Die neue MetricManager-API darf die macOS-14-Unterstützung nicht ungeprüft einschränken.

Quellen: https://developer.apple.com/documentation/metrickit/monitoring-app-performance-with-metrickit, https://developer.apple.com/videos/play/wwdc2026/222/, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-07-agent-chats-deep-dive/03-vergleich/tech-observability-secrets.md

### B3-R04 · Persistenzgarantien an kritischen Aktionen explizit machen

*Priorität hoch · Aufwand M · Features F-AC-01, F-AC-03, F-AC-09, F-KO-01 · Entscheidung E6/W5*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift und AgentWorkspaceRepository.swift zwischen „im Speicher angewendet“, „Save eingereiht“ und „gespeichert“ unterscheiden. Für kritische strukturelle Änderungen eine asynchrone Bestätigung nach erfolgreicher Persistenz ermöglichen; Migrationen, Zukunftsversionen und Recovery sichtbar behandeln. Crash-Tests unmittelbar nach Erstellen, Umbenennen, Account-Move und Tab-Änderung planen.

**Begründung:** Der bestehende 2-s-Debounce-Deckel ist bereits umgesetzt und darf nicht erneut als offener Befund geführt werden. Er beseitigt nicht das dokumentierte Verlustfenster gepufferter Daten; das kollidiert mit einer wörtlichen Null-Datenverlust-Garantie.

Quellen: /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md

### B3-R05 · Strict-Concurrency-Baseline statt Big-Bang-Migration

*Priorität hoch · Aufwand L · Features F-APP-08, F-AC-02, F-AC-05, F-AC-06, F-DIK-01 · Entscheidung E6*

Complete Checking zunächst als Diagnose-/CI-Baseline aufnehmen; globale mutable Zustände und Callback-/FD-Lifecycle nach Risiko ordnen. Kleine Targets anschließend einzeln auf Swift 6 umstellen. Für @unchecked Sendable, MainActor.assumeIsolated und @preconcurrency jeweils Schutzinvariante dokumentieren; keine neuen pauschalen Unterdrückungen akzeptieren.

**Begründung:** Die App verbindet Locks, DispatchSources, PTYs und SwiftUI. Sicherheit entsteht durch eindeutige Eigentümerschaft, nicht durch einen Compiler-Bump oder flächendeckendes MainActor.

Quellen: https://github.com/swiftlang/swift-migration-guide/blob/main/Guide.docc/EnableDataRaceSafety.md, https://developer.apple.com/videos/play/wwdc2024/10169/

### B3-R06 · Wenige fachliche SwiftPM-Targets schrittweise extrahieren

*Priorität mittel · Aufwand L · Features F-AC-01, F-AC-05, F-AC-08, F-DIK-01, F-DIK-09 · Entscheidung ADR 0001/E6*

In /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Package.swift zuerst Core, dann Process, danach AgentChatsCore und DictationCore abgrenzen. API-Fläche klein und Graph azyklisch halten; UI-/PTY-Brücken zunächst nicht mitverschieben. Clean-/Incremental-/Testzeiten vor und nach jedem Schritt vergleichen.

**Begründung:** Bei bestätigten 99.413 Swift-Zeilen werden Ordnerkonventionen zu schwach. Hauptgewinn sind erzwungene Grenzen und unabhängige Migration; konkrete Buildzeitgewinne sind hier nicht gemessen.

Quellen: https://developer.apple.com/videos/play/wwdc2024/10171/, https://github.com/CodeEditApp/CodeEdit/blob/fa2aebd86373211c78626074b53ab75010767575/CodeEdit.xcodeproj/project.pbxproj, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Package.swift

### B3-R07 · AgentChatsView nach Verantwortung statt Dateigröße zerlegen

*Priorität mittel · Aufwand L · Features F-AC-01, F-AC-02, F-AC-03, F-AC-04 · Entscheidung E6*

Aus /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/AgentChatsView.swift echte Sidebar-/Grid-/Tab-Hosts und fensterbezogene Lifecycle-/Command-Typen extrahieren. Kleine Dependencies-Strukturen statt neuer direkter shared-Zugriffe; PTY-Identität und alle bestehenden Interaktionen durch Inventar und gezielte QA erhalten.

**Begründung:** Weitere Extensions verkürzen Dateien, aber nicht den Abhängigkeitsgraph. Observation hilft nur, wenn die View schmale Datenzugriffe hat. 1.500 Zeilen sind ein Warnsignal, keine ausreichende Qualitätsmetrik.

Quellen: https://developer.apple.com/videos/play/wwdc2023/10149/, https://developer.apple.com/videos/play/wwdc2023/10160/, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Views/AgentChatsView.swift

### B3-R08 · SwiftTerm-2-Übergang vor libghostty-Wechsel untersuchen

*Priorität mittel · Aufwand M · Features F-AC-02, F-AC-03, F-AC-04, F-AC-10, F-DEV-01 · Entscheidung ADR 0001/E6*

Isolierten Upgrade-Spike von dem in /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/Package.swift gepinnten 1.15-Fork auf den v1.99/2.0-API-Pfad planen. Änderungen an Callback-Queues, rohen Terminal-Zugriffen, Paste und Clipboard-Schutz inventarisieren; Selection-Fork-Patches erst nach Verifikation entfernen. Bestehenden Launch-Pin und Metal-opt-in bis erfolgreicher Abnahme behalten.

**Begründung:** Upstream adressiert inzwischen Ownership, I/O und Selection direkt. Ein neuer Renderer ist kein belegter Performancegewinn und ein API-Bump trotz Versionsnummer 1.99 nicht risikolos.

Quellen: https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.99.0, https://github.com/migueldeicaza/SwiftTerm/blob/v1.99.0/Sources/SwiftTerm/Documentation.docc/MigratingFrom1To2.md, https://github.com/migueldeicaza/SwiftTerm/blob/v1.99.0/Sources/SwiftTerm/TerminalIOPipeline.swift, https://github.com/ghostty-org/ghostty/blob/e3ebb1d1bf772cf5d1bc70b5ae19e6943e33a110/README.md

### B3-R09 · Datenbankmigration nur durch Messwerte auslösen

*Priorität niedrig · Aufwand XL · Features F-AC-01, F-AC-03, F-AC-05, F-KO-01 · Entscheidung E6*

JSON zunächst behalten. Ein GRDB-Prototyp ist erst sinnvoll, wenn Voll-Encode-/Abfragekosten, atomare Mehrdateiänderungen oder Workspace-Wachstum einen konkreten Bedarf belegen. Dann Repository-API erhalten, Import transaktional und rückkehrbar gestalten; keine parallelen dauerhaften JSON-/DB-Schreiber.

**Begründung:** GRDB liefert klare Transaktionen und Migrationen, aber ein neuer Speicher beseitigt weder fachliche Mutationsfehler noch uncommittete Daten. SwiftData wäre ebenfalls ein Modell-/Lifecycle-Umbau und kein kostenloses Upgrade.

Quellen: https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md, https://developer.apple.com/videos/play/wwdc2023/10195/, /Users/giulianocosta/repos/whisperm8/.claude/worktrees/launch-readiness/WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift
