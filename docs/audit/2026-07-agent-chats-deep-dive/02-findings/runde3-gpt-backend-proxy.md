---
status: aktiv
updated: 2026-07-18
description: Runde-3-Audit der neuen GPT-Backend-Integration mit Fokus auf Prozessidentität, Start-/Stop-Races, Kill-Switch, Portbindung, Background-Spawns und fehlende Crash-Recovery des Claude-Code-Proxys.
---

# Runde 3: GPT-Backend-Proxy — Korrektheit und Lifecycle

## Gegenstand und Methode

Statisch geprüft wurden die neue Integration aus `30c4661..feac0c0`, insbesondere
`ClaudeCodeProxyManager`, `ClaudeGPTLaunchGuard`, die GPT-Zweige des
`AgentCommandBuilder`, der tatsächliche PTY-Launch sowie App-Quit und Tests. Zur
Verifikation der Launch-Kette wurden außerdem `ClaudeGPTMixRouter`,
`BackgroundAgentSpawner`, `AgentChatsView+BackgroundAgents` und die zugehörigen
Tests gelesen. Es wurden keine Builds, Tests oder Prozesse ausgeführt.

**Bilanz:** fünf Findings — vier hoch, eines mittel. Die normale Startreihenfolge
ist grundsätzlich richtig: `ensureRunning` serialisiert parallele Ensures, wartet
auf die eindeutige `/healthz`-Signatur und startet erst danach den Router
(`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-223,257-283,469-537`).
Der Launch wartet synchron auf dieses Ergebnis, bevor der PTY-Controller erzeugt
wird (`WhisperM8/Views/AgentSessionDetailView.swift:393-417,438-450,503-509`).
Die Defekte liegen in den konkurrierenden Übergängen, der Zeit **nach** diesem
Ready-Snapshot und einem zweiten Launch-Pfad, der den Guard ganz umgeht.

## G01 — Start und Stop/App-Quit sind nicht als ein Lifecycle serialisiert

**Schweregrad:** hoch

### Beleg

- Nur `ensureRunning` hält `ensureLock`; die Methode kann danach Proxy starten,
  registrieren, mehrfach prüfen und den Router starten
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-223,225-283`).
- `stopIfSelfStarted` nimmt dieses Lock nicht. Es liest den Handle separat,
  stoppt gegebenenfalls den Router und ersetzt den Handle anschließend durch
  `nil` (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`).
- App-Quit ruft genau diesen konkurrierenden Stop über einen Notification-
  Observer auf (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:198-205`),
  während `applicationShouldTerminate` sofort `.terminateNow` liefert
  (`WhisperM8/WhisperM8App.swift:343-351`).
- `terminate()` ist nur eine SIGTERM-Anforderung; weder der Handle noch
  `replaceSelfStartedProcess` warten auf Exit oder eskalieren auf SIGKILL
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:97-113,446-455,540-557`).

### Szenario

Ein Chat-Launch läuft im Detached Task. `ensureRunning` hat den anfänglichen
Healthcheck bereits begonnen, aber den neuen Prozess noch nicht in
`selfStartedProcess` eingetragen. Gleichzeitig beendet der User die App. Der
Quit-Observer sieht `nil` und kehrt zurück; anschließend kann der Detached Task
noch den Proxy starten und registrieren. Für diesen nach dem einzigen
Quit-Callback registrierten Prozess existiert kein weiterer Cleanup-Pfad
(`WhisperM8/Views/AgentSessionDetailView.swift:393-405`;
`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:235-255`).

Dasselbe Race ist über „Proxy stoppen“ möglich: Stop kann den soeben
registrierten Prozess zwischen Health-Probe und `routerStarter` terminieren;
der noch laufende Ensure-Pfad kann danach den Router erneut starten und
`.success` melden. Der anschließend gebaute Claude-Prozess erhält dann trotzdem
die Router-URL (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:257-283,286-300`;
`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:270-295`).

### Testlücke

Die Start-/Stop-Tests sind ausschließlich sequenziell
(`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:48-78,161-185,223-237`).
Der vermeintliche Quit-Test lässt `retryAttempts == 0`; `ensureRunning` verwirft
und terminiert den unerreichbaren Prozess bereits vor dem geposteten Quit-Event,
sodass die abschließende Bool-Assertion nicht beweist, dass das Event selbst
aufgeräumt hat (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:302-318`;
`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:266-268`).

