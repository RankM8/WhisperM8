---
status: abgeschlossen
updated: 2026-07-18
description: Adversarische Verifikation der drei Muster-Recherchen zu Supervisor-Verträgen, JSONL-Schema-Drift sowie Crash-Observability und Secrets gegen Primärquellen, aktuellen WhisperM8-Code und Refactor-Roadmap.
---

# Runde 3: Verifikation der Recherche-Muster

## Auftrag, Maßstab und Methode

Geprüft wurden:

- `03-vergleich/supervisor-detach-vertraege.md`,
- `03-vergleich/jsonl-schema-drift.md`,
- `03-vergleich/tech-observability-secrets.md`.

Die Prüfung umfasste Stichproben an den jeweils genannten lokalen Fremdquellen,
die commit-gepinnten containerd-/runc-Webquellen, die MetricKit-SDK-Header und
den im Observability-Dokument verlinkten Apple-Forumsbeleg. Jede zentrale
Empfehlung wurde danach gegen den aktuellen WhisperM8-Produktcode und die
verbindliche Reihenfolge der Roadmap geprüft. Es wurden weder Build noch Tests
ausgeführt und keine Produktdatei geändert.

Bewertungsskala:

- **TRAGFAEHIG:** Primärbeleg, heutiger Defekt und Roadmap-Scope passen; die
  Empfehlung kann mit den benannten Regression-Gates umgesetzt werden.
- **FRAGWUERDIG:** Richtung plausibel, aber Beleg, Zeitpunkt, Umfang oder
  Kompatibilitätsvertrag reichen in der vorgeschlagenen Form nicht.
- **ABLEHNEN:** Als konkrete Kern-Empfehlung würde die Maßnahme einen bestehenden
  Vertrag brechen, eine Roadmap-Grenze überspringen oder einen unbelegten
  Großumbau vorziehen. Das verwirft nicht zwingend die zugrunde liegende
  Technologie für alle Zukunft.

## Gesamturteil

| Recherche | Kern-Empfehlung | Urteil | Kurzbegründung |
|---|---|---:|---|
| Supervisor | V1 Ready-/Detach-Acceptance-Gate | **TRAGFAEHIG** | Schließt exakt die belegte Spawn→`setsid()`-Lücke und entspricht R2.4. |
| Supervisor | V2 Waiter besitzt den Turn nicht | **TRAGFAEHIG** | Ist bereits Produktsemantik und muss erhalten bleiben. |
| Supervisor | V2 zusätzlicher dauerhafter Control-Kanal mit Probe | **FRAGWUERDIG** | Für N07 nicht erforderlich; heutiges Reattach erfolgt per Short-ID und State. Roadmap fordert einen Bootstrap-Handshake, keinen neuen Broker. |
| Supervisor | V3 Prozess-/Protokoll-Finalitäts-Gate | **TRAGFAEHIG** | Drain existiert; Termination-Reason und `turn.completed` fehlen tatsächlich. |
| Supervisor | V3 `partial`/`stopped` auf neue Nicht-Erfolgs-Exitcodes umdeuten und nur parsebaren Report akzeptieren | **ABLEHNEN** | Bricht den ausdrücklich verbindlichen Maschinenvertrag: Exit 0 gilt heute für `success` **oder** `partial`, unparsebarer Rohtext bleibt zulässig. |
| Supervisor | V4 dauerhafter Stop-Latch, atomar mit Prozessregistrierung | **TRAGFAEHIG** | Behebt das konkrete No-op-Fenster und ist in R2.4 vorgesehen. |
| JSONL | P0 Provider-Korrelations-IDs statt FIFO | **TRAGFAEHIG** | Quelldaten tragen IDs; WhisperM8 verwirft sie und paart global per FIFO. |
| JSONL | P0 explizite Parse-Outcomes und sichtbare Unknown-Diagnose | **TRAGFAEHIG** | Behebt N16 ohne bekannte Inhalte zu entfernen; entspricht P1.11. |
| JSONL | P1 gemeinsamer Full-/Tail-Envelope samt `pendingFragment` | **FRAGWUERDIG** | Teilzeilen-Semantik ist richtig; ein gemeinsamer Scanner-Umbau gehört aber hinter die N15/N16-Oracles und überschneidet sich mit P2.4 in Welle 4. |
| JSONL | P1 breite Alias-/Feature-Detection | **FRAGWUERDIG** | Nur fixture-belegte Providerformen übernehmen; spekulative Aliase können Bedeutungen vermischen und liegen außerhalb des eng begrenzten P1.11. |
| JSONL | P2 Raw-Byte-Range-/Oversize-Subsystem als Teil von P1.11 | **ABLEHNEN** | Für N15/N16 nicht nötig, privacy-sensitiv und ein eigener Scanner-/Produktumfang; erst separat nach Messung und Privacy-Vertrag bewerten. |
| Observability | MetricKit als sofortige Welle-0-Produktmaßnahme | **FRAGWUERDIG** | Native Baseline ist plausibel, Direct-Distribution-Beleg aber nur ein DTS-Test plus Einzelfall; die Roadmap reserviert W0 für Oracles und verschiebt den Recorder-Fix in W1. Erst Fixture/Spike, dann Einordnung. |
| Observability | MetricKit **plus KSCrash Recording** als W0/P0 | **ABLEHNEN** | Neue Crashhandler-Abhängigkeit und Package-Eingriff vor C01/C02-Fix sowie außerhalb der konsolidierten Roadmap. KSCrash bleibt eine spätere Option, nicht W0-Pflicht. |
| Observability | Sentry Self-Hosted nur später bei Flottenbedarf | **TRAGFAEHIG** | Die Quellen belegen den Betriebsumfang; die Empfehlung vermeidet verfrühte Telemetrie. |
| Secrets | Frisches, pro Prozessklasse allowlistetes Child-Environment | **TRAGFAEHIG** | Behebt N09 und passt zu P1.1, sofern normale Shell-Tabs getrennt und Git/SSH/MCP-Fähigkeiten explizit regressionsgetestet werden. |
| Secrets | Keychain-Migration write→readback→delete | **TRAGFAEHIG** | Behebt den belegten Delete-on-unverified-write-Pfad und entspricht R2.3. |
| Secrets | Profil-Rename direkt über Security.framework, argv-frei und transaktional | **TRAGFAEHIG** | Beseitigt die reale argv-Exposition ohne CLI-Ersatz; passt zu P1.1. |

