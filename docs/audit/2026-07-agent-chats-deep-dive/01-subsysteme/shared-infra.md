# Shared-Infrastruktur & App-Shell

Audit-Stand: 2026-07-18. Gegenstand sind die gemeinsam genutzten Infrastrukturtypen,
der GUI-Start und das Fenster-Routing; Diktat- und Agent-Chat-Services werden nur dort
einbezogen, wo sie diese Infrastruktur unmittelbar konsumieren.

## 1. Zweck & Verantwortung

Das Subsystem bildet die Composition Root der GUI, hält prozessweite App- und
Preference-Zustände, routet SwiftUI-Fenster, vereinheitlicht Subprozess-Umgebungen und
kapselt Betriebssystemdienste wie Keychain, Berechtigungen, FSEvents, Logging und
Update-Prüfung (`WhisperM8/WhisperM8App.swift:11-113`,
`WhisperM8/Models/AppState.swift:21-52`,
`WhisperM8/Support/AppPreferences.swift:3-14`,
`WhisperM8/Services/Shared/WindowRequestCenter.swift:65-123`). Für Claude Code ist
insbesondere die bereinigte Login-Shell-Umgebung zentral: Sie entfernt geerbte
`CLAUDE_CODE_*`, `CLAUDECODE` und `CLAUDE_CONFIG_DIR`, setzt den aufgelösten `PATH` und
ergänzt Terminal-/Locale-Defaults (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`).

## 2. Datenfluss & Trigger

### App-Start-Sequenz

1. Der einzige `@main`-Typ entscheidet anhand von `argv[0]` beziehungsweise dem ersten
   Subcommand zwischen CLI und GUI; nur der GUI-Zweig ruft `WhisperM8App.main()` auf
   (`WhisperM8/CLI/CLIEntryPoint.swift:12-21`,
   `WhisperM8/CLI/CLIEntryPoint.swift:27-48`).
2. `WhisperM8App.init` prüft über laufende Bundle-Instanzen auf einen zweiten Prozess,
   aktiviert eine gefundene Instanz, sendet ihr eine Distributed Notification und
   terminiert sich; anschließend werden die globalen Aufnahme-Hotkeys registriert
   (`WhisperM8/WhisperM8App.swift:15-28`, `WhisperM8/WhisperM8App.swift:101-112`).
3. Vor dem ersten Fenster wählt `applicationWillFinishLaunching` anhand von
   Mikrofon-/Accessibility-Status und Nutzungsprofil zwischen `.regular` und
   `.accessory` (`WhisperM8/WhisperM8App.swift:201-218`).
4. Die erste Scene ist bewusst ein einzelnes Agent-Chats-`Window`; daneben existieren
   die wertgebundene `WindowGroup` für abgelöste Chats, `MenuBarExtra`, Settings und
   Onboarding (`WhisperM8/WhisperM8App.swift:30-99`). Das Primärfenster prüft das
   Profil-Gate und bezieht seine ID aus `AgentWindowStore`, Sekundärfenster akzeptieren
   nur IDs, die der Store kennt (`WhisperM8/WhisperM8App.swift:116-191`).
5. `applicationDidFinishLaunching` installiert den SIGTERM-Handler und den
   Notification-Delegate, fordert Notification-Rechte an und plant Update- sowie
   Theme-Synchronisierung (`WhisperM8/WhisperM8App.swift:220-253`). Danach starten drei
   detached Vorarbeiten: Retention, CLI-Symlink und Login-Shell-/CLI-Prewarm
   (`WhisperM8/WhisperM8App.swift:255-279`).
6. Anschließend werden auf dem Launch-Pfad Session-Scan, Directory-FSEvents,
   Subagent-Job-Sync und der verzögerte Summary-Abgleich angestoßen
   (`WhisperM8/WhisperM8App.swift:281-298`). Fehlen Mikrofon oder Accessibility, folgt
   nach 500 ms ein Onboarding-Request (`WhisperM8/WhisperM8App.swift:300-311`).
7. Beim Beenden sperrt die App zunächst Fenster-Close-Tracking und nimmt
   Terminal-Snapshots auf; im letzten Delegate-Hook werden Audio-Ducking beendet und
   der Fensterzustand synchron geflusht (`WhisperM8/WhisperM8App.swift:336-360`).

### Szenen-Routing über `WindowRequestCenter`

- `WindowRequest` bildet `.settings` und `.settingsOutput` auf dieselbe Window-ID, aber
  verschiedene Settings-Routen ab; Agent Chats und Onboarding besitzen eigene IDs
  (`WhisperM8/Services/Shared/WindowRequestCenter.swift:4-40`).
- `request(_:)` gibt bei einem expliziten Agent-Chats-Wunsch das Primärfenster frei,
  publiziert `latestRequest` und sendet zusätzlich eine lokale Notification
  (`WhisperM8/Services/Shared/WindowRequestCenter.swift:115-123`). Der im
  `MenuBarExtra`-Label montierte `AppWindowRequestHost` hält den Handler im View-Baum
  (`WhisperM8/WhisperM8App.swift:70-78`,
  `WhisperM8/Services/Shared/WindowRequestCenter.swift:262-266`).
- `WindowRequestHandler` übersetzt die drei Published-Ströme in `openWindow` und
  App-Aktivierung. Beim ersten Erscheinen stellt er nur persistierte Sekundärfenster
  des Full-Profils wieder her (`WhisperM8/Services/Shared/WindowRequestCenter.swift:205-259`).
- Settings liest denselben Published-Wert sowohl beim Erscheinen als auch fortlaufend
  und mappt ihn auf Seite und Untertab (`WhisperM8/Views/SettingsView.swift:104-109`,
  `WhisperM8/Views/SettingsView.swift:143-163`).
- Ein Notification-Klick validiert die Session durch einen Workspace-Load, mutiert
  Tab, Auswahl und Expand-Zustand im `AgentWindowStore` und publiziert erst danach den
  konkreten Fensterfokus (`WhisperM8/Services/Shared/WindowRequestCenter.swift:125-168`).
  Der AppDelegate reicht die lokale Session-ID auf dem MainActor dorthin weiter
  (`WhisperM8/WhisperM8App.swift:386-400`).
- Der zweite Prozess postet die Distributed Notification; der Singleton-Observer der
  laufenden Instanz wandelt sie auf dem MainActor in `.agentChats` um
  (`WhisperM8/Services/Shared/WindowRequestCenter.swift:69-75`,
  `WhisperM8/Services/Shared/WindowRequestCenter.swift:93-107`,
  `WhisperM8/Services/Shared/WindowRequestCenter.swift:191-201`).

### Login-Shell-PATH: Ermittlung und Konsumenten

`LoginShellEnvironment.path` prüft einen NSLock-geschützten Cache, führt bei einem Miss
`/bin/zsh -l -c "echo $PATH"` aus, mischt das Ergebnis dedupliziert mit dem statischen
Fallback und cached das Resultat (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:47-80`,
`WhisperM8/Services/Shared/LoginShellEnvironment.swift:146-186`). Der App-Start wärmt
PATH sowie `which claude/codex` detached vor; ein Chat-Start wiederholt denselben Warmup
vor der Command-Erzeugung off-main (`WhisperM8/WhisperM8App.swift:270-279`,
`WhisperM8/Views/AgentSessionDetailView.swift:382-397`).

