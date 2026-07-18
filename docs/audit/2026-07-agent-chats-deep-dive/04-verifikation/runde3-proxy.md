---
status: abgeschlossen
updated: 2026-07-18
description: Adversariale Vollverifikation aller fünf Runde-3-Findings zum GPT-Backend-Proxy gegen Prozess-, Router-, Launch-, Background- und Settings-Code einschließlich Aufrufern, Tests und relevanten Commit-Messages.
---

# Runde 3: Verifikation GPT-Backend-Proxy

## Auftrag, Methode und Bewertungsmaßstab

Geprüft wurden **alle fünf** Findings aus
`02-findings/runde3-gpt-backend-proxy.md` gegen den aktuellen Code auf `main`.
Für jedes Finding wurden nicht nur die zitierten Methoden, sondern auch die realen
Aufrufer, der Task-/Thread-Kontext, die Lock-Grenzen, die nachfolgenden Builder- und
PTY-Pfade sowie die vorhandenen Tests geöffnet. Zusätzlich wurden die relevanten
Commit-Messages `bd90262` und `0ff286b` auf bewusst akzeptierte Grenzen und bereits
adressierte Gegenbelege geprüft. Es wurden keine Builds, Tests oder Prozesse
ausgeführt und kein Produktcode geändert.

Urteile:

- **BESTAETIGT:** Das auslösende Szenario ist aus dem aktuellen Code ableitbar; vorhandene Guards schließen es nicht.
- **WIDERLEGT:** Ein Guard, Aufrufervertrag oder Test-/Implementierungsdetail verhindert das behauptete Szenario.
- **UNKLAR:** Der Repository-Code reicht nicht aus, um Auslösung oder Verhinderung belastbar zu entscheiden.

**Gesamturteil:** Alle fünf Findings sind im Kern **BESTAETIGT**. Bei G02 ist
„unbemerkt“ zu eng zu lesen: Einzelne Requests werden als HTTP 502 sichtbar, aber
der Proxy-Exit wird lifecycle-seitig weder erkannt noch repariert. Bei G03 ist die
WhisperM8-seitige Umgehung eindeutig; welche Umgebung ein bereits laufender externer
Claude-Supervisor zufällig besitzt, ist dagegen außerhalb dieses Repositories.

## G01 — Start und Stop/App-Quit sind nicht als ein Lifecycle serialisiert

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

1. Ein normaler Chat-Start läuft in `Task.detached`; darin wird
   `ClaudeCodeProxyManager.ensureRunning` auf einem globalen Executor aufgerufen
   (`WhisperM8/Views/AgentSessionDetailView.swift:387-405`). Der Settings-Start
   verwendet ebenfalls einen separaten Detached Task
   (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:282-297`).
2. `ensureRunning` hält `ensureLock` über Probe, Prozessstart, Handle-Registrierung,
   Readiness-Schleife, Router-Start und Agent-Definition-Sync
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`).
3. `stopIfSelfStarted` nimmt `ensureLock` überhaupt nicht. Die Methode liest unter
   `processLock` nur einen Bool-Snapshot, gibt den Lock frei, stoppt eventuell den
   Router und ruft danach separat `replaceSelfStartedProcess(with: nil)` auf
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`).
4. Der App-Quit-Observer ruft genau diese Methode synchron zur
   `NSApplication.willTerminateNotification` auf
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:198-205`), während
   `applicationShouldTerminate` nach Snapshot-Capture ohne asynchrones Drain oder
   Start-Barriere `.terminateNow` zurückgibt
   (`WhisperM8/WhisperM8App.swift:343-351`).

Damit existieren mindestens drei konkrete Interleavings:

- **Quit vor Registrierung:** Stop liest und leert `nil`; danach kann der bereits
  laufende Ensure-Pfad den Prozess noch starten und in Zeile 254 registrieren. Für
  diesen nach dem einzigen Quit-Cleanup registrierten Handle gibt es im Code keinen
  zweiten Terminate-Aufruf (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-255,286-300`).
- **Stop zwischen Ready-Probe und Router-Start:** Ensure kann in Zeile 259 Erfolg
  sehen; Stop terminiert danach den registrierten Prozess; Ensure startet anschließend
  trotzdem den Router und meldet Erfolg, weil vor `.success` keine erneute Proxy-
  oder Generation-Prüfung stattfindet
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:257-283,286-300`).
  Der Caller friert dieses `.ready` später als Router-Launch ein
  (`WhisperM8/Views/AgentSessionDetailView.swift:438-450,467-482,503-509`).