## 1. Quellenstichproben

### 1.1 Supervisor-Quellen

Die lokalen Revisionen stimmen mit der Quellenkonvention überein: tmux
`cad1c81c711a` und Zellij `68362d4cf0b2`.

- tmux wartet vor der Detach-Nachricht auf Control- und Dateipuffer, sendet
  `MSG_DETACH`, erhält `MSG_EXITING`, löst erst dann Session/TTY und bestätigt
  mit `MSG_EXITED`; erst dieses Event beendet den Client
  (`<tmux>/server-client.c:2279-2326,2604-2611`;
  `<tmux>/client.c:728-772`). Das trägt die Aussage „Detach ist bestätigtes
  Handoff, nicht bloß lokaler Spawn-Erfolg“.
- Zellij trennt `KillSession` und `DetachSession`: Kill bricht den Server-Loop
  ab, Detach entfernt nur Clients und droppt den Completion-Sender ausdrücklich
  nach der Trennung (`<zellij>/zellij-server/src/lib.rs:1430-1442,1462-1493`;
  `<zellij>/zellij-server/src/route.rs:1137-1153`). Das trägt die Owner-/Waiter-
  Trennung.
- Der gepinnte containerd-Code registriert in `preStart` den Exit-Subscriber vor
  `container.Start`, prüft in `handleStarted` unter `lifecycleMu` einen bereits
  eingetroffenen Exit und trägt den Prozess nur andernfalls als laufend ein
  ([containerd service.go:149-219,295-350]). `Wait` liefert erst nach `p.Wait`
  Exitstatus und Exitzeit ([containerd service.go:575-594]). Das ist ein echtes
  Frühereignis-Latch, aber nur ein Analogon für WhisperM8s Stop-Race, keine
  Begründung für einen vollständigen containerd-artigen Control-Plane-Umbau.
- runc publiziert den PID-File atomar per exklusiver temporärer Datei und Rename;
  der detached Pfad liefert erst nach Start, Console-Wait, PID-File und
  Notify-Forwarding 0 ([runc utils_linux.go:161-182,288-326]). Der Test verlangt
  danach einen laufenden Container und identische PID in Datei und Runtime-State
  ([runc start_detached.bats:34-55]). Das stützt V1 eng und direkt.

### 1.2 JSONL-Quellen

Die lokalen Revisionen wurden als `ccusage@7acee6c5853c`,
`sniffly@a237d7e9a9b3` und `lemmy@92e4ba60328b` gelesen.