### Fix-Skizze

Proxy und Router über **eine** Actor-/Serial-Queue-Zustandsmaschine verwalten
(`stopped → starting(generation) → ready → stopping`). Stop muss einen laufenden
Start invalidieren und auf dessen Abschluss warten; nach Eintritt in
`terminating` dürfen keine neuen Starts mehr registriert werden. Beim Quit:
SIGTERM, kurze Wait-Frist, dann PID-identitätsgeprüft SIGKILL und Exit abwarten.
Regressionstest mit steuerbaren Barrieren zwischen Launch, Handle-Registrierung,
Health-Ready und Router-Start.

## G02 — Proxy-Crash bleibt unbemerkt; Ownership und laufende Sessions werden stale

**Schweregrad:** hoch

### Beleg

- Der langlebige `serve`-Prozess wird ohne `terminationHandler` gestartet; der
  Handle enthält nur `process.isRunning` und `process.terminate()`
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:540-557`).
- `selfStartedProcess` wird nur durch einen späteren Ensure-/Stop-Fehlerpfad
  verändert, nicht durch den natürlichen Prozess-Exit
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-229,286-300,446-467`).
- Der Router bleibt unabhängig davon aktiv. Bereits gestartete Claude-Prozesse
  behalten ihre `ANTHROPIC_BASE_URL`; genau diese eingefrorene Abhängigkeit ist
  im Stop-Kommentar dokumentiert
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-290`;
  `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:270-295`).
- `stopIfSelfStarted` entscheidet Ownership nur über `selfStartedProcess != nil`,
  nicht über einen laufenden, zum Port passenden PID
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:292-299`).

### Szenario

Der selbst gestartete Proxy crasht nach einem erfolgreichen Chat-Launch. Der
Router läuft weiter, aber GPT-Requests der bereits laufenden PTY-Session haben
keinen Upstream. Es gibt weder automatische Recovery noch eine Statusänderung;
erst ein **weiterer** Session-Start ruft erneut `ensureRunning` auf und kann den
Proxy ersetzen (`WhisperM8/Views/AgentSessionDetailView.swift:399-417`).

Zusätzlich bleibt der tote Handle als Ownership-Marker liegen. Startet der User
anschließend denselben Proxy extern auf demselben Port, liefert der Healthcheck
sofort `true`; der Bereinigungszweig wird übersprungen und der stale Handle bleibt
registriert (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-231`).
„Proxy stoppen“ stoppt dann aufgrund des alten Handles den gemeinsam genutzten
Router, obwohl der aktuell gesunde Proxy extern ist und laut Klassenvertrag nie
übernommen wurde (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:116-118,286-300`).

### Testlücke

Der Test-Handle meldet ausnahmslos `isRunning == true`; natürlicher Exit,
später externer Ersatz und Recovery laufender Sessions sind damit nicht
modellierbar (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:443-447`).

### Fix-Skizze

Den echten Prozess mit PID, Startgeneration und Port registrieren und im
`terminationHandler` nur den identischen aktuellen Handle atomar entfernen.
Solange mindestens eine Router-Session eine Lease hält, mit begrenztem Backoff
neu starten oder den Router in einen expliziten „Upstream unavailable“-Zustand
setzen. Ownership nie aus Handle-Nichtnullheit ableiten, sondern aus
`generation + pid + running + configuredPort`.

## G03 — `claude --bg` kann GPT starten, bevor Guard und Router überhaupt laufen

**Schweregrad:** hoch

### Beleg

- Die verwaltete Agent-Definition `gpt` setzt im Frontmatter direkt ein
  `gpt-*`-Modell (`WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:37-47`).
- Background-Dispatch reicht den gewählten `subAgent` an
  `BackgroundAgentSpawner.spawn` und startet den Supervisor-Job **vor** dem
  späteren Attach (`WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68-95`).
- Der Spawn-Builder erzeugt nur argv; er besitzt keine GPT-/Router-Konfiguration
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:424-453`).
- Der Spawn-Runner setzt ausschließlich Login-Shell-Environment und Farbflags;
  `ANTHROPIC_BASE_URL`, Custom-/Subagent-Modell und ein Aufruf von
  `ensureRunning` fehlen (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:96-112,234-258`).
- Router-Environment wird erst für `claude attach <id>` gebaut
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:315-337`). Der
  Background-Agent arbeitet zu diesem Zeitpunkt bereits im Claude-Supervisor
  (`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:3-8`).

