---
status: abgeschlossen
updated: 2026-07-18
description: Adversarische Vollverifikation aller vier Security-Findings der Runde 3 gegen Produktionscode, Tests, Aufrufer, Task- und Lock-Kontexte sowie den gepinnten Proxy-Upstream.
---

# Runde 3: Verifikation GPT-Backend — Security

## Auftrag und Methode

Geprüft wurden alle Findings G01–G04 aus
`02-findings/runde3-gpt-backend-security.md`. Für jedes Finding wurden die
angegebenen Produktionsstellen geöffnet, der tatsächliche Launch- und
Weiterleitungspfad bis zum Socket beziehungsweise Child-Prozess verfolgt, die
relevanten Locks/Queues und Task-Grenzen geprüft und gezielt Gegenbelege in
Tests, Kommentaren, Plan/QA und Commit-Messages gesucht. Der gepinnte
Upstream-Stand `raine/claude-code-proxy@52c5501` wurde für die behaupteten
Routen-, Token- und Traffic-Capture-Eigenschaften ebenfalls direkt gelesen.
Es wurden weder Build noch Tests ausgeführt.

Bewertungsskala:

- **BESTAETIGT:** Der heutige Produktionspfad stellt das behauptete Szenario her.
- **WIDERLEGT:** Ein Guard, eine Invariante oder ein nicht erreichbarer Aufrufer verhindert es.
- **UNKLAR:** Der Code allein reicht für ein belastbares Urteil nicht aus.

## Gesamtergebnis

Alle vier Mechanismen sind im aktuellen Code vorhanden. Die ursprüngliche
Schwere von G03 ist jedoch zu hoch: Das Capture setzt voraus, dass der User die
explizite Diagnosevariable selbst in das App-Environment eingebracht hat; ein
zusätzlicher unautorisierter Leser der erzeugten Dateien ist nicht belegt.

| ID | Kurzfassung | Urteil | Ursprünglich | Eigene Schwere | Zentraler Beleg |
|---|---|---:|---:|---:|---|
| G01 | Nachbildbares `/healthz` legitimiert fremden Listener | **BESTAETIGT** | hoch | **hoch** | `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:225-283,469-537` |
| G02 | Lokale Listener exportieren die Codex-OAuth-Capability ohne Client-Auth | **BESTAETIGT** | hoch | **hoch** | `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:127-134,403-423,534-575` |
| G03 | Geerbtes `CCP_TRAFFIC_LOG` aktiviert vollständiges Payload-Capture | **BESTAETIGT** | mittel | **niedrig** | `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-137`; `ClaudeCodeProxyManager.swift:237-249,545-552` |
| G04 | Toggle deaktiviert neue Launches, beendet Listener aber nicht | **BESTAETIGT** | mittel | **mittel** | `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:47-78,329-337`; `ClaudeCodeProxyManager.swift:286-300` |

## G01 — Fremder Listener kann `/healthz` imitieren und den GPT-Datenstrom übernehmen

**Urteil: BESTAETIGT**  
**Eigene Schwere: hoch**

### Exakter Auslösepfad

1. Jeder nichtterminale Claude-Chat startet den GPT-Guard in einem eigenen
   `Task.detached`, sobald der globale Toggle aktiv ist; dort wird
   `ClaudeCodeProxyManager.shared.ensureRunning(...)` aufgerufen
   (`WhisperM8/Views/AgentSessionDetailView.swift:393-405`). Der nachfolgende
   Main-Actor-Abschnitt verwendet den Router nur bei `.ready`
   (`WhisperM8/Views/AgentSessionDetailView.swift:438-450,455-483`). Der Pfad ist
   damit realer Produktionspfad, kein nur über Settings erreichbarer Helfer.