- `ccusage` degradiert falsch typisierte optionale Zahlen und Nested-Objekte,
  statt den ganzen Record zu verlieren, und kennt beobachtete Codex-Aliase für
  Timestamp, Modell und Usage (`<ccusage>/rust/crates/ccusage/src/adapter/jsonl.rs:47-83,86-140`;
  `<ccusage>/rust/crates/ccusage/src/adapter/codex/types.rs:7-66,136-198`).
  Die Recherche zieht die richtige Grenze: `records(...).filter_map(...)`
  verwirft nicht deserialisierbare Records weiterhin vollständig
  (`<ccusage>/rust/crates/ccusage/src/adapter/jsonl.rs:47-61`) und ist daher kein
  Vorbild für Unknown-Erhalt.
- `claude-trace` hält rohe Request-/Response-Paare neben der Projektion und
  modelliert Tool-IDs ausdrücklich (`<lemmy>/apps/claude-trace/src/types.ts:3-32,49-88`).
  Die Resultatzuordnung verwendet `tool_use.id`/`tool_use_id` als Dictionary-
  Schlüssel statt Reihenfolge (`<lemmy>/apps/claude-trace/src/shared-conversation-processor.ts:587-638`).
  Das ist ein belastbarer Beleg für N15, obwohl die Recherche korrekt offenlegt,
  dass `claude-trace` API-SSE und nicht native CLI-JSONL verarbeitet.
- `sniffly` isoliert Decode-Fehler pro Zeile und hält bei erkannten Messages das
  Original-Dictionary als `_raw_data`; sein geschlossener Message-/Blockfilter
  bleibt aber verlustreich (`<sniffly>/sniffly/core/processor.py:340-403,424-479,481-521`).
  Die Recherche überhöht diese Quelle nicht.

### 1.3 Observability-/Secrets-Quellen und Webbeleg

Die genannten lokalen Revisionen für KSCrash, PLCrashReporter, Sentry,
OpenSSH, Git, KeychainAccess und Runic stimmen mit den Repositories überein.

- MetricKit deklariert Callstack, Termination-Reason, Mach-Typ/-Code, Signal und
  auf macOS 14 `exceptionReason`
  (`<MetricKit-SDK>/MXCrashDiagnostic.h:21-73`). Der SDK-Header macht die
  Zustellung subscriber- und App-Laufzeit-abhängig und nennt mindestens tägliche
  Callbacks (`<MetricKit-SDK>/MXMetricManager.h:105-138`).
- Der konkrete Direct-Distribution-Beleg ist schwächer als ein API-Vertrag:
  Im Apple-DTS-Thread 821002 bestätigt Quinn allgemein die macOS-Funktion und
  empfiehlt den ABRT→Relaunch-Test; ein einzelner Entwickler meldet danach
  promptes `didReceiveDiagnosticPayloads` für seine Developer-ID-verteilte
  Host-App. Der im Vergleich angegebene generische Tag-Link ist dafür zu
  unspezifisch; der belastbare Link ist
  <https://developer.apple.com/forums/thread/821002>. Die Recherche zieht daraus
  zu Recht noch keine formale Distributionsgarantie und fordert ein eigenes
  signiertes Fixture.
- KSCrash deklariert Mach-, Signal-, C++- und NSException-Monitore sowie die
  debugger-unsichere Mach-Option
  (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashMonitorType.h:44-78,93-147`).
  Memory-Introspection kann Objekt-/C-String-Inhalte in den Report aufnehmen und
  ist standardmäßig aus
  (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashConfiguration.h:92-110`).
  Der Store zeichnet auch ohne Sink lokal auf
  (`<KSCrash>/Sources/KSCrashRecording/include/KSCrashReportStore.h:73-114`).
  Die technische Beschreibung ist damit belastbar; daraus folgt aber keine
  Roadmap-Priorität.
- OpenSSH baut das Session-Environment leer auf und fügt Basiswerte einzeln
  hinzu; User-Environment läuft bei aktivierter Policy durch eine Allowlist
  (`<openssh>/session.c:934-1025,1059-1083`). Das trägt die Capability-Richtung,
  ist aber kein Beleg dafür, welche Variablen ein universeller lokaler
  Claude-/Codex-Host gefahrlos streichen kann.
- KeychainAccess wirft bei Conversion-, Copy-, Update-, Add- und Delete-Fehlern
  (`<KeychainAccess>/Lib/KeychainAccess/Keychain.swift:658-740,808-827`). Runic
  löscht das Legacy-Item nur nach erfolgreichem Ziel-Write
  (`<Runic>/Sources/RunicCore/ProviderCredentialKeychainMigration.swift:41-71,153-184`).
  Git liest Credentials über stdin, während argv nur die Operation enthält
  (`<git>/builtin/credential.c:12-50`;
  `<git>/contrib/credential/osxkeychain/git-credential-osxkeychain.c:391-463,480-510`).
  Diese Quellen stützen Fehlerkanal, Delete-Gate und argv-freie Übergabe; der
  zusätzliche bytegenaue Readback ist eine vernünftige WhisperM8-Härtung, aber
  eine eigene Designentscheidung.