Die wichtigsten Verbraucher sind:

| Verbraucher | Nutzung |
|---|---|
| CLI-Auflösung | `/usr/bin/which` erhält `processEnvironment()`; gefundene Pfade werden separat gecached (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:388-446`). |
| Claude-/Codex-PTY | `terminalEnvironmentArray()` wird vor dem SwiftTerm-Start mit session-spezifischen Overrides gemischt (`WhisperM8/Views/AgentTerminalView.swift:749-771`). |
| Claude-Background-Agent | Der `Process` bekommt die Basisumgebung plus `NO_COLOR`/`CLICOLOR` (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:240-258`). |
| Headless Summary | Resolver und Runner verwenden Command-Cache und bereinigte Prozessumgebung (`WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:7-18`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:27-43`). |
| Codex-Nachbearbeitung | Der detached Codex-Prozess erhält dieselbe Umgebung (`WhisperM8/Services/Dictation/CodexPostProcessor.swift:55-84`). |
| CLI-Transkription/-Extraktion | Auch der gemeinsame Binary-CLI-Pfad konsumiert `processEnvironment()` beziehungsweise `path` (`WhisperM8/CLI/CLIAudioExtractor.swift:196-221`). |

## 3. Zentrale Typen & Zustände

| Typ/Zustand | Verantwortung und Lebensdauer |
|---|---|
| `WhisperM8EntryPoint` | Prozessweiter CLI/GUI-Multiplexer (`WhisperM8/CLI/CLIEntryPoint.swift:12-21`). |
| `WhisperM8App` / `AppDelegate` | Scene-Deklaration, Hotkeys, Launch-/Reopen-/Terminate-Orchestrierung (`WhisperM8/WhisperM8App.swift:11-113`, `WhisperM8/WhisperM8App.swift:194-370`). |
| `AgentChatsPrimaryWindowRoot` / `AgentChatsSecondaryWindowRoot` | Profil-Gate und Validierung persistierter Fenster-IDs (`WhisperM8/WhisperM8App.swift:116-191`). |
| `WindowRequestCenter` | `@MainActor`-Singleton mit `latestRequest`, Session-/Fensterfokus und Primärfenster-Gate (`WhisperM8/Services/Shared/WindowRequestCenter.swift:65-95`). |
| `AppProfileActivator` | Persistiert Profil, ändert Activation Policy und koordiniert das Schließen aller Agent-Fenster (`WhisperM8/Services/Shared/AppProfileActivator.swift:4-17`, `WhisperM8/Services/Shared/AppProfileActivator.swift:19-41`). |
| `AppState` | Globaler `@MainActor @Observable`-Diktat-/Kontextzustand; delegiert Operationen an einen privaten `RecordingCoordinator` (`WhisperM8/Models/AppState.swift:21-59`, `WhisperM8/Models/AppState.swift:88-135`). |
| `AppPreferences` | Werttyp-Fassade über `UserDefaults`; das global austauschbare `static var shared` trägt Defaults, Migrationen, Agent- und Update-Schalter (`WhisperM8/Support/AppPreferences.swift:3-14`, `WhisperM8/Support/AppPreferences.swift:219-328`, `WhisperM8/Support/AppPreferences.swift:359-371`). |
| `LoginShellEnvironment` | `@unchecked Sendable`-Singleton, PATH-Cache und ENV-Hygiene für alle Kindprozesse (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:22-55`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:82-143`). |
| `KeychainManager` | Generisches Passwort-Service `com.whisperm8.app` mit prozessweitem String-Cache und UserDefaults-Migration (`WhisperM8/Services/Shared/KeychainManager.swift:4-9`, `WhisperM8/Services/Shared/KeychainManager.swift:37-69`). |
| `PermissionService` | Status, Requests und System-Settings-Deep-Links für Mikrofon, Accessibility und Screen Recording (`WhisperM8/Services/Shared/PermissionService.swift:6-53`). |
| `FileEventSource` | `@MainActor`-Wrapper um eine vnode-DispatchSource samt FD-Lifecycle (`WhisperM8/Services/Shared/FileEventSource.swift:3-29`, `WhisperM8/Services/Shared/FileEventSource.swift:31-70`). |
| `PerfSignposts` / `PerformanceBudget` / `PerfBudgets` | Signposter, strukturierte Intervalle und feste Budgets für Recording, Store, Sidebar und Grid (`WhisperM8/Services/Shared/PerformanceSignposts.swift:4-14`, `WhisperM8/Services/Shared/PerformanceSignposts.swift:16-94`, `WhisperM8/Services/Shared/PerformanceSignposts.swift:96-128`). |
| `Logger` | Kategorie-Logger plus optionales Debug-File unter `~/Library/Logs/WhisperM8` (`WhisperM8/Services/Shared/Logger.swift:4-20`, `WhisperM8/Services/Shared/Logger.swift:22-69`). |
| `CLISymlinkInstaller` | Idempotenter Start-Installer für `~/.local/bin/whisperm8` auf das laufende App-Binary (`WhisperM8/Services/Shared/CLISymlinkInstaller.swift:3-40`). |
| `AppUpdateChecker` | `@MainActor ObservableObject` mit Zustandsautomat, 10-s-Initialcheck, 24-h-Timer und In-flight-Deduplizierung (`WhisperM8/Services/Shared/AppUpdateChecker.swift:11-60`, `WhisperM8/Services/Shared/AppUpdateChecker.swift:94-127`). |

## 4. Threading-Modell & Invarianten

- `AppState`, `WindowRequestCenter`, `FileEventSource`, `AppProfileActivator` und
  `AppUpdateChecker` sind explizit MainActor-isoliert
  (`WhisperM8/Models/AppState.swift:21-23`,
  `WhisperM8/Services/Shared/WindowRequestCenter.swift:65-66`,
  `WhisperM8/Services/Shared/FileEventSource.swift:7-8`,
  `WhisperM8/Services/Shared/AppProfileActivator.swift:11-12`,
  `WhisperM8/Services/Shared/AppUpdateChecker.swift:11-12`). Die File-Event-Source
  liefert ihre Events auf `.main` und schließt den FD im Cancel-Handler
  (`WhisperM8/Services/Shared/FileEventSource.swift:39-59`).
- Teure Launch-Arbeit wird überwiegend in detached Tasks ausgelagert; Scan und Job-Sync
  lesen ihre Dateien ebenfalls detached, bevor sie auf den MainActor zurückkehren
  (`WhisperM8/WhisperM8App.swift:255-279`,
  `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:118-148`,
  `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:64-89`).
- Die beabsichtigte PATH-Invariante lautet „Loader einmal pro Prozess“. Der Cache selbst
  ist mit `NSLock` geschützt, der Loader läuft jedoch außerhalb des Locks; damit schützt
  die Implementierung den Wert, aber nicht die Einmaligkeit bei konkurrierenden Misses
  (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:47-80`).