- **Registrierung zwischen Bool-Snapshot und Replace:** Stop kann zunächst
  `hasSelfStartedProcess == false` lesen, danach aber einen gerade von Ensure
  registrierten neuen Handle über `replaceSelfStartedProcess(with: nil)` terminieren,
  ohne den Router zu stoppen. Die zwei Operationen sind getrennt
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:292-300,446-455`).

`ClaudeCodeProxyProcessHandle.terminate()` ist nur eine Closure ohne Wait-,
Exit- oder Eskalationsvertrag (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:95-113`).
Der reale Handle bildet diese Closure ausschließlich auf `Process.terminate()` ab;
`launchProcess` installiert weder Exit-Wait noch SIGKILL-Eskalation
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:540-557`).

### Aktiv gesuchte Gegenbelege

- `ensureLock` verhindert zuverlässig zwei parallele **Ensures**, nicht aber Ensure
  gegen Stop/Quit (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-223,286-300`).
- `processLock` schützt den Pointer vor einem Datenrace, koppelt aber den
  Bool-Snapshot nicht atomar an Router-Stop und Handle-Replacement
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:292-300,446-467`).
- Der Router selbst besitzt eine Generation und schützt alte Listener-Callbacks
  gegen einen inzwischen ersetzten Listener
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:117-228,238-258`). Das
  verhindert jedoch nicht, dass der Manager **nach** einem expliziten Stop einen
  neuen Router startet und Erfolg zurückgibt.
- Die Manager-Tests sind sequenziell. Insbesondere hat der Quit-Test
  `retryAttempts: 0`; der unerreichbare Testprozess wird deshalb bereits im
  Ensure-Fehlerpfad verworfen und terminiert, bevor das Notification-Event gepostet
  wird (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:302-318`;
  `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:257-268`). Die Assertion
  beweist den Quit-Cleanup daher nicht.

### Schluss

Die Locks verhindern Speicher-Datenraces, aber keine linearisierbare Lifecycle-
Reihenfolge. Das Finding ist vollständig bestätigt. **Hoch** ist angemessen, weil
der normale Chat-Start trotz Stop als erfolgreich enden und der Quit-Pfad einen
nachträglich gestarteten Proxy ohne explizites Cleanup zurücklassen kann.

## G02 — Proxy-Crash bleibt lifecycle-seitig unbemerkt; Ownership und Sessions werden stale

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

Der langlebige `serve`-Prozess wird mit verworfenen Ein-/Ausgabekanälen gestartet.
Anders als `runCommand` und der Device-Login erhält er keinen
`terminationHandler`; der zurückgegebene Handle exponiert nur `isRunning` und
`terminate()` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:540-557,566-577,640-653`).

`selfStartedProcess` wird ausschließlich in Ensure-/Stop-Hilfsmethoden gesetzt oder
gelöscht; es gibt keinen Callback des realen Child-Prozesses, der den aktuellen
Handle bei natürlichem Exit entfernt
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-255,286-300,444-467`).
`stopIfSelfStarted` prüft für seine Ownership-Entscheidung nur
`selfStartedProcess != nil`, nicht `isRunning`, PID, Startgeneration oder Port
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:292-299`).

Nach einem Proxy-Crash bleibt deshalb folgende Zustandskombination möglich:

- Router-Listener läuft weiter; sein Lifecycle ist unabhängig vom Proxy-Child
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:107-112,231-258`).
- Bereits gestartete PTYs behalten die beim Spawn eingefrorene
  `ANTHROPIC_BASE_URL` (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-295`;
  `WhisperM8/Views/AgentTerminalView.swift:749-770`).
- Erst ein späteres `ensureRunning` prüft `/healthz` erneut und räumt bei
  Nichterreichbarkeit den alten Handle ab
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-255`). Der einzige
  produktive Chat-Aufrufer erreicht diesen Pfad beim Start eines weiteren Chats
  (`WhisperM8/Views/AgentSessionDetailView.swift:399-417`).

Auch die stale-Ownership-Variante ist real: Startet nach dem Crash eine externe,
gesunde Instanz auf demselben Port, überspringt `ensureRunning` wegen erfolgreicher
Eingangsprobe den gesamten Handle-Bereinigungszweig; der tote alte Handle bleibt
stehen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-231`). Der
spätere Settings-Stop deutet dessen Nichtnullheit als Eigenbesitz und stoppt deshalb
den gemeinsam verwendeten Router, obwohl die aktuelle Proxy-Instanz nicht von
WhisperM8 registriert wurde
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`). Das
widerspricht dem dokumentierten Vertrag, bei externem Proxy den Router unangetastet
zu lassen (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-291`).