## 2. Supervisor-Detach-Verträge gegen Produktcode und Roadmap

### 2.1 V1 — Ready-/Detach-Acceptance-Gate

**Urteil: TRAGFAEHIG**

Der heutige Launcher startet ein direktes `Process`-Kind und gibt unmittelbar
nach `process.run()` dessen PID zurück; ein ACK-Kanal existiert nicht
(`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-60`). Das Kind
führt `setsid()`, SIGHUP-/SIGTERM-Konfiguration und Signal-Source-Installation
erst später aus (`WhisperM8/CLI/AgentSuperviseCommand.swift:8-33`). Trotzdem
persistiert der Parent diese frühe PID und emittiert anschließend
`state:"spawning"` mit Exit 0
(`WhisperM8/CLI/AgentCLICommand.swift:513-561`).

Ein kleiner geerbter Bootstrap-Kanal, der erst nach Detach, Signalbereitschaft
und atomarem State-Write bestätigt, behebt genau diese Strecke. Das ist kein
Ersatz der echten Codex-CLI: Der Supervisor startet weiterhin `codex exec` über
das aufgelöste echte Binary (`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:72-75,100-128`).
Die Roadmap fordert ausdrücklich Ready-/Detach-Handshake und Persistenz erst
nach Start (`05-roadmap/refactor-roadmap.md:125-139`).

**Gate:** Die neue JSON-Aussage muss capability-/versionsbewusst eingeführt und
zusammen mit der gebündelten CLI-Skill-Dokumentation geändert werden; dort ist
heute `state:"spawning"` der dokumentierte Detach-Vertrag
(`WhisperM8/Resources/whisperm8-agent-skill.md:100-102,123-129`).

### 2.2 V2 — Waiter-Semantik ja, dauerhafter Control-Kanal nein

**Urteil Owner-/Waiter-Trennung: TRAGFAEHIG**  
**Urteil verpflichtender dauerhafter Probe-Kanal: FRAGWUERDIG**

Die nicht besitzende Waiter-Semantik ist bereits explizit implementiert:
`run --wait` startet ebenfalls den detachten Supervisor; Ctrl-C/Timeout beendet
nur den Beobachter, und `agent wait <id>` hängt sich wieder an
(`WhisperM8/CLI/AgentCLICommand.swift:445-459`). Der Follow-Pfad liest den
korrigierten persistierten State per Short-ID bis zum terminalen Zustand
(`WhisperM8/CLI/AgentCLICommand.swift:465-484`). Diese Semantik darf durch den
V1-Fix nicht verloren gehen.

Ein **dauerhaftes** Supervisor-RPC samt Liveness-Probe ist für N07 dagegen nicht
belegt. R2.4 verlangt einen Start-Handshake, Stop-Latch und korrekte Exit-Wahrheit,
aber keinen neuen langlebigen Broker (`05-roadmap/refactor-roadmap.md:125-139`).
Die bestehende Reattach-Funktion müsste für einen Control-Kanal doppelte
Wahrheiten, Socket-Retention und Restart-Recovery beherrschen. Deshalb nur den
kurzlebigen Bootstrap-ACK umsetzen; einen dauerhaften Kanal erst bei einem
separat belegten Bedarf planen.

### 2.3 V3 — Finalität trennen, bestehenden Exit-Vertrag erhalten

**Urteil Prozess-/Protokoll-Gate: TRAGFAEHIG**  
**Urteil Report-/Exitcode-Neudefinition: ABLEHNEN**