- Keychain-Cache-Lesen und -Mutation sind NSLock-geschützt; die Security-Aufrufe selbst
  laufen synchron auf dem jeweiligen Aufrufer. Nur `exists` verbietet Authentication UI
  explizit, `load` nicht (`WhisperM8/Services/Shared/KeychainManager.swift:10-35`,
  `WhisperM8/Services/Shared/KeychainManager.swift:37-58`,
  `WhisperM8/Services/Shared/KeychainManager.swift:72-98`,
  `WhisperM8/Services/Shared/KeychainManager.swift:115-130`).
- Ein Performance-Token soll genau einmal enden: `ended` macht `end` und `cancel`
  idempotent, `withInterval` schließt per `defer` auch auf Throw-/Early-Return-Pfaden
  (`WhisperM8/Services/Shared/PerformanceSignposts.swift:29-41`,
  `WhisperM8/Services/Shared/PerformanceSignposts.swift:52-93`). Verletzungen loggen nur
  über `os.Logger`, damit optionales File-Logging nicht in den Hotpath gerät
  (`WhisperM8/Services/Shared/PerformanceSignposts.swift:16-22`,
  `WhisperM8/Services/Shared/PerformanceSignposts.swift:62-70`).
- Die Budgets reichen von 10 ms für UI-State-Saves über 16,7 ms für Grid-Streaming und
  30 ms für Store-Mutationen bis 400 ms für Recording-Start; Sidebar-Background-Indexing
  darf 2 s benötigen (`WhisperM8/Services/Shared/PerformanceSignposts.swift:99-127`).