2. `ensureRunning` serialisiert parallele WhisperM8-Starts zwar mit
   `ensureLock`, aber nur innerhalb dieses Managers
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-223`). Ist
   die Probe beim Eintritt positiv, wird der gesamte eigene Startblock
   übersprungen (`ClaudeCodeProxyManager.swift:225-270`) und der Mix-Router
   trotzdem gestartet (`ClaudeCodeProxyManager.swift:272-283`). Der Lock bindet
   den akzeptierten Socket weder an einen PID noch an einen UID oder einen von
   WhisperM8 gestarteten Prozess.
3. Die Probe ist streng gegen zufällige HTTP-Dienste, aber nicht
   authentisierend: festes `GET http://127.0.0.1:<port>/healthz`, Status 200,
   JSON-Content-Type und ein Dictionary mit `ok == true`
   (`ClaudeCodeProxyManager.swift:469-537`). Der Upstream liefert exakt die
   konstante Antwort `{"ok":true}`
   (`raine/claude-code-proxy@52c5501:src/server.rs:102-120`). Es gibt in diesem
   Vertrag keine Challenge und kein Geheimnis.
4. Nach Annahme verwendet der Router den konfigurierten Backend-Port direkt
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:85-93`), wählt ihn
   für jedes `model` mit Präfix `gpt-`
   (`ClaudeGPTMixRouter.swift:268-284`) und übernimmt den vollständigen Body in
   den Upstream-Request (`ClaudeGPTMixRouter.swift:529-575`). Claude erhält die
   Router-URL als `ANTHROPIC_BASE_URL`
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:267-295`); der
   Terminal-Controller merged diesen Override tatsächlich in das Child-Env
   (`WhisperM8/Views/AgentTerminalView.swift:748-771`).
5. Vor dem Codex-Zweig werden Claude-`Authorization`, `x-api-key` und
   `anthropic-*` entfernt (`ClaudeGPTMixRouter.swift:310-339`). G01 betrifft
   deshalb Prompt, System-/Tooldaten und manipulierbare Antworten, nicht den
   Abfluss des Claude-Credentials.

Auch der engere Race nach einer zunächst negativen Probe ist real: Der
Prozess-Handle wird bereits direkt nach `processLauncher` registriert
(`ClaudeCodeProxyManager.swift:235-255`), danach entscheidet wiederum nur die
Probe über Erfolg (`ClaudeCodeProxyManager.swift:257-269`). Gewinnt ein anderer
Listener den Bind-Race und der Child-Prozess beendet sich, wird
`process.isRunning` vor Router-Start nicht erneut geprüft.

### Widerlegungsversuche und Gegenbelege

- **Loopback:** Der verwaltete Proxy erhält `CCP_BIND_ADDRESS=127.0.0.1`
  (`ClaudeCodeProxyManager.swift:237-249`), der Router bindet ebenfalls fest an
  `127.0.0.1` (`ClaudeGPTMixRouter.swift:127-134`). Das schließt entfernte
  Netzhosts aus, authentisiert aber keinen lokalen Client oder Port-Owner.
- **Strenge Probe:** Redirects werden abgelehnt
  (`ClaudeCodeProxyManager.swift:24-35`), und die Response wird auf Status,
  Media-Type und JSON geprüft (`ClaudeCodeProxyManager.swift:517-537`). Das
  verhindert Fehlannahmen bei einem beliebigen Dienst, nicht bei einem
  Angreifer, der die öffentliche Upstream-Antwort gezielt nachbildet.