Der Runner besitzt bereits die richtige Drei-Wege-Barriere aus stdout-EOF,
stderr-EOF und Termination (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:240-310`).
Er übernimmt aber nur `terminationStatus`, nicht `terminationReason`
(`CodexExecRunner.swift:267-271`), und sein Result trägt weder Reason noch
`turnCompleted` (`CodexExecRunner.swift:39-50`). Der Stream-State merkt nur die
erste Thread-ID und `turn.failed`
(`CodexExecRunner.swift:493-500`). Entsprechend erklärt `mapOutcome` Exit 0 ohne
Stall/`turn.failed` zu `.done`, auch wenn `lastMessage` fehlt
(`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-119`).

Termination-Reason, Exit 0, gelatchtes `turn.completed`, kein `turn.failed` und
eine vorhandene finale Nachricht als Konjunktion sind daher tragfähig und
entsprechen R2.4 (`05-roadmap/refactor-roadmap.md:125-139`).

Nicht tragfähig ist die zusätzliche Forderung, `partial` und `stopped` zwingend
auf neue Nicht-Erfolgswerte zu legen und einen unparsebaren Report nie als
technisch abgeschlossenen Turn zuzulassen. Der externe Maschinenvertrag erklärt
Exit 0 ausdrücklich als „Report-status success oder partial“ und erlaubt bei
`report:null` weiterhin `rawLastMessage`
(`WhisperM8/Resources/whisperm8-agent-skill.md:113-121,158-161`). Der Code bildet
nur `.failed` beziehungsweise Report-`failure` auf Exit 2 ab
(`WhisperM8/CLI/AgentCLICommand.swift:617-629`); die vier Codes sind öffentlich
festgelegt (`WhisperM8/CLI/AgentCLIArguments.swift:3-13`). Eine Änderung wäre eine
Versionierung des CLI-Vertrags, kein Bugfix für N08. Sie ist ohne eigenes
Feature-Inventar, Migrationsplan und Consumer-Gates abzulehnen.

### 2.4 V4 — Stop vor Prozessregistrierung latchen

**Urteil: TRAGFAEHIG**

`requestStop()` setzt sein Bool unter einem Supervisor-Lock und ruft danach
`runner.terminate()` (`WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-57`).
Der Runner veröffentlicht das Kind aber erst **nach** `process.run()` unter einem
anderen Lock (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:274-286`);
`terminate()` ist vorher ein No-op (`CodexExecRunner.swift:327-335`). Zusätzlich
sendet `agent stop` nur SIGTERM an die gespeicherte PID, ignoriert den
`kill(2)`-Rückgabewert und meldet nach dem Pollfenster dennoch Exit 0
(`WhisperM8/CLI/AgentCLICommand.swift:355-392`).

Ein persistierter Stop-Intent plus eine einzige atomare
`registerProcessAndApplyPendingStop`-Operation schließt genau dieses Race. R2.4
fordert denselben Vertrag (`05-roadmap/refactor-roadmap.md:125-139`). Die
containerd-Quelle trägt das Latch-Muster, ohne dass dafür dessen gesamte
Architektur kopiert werden muss.

## 3. JSONL-Schema-Drift gegen Produktcode und Roadmap

### 3.1 Provider-ID durch Modell, Reader und Timeline tragen

**Urteil: TRAGFAEHIG**

`AgentChatBlock` besitzt heute weder bei Tool-Use noch Result eine
Korrelations-ID, und der Stable-ID-Digest kennt nur Name/Input beziehungsweise
Inhalt/Fehler (`WhisperM8/Models/AgentChatTranscript.swift:53-79,93-109`). Der
Claude-Reader liest die vorhandenen ID-Felder nicht
(`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:160-180,204-220`),
der Codex-Reader verwirft `call_id` ebenfalls
(`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:151-170`). Die
Timeline paart über den ersten global offenen Index
(`WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:89-100,119-138,228-251`).

Die minimale Änderung — optionale ID im Blockmodell, Übernahme in beiden
Readern, Digest-Erweiterung und ID-Index mit ausdrücklich markiertem
Single-Candidate-Fallback für historische ID-lose Daten — behebt N15 ohne
bekannte Timeline-Features zu entfernen. Genau diesen Umfang nennt P1.11
(`05-roadmap/refactor-roadmap.md:338-354`). Orphans und Duplikate sichtbar zu
lassen ist sicherer als eine möglicherweise falsche Zuordnung.

### 3.2 Parse-Outcome statt mehrdeutigem `nil`

**Urteil: TRAGFAEHIG**

Der Codex-Reader gibt für unbekannte äußere, `event_msg`- und `response_item`-
Typen jeweils `nil` zurück; der Tail-Pfad entfernt alles per `compactMap`, und
der Full-Pfad zählt nur ungültiges JSON als `skipped`
(`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:65-86,95-107,112-145,151-199`).
Der Claude-Reader trennt bekannte ignorierte Metadaten und neue unbekannte
Blocks ebenfalls nicht im Rückgabetyp
(`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:132-144,160-183,195-231`).

Ein interner Outcome-Typ `projected/ignoredKnown/unknown/malformed/pendingFragment`
ist eine passende kleine Naht. P1.11 verlangt Zählung, sichtbare Degradation und
diagnostischen Erhalt unbekannter gültiger Events
(`05-roadmap/refactor-roadmap.md:338-354`). Das UI sollte nur einen begrenzten,
nicht sensitiven Hinweis rendern; kein kompletter Raw-Dump gehört automatisch
in die Timeline.