## 5. Risiken & Schwachstellen

Es wurde kein belegbarer kritischer Fehler in diesem abgegrenzten Subsystem gefunden.

| Schweregrad | Datei:Zeile | Problem | Mögliche Wirkung |
|---|---|---|---|
| hoch | `WhisperM8/Services/Shared/LoginShellEnvironment.swift:166-184`; `WhisperM8/Views/AgentSessionDetailView.swift:382-397` | Die Login-Shell hat keinen Timeout und `waitUntilExit()` ist synchron. Der Chat-Warmup wartet vor der Command-Vorbereitung auf genau diesen Aufruf. | Eine blockierende oder interaktive Shell-Konfiguration kann den ersten Chat-Start unbegrenzt festhalten; der Launch-Prewarm verschiebt die Arbeit off-main, garantiert aber keinen Abschluss. |
| hoch | `WhisperM8/WhisperM8App.swift:294-298`; `WhisperM8/Services/AgentChats/AgentWindowStore.swift:39-65`; `WhisperM8/Services/AgentChats/AgentSessionStore.swift:45-110`; `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:246-252` | Die scheinbar leichte Planung des Summary-Abgleichs wertet `AgentWindowStore.shared.openTabIDsAtLaunch` synchron im Launch-Callback aus. Der Singleton-Init lädt Workspace und UI-State, dekodiert, migriert, vergleicht und kann repariert zurückschreiben. | Blocking beim App-Start wächst mit Workspace/UI-State; die parallel gestartete Retention ist kein Ordnungsvertrag und verhindert diesen MainActor-Load nicht. |
| mittel | `WhisperM8/Services/Shared/LoginShellEnvironment.swift:59-79`; `WhisperM8/WhisperM8App.swift:275-279`; `WhisperM8/Views/AgentSessionDetailView.swift:393-397` | Cache-Check und Loader sind kein atomisches Once. Launch-Prewarm und früher Chat-Warmup können beide einen Miss sehen und jeweils `zsh` sowie nachfolgende `which`-Prozesse starten. | Doppelte Prozess-Spawns, zusätzliche Last und kein tatsächlich garantiertes „einmalig“; der vorhandene Cache-Test deckt nur serielle Zugriffe ab. |
| mittel | `WhisperM8/Services/Shared/KeychainManager.swift:10-58`; `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:38-49`; `WhisperM8/Views/OnboardingView.swift:611-622`; `WhisperM8/Services/Dictation/RecordingCoordinator.swift:25-26`; `WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:8-23` | Jeder eingegebene API-Key-Zwischenstand löst synchron `SecItemUpdate` beziehungsweise `SecItemAdd` auf dem View-Pfad aus. `load` erlaubt im Gegensatz zu `exists` Authentication UI (`WhisperM8/Services/Shared/KeychainManager.swift:77-84`). | Tipp-Latenz und viele Keychain-Schreibzugriffe; ein Keychain-ACL-/Auth-Fall kann beim synchronen Load oder Save einen System-Prompt und MainActor-Stall verursachen. |
| mittel | `WhisperM8/Services/Shared/AppProfileActivator.swift:24-41`; `WhisperM8/Services/AgentChats/AgentWindowStore.swift:724-762` | Close-Tracking wird nach fest angenommenen 500 ms wieder aktiviert, obwohl der Kommentar selbst den asynchronen Fensterabbau als Grund nennt. Es gibt keine Bestätigung, dass alle `willClose`-Ereignisse vorher eingetroffen sind. | Unter Last können verspätete programmatische Closes als User-Closes behandelt und persistierte Sekundärfenster aus dem Store entfernt werden; Restore-Zustand geht verloren. |
| mittel | `WhisperM8/WhisperM8App.swift:15-25` | Die Single-Instance-Entscheidung ist ein nicht atomarer Snapshot über `runningApplications`; es existiert kein Prozess-Lock oder bestätigter Besitzer. | Bei nahezu gleichzeitigem Start können beide Prozesse den jeweils anderen sehen und sich beide terminieren; der Nutzer erlebt einen sporadisch fehlgeschlagenen Launch. |
| mittel | `WhisperM8/Services/Shared/WindowRequestCenter.swift:128-168` | `requestSessionFocus` lädt und durchsucht den gesamten Workspace synchron auf dem MainActor, bevor das Fenster geöffnet wird. | Notification-Klicks können mit großem Workspace verzögert reagieren; Routing, Persistenzzugriff und UI-Fokus sind eng gekoppelt. |
| mittel | `WhisperM8/Services/Shared/Logger.swift:24-64`; `WhisperM8/Support/AppPreferences.swift:79-82` | Optionales Debug-File-Logging führt Directory-Erzeugung, Existenzprüfung, Open, Seek und Write synchron pro Logzeile aus; die Dateioperationen sind nicht gemeinsam serialisiert. | Bei aktiviertem Debug-Logging blockieren Aufrufer auf Dateisystem-I/O; parallele Logs können sich zwischen Existenzprüfung und Append überholen und Zeilen verlieren oder überschneiden. |
| mittel | `WhisperM8/WhisperM8App.swift:242-298`; `WhisperM8/Support/AppPreferences.swift:3-14`; `WhisperM8/Models/AppState.swift:21-24`; `WhisperM8/Services/Shared/WindowRequestCenter.swift:65-67` | Die Composition Root greift direkt auf zahlreiche globale Singletons zu; `AppPreferences.shared` ist zusätzlich global austauschbar. Ownership, Startreihenfolge und Fehlerflächen sind dadurch implizit. | Launch-Sequenz und Profil-/Fensterwechsel sind nur schwer isoliert testbar; Seiteneffekte können zwischen Tests oder späteren Startup-Erweiterungen koppeln. |
| niedrig | `WhisperM8/Services/Shared/LoginShellEnvironment.swift:34-45`; `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:400-418` | Zwei getrennte PATH-Fallback-Listen driften bereits: der Command-Resolver kennt `~/.claude/local`, die an Kindprozesse vererbte Login-Shell-Fallback-Umgebung nicht. | Bei fehlgeschlagener Shell-Abfrage kann WhisperM8 das Claude-Binary absolut finden, dessen Kindprozesse erhalten aber einen anderen Suchpfad; künftige Pfadänderungen müssen doppelt gepflegt werden. |
| niedrig | `WhisperM8/Services/Shared/PerformanceSignposts.swift:33-40`; `WhisperM8/Services/Shared/PerformanceSignposts.swift:47-63` | Budgetdauer wird mit `Date` statt einer monotonen Uhr berechnet. | Systemzeitkorrekturen während eines Intervalls können Warnungen unterdrücken oder falsche Budgetverletzungen erzeugen; die Instruments-Signposts selbst bleiben davon unabhängig. |
| niedrig | `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:21-49`; `WhisperM8/WhisperM8App.swift:263-268` | Ein vorhandener, abweichender Symlink namens `whisperm8` wird ohne Ownership-Marker entfernt und durch das aktuelle Binary ersetzt; nur reguläre Dateien werden geschont. | Eine bewusst vom Nutzer verwaltete alternative Symlink-Installation wird beim App-Start überschrieben; bei Dev-Builds kann der Link anschließend auf ein kurzlebiges Build-Artefakt zeigen. |