### Aktiv gesuchte Gegenbelege und Eingrenzung

- Der Crash ist nicht in jedem Sinn „unsichtbar“: Kann der Router den lokalen
  Upstream nicht erreichen und wurde noch kein Response-Head gesendet, antwortet er
  dem Claude-Client mit HTTP 502 und loggt Status 502
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-609,654-657`). Das
  widerlegt aber weder den stale Handle noch die fehlende automatische Recovery;
  es macht nur den **einzelnen fehlgeschlagenen Request** sichtbar.
- Ein manueller Settings-Refresh prüft den konfigurierten Port und kann
  „nicht erreichbar“ anzeigen
  (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:259-279`). Es gibt
  jedoch keinen automatischen Refresh aus einem Prozess-Exit.
- Der Eingangs-Healthcheck eines späteren Ensure ist eine echte Recovery für
  **künftige Launches**, nicht für bereits laufende Router-Sessions
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-270`).
- Der Test-Handle meldet fest `isRunning == true`; natürlicher Exit und externer
  Ersatz sind dadurch in der vorhandenen Suite nicht modelliert
  (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:407-447`).

### Schluss

Das Finding ist bestätigt, mit der Präzisierung „lifecycle-seitig unbemerkt“ statt
„jeder Request scheitert still“. **Hoch** bleibt angemessen: Ein einzelner Child-
Crash trennt alle bestehenden GPT-Routen vom Upstream und kann die spätere
Ownership-Entscheidung verfälschen; der Code repariert dies erst beim nächsten
Ensure oder durch manuelles Eingreifen.

## G03 — `claude --bg` kann GPT vor Guard und Router starten

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

Die von WhisperM8 verwaltete Agent-Definition heißt `gpt` und schreibt das
konfigurierte `gpt-*`-Modell direkt ins Frontmatter
(`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:37-47,57-63`).
Der Background-Dispatch reicht den ausgewählten Agent-Namen unmittelbar an
`BackgroundAgentSpawner.spawn` weiter. Erst nach erfolgreichem Spawn und Persistenz
der Short-ID löst er den Attach-Start aus
(`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68-95`).

Der tatsächliche Spawn-Pfad hat keine GPT-Lifecycle-Abhängigkeit:

- `backgroundSpawnArguments` baut nur `--settings`, `--bg`, `--agent`,
  Permission-Mode, Extra-Args und Prompt
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:424-453`).
- `BackgroundAgentSpawner.spawn` ruft keinen Launch-Guard und keinen
  `ClaudeCodeProxyManager.ensureRunning` auf
  (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-137`).
- Das `ProcessRunner`-Protokoll besitzt keinen Environment-Parameter
  (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:215-230`).
- Der reale Runner erzeugt sein Environment fest aus
  `LoginShellEnvironment.processEnvironment()` plus Farbflags; weder
  `ANTHROPIC_BASE_URL` noch `ANTHROPIC_CUSTOM_MODEL_OPTION` oder
  `CLAUDE_CODE_SUBAGENT_MODEL` werden gesetzt
  (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:234-258`).

Der Launch-Guard greift erst, wenn die Short-ID bereits existiert und die UI in
Zeile 95 einen `.start`-Request für den Attach erzeugt. Dieser Request läuft durch
`launchAfterCacheWarmup`, das den Proxy/Router prüft
(`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:86-95`;
`WhisperM8/Views/AgentSessionDetailView.swift:372-405`). Der Builder versieht danach
`claude attach <short-id>` mit Router-Environment
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:315-337`). Laut eigenem
Spawner-Vertrag wird die eigentliche Session zu diesem Zeitpunkt aber bereits vom
Claude-Supervisor gehostet
(`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:3-8`). Der spätere
Attach-PTY ist daher kein Guard **vor** dem Background-Start.

Dasselbe strukturelle Loch betrifft den globalen nativen Subagent-Override: Der
normale PTY-Builder setzt `CLAUDE_CODE_SUBAGENT_MODEL` nur im Router-Environment
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:270-295`), der Background-
Spawn verwendet diesen Builder-Zweig nicht. Die Settings beschreiben das Feld als
Override für alle nativen Subagents
(`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:185-190`), ohne den
Background-Pfad einzuschränken.