- **Tests:** Der Test erwartet ausdrücklich, dass bei positiver Reachability
  kein Prozess gestartet, der Router aber gestartet wird
  (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:18-37`). Der
  Probe-Test akzeptiert genau den statischen Body `{"ok":true}`
  (`ClaudeCodeProxyManagerTests.swift:187-208`). Das ist Regressionsschutz für
  die aktuell unsichere Identitätsannahme, kein Gegenbeleg.
- **Bewusste Härtung:** Commit `bd90262` beschreibt die `/healthz`-Prüfung als
  Schutz gegen einen fremden Listener. Der implementierte Vertrag enthält
  jedoch weiterhin nur die nachbildbare Konstante; Produktionscode und Tests
  tragen die stärkere Aussage der Commit-Message nicht.
- **Unabhängige Vorprüfung:** Der bereits vorhandene Vollreview kommt am selben
  Produktionspfad ebenfalls zu `CONFIRMED`
  (`docs/plans/claudex-gpt-backend/REVIEW-2026-07-18.md:125-138`).

### Schluss

Ein vorab gebundener Listener erfüllt alle aktuellen Guards und erhält danach
unverändert die GPT-Bodies. `ensureLock`, `processLock` und die Router-
`lifecycleQueue` schützen nur interne Zustandsrennen; keine dieser
Serialisierungen beweist die Identität des Backend-Prozesses. Der Datenabfluss
und die Antwortmanipulation über die lokale Account-Grenze rechtfertigen
**hoch**.

## G02 — Proxy und Mix-Router exportieren die OAuth-Capability ohne lokale Client-Authentisierung

**Urteil: BESTAETIGT**  
**Eigene Schwere: hoch**

### Exakter Auslösepfad

1. Der Router bindet zwar nur an `127.0.0.1`
   (`WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:127-134`), nimmt
   aber jede vom aktiven Listener gelieferte `NWConnection` an. `accept` prüft
   ausschließlich Listener-Generation und Objektidentität, erzeugt anschließend
   unmittelbar eine `ClientConnection` und startet sie
   (`ClaudeGPTMixRouter.swift:403-423`). Eine Peer-UID/-PID- oder Tokenprüfung
   existiert in diesem Annahmepfad nicht.
2. Die Client-Verbindung parst Head und Content-Length
   (`ClaudeGPTMixRouter.swift:481-531`) und entscheidet allein anhand des vom
   Client gelieferten JSON-Modells über den Upstream
   (`ClaudeGPTMixRouter.swift:534-575`). Die URL-Prüfung bindet Host, Scheme und
   Port an den konfigurierten Upstream
   (`ClaudeGPTMixRouter.swift:537-545`), ist also ein sinnvoller SSRF-Guard,
   aber keine Client-Authentisierung.
3. Beim verwalteten Proxy-Start werden nur Bind-Adresse, `serve`, Port und
   `--no-monitor` gesetzt (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:237-249`).
   Es wird kein Client-Credential erzeugt oder an den Proxy übergeben.
4. Der gepinnte Proxy registriert `/healthz`, `/v1/messages` und
   `/v1/messages/count_tokens` direkt am Axum-Router, ohne Auth-Layer zwischen
   Route und Handler (`raine/claude-code-proxy@52c5501:src/server.rs:102-127`).
5. Unter macOS verwendet der Codex-Provider ohne `CCP_CONFIG_DIR` den eigenen
   Keychain-Store `claude-code-proxy.codex`/`auth`
   (`raine/claude-code-proxy@52c5501:src/providers/codex/auth/token_store.rs:6-7,49-67`).
   Aus dem geladenen `auth.access` erzeugt der Client den
   `Authorization: Bearer ...`-Header selbst
   (`raine/claude-code-proxy@52c5501:src/providers/codex/client.rs:95-113`). Der
   lokale HTTP-Aufrufer braucht dieses Token somit gerade nicht.

Damit kann jeder Prozess, der den maschinenlokalen Port erreicht, einen
syntaktisch gültigen GPT-Request einspeisen und die unter dem
WhisperM8-/Proxy-User autorisierte Antwort über seinen eigenen Socket lesen.
Der Angriff liest das Keychain-Secret nicht aus; er nutzt die vom Proxy daraus
abgeleitete Capability. Das ist genau die behauptete Authentisierungsumgehung.

### Widerlegungsversuche und Gegenbelege

- **Loopback-only:** Die Bindungen in `ClaudeGPTMixRouter.swift:127-134` und
  `ClaudeCodeProxyManager.swift:237-249` verhindern LAN-/WAN-Zugriff. Loopback
  ist hier aber eine Host-, keine User- oder Prozessidentität; der Code fragt
  an keiner Stelle Peer-Credentials ab.
- **Credential-Strip:** Vor dem Codex-Proxy entfernt der Router Claude-
  Credentials korrekt (`ClaudeGPTMixRouter.swift:317-324`). Das reduziert die
  Auswirkung eines kompromittierten Backends und verhindert Cross-Provider-
  Secret-Leaks, ändert aber nichts daran, dass der Proxy seine eigene
  Keychain-Autorisierung für jeden Request einsetzt.
- **HTTP-Härtung:** Größenlimits
  (`ClaudeGPTMixRouter.swift:73-75,502-525`), Host-/Port-Bindung
  (`ClaudeGPTMixRouter.swift:537-545`) und serielle Connection-Queues
  (`ClaudeGPTMixRouter.swift:434-469`) schützen Protokoll und Speicher, nicht
  den Aufrufer.