## 6. Testabdeckung

### Vorhanden

- `LoginShellEnvironmentTests` deckt Merge/Deduplizierung, Nil-/Leer-Fallback,
  serielles Caching, Terminal-Defaults und die für Claude wichtigste Bereinigung von
  `CLAUDE_CODE_*`, `CLAUDECODE` und `CLAUDE_CONFIG_DIR` ab
  (`Tests/WhisperM8Tests/LoginShellEnvironmentTests.swift:8-159`).
- `PerformanceBudgetTests` prüft unter/über/genau am Budget, idempotentes `end` und
  strukturelles Ende bei synchronem Throw (`Tests/WhisperM8Tests/PerformanceBudgetTests.swift:28-98`).
- `WindowAndOverlayTests` prüft Request-Speicherung, Window-/Settings-Mapping und das
  Freigeben des Primärfensters (`Tests/WhisperM8Tests/WindowAndOverlayTests.swift:6-55`).
- `FileEventSourceTests` beobachtet echten Write und Delete sowie den Open-Fehler
  (`Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:5-57`).
- `AppUpdateCheckerTests` deckt Versionsvergleich, Brew-Kanal, Netzwerk-/Decode-Fehler
  und Release-URL-Fallback ab (`Tests/WhisperM8Tests/AppUpdateCheckerTests.swift:41-141`).