### Szenario

Der User aktiviert das Backend und dispatcht einen Background-Agenten mit dem
Agent-Typ `gpt`. `claude --bg --agent gpt ...` startet sofort mit dem GPT-Modell,
aber ohne Router-URL; die Anfrage geht damit nicht über den lokalen Mix-Router.
Der danach ausgelöste PTY-Attach kann den bereits gestarteten Supervisor-Job
nicht rückwirkend reparieren. Dasselbe gilt für das konfigurierte
`CLAUDE_CODE_SUBAGENT_MODEL`: Die Settings beschreiben es als Override für alle
nativen Subagents, der Background-Spawn erbt es aber nicht
(`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:185-190`).

### Testlücke

Der Background-Test prüft nur argv und cwd. Sein `ProcessRunner`-Protokoll und
Mock haben nicht einmal einen Environment-Parameter
(`Tests/WhisperM8Tests/BackgroundAgentSpawnerTests.swift:103-141,224-244`;
`WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:223-230`). Der
Builder-Test bestätigt Router-Environment nur für den späteren Attach
(`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:605-647`).

### Fix-Skizze

Vor jedem GPT-fähigen Background-Spawn denselben Launch-Guard ausführen und den
**erfolgreich gebundenen** Router-Endpunkt als Environment-Snapshot an den
Spawner übergeben. `ProcessRunner.run` um explizite Environment-Overrides
erweitern. Bei nicht verfügbarem Backend einen `gpt`-Spawn nicht still direkt
starten, sondern blockieren oder nach bestätigtem Fallback einen Claude-Agenten
verwenden. Spawn und Attach müssen dieselbe Konfigurationsgeneration tragen.

## G04 — Der Kill-Switch kann einen bereits vorbereiteten GPT-Launch nicht stoppen

**Schweregrad:** hoch

### Beleg

- Die Preference bezeichnet sich als zentralen Kill-Switch, der GPT-Stempel beim
  Claude-Start ignorieren soll
  (`WhisperM8/Support/AppPreferences.swift:257-261`).
- Der Detached Launch liest den Schalter nur einmal **vor** `ensureRunning` und
  kann danach noch einen bis zu 500 Einträge großen Resume-Reparaturscan
  durchführen (`WhisperM8/Views/AgentSessionDetailView.swift:399-436`).
- Ein früheres `.ready` führt im Guard bedingungslos zu `usesRouter == true`;
  der aktuelle Kill-Switch ist kein Entscheidungsparameter
  (`WhisperM8/Services/AgentChats/ClaudeGPTLaunchGuard.swift:18-38`).
- Auf dem MainActor wird dieses alte Ergebnis anschließend in den Builder
  eingefroren und direkt zum PTY-Start verwendet
  (`WhisperM8/Views/AgentSessionDetailView.swift:438-450,467-482,503-509`).