- **Integrationstest:** Ein Raw-Client sendet einen frei gewählten Bearer-Wert
  an den Router und erhält erfolgreich die Codex-Antwort; upstream ist der
  Authorization-Header sogar vollständig entfernt
  (`Tests/WhisperM8Tests/ClaudeGPTMixRouterTests.swift:219-267`). Der beliebige
  Client-Header wird weder validiert noch als Authentisierung verwendet.
- **Planlage:** Der Vollreview priorisiert ausdrücklich „Lokalen Proxy
  authentifizieren beziehungsweise dessen Prozess/Owner prüfen“
  (`docs/plans/claudex-gpt-backend/REVIEW-2026-07-18.md:55-63`). Ein bereits
  vorhandener Schutz ist dort nicht dokumentiert und im Code nicht vorhanden.

### Schluss

Der Angriff überschreitet im vorgegebenen Modell eine macOS-Account-/Keychain-
Grenze und ermöglicht fremde Modellnutzung unter dem autorisierten Account.
Die Voraussetzung ist lokaler Codezugriff auf demselben Mac; der Impact ist
aber ein konkreter Authentisierungs-Bypass, nicht nur Rate-Limit-Verbrauch.
Daher bleibt die eigene Einstufung **hoch**.

## G03 — Geerbtes `CCP_TRAFFIC_LOG` persistiert Chat-, Tool- und Antwortinhalte

**Urteil: BESTAETIGT**  
**Eigene Schwere: niedrig**

### Exakter Auslösepfad

1. `processEnvironment` beginnt mit einer vollständigen Kopie des übergebenen
   Basis-Environments; standardmäßig ist das
   `ProcessInfo.processInfo.environment`
   (`WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-93`). Entfernt
   werden geerbte `CLAUDE_CODE_*`/`CLAUDECODE`, `CLAUDE_CONFIG_DIR` und
   `NO_COLOR` (`LoginShellEnvironment.swift:94-132`). Ein generischer Filter
   für `CCP_*` oder speziell `CCP_TRAFFIC_LOG` existiert nicht
   (`LoginShellEnvironment.swift:91-137`).
2. Der Proxy-Manager nutzt genau diesen Helper als Default-Resolver
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:161-177`) und
   ändert beim Start nur `CCP_BIND_ADDRESS`
   (`ClaudeCodeProxyManager.swift:237-249`). Ein geerbtes
   `CCP_TRAFFIC_LOG=1|true|yes` bleibt folglich im Child.
3. Der Upstream aktiviert Capture exakt für diese drei Werte
   (`raine/claude-code-proxy@52c5501:src/traffic.rs:32-50`). Er schreibt unter
   anderem den vollständigen normalisierten Anthropic-Request
   (`raine/claude-code-proxy@52c5501:src/server.rs:393-424`), den übersetzten
   Codex-Request und erfolgreiche SSE-Response
   (`raine/claude-code-proxy@52c5501:src/providers/codex/client.rs:939-985`)
   sowie Up-/Downstream-Events
   (`raine/claude-code-proxy@52c5501:src/traffic.rs:272-297`). Die
   Traffic-JSON-Helfer wenden zwar Redaction an
   (`raine/claude-code-proxy@52c5501:src/traffic.rs:68-103`), entfernen aber
   nicht pauschal Prompt- und Toolinhalte aus den übergebenen Bodies.
4. Der verwaltete Child-Prozess schreibt stdout und stderr auf
   `FileHandle.nullDevice`
   (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:540-552`). Die
   WhisperM8-Settings erhalten deshalb aus diesem Prozesspfad keinen sichtbaren
   Capture-Status.
5. Die bestehende Testkonvention bestätigt, dass nicht speziell bereinigte
   Environment-Werte erhalten bleiben: `HOME` bleibt beim
   `processEnvironment`-Merge bestehen
   (`Tests/WhisperM8Tests/LoginShellEnvironmentTests.swift:45-50`), während die
   Tests nur die expliziten Claude-Variablen als entfernt erwarten
   (`LoginShellEnvironmentTests.swift:118-159`).

### Widerlegungsversuche und begrenzende Gegenbelege