- `PreferencesTests` prüft Defaults, stabile Keys, Persistenz, Profilableitungen und die
  Screenshot-Migration mit isolierten `UserDefaults`-Suites
  (`Tests/WhisperM8Tests/PreferencesTests.swift:6-218`,
  `Tests/WhisperM8Tests/PreferencesTests.swift:272-505`).
- `PermissionSettingsModelTests` prüft die UI-Policy und Polling-Cancellation über
  injizierte Closures, nicht die realen System-APIs
  (`Tests/WhisperM8Tests/PermissionSettingsModelTests.swift:5-241`).
- Die Priorität der reinen `RecordingPhase.resolve`-Logik ist separat abgedeckt
  (`Tests/WhisperM8Tests/TranscriptionUtilityTests.swift:114-131`).

### Konkrete Lücken

- Kein Concurrent-Once-Test und kein Timeout-/hängende-Shell-Test für
  `LoginShellEnvironment`; der vorhandene Cache-Test ruft `path` dreimal seriell auf
  (`Tests/WhisperM8Tests/LoginShellEnvironmentTests.swift:33-43`).
- Keine direkten Tests für `KeychainManager`-Statuspfade, Migration, Cache-Kohärenz,
  Prompt-Unterdrückung oder konkurrierende Zugriffe; Produktionsaufrufe sind statisch
  und besitzen keinen injizierbaren Security-Client
  (`WhisperM8/Services/Shared/KeychainManager.swift:4-132`).