### Aktiv gesuchte Gegenbelege und Eingrenzung

- `--settings <path>` wird korrekt **vor** `--bg` gesetzt; dadurch erhält die
  Background-Session die Hook-Konfiguration
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:430-453`;
  `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68-84`). Die Hook-Settings
  enthalten jedoch keinen GPT-Proxy-Guard oder Spawn-Environment-Override in diesem
  Pfad.
- Der spätere Attach erhält tatsächlich das Router-Environment, und ein Builder-
  Test belegt genau diesen Zustand
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:321-337`;
  `Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:605-647`). Das ist ein Guard
  für den Attach-Client, nicht für die bereits gestartete Background-Session.
- Die Spawner-Tests prüfen argv, executable und cwd. Ihr Mock-Protokoll kann ein
  Environment gar nicht erfassen
  (`Tests/WhisperM8Tests/BackgroundAgentSpawnerTests.swift:102-141,222-244`).
- Nicht aus diesem Repository ableitbar ist, welche Umgebung ein **bereits vorher
  extern gestarteter** Claude-Supervisor zufällig besitzt. Das schwächt aber nicht
  die Verifikation: WhisperM8 stellt im Spawn-Pfad weder Router-Readiness noch den
  vorgesehenen Environment-Snapshot sicher.

### Schluss

Der Titel behauptet zu Recht „kann“: Der Supervisor-Job wird vor dem einzigen
WhisperM8-Guard erzeugt, und sein Spawn erhält die GPT-Router-Konfiguration nicht.
**Hoch** ist angemessen, weil ein explizit ausgewählter, von WhisperM8 bereitgestellter
`gpt`-Agent damit gerade den Integrationspfad umgehen kann, dessen Verfügbarkeit für
ihn Voraussetzung ist.

## G04 — Der Kill-Switch stoppt einen bereits vorbereiteten GPT-Launch nicht

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **hoch**

### Exakte Ausführung

Der Preference-Vertrag ist eindeutig: Bei `false` sollen GPT-Stempel ignoriert und
Claude ohne Proxy-Argumente/-Environment gestartet werden
(`WhisperM8/Support/AppPreferences.swift:257-262`). Der normale Builder erfüllt
diesen Vertrag, **wenn** sein Resolver beim Build `false` liefert: Dann werden weder
Session-GPT-Modell noch Router-Environment angewandt
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:259-265,270-295`). Ein
Test belegt genau diesen statischen Fall
(`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:579-603`).

Der reale Launch-Caller hebelt die erneute Preference-Auswertung jedoch aus:

1. Der Detached Task liest `claudeGPTBackendEnabled` genau einmal vor Ensure und
   speichert danach nur `.ready`, `.unavailable` oder `.notNeeded`
   (`WhisperM8/Views/AgentSessionDetailView.swift:393-416`).
2. Nach Ensure kann noch der bis zu 500 Einträge große Resume-Reparaturscan laufen
   (`WhisperM8/Views/AgentSessionDetailView.swift:418-436`).
3. Auf dem MainActor wird vor Start nur geprüft, ob die Session noch existiert und
   nicht archiviert ist; der aktuelle Kill-Switch wird nicht erneut geprüft
   (`WhisperM8/Views/AgentSessionDetailView.swift:438-450`).
4. `ClaudeGPTLaunchGuard.decision` setzt für jedes alte `.ready` bedingungslos
   `usesRouter = true`, ohne Preference- oder Generationseingang
   (`WhisperM8/Services/AgentChats/ClaudeGPTLaunchGuard.swift:14-39`).
5. Der Caller überschreibt `builder.gptBackendEnabledResolver` anschließend mit
   einer Closure auf genau diesen alten Bool und startet direkt den Controller
   (`WhisperM8/Views/AgentSessionDetailView.swift:455-482,503-509`).

Wird das Backend zwischen Schritt 1 und 5 deaktiviert, kann der tatsächliche
Prozessstart deshalb weiterhin `--model gpt-*` und `ANTHROPIC_BASE_URL` erhalten
(`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:259-295,340-348,410-420`).
Die Settings-Reaktion löscht Statusanzeige und synchronisiert die verwaltete
Agent-Datei, stoppt aber weder Manager/Router noch pending Launches
(`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-85,329-337`).

### Aktiv gesuchte Gegenbelege

- Der Builder-Kill-Switch selbst ist korrekt und getestet
  (`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:579-603`). Der Fehler liegt
  in der vom Caller eingefrorenen Resolver-Closure, nicht im isolierten Builder.
- Der Session-Existenz-/Archiv-Guard verhindert nach einem langen Warmup unsichtbare
  PTYs für gelöschte Sessions
  (`WhisperM8/Views/AgentSessionDetailView.swift:438-446`). Er enthält aber keine
  Backend- oder Konfigurationsgeneration.
- Die Settings-`.task(id: backendEnabled)` reagiert auf den Toggle und entfernt die
  verwaltete `gpt.md`
  (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-77`). Das ändert
  weder das schon gespeicherte `.ready` noch einen bereits gestempelten
  `AgentChatSession`-Snapshot.