- **Kein Import des kompletten Login-Shell-Environments:** Der Helper führt die
  Login-Shell nur für `echo $PATH` aus
  (`LoginShellEnvironment.swift:163-180`). `CCP_TRAFFIC_LOG` wird daher nicht
  aus einer beliebigen `.zprofile`-Sitzung nachgeladen; es muss bereits im
  Environment des gestarteten WhisperM8-Prozesses liegen. Das konkrete
  Szenario „Export im selben Terminal, danach Entwicklungsstart“ erfüllt diese
  Voraussetzung, ein normaler Launchd-/Finder-Start in der Regel nicht.
- **Explizites Upstream-Opt-in:** `CCP_TRAFFIC_LOG` ist selbst der dokumentierte
  Aktivierungsschalter; ohne einen der Werte `1|true|yes` ist Capture aus
  (`raine/claude-code-proxy@52c5501:src/traffic.rs:32-46`). Der User oder dessen
  Launch-Kontext hat die Diagnose somit vorher ausdrücklich aktiviert.
- **Teilweise Redaction:** JSON-Captures laufen durch `redact_traffic`
  (`raine/claude-code-proxy@52c5501:src/traffic.rs:73-103`). Das schützt
  benannte Credential-Felder, nicht den eigentlichen Gesprächsinhalt.
- **Bewusste Environment-Policy:** Kommentare und Tests verlangen, dass
  andere Environment-Werte grundsätzlich erhalten bleiben
  (`LoginShellEnvironment.swift:82-90`;
  `LoginShellEnvironmentTests.swift:45-57`). Eine minimale Allowlist wäre also
  eine neue, potenziell featurebrechende Policy; der engere Fix ist das
  gezielte Neutralisieren sicherheitsrelevanter Proxy-Diagnosevariablen.

### Schluss

Der technische Mechanismus und das behauptete zweite Payload-Archiv sind
belegt. Die ursprüngliche Einstufung **mittel** ist jedoch nicht angemessen:
Erforderlich ist ein bewusst gesetzter Diagnose-Schalter im tatsächlich
geerbten App-Environment, und der geprüfte Pfad belegt keinen unautorisierten
Leser der Dateien. Das ist eine reale Privacy-/Retention-Falle und verdient
Härtung, aber nach dem vorgegebenen Angreifermodell nur **niedrig**.

## G04 — Kill-Switch deaktiviert Launch-Routing, lässt Listener weiterlaufen

**Urteil: BESTAETIGT**  
**Eigene Schwere: mittel**

### Exakter Auslösepfad

1. Der Toggle ist im Produktionscode als zentraler Kill-Switch beschrieben;
   `false` soll GPT-Stempel ignorieren und ohne Proxy-Argumente/-Environment
   starten (`WhisperM8/Support/AppPreferences.swift:257-262`). Die Settings-UI
   verspricht für neue Claude-Chats direkte Anthropic-Verbindung
   (`WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:27-32`).
2. Die an `backendEnabled` gebundene `.task` ruft beim Ausschalten nur
   `clearStatus()` und den Agent-Definition-Sync auf
   (`GPTBackendSettingsPage.swift:66-78`); `clearStatus` leert ausschließlich
   View-State (`GPTBackendSettingsPage.swift:329-337`). Weder
   `stopIfSelfStarted()` noch `ClaudeGPTMixRouter.stop()` liegt in diesem Pfad.
3. Stoppen ist eine separate Button-Aktion und ruft nur
   `proxyManager.stopIfSelfStarted()` auf
   (`GPTBackendSettingsPage.swift:47-63`). Der Button ist nicht der Toggle-
   Callback.
4. `stopIfSelfStarted` prüft nur, ob ein eigener Proxy-Handle registriert ist.
   Nur dann stoppt es den Router; anschließend wird lediglich der eigene Handle
   entfernt (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:286-300`).
   Bei einem zuvor positiv erkannten externen Proxy gibt es keinen Handle, also
   bleibt der von WhisperM8 gestartete In-Process-Router aktiv.
5. Neue Launches sind tatsächlich geschützt: Der detached Launch-Guard ruft
   `ensureRunning` nur bei aktivem Toggle auf
   (`WhisperM8/Views/AgentSessionDetailView.swift:393-415`), und der Builder
   injiziert `ANTHROPIC_BASE_URL` nur bei aktivem Resolver
   (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:259-295`). Der
   Toggle wirkt daher wie behauptet auf zukünftige Launches, nicht auf den
   bestehenden Listener-Lifecycle.