- Keine AppDelegate-/Scene-Integrationstests für Startreihenfolge, Single-Instance-Race,
  Onboarding-Routing, Restore und Terminate-Flush; die Window-Tests prüfen nur den
  Zustandscontainer, nicht `openWindow`/Distributed Notifications/Session-Fokus
  (`Tests/WhisperM8Tests/WindowAndOverlayTests.swift:13-55`,
  `WhisperM8/Services/Shared/WindowRequestCenter.swift:205-259`).
- Keine Tests für `AppProfileActivator.closeAgentChatWindows`, insbesondere nicht für
  verspätete Close-Callbacks jenseits von 500 ms
  (`WhisperM8/Services/Shared/AppProfileActivator.swift:19-41`).
- File-Event-Tests fehlen für Rename, wiederholtes Start/Stop, Re-Arm nach Gone und
  nachweisbare FD-Schließung im Cancel-/Deinit-Pfad
  (`Tests/WhisperM8Tests/AgentSessionEventWatchTests.swift:16-55`,
  `WhisperM8/Services/Shared/FileEventSource.swift:25-29`).
- Performance-Budget-Tests fehlen für `cancel`, async `withInterval`, Uhrsprünge und die
  konkreten Budgetwerte; derzeit wird ausschließlich ein synthetisches Store-Signpost
  verwendet (`Tests/WhisperM8Tests/PerformanceBudgetTests.swift:14-25`,
  `Tests/WhisperM8Tests/PerformanceBudgetTests.swift:28-98`).
- AppUpdate-Tests prüfen weder Timer-Scheduling/Kill-Switch noch überlappende
  `checkNow`-Aufrufe und `activeCheck`-Aufräumen
  (`WhisperM8/Services/Shared/AppUpdateChecker.swift:94-127`,
  `Tests/WhisperM8Tests/AppUpdateCheckerTests.swift:62-141`).
- Keine direkten Tests für `Logger.debug`, die Installationslogik von
  `CLISymlinkInstaller` oder die globale `AppState`-/`RecordingCoordinator`-Verdrahtung;
  die vorhandenen CLI-Symlink-Tests prüfen nur `CLIInstallStatus`
  (`WhisperM8/Services/Shared/Logger.swift:36-69`,
  `WhisperM8/Services/Shared/CLISymlinkInstaller.swift:10-40`,
  `Tests/WhisperM8Tests/CLISkillExporterTests.swift:160-212`,
  `WhisperM8/Models/AppState.swift:21-24`, `WhisperM8/Models/AppState.swift:93-103`).