- Commit `bd90262` nennt „Kill-Switch-Umschalten waehrend laufendem Launch“
  ausdrücklich als bewusst offene Grenze. Das ist kein Gegenbeleg, sondern
  bestätigt, dass die statische Builder-Wahrheitstabelle nie als vollständige
  Lifecycle-Lösung gedacht war.
- Die Guard-Tests prüfen ausschließlich feste Eingaben; ein Preference-Wechsel
  zwischen Ensure und Controller-Start kommt nicht vor
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:176-217`).

### Schluss

Das Finding ist exakt bestätigt. **Hoch** ist trotz des kurzen Race-Fensters
angemessen, weil ein ausdrücklich deaktivierter zentraler Backend-Schalter gegen
einen älteren Snapshot verlieren kann und der danach gestartete Prozess tatsächlich
weiter über den GPT-Router läuft.

## G05 — Backend-/Router-Port sind kein atomarer, verifizierter Endpunkt-Snapshot

**Urteil:** **BESTAETIGT**  
**Eigener Schweregrad:** **mittel**

### Exakte Ausführung

Es gibt drei voneinander getrennte Port-Lesezeitpunkte:

1. Der Caller liest den Backend-Port und übergibt nur dessen `Int` an
   `ensureRunning` (`WhisperM8/Views/AgentSessionDetailView.swift:399-405`).
2. Der Manager liest den Router-Port später aus einem separaten Resolver, startet
   den Listener und gibt nur `Result<Void, ClaudeCodeProxyError>` zurück — weder
   gebundener Port noch Konfigurationsgeneration verlassen die Methode
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:138-153,218-223,272-283`).
3. Der Builder liest den Router-Port beim späteren Command-Build erneut aus
   Preferences und schreibt daraus `ANTHROPIC_BASE_URL`
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:68-78,270-295`).

Der Router kennt zwar seinen tatsächlich gebundenen Port
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:107-112,168-181`), dieser
Wert wird vom Manager aber nicht an den Builder weitergereicht. Ändert sich die
Router-Port-Preference zwischen Manager-Start und Build, kann der Builder deshalb
einen anderen Endpunkt einfrieren als den Listener, dessen `.ready` der Manager
beobachtet hat.

Für den Backend-Port ist die Auslösung direkt über die UI möglich: Das
`@AppStorage`-Feld ist unmittelbar an ein numerisches Textfeld gebunden; ein Apply-
oder Restart-Schritt existiert in dieser Konfigurationssektion nicht
(`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:4-8,167-175`). Der
Router löst den Codex-Proxy nicht beim eigenen Start auf, sondern seine Default-
Closure liest bei jedem `forward` den **aktuellen** Backend-Port aus Preferences
(`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:76-95,403-416,534-542`).
Damit ist das im Finding beschriebene Szenario exakt möglich: Port A wird durch
`ensureRunning` gesund geprüft, der User editiert anschließend auf Port B, und der
nächste GPT-Request wird ohne neue Health-Probe an B weitergeleitet.