- Das Deaktivieren in den Settings löscht nur angezeigten Status und die
  verwaltete Agent-Datei; es invalidiert keinen laufenden Launch und stoppt den
  Manager nicht (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66-77`).

### Szenario

Ein Resume-Launch hat Proxy und Router erfolgreich geprüft. Während der
anschließende Index-Scan läuft, schaltet der User das GPT-Backend aus. Der
MainActor übernimmt danach trotzdem das alte `.ready`, setzt
`gptBackendEnabledResolver = { true }` und startet Claude mit Router-Environment
und gegebenenfalls `--model gpt-*`. Der explizite Kill-Switch verliert somit
gegen einen älteren Launch-Snapshot.

### Testlücke

Die Guard-Tests prüfen nur eine pure Wahrheitstabelle; es gibt keinen Wechsel
des Preferences-Zustands zwischen Probe und PTY-Start
(`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:176-217`).

### Fix-Skizze

Jede Backend-Aktivierung erhält eine monotone Konfigurationsgeneration. Der
Launch erfasst sie vor Ensure und muss sie unmittelbar vor `startController`
gegen den aktuellen Zustand prüfen. Ein Wechsel auf „aus“ invalidiert alle
pending Starts; ihr Ergebnis wird `.notNeeded` beziehungsweise der Launch wird
neu als Direktbetrieb gebaut. Diese Prüfung gehört in einen gemeinsamen
Lifecycle-Koordinator, nicht nur in die pure Guard-Wahrheitstabelle.

## G05 — Backend-/Router-Port sind kein atomarer, verifizierter Endpunkt-Snapshot

**Schweregrad:** mittel

### Beleg

- `ensureRunning` erhält den Backend-Port als Parameter, liest den Router-Port
  aber separat aus einem Resolver und liefert nur `Result<Void, ...>` zurück;
  der tatsächlich gebundene Endpunkt wird nicht an den Caller übergeben
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:148-153,218-223,272-283`).
- Der Builder liest den Router-Port später erneut aus Preferences
  (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:72-74,270-275`).
- Der Router löst den Backend-Upstream bei jeder Weiterleitung erneut aus der
  **aktuellen** Backend-Port-Preference auf
  (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:85-95,534-540`).
- Der Backend-Port ist ein unmittelbar gebundenes `@AppStorage`-Textfeld; es
  gibt keinen Apply-/Restart-Übergang
  (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:5-7,167-175`).
- Bei einer echten Portkollision werden stdout/stderr des gestarteten
  `serve`-Prozesses verworfen. Ein früher Exit mit `EADDRINUSE` wird daher nur
  als spätes `.notReachable(port:)` sichtbar
  (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:245-269,545-552`).

### Szenario

`ensureRunning` prüft erfolgreich einen Proxy auf 18765. Vor dem ersten
GPT-Request editiert der User das Portfeld auf 19001. Der bereits laufende Router
löst seinen GPT-Upstream nun dynamisch als 19001 auf, obwohl nur 18765 als gesund
verifiziert wurde. Der Guard bleibt `.ready`; der Chat startet ohne Fallback-
Warnung, aber GPT-Requests laufen in einen nicht gestarteten Port. Bei einer
Portkollision ist das beobachtbare Ergebnis ähnlich, nur dass die eigentliche
Ursache durch das Null-Device-Logging verloren geht.

### Testlücke

Manager- und Builder-Tests injizieren konstante, voneinander unabhängige Ports
und prüfen weder eine Änderung zwischen Ensure und Build noch einen frühen
Child-Exit wegen Portbelegung
(`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:18-37,48-78,407-440`;
`Tests/WhisperM8Tests/AgentCommandBuilderTests.swift:394-424`).

### Fix-Skizze

Eine unveränderliche `ProxyConfiguration` mit validierten, verschiedenen
Backend-/Router-Ports bilden. `ensureRunning(configuration:)` muss bei Erfolg
den exakt gebundenen Router-Endpunkt beziehungsweise eine Generation
zurückgeben; genau diesen Wert verwendet der Builder. Der Router erhält den
Backend-Upstream als Snapshot statt als Live-Preference. Portänderungen nur über
einen koordinierten Stop/Restart anwenden. Während des Startup-Fensters
Child-Exit und begrenztes stderr erfassen, damit `addressInUse`, ungültiger Port
und Health-Timeout getrennte Fehler sind.

## Priorität

1. **Sofort:** G01 und G04 zusammen beheben — ein zentraler Lifecycle mit
   Stop-/Quit-Barriere und Konfigurationsgeneration.
2. **Danach:** G02 — Exit-Wahrheit, Ownership und Recovery für gemeinsam genutzte
   Sessions.
3. **Vor Freigabe von GPT-Background-Agenten:** G03 — Guard und Environment in
   den tatsächlichen `--bg`-Spawn integrieren.
4. **Anschließend:** G05 — Portkonfiguration atomisieren und Kollisionen
   diagnostizierbar machen.