## 7. Refactor-Kandidaten

1. **Asynchroner, echter Once-Loader mit Timeout für PATH.** Einen kleinen Actor oder
   einen unter Lock installierten gemeinsamen `Task<String, Never>` verwenden; Shell
   mit Deadline terminieren und alle Aufrufer dasselbe Ergebnis abwarten lassen. Das
   beseitigt Doppelspawns und unbegrenztes Warten
   (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:47-80`,
   `WhisperM8/Services/Shared/LoginShellEnvironment.swift:166-184`).
2. **Eine einzige Command-/PATH-Policy.** Fallback-Verzeichnisse in einen gemeinsamen
   Resolver heben und daraus sowohl `PATH` als auch die absolute Command-Suche ableiten;
   so kann `~/.claude/local` nicht nur vom Resolver, sondern auch von Claude-Kindprozessen
   gesehen werden (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:34-45`,
   `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:400-418`).
3. **Launch-Snapshot vorberechnen.** Workspace/UI-State auf einer Utility-Task laden,
   anschließend nur den fertigen `openTabIDsAtLaunch`-Wert auf den MainActor übernehmen;
   `runStartupReconciliation` darf keinen Singleton mit synchronem Disk-Init als
   Argument auswerten (`WhisperM8/WhisperM8App.swift:255-298`,
   `WhisperM8/Services/AgentChats/AgentWindowStore.swift:61-65`). Erwarteter Nutzen:
   weniger Launch-Hänger und eine explizite Reihenfolge zu Retention/Restore.
4. **Keychain als injizierbaren, seriellen Service modellieren.** UI-Eingaben lokal
   halten und nur bei Commit/Focus-Loss debounced speichern; `load` wahlweise mit
   `.fail`/`.allowPrompt`-Policy und off-main ausführen
   (`WhisperM8/Services/Shared/KeychainManager.swift:10-58`,
   `WhisperM8/Views/Settings/Pages/TranscriptionSettingsPage.swift:38-49`). Erwarteter
   Nutzen: weniger Security-Aufrufe, kontrollierbare Prompts und echte Unit-Tests.
5. **Profilwechsel ereignisgesteuert abschließen.** Close-Tracking über gezählte
   Window-Close-Acknowledgements beziehungsweise einen scoped Suppression-Token wieder
   freigeben, nicht nach 500 ms (`WhisperM8/Services/Shared/AppProfileActivator.swift:24-41`).
   Erwarteter Nutzen: kein timingabhängiger Verlust des Restore-Zustands.
6. **Composition Root explizit machen.** Ein `AppServices`-/`AppRuntime`-Objekt in
   `WhisperM8App` erzeugen und AppState, Window-Router, Preferences, Update-Checker und
   Launch-Jobs injizieren; `.shared` bleibt vorübergehend nur als Adapter
   (`WhisperM8/WhisperM8App.swift:11-13`, `WhisperM8/WhisperM8App.swift:220-298`).
   Erwarteter Nutzen: deterministische Start-/Shutdown-Reihenfolge und isolierbare Tests.
7. **Logger auf einen seriellen Writer umstellen.** Optionales File-Logging über eine
   dedizierte Queue/einen Actor mit persistentem Handle und Rotation führen; `os.Logger`
   bleibt der synchrone Primärpfad (`WhisperM8/Services/Shared/Logger.swift:22-64`).
   Erwarteter Nutzen: keine Dateisystemarbeit in Aufrufer-Hotpaths und geordnete Logs.
8. **Monotone Budget-Uhr injizieren.** `ContinuousClock`/`SuspendingClock` statt `Date`
   für Dauern verwenden und `cancel` sowie async Intervalle ergänzend testen
   (`WhisperM8/Services/Shared/PerformanceSignposts.swift:33-63`,
   `Tests/WhisperM8Tests/PerformanceBudgetTests.swift:28-98`). Erwarteter Nutzen:
   belastbarere Telemetrie ohne Wall-Clock-Artefakte.