### 3.3 Teilzeilen-Semantik übernehmen, Scanner-Konsolidierung nicht vorziehen

**Urteil: FRAGWUERDIG**

`LineStream` puffert bis Newline, gibt am EOF aber auch den nicht terminierten
Rest als reguläre Zeile zurück
(`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:301-334`). Der
Tail-Reader splittet den gelesenen String ebenfalls ohne Unterscheidung zwischen
vollständiger letzter Zeile und live wachsendem Fragment
(`ClaudeTranscriptReader.swift:271-297`). `pendingFragment` statt temporärem
Malformed/Drop ist deshalb semantisch richtig.

Die Recherche schlägt zugleich einen gemeinsamen Envelope-/Diagnostikpfad für
Full und Tail vor. Das ist mehr als N15/N16 verlangen und berührt den späteren
Roadmap-Punkt „gemeinsame Scannerbausteine“, der provider-spezifische Semantik
erst in Welle 4 extrahiert (`05-roadmap/refactor-roadmap.md:387-400`). In Welle 3
nur die Teilzeilen-Oracles und identische Outcome-Semantik ergänzen; keine
vorzeitige Scanner-Neuarchitektur.

### 3.4 Aliase nur nach beobachtetem Fixture

**Urteil: FRAGWUERDIG**

Der ccusage-Beleg zeigt robuste, **beobachtete** Alternativformen. WhisperM8s
Codex-Reader akzeptiert derzeit nur String-Timestamps und feste
`(outerType,payload.type)`-Formen
(`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:112-145,234-239`).
Feature Detection ist daher als Strategie plausibel. P1.11 ist laut Roadmap aber
bewusst auf bestätigte N15/N16-Verträge und einen Golden-Korpus begrenzt
(`05-roadmap/refactor-roadmap.md:338-354`); das globale Ship-Gate verlangt
capability-/versionsgegatete Formate (`05-roadmap/refactor-roadmap.md:473-482`).

Folge: Alias nur übernehmen, wenn ein gespeichertes reales Provider-Fixture und
ein semantisch eindeutiger Decoder vorliegen. Eine pauschale Aliasbibliothek aus
einem Statistiktool ist kein tragfähiger P1-Umfang.

### 3.5 Raw-Byte-Range und Oversize-Base64 nicht in P1.11 hineinziehen

**Urteil: ABLEHNEN**

Der Full-Reader ist zwar chunked, hält aber eine Einzelzeile bis Newline und
materialisiert sie anschließend über `JSONSerialization`; Image-Base64 wird erst
**nach** diesem Parse auf eine Längenmetrik reduziert
(`WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:79-100,160-172,301-334`).
Das Speicherproblem ist real. Ein allgemeiner Raw-Zugriff über File-URL,
Byte-Range, Digest und Preview ist jedoch weder für N15 noch N16 erforderlich
und würde neue Privacy-, File-Lifecycle- und UI-Verträge schaffen.

P1.11 fordert große Dateien als Regression-Fixture, nicht ein neues Raw-
Subsystem (`05-roadmap/refactor-roadmap.md:338-354`). Gemeinsame Scannerbausteine
stehen erst in Welle 4 (`05-roadmap/refactor-roadmap.md:387-400`). Daher in Welle
3 Limits messen und Oversize-Verhalten als Oracle festhalten; eine bytebasierte
Streaming-/Raw-Architektur nur als separates, späteres Vorhaben mit eigenem
Privacy-Gate bewerten.

## 4. Crash-Observability und Secrets gegen Produktcode und Roadmap

### 4.1 MetricKit als Baseline: technisch plausibel, Priorität nicht belegt

**Urteil als W0/P0-Produktmaßnahme: FRAGWUERDIG**

Der Problemkontext ist korrekt: Nach einer einmaligen Formatvalidierung folgen
Converter-/File-Aufbau und erst danach `installTap`/`engine.start`, ohne erneute
Hardwareformatprüfung
(`WhisperM8/Services/Dictation/AudioRecorder.swift:101-120,122-170`). Der
Configuration-Handler bindet `engine` vor einem 300-ms-`await` und prüft danach
weder Aufnahmegeneration noch Engine-Identität, bevor er Tap und Converter neu
installiert (`AudioRecorder.swift:251-288,307-348`). Observability ersetzt diese
Fixes nicht.