6. Der vorhandene Test pinnt das Restverhalten ausdrücklich: Nach positiver
   externer Reachability muss `stopIfSelfStarted()` den Router **nicht** stoppen
   (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:223-236`).

### Widerlegungsversuche und bewusste Designentscheidung

- **Laufende PTYs:** Der Manager kommentiert ausdrücklich, der Router solle
  bereits laufende PTY-Sessions weiter versorgen, weil deren
  `ANTHROPIC_BASE_URL` beim Spawn eingefroren ist
  (`ClaudeCodeProxyManager.swift:286-291`). Das erklärt die Entscheidung, ist
  aber kein Gegenbeleg zum Finding: Der Toggle blendet Status aus und der
  unauthentisierte Listener bleibt auch für fremde lokale Clients erreichbar.
- **App-Quit:** Der Manager registriert einen Termination-Observer, der
  `stopIfSelfStarted()` aufruft (`ClaudeCodeProxyManager.swift:198-205`). Beim
  App-Ende verschwindet zudem der In-Process-Router mit dem Prozess. G04 betrifft
  ausdrücklich das Umschalten während die App weiterläuft.
- **Manueller Stop bei eigenem Proxy:** Hat WhisperM8 den Proxy selbst
  gestartet, stoppt die separate Aktion Router und Prozess
  (`ClaudeCodeProxyManager.swift:292-300`;
  `ClaudeCodeProxyManagerTests.swift:48-77`). Das widerlegt nicht, dass der
  Master-Toggle dies nicht tut, und deckt den extern erkannten Proxy nicht ab.
- **Dokumentierte Grenze:** Die QA nennt als Soll beim Toggle „Proxy/Router
  werden gestoppt“
  (`docs/plans/claudex-gpt-backend/QA-CHECKLISTE.md:69-74`), führt zugleich aber
  „wirkt erst auf den nächsten Launch“ als bekannte Grenze auf
  (`QA-CHECKLISTE.md:82-88`). Diese widersprüchliche Dokumentation bestätigt,
  dass das heutige Verhalten bewusst bekannt, aber nicht vertragsklar gelöst
  ist.
- **Planvertrag:** Der ursprüngliche Plan nennt bei AUS ausdrücklich „kein
  Router, kein Proxy-Autostart, keine Proxy-Env“ und einen „echten
  Kill-Switch“ (`docs/plans/claudex-gpt-backend/PLAN.md:97-108`). Der
  Produktionscode erfüllt davon den Launch-Teil, nicht das sofortige
  Listener-Teardown.

### Schluss

G04 ist kein Missverständnis eines rein zukünftigen Launch-Flags: Der Code und
ein Test halten den Listener bewusst am Leben. Wegen der Abhängigkeit von G02
und der lokalen Angriffsvoraussetzung ist **mittel** angemessen. Eine sichere
Lösung muss den Schutz laufender PTYs und die Schließung der extern nutzbaren
Capability explizit gegeneinander abwägen; das bloße Ausblenden des Status ist
kein Teardown.

## Die drei wichtigsten bestätigten Findings

1. **G01 — Port-Identitäts-Bypass (hoch):** Ein nachbildbares statisches
   Health-Protokoll lässt einen fremden Listener zum vollständigen GPT-Upstream
   werden (`ClaudeCodeProxyManager.swift:225-283,469-537`;
   `ClaudeGPTMixRouter.swift:529-575`).
2. **G02 — Unauthentisierter OAuth-Capability-Export (hoch):** Router und Proxy
   prüfen keinen lokalen Client, während der Proxy selbst das Keychain-Token in
   den Codex-Upstream-Header einsetzt
   (`ClaudeGPTMixRouter.swift:403-423,534-575`;
   `raine/claude-code-proxy@52c5501:src/providers/codex/client.rs:95-113`).
3. **G04 — Unvollständiger Kill-Switch (mittel):** Ausschalten verhindert neue
   Router-Launches, beendet den bereits laufenden Router/Proxy aber nicht und
   blendet dessen Status aus
   (`GPTBackendSettingsPage.swift:66-78,329-337`;
   `ClaudeCodeProxyManager.swift:286-300`).