Die Kollisionsdiagnose ist ebenfalls wie behauptet: `launchProcess` leitet stdout
und stderr auf `/dev/null` und installiert keinen Termination-Handler
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:540-557`). Ein früher
Child-Exit wegen Portbelegung wird vom Manager nicht als eigener Fehlergrund gelesen;
nach erfolglosen Health-Probes bleibt nur `.notReachable(port:)`
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:257-269`).

### Aktiv gesuchte Gegenbelege und Eingrenzung

- Die `/healthz`-Probe ist stark: Sie verlangt Status 200, JSON-Content-Type und
  `{ "ok": true }`, sodass ein beliebiger fremder Listener nicht als Proxy gilt
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469-537`). Sie ist
  jedoch nur ein Snapshot des damals geprüften Backend-Ports.
- Der Router wartet beim Start synchron auf `.ready` und speichert den gebundenen
  Port (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:153-228`). Auch das
  schützt nur den Listener selbst, nicht die spätere erneute Preference-Auswertung
  im Builder oder Upstream-Resolver.
- Der Router-Port hat aktuell keinen Editor auf der GPT-Settings-Seite; dort ist nur
  der Backend-Port gebunden
  (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:4-8,167-175`). Die
  Router-Port-Hälfte des Findings ist daher im normalen UI weniger leicht auslösbar
  als die Backend-Port-Hälfte. `AppPreferences` exponiert trotzdem einen live
  lesenden Getter/Setter, und Manager sowie Builder lesen ihn unabhängig
  (`WhisperM8/Support/AppPreferences.swift:272-277`;
  `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:148,171`;
  `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:72-74`).
- Nicht-GPT-Requests werden weiterhin an Anthropic geroutet; die Portänderung trifft
  den `gpt-*`-Zweig
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:279-283,534-542`).

### Schluss

Das Finding ist bestätigt. **Mittel** ist angemessen: Die Backend-Port-Variante ist
über die sichtbare UI deterministisch auslösbar und kann laufende GPT-Anfragen
unterbrechen, setzt aber eine bewusste Konfigurationsänderung voraus, ist durch
Zurückstellen korrigierbar und betrifft den Claude-Upstream nicht.

## Ergebnistabelle

| ID | Kurzfassung | Urteil | Eigener Schweregrad | Wichtigste Verifikationsstelle |
|---|---|---|---|---|
| G01 | Ensure gegen Stop/Quit nicht serialisiert | **BESTAETIGT** | hoch | `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-300` |
| G02 | Proxy-Exit ohne Lifecycle-Recovery, stale Ownership | **BESTAETIGT** | hoch | `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300,540-557` |
| G03 | `--bg`-Spawn vor Guard und ohne Router-Environment | **BESTAETIGT** | hoch | `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68-95`; `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-137,223-258` |
| G04 | Alter `.ready`-Snapshot überlebt Kill-Switch-Wechsel | **BESTAETIGT** | hoch | `WhisperM8/Views/AgentSessionDetailView.swift:393-450,455-509` |
| G05 | Ports werden an drei Zeitpunkten live neu gelesen | **BESTAETIGT** | mittel | `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`; `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:85-95,534-542` |

**Bilanz:** 5× BESTAETIGT, 0× WIDERLEGT, 0× UNKLAR; davon nach eigener
Einordnung 4× hoch und 1× mittel.

## Die drei wichtigsten bestätigten Findings

1. **G03 — Background-GPT umgeht den einzigen Guard.** Der Job wird bereits über
   `claude --bg --agent gpt` erzeugt, bevor WhisperM8 Proxy und Router sicherstellt;
   der reale Spawn kann das vorgesehene Environment nicht einmal entgegennehmen
   (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68-95`;
   `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78-137,223-258`).
2. **G01 — Start und Stop/Quit bilden keine Zustandsmaschine.** Ein Stop kann nach
   erfolgreicher Health-Probe den Proxy terminieren, während Ensure danach Router
   startet und Erfolg meldet; beim Quit kann eine Registrierung nach dem einzigen
   Cleanup erfolgen
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-300`;
   `WhisperM8/WhisperM8App.swift:343-351`).
3. **G02 — Ein Proxy-Crash entkoppelt laufende Router-Sessions und verfälscht
   Ownership.** HTTP 502 macht einzelne Requests sichtbar, aber weder Manager noch
   UI erhalten einen Exit-Übergang; ein späterer externer Ersatz kann wegen des
   stale Handles den falschen Router-Stop auslösen
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-300,540-557`;
   `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:603-609`).