MetricKit benötigt keine neue Package-Abhängigkeit und ist als lokaler,
output-only Diagnose-Spike plausibel. Der direkte Distributionsfall ist aber nur
über den genannten DTS-Thread plus einen einzelnen erfolgreichen Host-App-Test
belegt; die Recherche fordert selbst erst ein signiertes/notarisiertes Fixture.
Die konsolidierte Roadmap definiert W0 als Testoracles und Swift-6-Diagnostik
(`05-roadmap/refactor-roadmap.md:47-61`) und priorisiert die eigentlichen
Recorder-Fixes in W1 (`05-roadmap/refactor-roadmap.md:63-82`).

Deshalb: Fixture und Datenschutz-/Symbolication-Oracle sind tragfähig; ein
bereits beschlossener W0-Produkt-Subscriber samt Retention-UI ist es noch nicht.
Nach erfolgreichem Direct-Build-Fixture separat in die Roadmap aufnehmen.

### 4.2 KSCrash nicht vor die bestätigten Recorder-Fixes ziehen

**Urteil als W0/P0-Pflicht zusammen mit MetricKit: ABLEHNEN**

Die KSCrash-Quellen tragen die technische Behauptung eines lokalen Recorders.
Die konkrete Empfehlung würde aber eine neue C/ObjC-Crashhandler-Abhängigkeit in
ein Package einführen, das heute nur KeyboardShortcuts, Defaults,
LaunchAtLogin und SwiftTerm bindet (`Package.swift:12-34`). Die Roadmap gibt
`Package.swift` je Welle einen exklusiven Owner
(`05-roadmap/refactor-roadmap.md:19-29`), enthält KSCrash in keiner Technologie-
Entscheidung und setzt zuerst die kausalen C01/C02-Fixes
(`05-roadmap/refactor-roadmap.md:63-82,462-482`).

Damit ist nicht KSCrash generell verworfen, sondern die Aussage „W0 sollte
MetricKit **und** KSCrash kombinieren“. Nach den Recorder-Fixes und einem
MetricKit-Fixture kann ein eigener Feature-Flag-Spike Handlerkoexistenz,
System-Crashreporter, dSYM-Prozess, Dateirechte, Retention und null Netzwerk
beobachten. Vorher wäre es ein verfrühter Technologieeinbau.

### 4.3 Sentry Self-Hosted bewusst vertagen

**Urteil: TRAGFAEHIG**

Der Self-Hosted-Stack fordert im Vollprofil mindestens 14 GB Docker-RAM und vier
CPUs, im `errors-only`-Profil 7 GB und zwei CPUs
(`<sentry-self-hosted>/install/_min-requirements.sh:1-18`). Für die aktuelle
lokale Diagnoseaufgabe ist die Empfehlung „erst bei Flotten-/Team-Triage und
mit eigener Datenschutz-/Retention-RFC“ daher angemessen. Sie fügt weder jetzt
eine Uploadpipeline hinzu noch ersetzt sie C01/C02.

### 4.4 Child-Environment als Prozessklassen-Vertrag

**Urteil: TRAGFAEHIG mit zwingendem Kompatibilitäts-Gate**

`processEnvironment` kopiert heute das gesamte Parent-Environment und entfernt
nur Claude-spezifische Variablen sowie `NO_COLOR`
(`WhisperM8/Services/Shared/LoginShellEnvironment.swift:82-137`). Die App hostet
aber mehrere echte Prozessklassen: normale Terminal-Tabs starten ausdrücklich
die interaktive Login-Shell (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:160-186`),
während Agent-Chats die realen `codex`-/`claude`-Binaries starten
(`AgentCommandBuilder.swift:189-243,246-257`). Genau deshalb ist die Trennung
`.agent/.helper/.interactiveShell` substanziell und wahrt den CLI-Host-Vertrag.

P1.1 verlangt eine klassifizierte Environment-Fabrik für **alle** Spawnpfade,
Cloud-Credential-Entzug und einen Regressionstest für PATH, Multi-Account, MCP
und bestehende Agent-Starts (`05-roadmap/refactor-roadmap.md:141-156`). Eine
Allowlist darf daher nicht als einmaliger globaler Filter landen. Shell-Tabs
behalten Login-Shell-Semantik; Agenten erhalten Git-/SSH-/Docker-/MCP-
Capabilities nur über explizite, sichtbare Overrides. Erst eine vollständige
Processklassen-Matrix macht die Empfehlung feature-erhaltend.

### 4.5 Legacy-Keychain-Migration transaktional machen

**Urteil: TRAGFAEHIG**

`KeychainManager.save` liefert keinen Fehler an den Aufrufer; bei Fehler wird nur
geloggt (`WhisperM8/Services/Shared/KeychainManager.swift:10-35`). `load` ruft
für den Legacy-Wert `save` auf und löscht UserDefaults unmittelbar danach
unabhängig vom Ergebnis (`KeychainManager.swift:37-69`).

Ein fehlerfähiger Security-Adapter, Ziel-Write, bytegleicher Readback und erst
danach Quell-Delete behebt genau diese Verluststrecke. R2.3 fordert denselben
Vertrag und passende Disk-/Permission-/Keychain-Gates
(`05-roadmap/refactor-roadmap.md:110-123`). Das ist ein enger Fix, kein
Keychain-Library-Großumbau.

### 4.6 Profil-Rename ohne Secret in argv

**Urteil: TRAGFAEHIG**

Der injizierbare Runner setzt sein Array direkt als `/usr/bin/security`-argv
(`WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:326-342`). Beim
Rename landet das gelesene Secret hinter `-w` in diesem Array; das Ziel wird mit
`-U` überschrieben, danach wird die Quelle gelöscht
(`ClaudeAccountProfiles.swift:355-384`). Der neue Service-Name ist schon vor dem
Ordner-Rename deterministisch aus dem Zielpfad berechenbar
(`ClaudeAccountProfiles.swift:278-301`).

Ein direkt injizierbarer Security.framework-Adapter kann deshalb das alte Item
als `Data` lesen, ein noch nicht vorhandenes Ziel schreiben, separat zurücklesen
und erst nach erfolgreichem Datei-/Profilübergang die Quelle löschen. Das
entfernt argv-Klartext, ohne Claude Code oder dessen Keychain-Schema zu ersetzen.
P1.1 nennt Security-API beziehungsweise sicheren stdin-/Keychain-Pfad und die
Multi-Account-Regression ausdrücklich
(`05-roadmap/refactor-roadmap.md:141-156`).

## 5. Verbindliche Korrekturen für die Übernahme in die Roadmap

1. **R2.4 aus dem Supervisor-Vergleich übernehmen:** Bootstrap-Ready-Gate,
   Termination-Reason, `turn.completed` und atomaren Stop-Latch. Den bestehenden
   Waiter-Reattach-Vertrag beibehalten. Keinen dauerhaften Supervisor-Broker als
   implizite Voraussetzung ergänzen.
2. **CLI-Kompatibilität schützen:** `partial` bleibt bis zu einem eigenständig
   versionierten Vertragswechsel Exit 0; `rawLastMessage` bleibt als
   Degradationspfad. N08 darf nicht als Vorwand für einen stillen Exitcode-Bruch
   dienen.
3. **P1.11 eng halten:** zuerst IDs und Unknown-Outcomes, danach
   Teilzeilen-Oracles. Aliasformen nur mit realen Fixtures. Raw-Byte-Range und
   gemeinsamer Scanner sind keine verdeckten Welle-3-Pflichten.
4. **Observability neu einsortieren:** MetricKit zunächst als signiertes
   Direct-Distribution-Fixture/Spike; KSCrash nicht als W0-Pflicht. C01/C02-
   Ursachenfixes bleiben vor neuer Crashhandler-Runtime.
5. **Secrets-Empfehlungen übernehmen:** Keychain copy→readback→delete,
   Security.framework-Rename und pro Prozessklasse allowlistetes Environment;
   Shell-, PATH-, Multi-Account-, Git/SSH- und MCP-Verträge sind obligatorische
   Feature-Erhalt-Gates.

## Webquellen

- [Apple Developer Forums: MetricKit-Thread 821002] —
  <https://developer.apple.com/forums/thread/821002>
- [containerd service.go, gepinnte Revision] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L149-L350>
- [containerd binary.go, gepinnte Revision] —
  <https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/core/runtime/v2/binary.go#L66-L152>
- [runc utils_linux.go, gepinnte Revision] —
  <https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/utils_linux.go#L161-L326>
- [runc start_detached.bats, gepinnte Revision] —
  <https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/tests/integration/start_detached.bats#L34-L55>

[containerd service.go:149-219,295-350]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L149-L350
[containerd service.go:575-594]: https://github.com/containerd/containerd/blob/29edc6e8b7fe4a66d4f4fde6666893941910d954/cmd/containerd-shim-runc-v2/task/service.go#L575-L594
[runc utils_linux.go:161-182,288-326]: https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/utils_linux.go#L161-L326
[runc start_detached.bats:34-55]: https://github.com/opencontainers/runc/blob/fc89fbd9ebec617475d7e7a7a38f4e4bf277cf54/tests/integration/start_detached.bats#L34-L55
