---
status: spezifikation
updated: 2026-07-20
description: Vollständige Test-Spezifikationen für Welle 0/1 mit getrennt markierten W2/W3-Oracles, deterministischen Fakes, Claim-Matrix und Runde-4-Gates.
---

# Test-Spezifikationen Welle 0/1

> **Identitäts-Gate für die G4-Revision:** Tests der Session-Bindung müssen gegen die Capability-Zustände `hostAssignedUnsupported`/`hostAssignedVerified` und die Claim-API aus [`identitaetsmodell-spec.md` §2.2](identitaetsmodell-spec.md) geschrieben werden. A02 ist in seiner heutigen Form überholt und wird in der G4-Revision durch capability-/claim-spezifische Oracles ersetzt.

## 0. Geltungsbereich und Ausführungsregel

Dieses Dokument spezifiziert ausschließlich Tests; es enthält keinen Test- oder Produktcode. Kategorie 1 friert korrektes Ist-Verhalten als Refactoring-Gate ein. Diese Tests müssen **vor** der jeweiligen Produktionsänderung grün sein. Kategorie 2 beschreibt bewusst zunächst rote Bug-Soll-Tests, die im selben Change wie der jeweilige Fix grün werden. **A02 ist die einzige bewusst rote W0-Ausnahme in Kategorie 1:** Die alte Direktbindung ist kein schützenswertes Ist-Verhalten; ihr Ersatz definiert das normative Capability-/Claim-Gate aus `identitaetsmodell-spec.md` §2.2.

Jeder Vertrag verwendet dieselbe Given/When/Then-Lesart: **Setup/Fixtures oder Auslöse-Szenario = Given**, **ausgelöste Operation = When**, **Assertions/Soll-Verhalten = Then**. Zeit und Reihenfolge kommen ausschließlich aus `ManualClock`, `ManualSleeper`, einem injizierten Scheduler oder `ManualGate`; ein Test mit zeitlicher Aussage darf keinen Wanduhr-Sleep enthalten. Jeder Vertrag nennt außerdem seinen Negativfall und unterscheidet Row-/Sidecar-/UI-State-Persistenz von bewusst ephemeren Effekten. Wo der heutige Code harte Framework-Abhängigkeiten besitzt, ist zuerst nur die beim Test genannte minimale Naht verhaltensneutral zu extrahieren; erst wenn ein Charakterisierungstest gegen den unveränderten Altpfad grün ist, beginnt der Fix.

Die vorhandene Suite erreicht bei Recorder und Terminal nur vorgelagerte pure Funktionen beziehungsweise Container, nicht die besitzenden Lifecycle-Pfade (`Tests/WhisperM8Tests/AudioFormatDecisionTests.swift:5-7`, `docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde2-tests-qualitaet-codex.md:80-82`). Die vorgeschlagenen Hilfen folgen der Repository-Konvention aus Closure-DI, kleinen Protokollen und Spies; `AgentTestSupport` enthält derzeit nur Codex-Fixtures und zwei Temp-Helfer (`Tests/WhisperM8Tests/AgentTestSupport.swift:4-10`, `Tests/WhisperM8Tests/AgentTestSupport.swift:73-86`).

### 0.1 Neue gemeinsame Helfer-Kürzel

| Kürzel | Ergänzung in `AgentTestSupport.swift` | Zweck |
|---|---|---|
| H1 | `TemporaryTestRoot` / `withTemporaryDirectory` | Throw-sicheres automatisches Cleanup, optionaler Fake-Home und benannte Unterpfade. |
| H2 | `ManualSleeper`, `ManualClock`, `ManualGate` | Suspension-Points und Reihenfolgen ohne Wanduhr-Sleeps steuern. |
| H3a | `OneShotProcessRunning` | Minimales vorhandenes Runner-Protokoll für executable, argv, cwd, Environment, Timeout und fertiges Resultat; keine Prozesssignale oder Handles. |
| H3b | `ControllableChildProcess` + Launcher-Closure | Nur für langlebige Kinder: Spawn-Identität, Ready, Exit, Output und TERM/KILL über `ManualGate` steuern. Kein gemeinsames God-Interface mit H3a. |
| H4 | `IsolatedPreferencesScope` | `AppPreferences.shared` serialisiert und auch bei async/throw/cancellation sicher restaurieren. |
| H5 | `AudioEngineSpy` / `AudioRecordingBackendSpy` | Formatfolgen, Tap, Converter, Start/Stop und Observer deterministisch protokollieren. |
| H6a | `TerminalExitControlling` | Nur graceful Interrupt, Exit-Bestätigung, Drain und Eskalation steuern; keine Snapshot- oder Registry-Verantwortung. |
| H6b | lokale `snapshotSink`-/`detachMonitors`-Closures | Snapshot-Reihenfolge und Monitor-Cleanup im jeweiligen Controller-Test beobachten, ohne universellen PTY-Spy. |
| H7 | `KeychainClientSpy` | Security-Status für Copy/Update/Add/Readback ohne echten Schlüsselbund vorgeben. |
| H8 | `PasteTargetSpy` | App-, Fenster- und Agent-Session-Identität sowie Aktivierung/Cmd+V beobachten. |
| H9 | `TranscriptDiagnosticSpy` + providerübergreifende Golden-Fixtures | Schema-Drift, unbekannte Events und parallele Tool-Korrelation prüfen. |
| H10a | `claimProviderSession`-/Workspace-Mutations-Closure | Claim-Outcome und atomare Persistenzmutation unter einem Test-Lock beobachten. |
| H10b | lokale `watcherFactory`, `statusSink`, `flush` und `terminalIDUpdate`-Closures | Nur die im jeweiligen Coordinator-Test benötigten Runtime-Effekte injizieren; kein gemeinsamer Pipeline-Harness. |

H1–H4 bleiben generisch. Subsystemnahe Spies wohnen dateilokal oder in thematischen Test-Support-Dateien; insbesondere werden H3a/H3b, H6a/H6b und H10a/H10b nicht zu universellen Interfaces zusammengezogen. Jeder Produktionspfad erhält nur die kleinste Naht, die sein Oracle benötigt (`docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:294-303`, `docs/audit/2026-07-agent-chats-deep-dive/06-umsetzung/verifikation-schluss.md:323-329`).

---

# KATEGORIE 1 — Absicherungs-Tests für korrektes Ist-Verhalten

## A01 — Recorder-Start commitet Zustand erst nach erfolgreichem Engine-Start

- **Zweck:** Den erfolgreichen Start- und Rollback-Vertrag einfrieren, ohne die heutigen TOCTOU-/Reconfiguration-Bugs als Soll zu zementieren.
- **Setup/Fixtures:** Mikrofonfreigabe-Closure liefert `true`; H5 liefert ein stabiles, recordable 48-kHz-Stereoformat, einen erfolgreichen Converter, Tap und Engine-Start. Eine zweite Tabellenzeile lässt ausschließlich `engine.start()` fehlschlagen. `AudioRecorder` setzt heute Ressourcen zurück, bindet Gerät und Format, installiert den Tap, startet die Engine und setzt erst danach `self.engine`/`isRecording` (`WhisperM8/Services/Dictation/AudioRecorder.swift:33-51`, `WhisperM8/Services/Dictation/AudioRecorder.swift:62-120`, `WhisperM8/Services/Dictation/AudioRecorder.swift:122-178`).
- **Assertions:** Erfolgsfall: Reihenfolge `permission → engine/input → format → converter/file → tap → start`, danach `isRecording == true`; `stopRecording()` stoppt genau diese Engine und liefert genau die erzeugte M4A-URL. Fehlerfall: Tap entfernt, Datei/Converter/URL verworfen, `isRecording == false`, Startfehler unverändert weitergereicht. Der heutige Fehlerpfad entfernt Tap und Ressourcen und setzt die Recording-URL zurück (`WhisperM8/Services/Dictation/AudioRecorder.swift:157-173`, `WhisperM8/Services/Dictation/AudioRecorder.swift:182-214`).
- **Testziel:** neue `Tests/WhisperM8Tests/AudioRecorderLifecycleTests.swift`; Typ `AudioRecorder`.
- **AgentTestSupport:** **Ja — H1, H5.**

## A02 — Capability-Gate und atomare Claim-API sind der einzige Bindungsweg `[W0, zunächst rot]`

- **Zweck:** Die überholte Direktbindung durch den normativen Vertrag aus `identitaetsmodell-spec.md` §2.2 ersetzen. Kein Hook, Indexer-Recovery- oder Control-CLI-Pfad darf `externalSessionID`, Transcriptpfad oder Lineage direkt setzen.
- **Given:** H1/H2/H10a mit `ManualClock`, zwei kanonischen Config-Roots, einer lokalen Row samt vor Spawn synchron persistiertem `LaunchRecord(chatID, launchID, generation, intent, expectedConfigRoot, launchedAt)` und einer reinen Capability-Quelle. `ProviderSessionKey` besteht immer aus `(provider, canonicalConfigRoot, externalSessionID)`.
- **When/Then — Capability-Matrix:**
  1. `hostAssignedUnsupported`: Fresh und Fork starten ohne `--session-id`, Resume nur mit `--resume <sourceID>`; `expectedProviderKey` ist bei Fresh/Fork `nil`, bei Resume der Source-Key. Genau ein aktueller, neuer, ungeclaimter Kandidat darf anschließend `claimed` werden.
  2. `hostAssignedVerified`: Nur eine gespeicherte, vollständig grüne Live-Probe für Fresh, Resume **und** Fork desselben aufgelösten CLI-Pfads und derselben Version erlaubt reservierte Fresh-/Fork-Keys und `--session-id`. Wechsel/Upgrade, unbekanntes, fehlgeschlagenes oder per Rollback deaktiviertes Probe-Ergebnis fällt vor Spawn auf `hostAssignedUnsupported` zurück.
- **When/Then — fünf Claim-Outcomes:** Eine parametrisierte Store-Suite ruft ausschließlich `claimProviderSession(...)` auf. `claimed` commitet Key, Pfad, cwd, Source, Lineage und Recovery-State atomar; `alreadyOwnedBySameRow` aktualisiert nur neuere bestätigte Metadaten derselben Generation; `collision`, `ambiguous` und `staleGeneration` verändern **kein Feld** der Row. `collision`/`ambiguous` dürfen nur einen separaten App-eigenen `RecoveryCase` erzeugen, `staleGeneration` nur Diagnose.
- **Negativfall/Persistenz:** Mismatch von erwarteter ID, Root, komponentenweisem Transcriptpfad, Launchfenster oder Generation erreicht nie `healthy`. Vorher-/Nachher-Snapshot der Row bleibt bei den drei negativen Outcomes feld- und bytegleich; Provider-Dateien bleiben read-only. Die Uhr wird nur durch `ManualClock.advance` bewegt, die konkurrierenden Claims werden über `ManualGate` geordnet.
- **Testziel:** neue `Tests/WhisperM8Tests/AgentProviderSessionClaimTests.swift` und `AgentCapabilityLaunchTests.swift`; atomare Store-Operation plus pure Launch-Entscheidung. Die Statuskette für normale und Background-Chats bleibt separat in bestehenden `AgentSessionStatusCoordinatorTests` und erhält nur lokale `watcherFactory`-/`statusSink`-Closures.
- **AgentTestSupport/minimale Naht:** **Ja — H1, H2, H10a;** kein H10-Gesamtharness.

### A02-S01 bis A02-S08 — normative `source`-/Transitionsoracles

Jede Zeile ist ein eigener Test; im Negativfall bleiben Binding, Lineage, Transcriptpfad und Chat-Row unverändert. Zeitfenster werden mit derselben `ManualClock`, Ereignisreihenfolgen mit `ManualGate` gesteuert.

| Test-ID | Given / When | Then, Negativfall und Persistenzmutation |
|---|---|---|
| `A02-S01` | Rohwerte `startup`, `resume`, `branch`, `rewind`, `clear`, `compact` und ein Future-Wert werden geparst. | Bekannte Werte bleiben typisiert; Future-Wert bleibt `unknown(rawValue)`, nie Default `startup`; **keine Persistenzmutation**. |
| `A02-S02` | Aktuelle und supersedierte `(chatID, launchID, generation)` liefern denselben Kandidaten. | Aktuell erreicht Claim; supersediert liefert `staleGeneration`, nur Diagnose, **keine Row-/Recovery-Mutation**. |
| `A02-S03` | `/branch`, `source=branch`, eindeutiger neuer Key und passender Pfad. | `claimed` erzeugt atomar `activeBranchChange`; falsche Source, gleicher Key, `collision` oder mehrere Kandidaten erzeugen Recovery, alter Key bleibt aktiv. |
| `A02-S04` | `/rewind`, `source=rewind`, neuer Key sowie autoritative beziehungsweise nur aus JSONL abgeleitete Lineage. | Nur autoritative Lineage wird atomar übernommen; JSONL-Nachrichtenverkettung oder Mehrdeutigkeit führt zu `ambiguous`/Recovery ohne Claim. |
| `A02-S05` | `/clear`, `source=clear`, derselbe Key und derselbe kanonische Pfad. | `alreadyOwnedBySameRow` bestätigt `inPlaceClear`; andere ID, Root oder Pfad mutiert nichts und erzeugt Recovery. |
| `A02-S06` | `/resume` mit explizitem Target-Key und passendem Root. | Exaktes Target wird bestätigt; nackte UUID ohne eindeutigen Root, belegtes oder mehrfaches Target bleibt ungeclaimt; definierter abweichender Branchwechsel braucht ein eigenes autoritatives Event. |
| `A02-S07` | `/compact`, `source=compact`, derselbe Key. | `inPlaceCompact` ohne Unread/Auto-Rename; andere ID, Root oder konkurrierende Generation erzeugt weder Compact noch geratenen Branchwechsel. |
| `A02-S08` | Prozessende der aktuellen Generation, danach spätes Event; zweiter Fall Crash in `bindingPending`. | Nur Generation wird geschlossen, letztes Binding bleibt; spätes Event `staleGeneration`; Crash persistiert Recovery statt Fresh. |

## A03 — Terminal-Teardown versucht graceful Exit vor Eskalation und snapshotet nach Drain

- **Zweck:** Den fachlichen Teardown-Vertrag schützen, ohne `usleep`-Dauern oder die aktuelle Anzahl von Ctrl-C-Signalen als Produktinvariante festzuschreiben.
- **Given:** H6a liefert einen laufenden Controller, gepufferten Text `vor-exit`, ein manuelles Exit-/Drain-Gate; H6b beobachtet Snapshot und Monitor-Detach. Zwei Tabellenfälle bestätigen Exit nach dem ersten graceful Versuch beziehungsweise ausbleibenden Exit bis zur Eskalation.
- **When:** `terminate()` wird ausgelöst, die Teststeuerung bestätigt Exit/Drain oder lässt die explizite manuelle Deadline verstreichen; danach trifft der normale Exit-Callback ein.
- **Then:** Mindestens ein graceful Exit-Versuch liegt vor jeder Eskalation; nach bestätigtem Exit wird **kein** weiteres Signal gesendet. Der Snapshot enthält alle bis zum finalen Drain gelieferten Bytes und wird trotz nachfolgendem Exit-Callback genau einmal gespeichert; Monitore sind gelöst und `isRunning == false`. Keine Assertion auf exakte Ctrl-C-Anzahl, 80/180 ms oder MainActor-Blockade.
- **Negativfall/Persistenz:** Doppelte `terminate()`-/Exit-Callbacks erzeugen weder zweite Eskalation noch zweiten Snapshot; nur der finale Snapshot wird persistiert, Zwischenzustände bleiben ephemer.
- **Testziel:** neue `Tests/WhisperM8Tests/AgentTerminalControllerTests.swift`; Typen `AgentTerminalController`, `AgentTerminalRegistry`.
- **AgentTestSupport/minimale Naht:** **Ja — H2, H6a/H6b;** zuerst `TerminalExitControlling` sowie lokale Sink-Closures verhaltensneutral extrahieren.

## A04 — Workspace-Persistenz besteht einen echten Cold-Load-Roundtrip

- **Zweck:** Beweisen, dass die Datei und nicht der pro URL geteilte Registry-Kern den Zustand trägt.
- **Setup/Fixtures:** H1; `AgentWorkspaceRepository(fileURL:)` speichert einen Workspace mit zwei Projekten und Sessions, einschließlich `externalSessionID`, `kind`, Profilstempel, Prompt-/Launch-Flags und festen Zeitstempeln. Danach wird eine **neue Repository-Instanz** aus derselben URL erzeugt; kein `AgentWorkspaceStoreRegistry`-Zugriff. Der Repository-Pfad dekodiert ISO-8601 und schreibt atomar mit ISO-8601 (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:29-47`, `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:82-102`).
- **Assertions:** Geladener Workspace ist feldgleich zum gespeicherten Workspace; IDs, Reihenfolge, Zeitstempel und optionale Sessionfelder bleiben erhalten; ein zweiter Read ist ebenfalls identisch. Damit wird die bekannte Schwäche vermieden, bei der zwei Facades denselben Registry-Kern lesen können (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde2-tests-qualitaet-codex.md:48-52`).
- **Testziel:** `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift`; Typ `AgentWorkspaceRepository`.
- **AgentTestSupport:** **Ja — H1.**

## A05 — Gültige Output-Modi laden und normalisieren ohne Inhaltsverlust

- **Zweck:** Den gültigen Datei-Contract vor der fehlertoleranten Einzeldatensatz-Dekodierung absichern.
- **Setup/Fixtures:** H1/H4; valide Datei mit alten Raw-Feldern, zwei Custom-Modi in unsortierter Reihenfolge, stillgelegtem Chat-Modus und Custom-Verweis auf das alte Chat-Template. Cache vor/nach Test zurücksetzen. `OutputModeStore` füllt Built-ins auf, migriert Raw zu Fast, filtert stillgelegte IDs, remappt das alte Chat-Template und sortiert Customs nach Name (`WhisperM8/Services/Dictation/OutputModeStore.swift:145-208`).
- **Assertions:** Built-ins stehen in Katalogreihenfolge; Raw/Fast ist enabled, `.raw`, ohne Template/Overrides; Default ist enabled; Customs bleiben vollständig und alphabetisch; stillgelegter Chat-Modus fehlt; Custom-Chat-Template zeigt auf Prompt. Diese Vertragswerte werden heute bereits teilweise separat geprüft (`Tests/WhisperM8Tests/OutputModeCompatTests.swift:102-169`, `Tests/WhisperM8Tests/OutputModeCompatTests.swift:174-234`).
- **Testziel:** `Tests/WhisperM8Tests/OutputModeCompatTests.swift`; Typ `OutputModeStore`.
- **AgentTestSupport:** **Ja — H1, H4** (`IsolatedPreferencesScope` ersetzt den heutigen dateilokalen Helfer).

## A06 — GPT-Proxy-Lifecycle besitzt nur selbst gestartete Prozesse

- **Zweck:** Start, Fremdinstanz, Router-Kopplung, Fehlercleanup und App-Quit als einen Lifecycle-Vertrag sichern.
- **Setup/Fixtures:** Vorhandene Closure-DI von `ClaudeCodeProxyManager`: Reachability-Folge, Launcher-Handle, Router-Starter/-Stopper, Agent-Definition-Syncer und private `NotificationCenter`. Der Manager serialisiert `ensureRunning`, startet nur bei nicht erreichbarem Proxy, registriert den eigenen Handle und startet danach den Router (`WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218-283`).
- **Assertions:** Bereits erreichbarer externer Proxy wird nie gestartet oder beendet, Router startet; nicht erreichbarer Proxy startet exakt `serve --no-monitor --port`, mit `CCP_BIND_ADDRESS=127.0.0.1`; Erfolg synchronisiert die Agent-Definition; nicht erreichbarer Proxy und Router-Fehler terminieren nur den im selben Versuch gestarteten Handle; `stopIfSelfStarted` und `willTerminate` stoppen Router/Prozess nur bei Eigenbesitz. Die bestehende Suite besitzt diese Spies und Einzelassertionen bereits (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:18-78`, `Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:96-159`, `Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:211-237`, `Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:302-318`).
- **Testziel:** `Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift`; Typ `ClaudeCodeProxyManager`.
- **AgentTestSupport:** **Nein.** Vorhandene lokale Closure-Spies und `processHandle` genügen (`Tests/WhisperM8Tests/ClaudeCodeProxyManagerTests.swift:407-447`).

---

# KATEGORIE 2 — Bug-Soll-Tests für bestätigte Findings

## P0 — Crash und Datenverlust zuerst

## B01 — C01: Start revalidiert Hardwareformat unmittelbar vor Tap/Engine-Start

- **Bug-ID:** C01 — bestätigtes TOCTOU-Fenster zwischen Format-Query, Tap und `engine.start` (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:34-44`).
- **Auslöse-Szenario:** H5 liefert beim ersten Query Format A (48 kHz/stereo) und direkt vor Tap/Start Format B (16 kHz/mono); beide sind einzeln gültig. Heute bleibt der Snapshot aus dem Retry bis `installRecordingTap` und `engine.start` unverifiziert (`WhisperM8/Services/Dictation/AudioRecorder.swift:106-120`, `WhisperM8/Services/Dictation/AudioRecorder.swift:152-160`).
- **Soll-Verhalten nach Fix:** Recorder erkennt A→B, baut abhängige Ressourcen auf B neu und verwendet ausschließlich B für Tap/Converter/Start; alternativ bricht er über einen expliziten `RecordingError` ab. Eine synchron gefangene AVFoundation-Exception wird als Swift-Fehler geliefert, nie als Prozessabbruch; der Trampolin-Vertrag gilt nur für synchrone Framework-Aufrufe (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:68-77`).
- **Setup:** `AudioRecordingBackendSpy` mit formatSequence `[A, B, B]`, Converter-/Tap-/Start-Protokoll und Exception-Ergebnis; Temp-Ausgabedatei.
- **Assertions:** Kein Tap/Converter mit A; Tap und Start nutzen denselben finalen B-Snapshot; bei Exception `isRecording == false`, Ressourcen bereinigt, sichtbarer Fehler genau einmal.
- **Testziel:** neue `Tests/WhisperM8Tests/AudioRecorderLifecycleTests.swift`; `AudioRecorder` plus synchroner Exception-Adapter.
- **AgentTestSupport:** **Ja — H1, H5.**

## B02 — C02: Cancel während Configuration-Backoff darf alte Engine nicht berühren

- **Bug-ID:** C02 — nach Suspension fehlt die Revalidierung von Recording-/Engine-Generation (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:46-55`).
- **Auslöse-Szenario:** Configuration-Change stoppt Engine A und wartet am 300-ms-Punkt; während H2 dort hält, beendet `stopRecording()` die Aufnahme und eine neue Generation/Engine B kann starten. Der heutige Handler arbeitet nach dem `await` weiter auf der zuvor gebundenen lokalen Engine (`WhisperM8/Services/Dictation/AudioRecorder.swift:251-287`, `WhisperM8/Services/Dictation/AudioRecorder.swift:307-340`).
- **Soll-Verhalten nach Fix:** Nach jedem Suspension-Point werden Generation, Engine-Identität und Sessionzustand geprüft; eine veraltete Generation beendet sich ohne Tap/Converter/Start/Observer-Zugriff (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:71-73`).
- **Setup:** H2 hält den Stabilisierungsschlaf; H5 stellt Engine A/B mit getrennten Call-Logs; zwischen Hold und Release `stopRecording()` und optional Start B auslösen.
- **Assertions:** Nach Release keine neuen Calls auf A, B bleibt unberührt/laufend, kein Observer für A, kein Rücksetzen des Zustands von B; veralteter Task endet ohne Fehler-/Erfolgsmeldung für B.
- **Testziel:** `Tests/WhisperM8Tests/AudioRecorderLifecycleTests.swift`; `AudioRecorder.handleConfigurationChange` über eine interne Test-Naht.
- **AgentTestSupport:** **Ja — H2, H5.**

## B03 — N04: Ein inkompatibler Output-Mode löscht keinen gültigen Bestand

- **Bug-ID:** N04 — ein Array-Decodefehler fällt auf Built-ins zurück; die nächste Einstellung kann den Ersatzbestand zurückschreiben (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:40-42`).
- **Auslöse-Szenario:** `OutputModes.json` enthält zwei gültige Customs und dazwischen einen Eintrag mit inkompatiblem Pflichtfeld/Enum; die Template-Datei enthält die beiden referenzierten Custom-Templates. Heute dekodiert `loadModes()` das Array als Einheit und liefert bei jedem Fehler `[]` (`WhisperM8/Services/Dictation/OutputModeStore.swift:118-134`).
- **Soll-Verhalten nach Fix:** Einträge werden einzeln dekodiert; gültige Modi/Templates bleiben erhalten, der defekte Rohdatensatz wird diagnostisch quarantänisiert, und vor einem expliziten Repair-Save entsteht ein Backup (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97-108`).
- **Setup:** H1/H4; echte Modus- und Template-Dateien; `OutputModesViewModel` lädt und ändert anschließend einen gültigen Modus.
- **Assertions:** Beide gültigen Custom-IDs vor und nach Änderung vorhanden; Template-Datei byte-identisch; genau ein Quarantäne-/Diagnoseeintrag; Originaldatei wird beim bloßen Load nicht überschrieben; Repair-Save enthält gültige Modi und besitzt Backup.
- **Testziel:** `Tests/WhisperM8Tests/OutputModeCompatTests.swift`; `OutputModeStore`, `OutputModesViewModel`, `PostProcessingTemplateStore`.
- **AgentTestSupport:** **Ja — H1, H4.**

## B04 — N05: Future-Schema bleibt read-only und bytegenau unangetastet

- **Bug-ID:** N05 — ein Downgrade kann eine neuere `AgentSessions.json` auf Schema 1 zurückschreiben (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:44-46`).
- **Auslöse-Szenario:** Datei mit `schemaVersion = current + 1`, bekannten Pflichtfeldern sowie zusätzlichen unbekannten Root-/Sessionfeldern. Heute akzeptiert der Decoder jede Zahl und `migratedWorkspace` setzt sie immer auf die aktuelle Version (`WhisperM8/Models/AgentChat.swift:585-610`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:1172-1179`); ein abweichender Migrationswert wird bereits im Load-Pfad gespeichert (`WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:33-47`).
- **Soll-Verhalten nach Fix:** Future-Schema wird explizit als unsupported/read-only geöffnet; keine Migration, Normalisierung, Prune oder Save-Aktion darf die Datei verändern (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:110-123`).
- **Setup:** H1; Raw-JSON-Bytes plus Persist-/Backup-Spies; danach ein normaler Mutations-/Flush-Versuch über die Facade.
- **Assertions:** Loader meldet `unsupportedFutureSchema(found:expected:)`; Datei bleibt bytegleich; Persist- und Backup-Spy bleiben bei null; Mutation/Save wird sichtbar abgelehnt; unbekannte Felder sind nach dem Test weiter vorhanden.
- **Testziel:** `Tests/WhisperM8Tests/AgentWorkspaceStoreTests.swift`; `AgentWorkspaceRepository`, `AgentWorkspaceStoreRegistry`/`AgentSessionStore`.
- **AgentTestSupport:** **Ja — H1.**

## B05 — N06: Legacy-Key wird erst nach erfolgreichem Write und Readback gelöscht

- **Bug-ID:** N06 — `save` hat keinen Fehlerkanal und der Legacy-Wert wird bedingungslos entfernt (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:48-50`).
- **Auslöse-Szenario:** Keychain-Lookup liefert `errSecItemNotFound`, UserDefaults enthält den einzigen Key; Matrixfall A lässt Update/Add scheitern, Matrixfall B lässt Write gelingen, aber Readback fehlt/mismatched. Der aktuelle Migrationspfad ruft `save` auf und löscht danach immer UserDefaults (`WhisperM8/Services/Shared/KeychainManager.swift:10-35`, `WhisperM8/Services/Shared/KeychainManager.swift:61-66`).
- **Soll-Verhalten nach Fix:** `save` liefert Fehler; Migration entfernt Legacy erst nach erfolgreichem Keychain-Write **und** erfolgreichem Readback (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:110-117`).
- **Setup:** H4/H7; isolierte Defaults-Suite mit Canary-Key, parametrisierte Security-Statusfolge.
- **Assertions:** In beiden Fehlerfällen bleibt Legacy bytegleich, Fehler ist beobachtbar, ein zweiter Load versucht Migration erneut; nur im Erfolgsfall ist Legacy entfernt und Keychain/Cache liefern exakt den Canary-Key.
- **Testziel:** neue `Tests/WhisperM8Tests/KeychainManagerTests.swift`; `KeychainManager` hinter kleinem Security-Client-Protokoll.
- **AgentTestSupport:** **Ja — H4, H7.**

## Weitere kritische/hohe rot-nach-grün-Tests

## B06 — N01: Veraltete Restart-Aktion signalisiert keine recycelte PID

- **Bug-ID:** N01 — Restart kann nach Process-Exit über einen veralteten Controller eine inzwischen fremde PID treffen (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:28-30`).
- **Auslöse-Szenario:** Restart-Request wird für Session S und Spawn-Token T1 erzeugt; vor Verarbeitung endet T1, PID 4242 wird einem fremden Prozess/T2 zugeteilt. Der heutige View-Pfad ruft bei `.restart` ungeprüft `restartTerminal()`, das Registry-`terminate` ausführt (`WhisperM8/Views/AgentSessionDetailView.swift:372-379`, `WhisperM8/Views/AgentSessionDetailView.swift:613-615`, `WhisperM8/Views/AgentTerminalView.swift:367-369`).
- **Soll-Verhalten nach Fix:** Unmittelbar vor Signal werden Controller, Session, Spawn-Token sowie PID/Prozessstart-Identität validiert; stale Restart wird verworfen und als normaler Start neu bewertet (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:238-249`).
- **Setup:** H3b/H6a; Identity T1/PID 4242, Exit-Barriere, danach fremde Identity T2 mit derselben PID; Signal- und Start-Spies.
- **Assertions:** Kein Signal an T2/fremde Identity; T1-Controller entfernt; genau ein neuer Start für S; Registry enthält danach nur den neuen Controller und keinen Orphan.
- **Testziel:** `Tests/WhisperM8Tests/AgentTerminalControllerTests.swift`; `AgentTerminalRegistry`, extrahierter Restart-Entscheider.
- **AgentTestSupport:** **Ja — H3b, H6a.**

## B07 — N07: Supervisor gilt erst nach Detach-/Ready-Handshake als gestartet

- **Bug-ID:** N07 — Launcher gibt die Kind-PID direkt nach `Process.run()` zurück, bevor der Supervisor sicher detacht ist (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:52-54`).
- **Auslöse-Szenario:** H3b startet ein Kind, hält es vor `setsid`/Prozessgruppenbildung und beendet den Waiter; zweiter Matrixfall lässt das Kind vor Ready sterben. Der heutige Launcher besitzt keinen Ready-Handshake (`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-60`).
- **Soll-Verhalten nach Fix:** Spawn setzt neue Session/Prozessgruppe früh; Launcher publiziert Erfolg/PID erst nach Ready-/Detach-Handshake, ein Vorher-Exit ist Launchfehler (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:125-139`).
- **Setup:** H2/H3b mit Zuständen `spawned`, `detachedReady`, `exited`; Persist-Spy für `supervisorPid`.
- **Assertions:** Vor Ready kein erfolgreicher Return und keine PID-Persistenz; nach Ready genau eine persistierte eigene Identität; Waiter-Abbruch nach Ready beendet Supervisor nicht; Exit vor Ready liefert Fehler und hinterlässt keine aktive Job-PID.
- **Testziel:** neue `Tests/WhisperM8Tests/AgentSupervisorLauncherTests.swift`; `AgentSupervisorLauncher` und aufrufender Startvertrag.
- **AgentTestSupport:** **Ja — H2, H3b.**

## B08 — N08: `.done` verlangt vollständigen Codex-Turn

- **Bug-ID:** N08 — Exit 0 ohne finale Nachricht kann heute `.done` werden (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:56-58`).
- **Auslöse-Szenario:** Ergebnis-Matrix variiert `terminationReason`, Exitcode, beobachtetes `turn.completed` und finale semantische Nachricht. Der heutige Mapper prüft nur stalled, `turn.failed`, Exitcode und parst optional `lastMessage` (`WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-120`).
- **Soll-Verhalten nach Fix:** `.done` nur bei `.exit`, Code 0, `turn.completed` und semantisch vollständiger finaler Nachricht; EOF/Transportende allein ist Fehler (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:127-132`).
- **Setup:** Pure `mapOutcome`-Fixtures; ein vollständiger Erfolg als Kontrollfall, dann je ein fehlendes Kriterium.
- **Assertions:** Nur Kontrollfall `.done`; jeder unvollständige Fall `.failed` mit spezifischem Grund; Sink erhält exakt dasselbe Outcome wie Return.
- **Testziel:** neue `Tests/WhisperM8Tests/CodexTurnExecutorTests.swift`; `CodexTurnExecutor`, erweitertes `CodexTurnResult`.
- **AgentTestSupport:** **Nein.** Datenfixtures können dateilokal bleiben; reale Codex-Linien existieren bereits (`Tests/WhisperM8Tests/AgentTestSupport.swift:10-30`).

## B09 — C10: Teardown drainiert Exit-Output ohne MainActor-Sleep

- **Bug-ID:** C10 — synchrones `usleep` blockiert den MainActor und Snapshot entsteht vor den verspäteten Exit-Bytes (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts.md:135-145`).
- **Auslöse-Szenario:** H6a stellt `resume-hinweis` erst nach dem ersten Interrupt und einem expliziten Drain-/Exit-Gate bereit. Der aktuelle Teardown schläft 80/180 ms auf dem Controllerpfad und snapshotet vor `terminal.terminate()` (`WhisperM8/Views/AgentTerminalView.swift:775-795`).
- **Soll-Verhalten nach Fix:** Expliziter Zustandsautomat ordnet Interrupt, Exit-Beobachtung, Output-Drain, Snapshot und I/O-Close; Sleeps sind keine Ordnungsgarantie (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:277-286`).
- **Setup:** H2/H6a/H6b, MainActor-Probe-Task, Output-Gate, Snapshot-Sink; zusätzlich drei Controller für `terminateAll`.
- **Assertions:** MainActor-Probe läuft, während Teardown wartet; Snapshot enthält `resume-hinweis`; Snapshot genau einmal nach Drain; finaler Terminate/Eskalation genau einmal; `terminateAll` wartet parallel/konstant statt N serieller 260-ms-Phasen.
- **Testziel:** `Tests/WhisperM8Tests/AgentTerminalControllerTests.swift`; `AgentTerminalController`, `AgentTerminalRegistry`.
- **AgentTestSupport:** **Ja — H2, H6a/H6b.**

## B10 — N02: App-Quit finalisiert oder persistiert eine laufende Aufnahme

- **Bug-ID/Welle:** N02 — **W1**, Quit sichert nur Terminal-Snapshots und antwortet sofort `.terminateNow`; die M4A liegt temporär (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:32-34`).
- **Given:** H1/H2/H5, aktive Aufnahme mit datenhaltiger temporärer M4A, Pending-Record-Store-Spy und eine minimale AppKit-Naht aus `deferTermination() -> NSApplication.TerminateReply` plus `replyToTermination(shouldTerminate: Bool)`. Kontrollfall ohne Aufnahme.
- **When:** `applicationShouldTerminate` wird wie durch Menü- oder System-Quit einmal aufgerufen; `ManualGate` hält Finalize/Pending-Persistenz bis zur expliziten Freigabe.
- **Then:** Aktive Aufnahme liefert einmalig `.terminateLater`; Stop/Finalize oder Pending-Persistenz läuft genau einmal; Datei ist danach existent/recoverbar; anschließend erfolgt genau ein `replyToTermination(shouldTerminate: true)`. Es gibt **keinen** zweiten Rückgabewert `.terminateNow` und keinen Transcribe-/Paste-Aufruf. Ohne Aufnahme bleibt normaler Quit unmittelbar `.terminateNow` und ruft kein späteres Reply auf.
- **Negativfall/Persistenz:** Bei fehlgeschlagener Finalisierung wird ein recoverbarer Pending-Record dauerhaft geschrieben oder `replyToTermination(false)` genau einmal ausgelöst; niemals positives Reply ohne gesicherte Aufnahme. Wiederholte Quit-Callbacks duplizieren weder Record noch Reply.
- **Testziel:** neue `Tests/WhisperM8Tests/AppTerminationRecordingTests.swift`; extrahierter Quit-Koordinator plus dünne `AppDelegate`-Verdrahtung.
- **AgentTestSupport/minimale Naht:** **Ja — H1, H2, H5;** zwei AppKit-Closures statt `NSApplication`-God-Spy.

## B11 — N03: Doppelte Output-Mode-ID crasht nicht und wird deterministisch quarantänisiert

- **Bug-ID:** N03 — ungeprüfte IDs erreichen `Dictionary(uniqueKeysWithValues:)` (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:36-38`).
- **Auslöse-Szenario:** Valides JSON mit zwei Custom-Einträgen derselben ID, aber unterschiedlichen Namen/Templates. Der Decoder liefert beide und `normalized` erzeugt heute direkt das Dictionary (`WhisperM8/Services/Dictation/OutputModeStore.swift:126-134`, `WhisperM8/Services/Dictation/OutputModeStore.swift:153-165`).
- **Soll-Verhalten nach Fix:** Kein Trap; dokumentierte stabile Winner-Policy (für diesen Test: erster valider Eintrag gewinnt), zweiter Rohdatensatz wird mit Konflikt-ID quarantänisiert; Ausgabe-IDs sind eindeutig (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:97-108`).
- **Setup:** H1/H4; Datei mit Duplikat zwischen gültigen Nachbarn; Quarantäne-/Diagnose-Spy.
- **Assertions:** Zugriff auf `modes` kehrt normal zurück; ID exakt einmal und mit erstem Datensatz; Nachbarn unverändert; Diagnose nennt ID und beide Positionen; bloßer Load schreibt Original nicht um.
- **Testziel:** `Tests/WhisperM8Tests/OutputModeCompatTests.swift`; `OutputModeStore`.
- **AgentTestSupport:** **Ja — H1, H4.**

## B12 — N11: Auto-Paste bleibt an den Aufnahme-Intent gebunden

- **Bug-ID:** N11 — Auslieferung nimmt die zum Lieferzeitpunkt aktuelle `previousApp`, nicht zuverlässig den Start-Intent (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:68-70`).
- **Auslöse-Szenario:** Aufnahme startet in App A, Fenster/Agent-Session S1; während Transkription wechselt Fokus zu App B beziehungsweise WhisperM8-Session S2. Der Recorder friert den Kontext am Start ein (`WhisperM8/Services/Dictation/RecordingCoordinator.swift:118-133`, `WhisperM8/Services/Dictation/RecordingCoordinator.swift:172-178`), die Delivery holt `previousApp` dagegen erst unmittelbar vor Paste (`WhisperM8/Services/Dictation/RecordingCoordinator+Transcription.swift:61-101`).
- **Soll-Verhalten nach Fix:** Ziel-App, Fenster-/Session-ID und Policy werden beim Start eingefroren und vor Delivery revalidiert; bei Abweichung nur Clipboard + sichtbare Bestätigung, kein Cmd+V (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:251-262`).
- **Setup:** H4/H8; Start-Intent A/S1, danach Frontmost B/S2; Clipboard-, Activation-, Paste- und Confirmation-Spies. Kontrollfall Identität unverändert.
- **Assertions:** Wechsel-Fall: Text im Clipboard, null Aktivierungen/Cmd+V/Attachment-Pastes nach B/S2, sichtbarer Confirm-Fallback genau einmal. Kontrollfall: A/S1 wird genau einmal aktiviert und erhält Text/Attachments; Clipboard-Restore bleibt erhalten.
- **Testziel:** neue `Tests/WhisperM8Tests/RecordingPasteIntentTests.swift`; `RecordingCoordinator`, `PasteService` hinter Zielidentitäts-Naht.
- **AgentTestSupport:** **Ja — H4, H8.**

## B13 — N12: Stale Orphan-Korrektur darf `done` nicht überschreiben

- **Bug-ID:** N12 — `correctIfOrphaned` schreibt einen zuvor gelesenen Vollsnapshot ohne Re-Read/CAS zurück (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:72-74`).
- **Auslöse-Szenario:** Aktiven Snapshot A lesen; danach Store unter Lock auf `done`/Revision B setzen; anschließend Orphan-Korrektur mit A und toter PID ausführen. Heute erstellt sie aus A `failed` und ruft `writeState` auf (`WhisperM8/Services/AgentChats/AgentJobStore.swift:249-275`).
- **Soll-Verhalten nach Fix:** Orphan-Korrektur nutzt denselben Lock-/CAS-Vertrag, re-readet den aktuellen Zustand und respektiert monotone Übergänge (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:264-275`).
- **Setup:** H1; realer Temp-`AgentJobStore`, feste Uhr, `livenessProbe=false`, stale Snapshot A und explizite Completion B; optional Persist-Revisions-Spy.
- **Assertions:** Rückgabe und Disk-State bleiben `done`; Turns/Metrics/Report und Revision B unverändert; kein `failureReason`; keine zusätzliche Persistenz eines stale Snapshots.
- **Testziel:** `Tests/WhisperM8Tests/AgentJobStoreTests.swift`; `AgentJobStore.correctIfOrphaned`.
- **AgentTestSupport:** **Ja — H1.**

## B14 — N13: Parent-PID-Nachtrag darf `running` nicht auf `spawning` zurücksetzen

- **Bug-ID:** N13 — UI reserviert unter Lock, startet danach das Kind und mutiert PID außerhalb desselben atomaren Vertrags (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:76-78`).
- **Auslöse-Szenario:** UI-Claim erzeugt `spawning`; injizierter Launcher lässt vor seinem Return das Kind `running` mit eigener PID persistieren; danach führt der Parent seinen PID-Nachtrag aus. Der heutige View-Code trennt Claim und PID-Mutation (`WhisperM8/Views/SubagentJobDetailView.swift:461-503`).
- **Soll-Verhalten nach Fix:** UI-Folgeturn und Kindstart verwenden denselben Lock-/CAS-Vertrag; Parent darf nur noch passende Metadaten ergänzen und keinen neueren Status regressieren (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:264-275`).
- **Setup:** H1/H2; aus dem View extrahierter `AgentFollowUpDispatcher`, Launcher-Closure mit Gate und Child-Transition vor Return.
- **Assertions:** Final `running`; Supervisor-Identität ist die autoritative Kindidentität; Prompt genau einmal konsumiert; nie ein beobachteter/persistierter Rückschritt `running → spawning`; keine zweite Supervisor-Instanz.
- **Testziel:** neue `Tests/WhisperM8Tests/AgentFollowUpDispatcherTests.swift`; extrahierter Service aus `SubagentJobDetailView.sendFollowUpPrompt`.
- **AgentTestSupport:** **Ja — H1, H2.**

## B15 — N14: Stop vor Prozessregistrierung wird nach Registrierung nachgeholt

- **Bug-ID:** N14 — `requestStop` merkt das Flag, aber der aktuelle `terminate()` ist ohne publizierten Prozess ein No-op (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:80-82`).
- **Auslöse-Szenario:** Supervisor hat `running`/PID geschrieben; H3b hält den Codex-Start zwischen `process.run()` und Veröffentlichung des Handles; in diesem Fenster `requestStop()`, dann Gate lösen. Die heutige Zuweisung folgt erst nach `process.run()` (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:274-286`), während `terminate()` ohne Handle zurückkehrt (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`).
- **Soll-Verhalten nach Fix:** Stop-Intent bleibt pending und wird unmittelbar bei Handle-Registrierung angewandt; TERM→KILL wirkt auf die eigene Prozessgruppe (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:127-139`).
- **Setup:** H2/H3b; kontrollierbarer Prozessgruppen-Handle, Stop zwischen Launch und Publish, finaler Outcome-Sink.
- **Assertions:** Nach Publish sofort genau ein TERM an eigene Gruppe, bei ausbleibendem Exit genau ein KILL nach manueller Frist; kein Prompt-Write nach Stop; finaler Job `stopped`, nicht `running`/`done`/`failed`; fremde Gruppe unberührt.
- **Testziel:** `Tests/WhisperM8Tests/AgentJobSupervisorTests.swift`; `AgentJobSupervisor`, `CodexExecRunner`-Prozessnaht.
- **AgentTestSupport:** **Ja — H2, H3b.**

## B16 — N15: Tool-Resultate werden über Provider-ID statt FIFO korreliert

- **Bug-ID:** N15 — Blockmodell verliert `tool_use.id`/`tool_use_id` beziehungsweise `call_id`; Timeline paart FIFO (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:84-86`).
- **Auslöse-Szenario:** Zwei Tool-Calls A/B, danach Resultate in Reihenfolge B/A; je ein Claude- und Codex-Goldenfall. Das Modell trägt heute keine ID (`WhisperM8/Models/AgentChatTranscript.swift:93-103`), und `RoundAccumulator` hält nur offene Step-Indizes FIFO (`WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:91-100`, `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:228-251`).
- **Soll-Verhalten nach Fix:** Gemeinsames Blockmodell erhält Provider-Korrelations-ID; Reader bewahren sie, Builder paart per ID und degradiert nur ID-lose Altbestände kontrolliert (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:338-354`).
- **Setup:** H9 mit Claude `tool_use.id`/`tool_result.tool_use_id` und Codex `call_id`; Interleaving A-call, B-call, B-result, A-result. Reale Codex-Fixtures enthalten `call_id` bereits (`Tests/WhisperM8Tests/AgentTestSupport.swift:53-56`).
- **Assertions:** Step A enthält Result A, Step B Result B; Reihenfolge der Call-Steps bleibt A/B; kein orphan result, keine Duplikate; IDs überstehen Full- und Tail-Reader.
- **Testziel:** `Tests/WhisperM8Tests/AgentTranscriptReaderTests.swift` plus `Tests/WhisperM8Tests/TranscriptTimelineBuilderTests.swift`; `AgentChatBlock`, beide Reader, `TranscriptTimelineBuilder`.
- **AgentTestSupport:** **Ja — H9.**

## B17 — N16: Unbekannte syntaktisch gültige Codex-Events degradieren sichtbar

- **Bug-ID:** N16 — unbekannte Outer-/Payload-Typen liefern `nil`; Tail entfernt sie per `compactMap`, Full-Read zählt nur ungültiges JSON als skipped (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:88-90`).
- **Auslöse-Szenario:** Versioniertes JSONL enthält bekannte Nachricht, unbekanntes `event_msg`-Payload, unbekanntes `response_item` und danach bekannte Nachricht. Der aktuelle Reader defaultet in beiden Switches zu `nil` (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:112-145`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:151-199`), der Tail-Reader filtert diese Werte aus (`WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:95-107`).
- **Soll-Verhalten nach Fix:** Syntaktisch gültige unbekannte Typen werden gezählt, diagnostisch mit Typ/Payload-Kontext erhalten und in der Timeline kontrolliert sichtbar degradiert; bekannte Nachbarn bleiben unverändert (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:340-354`).
- **Setup:** H1/H9; identisches Goldenfile durch Full- und Tail-Read, Diagnostic-Spy und Timeline-Build.
- **Assertions:** Beide Reader melden exakt zwei Schema-Drift-Ereignisse mit Outer-/Payload-Typ; Timeline enthält zwei klar markierte Diagnose-/System-Steps zwischen den bekannten Nachrichten; keine Payload wird als normale User-/Assistant-Antwort fehlklassifiziert; Full und ungekürzter Tail liefern dieselbe Degradationsmatrix.
- **Testziel:** `Tests/WhisperM8Tests/AgentTranscriptReaderTests.swift` und `Tests/WhisperM8Tests/TranscriptTimelineBuilderTests.swift`; `CodexTranscriptReader`, `TranscriptTimelineBuilder`.
- **AgentTestSupport:** **Ja — H1, H9.**

---

## 2.1 Verbindlicher Wellenschnitt und Vollständigkeit

| Welle | Testverträge in diesem Dokument | Bedeutung |
|---|---|---|
| **W0** | A01–A06, A02-S01–S08, C07-1–C07-6, R4-AS-11 sowie die W0-Anteile R4-WAIT-01/02 | Charakterisierung, normative Oracles und Testnähte vor Produktänderungen. A02/C07 und offene Runde-4-Oracles sind bewusst zunächst rot. |
| **W1** | B01–B05, B07, B08, B10, B11, B15, B18–B22, R4-AUTH-01/02, R4-IDEM-01, R4-WAIT-01/02, R4-PROF-01 sowie die erledigten Phase-0-Gates | Aktiven Schaden stoppen; jedes rote Oracle wird im eigenen Fix-Change grün. |
| **W2 — separat, nicht Teil des W0/W1-Vollständigkeitsnachweises** | B06, B09, B12–B14 | Nachgelagerte Session-, Terminal- und UI-Korrektheit. |
| **W3 — separat, nicht Teil des W0/W1-Vollständigkeitsnachweises** | B16, B17 | Transcript-Korrelation und sichtbare Schema-Drift. |

Die W2/W3-Verträge bleiben als bereits wertvolle Spezifikation sichtbar erhalten, dürfen aber weder ein fehlendes W0-Oracle noch ein fehlendes W1-Fix-Gate kompensieren.

## 2.2 C07 — vollständige atomare Claim-Matrix `[W0, zunächst rot]`

Gemeinsames Given aller sechs Fälle: H1/H2/H10a, `ManualClock`, zwei lokale Rows mit unveränderlichen Vorher-Snapshots, per Launch eigener `launchID`/Generation und Bridge-Dateipfad. Hook und Scan rufen dieselbe `claimProviderSession`-Operation unter demselben Workspace-Lock auf. Jeder Test protokolliert `ClaimOutcome`, Row-Diff, Recovery-Sidecar, Workspace-Revision und Provider-Datei-Bytes.

### C07-1 — Parallele Launches bleiben bei invertierter Hook-/Scan-Reihenfolge getrennt

- **Given:** Launch A/B im selben cwd und Zeitfenster, aber mit eigenen Generationen; neue Keys KA/KB. Zwei Scheduler-Tabellen: `Hook(A) → Scan(B) → Hook(B) → Scan(A)` und exakt invertiert.
- **When:** H2 löst die vier Evidenzen in der jeweiligen Reihenfolge; spätere Duplikate derselben Evidenz werden erneut zugestellt.
- **Then:** Erster eindeutiger Claim pro Row liefert `claimed`, seine Wiederholung `alreadyOwnedBySameRow`; A endet ausschließlich mit KA, B ausschließlich mit KB. Genau zwei atomare Row-Commits, danach höchstens Metadatenupdate derselben Generation.
- **Negativfall/Persistenz:** Keine Cross-Bindung, keine zusätzliche Row und kein RecoveryCase. Scheduler-Reihenfolge ändert das persistierte Endergebnis nicht; Provider-Dateien bleiben bytegleich.
- **Minimale Naht:** H10a plus injizierter Evidenz-Scheduler; kein Bridge-/Watcher-Gesamtharness.

### C07-2 — Bereits belegter externer Key kollidiert ohne Row-Mutation

- **Given:** `ProviderSessionKey K` gehört Row A beziehungsweise einer aktiven Writer-Lease; aktueller Launch B präsentiert K mit sonst passender Evidenz.
- **When:** B ruft Claim unter dem Store-Lock auf.
- **Then:** Outcome `collision`; Row A bleibt Besitzerin, Row B bleibt in `bindingPending`; kein Terminal-ID-/Watcher-Update.
- **Negativfall/Persistenz:** Sämtliche Felder beider Rows bleiben zum Vorher-Snapshot identisch. Nur ein separater `RecoveryCase(B, collision, [K], launchID, revision)` darf persistieren; Provider-Dateien werden nicht verändert.
- **Minimale Naht:** H10a, Writer-Lease-Fixture und Recovery-Sink.

### C07-3 — Zwei Kandidaten im Launchfenster sind mehrdeutig

- **Given:** Ein Fresh-/Fork-Launch unter `hostAssignedUnsupported`; zwei neue, ungeclaimte, cwd-/root-kompatible JSONL-Kandidaten K1/K2 liegen symmetrisch im durch `ManualClock` definierten Fenster.
- **When:** Indexer-Recovery übergibt beide Kandidaten in einem atomaren Claim-Versuch.
- **Then:** Outcome `ambiguous`; weder Zeitnähe noch Dateireihenfolge wählt einen Gewinner.
- **Negativfall/Persistenz:** Row-Binding, Lineage, Transcriptpfad, cwd und UI-Auswahl bleiben unverändert; nur Recovery-Evidenz mit **beiden** Keys persistiert. Ein späterer expliziter User-Claim braucht neue Revision und dieselbe Claim-API.
- **Minimale Naht:** H1/H2/H10a; pure Candidate-Ranking-Closure darf nur `unique | ambiguous` liefern.

### C07-4 — Fork-Parent vor Child bindet niemals den Parent an die Child-Row

- **Given:** Parent-Row besitzt KP. Neue Child-Row ist mit `intent=fork(KP)` und leerem Binding vorbereitet. Das erste aktuelle Event/Scan-Ergebnis nennt KP, das spätere autoritative Event KC.
- **When:** Erst KP, nach `ManualGate` KC geclaimt wird.
- **Then:** KP gegen die Child-Row liefert `collision` und keine Row-Mutation; KC liefert anschließend `claimed`, persistiert `parentKey=KP`, `activeKey=KC`, Transcriptpfad/cwd gemeinsam und lässt die Parent-Row unverändert.
- **Negativfall/Persistenz:** Trifft KC nie ein, bleibt Child ungeclaimt mit Recovery statt Parent-Binding. Zwischen KP und KC darf keine Terminal-ID-, Watcher- oder Auto-Name-Persistenz erfolgen.
- **Minimale Naht:** H2/H10a; zwei explizit geordnete Claim-Aufrufe.

### C07-5 — Spätes Event einer alten Launchgeneration ist reine Diagnose

- **Given:** Row besitzt neue aktive `(launchID=L2, generation=2)`; supersedierte Eventdatei L1 meldet einen plausiblen Key, nachdem L2 bereits vorbereitet oder gesund ist.
- **When:** Das L1-Envelope nach dem L2-Commit zugestellt wird.
- **Then:** Outcome `staleGeneration`; Eventpfad und beobachteter Key erscheinen in genau einer Diagnose.
- **Negativfall/Persistenz:** Kein Row-, Binding-, Recovery-, UI-, Watcher- oder Workspace-Revisions-Diff; insbesondere verdrängt L1 weder den L2-Key noch dessen `bindingPending`/`healthy`-Zustand.
- **Minimale Naht:** H2/H10a und generationengegatteter Envelope-Dispatcher.

### C07-6 — Gleiche nackte UUID in zwei Config-Roots bleibt gescopte Identität

- **Given:** Root RA/RB enthalten jeweils `uuid.jsonl`; daraus entstehen `KA=(claude, RA, uuid)` und `KB=(claude, RB, uuid)`. Je eine aktuelle Row erwartet ihren Root.
- **When:** Hooks/Scans in beiden Reihenfolgen claimen; zusätzlicher Fall liefert einen Transcriptpfad, der keinem oder mehreren bekannten Roots eindeutig zugeordnet werden kann.
- **Then:** KA und KB dürfen jeweils `claimed` werden und kollidieren nicht, weil der kanonische Root Teil des Keys ist. Der ungescopte/mehrdeutige Pfad liefert `ambiguous`.
- **Negativfall/Persistenz:** Beim `ambiguous`-Fall keine Row-Mutation; nur Recovery-Sidecar. Root-Kanonisierung löst Symlinks und vergleicht Pfadkomponenten, nie String-Präfixe; beide Provider-Roots bleiben read-only.
- **Minimale Naht:** H1/H10a plus pure `canonicalConfigRoot`-/Pfadvalidierungsfunktion.

## 2.3 Fehlende W1-Gates B18–B22

## B18 — P1.1: Child-Environment ist pro Prozessklasse minimal, profilbewusst und secret-frei `[W1, rot]`

- **Bug-/Maßnahmen-ID:** P1.1, N09/N10 sowie R4-CP-05.
- **Given:** Tabellenmatrix für PTY, `--bg`, Attach, Logs/Stop/Respawn/Health, `agents --json`, Auto-Namer und Summarizer. Basis-Environment enthält benötigte PATH/TERM-Werte sowie Canary-Secrets `AWS_SECRET_ACCESS_KEY`, `GITHUB_TOKEN`, fremdes `SSH_AUTH_SOCK`, `CCP_TRAFFIC_LOG` und unbekannte `CLAUDE_CODE_*`; Profil-Overlay setzt `CLAUDE_CONFIG_DIR` und versucht im Negativfall, eine gesperrte Variable erneut einzuführen.
- **When:** Die pure klassifizierte Environment-Fabrik baut das Child-Environment; One-shot-Pfade laufen über H3a, langlebige Kinder über ihre vorhandene Launcher-/PTY-Closure. `ManualGate` ordnet nur die Capture-Zeitpunkte, es gibt keinen Wanduhr-Sleep.
- **Then:** Jede Prozessklasse erhält nur ihre Allowlist plus explizit zulässige Overrides; PATH/TERM und das gewählte Profil bleiben funktionsfähig. Supervisor-Reader und alle Active-Background-Pfade verwenden denselben Profil-Root. Die gesamte `CLAUDE_CODE_*`-Familie und Canary-Secrets fehlen, sofern nicht ein Feld für genau diese Prozessklasse ausdrücklich erlaubt ist.
- **Negativfall/Persistenz:** Profil-/Context-Overlay darf verbotene Familien nach der Bereinigung nicht wieder einführen. Ein fehlendes/ungültiges Profil fällt sichtbar und fail-closed aus, statt unter Main-Account zu starten. Keine Workspace-Mutation; persistiert werden höchstens der schon beschlossene Profilstempel beziehungsweise eine Diagnose, nie Secret-Werte oder argv-Klartext.
- **Testziel/minimale Naht:** neue `ChildProcessEnvironmentTests.swift`; pure `environment(for:base:profile:overrides:)`, H3a nur für One-shot-Argumentcapture, bestehende Launcher-Closure für langlebige Kinder.

## B19 — P0.4a: Headless-Hilfsläufe sind nicht persistent, nutzen Scratch-cwd und das richtige Profil `[W1, teilweise grün]`

- **Erfüllte Charakterisierung:** Commit `8a86863`; `testClaudeTitleRunOptsOutOfSessionPersistence`, `testSummaryRunsOptOutOfSessionPersistence`, `testCodexTitleRunIsEphemeral` und `testHeadlessCLIRunsInGivenWorkingDirectory` belegen Flagsetzung, Codex-Ephemeralität und explizites Scratch-cwd. `testRetryAfterUnknownOptionStripsOnlyTheRejectedFlag` dokumentiert den heutigen Kompatibilitätsfallback, **nicht** das Soll-Gate.
- **Given:** Fake-Home mit Main- und Profilroot, leere Provider-Sessionverzeichnisse, Scratch-cwd außerhalb echter Projekte, profilbewusstes Minimal-Environment und ein Runner, der wahlweise Non-Persistence unterstützt oder als unbekannte Option ablehnt.
- **When:** Auto-Namer und Summarizer für Claude/Codex ausgeführt werden; H3a protokolliert argv/cwd/env/result, H2 steuert Timeout/Retry ohne Wanduhr.
- **Then:** Unterstützter Pfad liefert das Ergebnis und erzeugt in keinem gescannten Provider-Root importierbare JSONL. Claude trägt `--no-session-persistence`, Codex das verifizierte Äquivalent; cwd ist Scratch, `CLAUDE_CONFIG_DIR` entspricht dem Sessionprofil, und B18s Secret-Canaries fehlen.
- **Negativfall/Persistenz:** Lehnt die CLI alle sicheren Ephemeral-Flags ab, endet der Hilfslauf sichtbar fail-closed; er darf **nicht** durch Entfernen des einzigen Non-Persistence-Flags persistent wiederholt werden. Provider-Verzeichnisse und Workspace bleiben byte-/revisionsgleich; nur Ergebnis oder Diagnose ist ephemer.
- **Rest-Oracles:** Profilmatrix, Fake-Home-Nichtimportierbarkeit und fail-closed-Fallback sind vor Abschluss von P0.4a noch rot.
- **Testziel/minimale Naht:** bestehende AutoNamer-/Summarizer-Suiten plus `AgentHeadlessCLI`; H1/H2/H3a und pure Retry-Entscheidung.

## B20 — P1.6: Langsames Git-Ergebnis darf neuen Projektpfad nicht überschreiben `[W1, Grundfix grün; Stale-Apply-Oracle rot]`

- **Erfüllte Charakterisierung:** Commit `87d3027`; `GitProjectStatusTests.testAsyncLoadMatchesSyncInit` belegt den off-main Loader, Parsertests bewahren Branch/Numstat-Verhalten.
- **Given:** View-Modell startet Generation G1 für Pfad A; H2 hält A im Runner. Danach wechselt es auf Pfad B/G2, leert den sichtbaren Altstatus sofort und B liefert zuerst. Anschließend wird A trotz Cancellation kontrolliert freigegeben.
- **When:** Beide Load-Tasks ihr Resultat an die minimale Apply-Closure liefern.
- **Then:** Nur `(path=B, generation=G2)` darf Status B publizieren; A wird verworfen, auch wenn der Runner Cancellation ignoriert. Timeout/Fehler für B lässt den Status leer und alle Pipes/Tasks beendet.
- **Negativfall/Persistenz:** Ohne Pfad-/Generationstreffer keine UI-Mutation und kein Wiedererscheinen des alten Status. Git-Status bleibt ephemer; weder Workspace noch UI-Sidecar wird gespeichert.
- **Testziel/minimale Naht:** `GitProjectStatusTests` plus kleiner `ProjectGitStatusLoader` oder pure `apply(result:for:generation:)`-Closure aus `ProjectDetailPanel`; H2/ManualGate, injizierter Runner und Scheduler.

## B21 — P1.7: WindowStore publiziert/speichert nur semantische Diffs `[W1, erfüllt]`

- **Erfüllte Charakterisierung:** Commit `a36fcee`; `testNoOpMutationsDoNotDirtyStore`, `testRealMutationBumpsRevisionExactlyOnce` und `testNoOpGridWorkspaceMutationDoesNotDirtyStore` belegen das zentrale Diff-Gate.
- **Given/When:** Identische Hot-Caller-Mutationen und danach eine echte State-Änderung; Debounce wird im Test über injizierten manuellen Scheduler statt Wanduhr vorgerückt.
- **Then:** No-op verändert weder Observable-State, `dirtyRevision` noch Save-Count; echte semantische Änderung schreibt State einmal, erhöht Revision einmal und plant genau einen Save. `flush()` bleibt als explizite, No-op-unabhängige Persistenzbarriere zulässig.
- **Negativfall/Persistenz:** Ephemere Multi-Selection bleibt nicht persistiert; unbekannte Fenster bleiben No-op und werden nicht als Geisterfenster erzeugt. Persistierter Sidecar ändert sich nur beim echten Diff beziehungsweise expliziten Flush-Reconcile.
- **Testziel/minimale Naht:** bestehende `AgentWindowStoreTests`; lokaler Save- und Scheduler-Spy, kein globaler Store-Harness.

## B22 — P1.9: Transcript-Locator cached Hit/Miss/Move **und Config-Root/Profile** korrekt `[W1, teilweise grün]`

- **Erfüllte Charakterisierung:** Commit `97a124d`; `testFindsSessionByID`, `testOneScanHarvestsAllSessions`, `testMissIsNegativelyCachedUntilTTLExpires` und `testMovedFileIsReResolved` belegen Hit, Harvest, manuellen Negativ-TTL und Move-Revalidation.
- **Given:** H1 mit zwei kanonischen Codex-/Profilroots RA/RB, gleicher Session-ID in beiden Roots und getrennten Dateien; `ManualClock` kontrolliert positiven/negativen TTL. Nach erstem Hit wird Datei in RA verschoben, in RB bleibt sie unverändert.
- **When:** Lookups in der Folge `RA → RB → RA`, Miss→Dateierzeugung vor/nach Clock-Advance und Move durchgeführt werden.
- **Then:** Cache-Key enthält mindestens kanonischen Root plus Session-ID; RA liefert nur RA, RB nur RB. Hit validiert Dateiexistenz, Move führt zum Re-Scan, Miss bleibt nur bis zur manuellen TTL negativ. Kein Root-Wechsel darf einen alten Profiltreffer wiederverwenden.
- **Negativfall/Persistenz:** Gleiche nackte UUID in RA/RB ist kein globaler Cache-Hit; nicht eindeutig kanonisierbarer Root liefert Miss/Diagnose statt fremder Datei. Locator-Cache bleibt prozessephemer, Provider-Dateien und Workspace bleiben unverändert.
- **Rest-Oracle/Testziel/minimale Naht:** Root-/Profilisolation ist noch rot in `CodexTranscriptLocatorTests`; H1, injizierte `ManualClock` und pure kanonische Cache-Key-Funktion.

## 2.4 Runde-4-Hochbefund-Oracles

### R4-AS-11 — Doppelte lokale Session-IDs erreichen keinen trap-fähigen Planer `[W0/W1, erfüllt]`

- **Given/When/Then:** Workspace enthält zwei Rows derselben lokalen UUID; Startup-Planung läuft. `AgentSessionSummarizerTests.testDuplicateSessionIDsDoNotTrapAndPlanOnce` (Commit nach Runde 4) belegt: kein Trap, ID höchstens einmal geplant.
- **Negativfall/Persistenz:** Duplikat darf keine zusätzliche Summary oder ungeprüfte Dictionary-Konstruktion erzeugen; der Planer selbst persistiert nichts. Ein künftiger Load-Repair muss getrennt getestet und darf nicht still fremde Row-Daten überschreiben.
- **Minimale Naht:** bestehender purer `SummaryStartupPlanner`; keine neue Hilfe.

### R4-AUTH-01 — Jede Control-Mutation verlangt verifizierte Actor-Capability `[W1, rot]`

- **Given:** Methodenmatrix `send`, `interrupt`, `new`, `rename`, `group`, `archive`, Workspace-/Grid-Mutationen; Actor fehlt, Token ist falsch/abgelaufen oder Zielbeziehung unzulässig. Kontrollfall besitzt gültige Capability. `ManualClock` steuert Ablauf, H1 den Store.
- **When:** Request den zentralen Authorization-Guard vor dem Methodendispatch erreicht.
- **Then:** Ungültige Fälle liefern ein einheitliches Auth-/Authorization-Ergebnis und rufen keinen Mutationshandler auf; gültiger Fall erreicht genau den erlaubten Handler. `force` überstimmt niemals Auth.
- **Negativfall/Persistenz:** Workspace, PTY, Audit-Log und Tokenregistry bleiben bei Ablehnung unverändert; Ablehnungsdiagnose darf keine Prompt-/Token-Secrets enthalten.
- **Minimale Naht:** pure `authorize(actor:method:target:now:)`-Policy plus Handler-Closures; kein echter Socket.

### R4-AUTH-02 — Control-Client authentisiert Socket und korreliert Response vor Secretversand `[W1, rot]`

- **Given:** Scripted-Unix-Transport mit Discovery-Datei-Matrix: falscher Owner/Mode/Dateityp, falsche Peer-EUID, falsche `protocolVersion`, falsche `requestID`; Kontrollfall ist vollständig korrekt. H2 hält Connect/Write/Read deterministisch.
- **When:** Client verbindet und bereitet Actor-Token/Prompt vor.
- **Then:** Dateisystem-/Peer-Guards passieren **vor** Secretversand; Response wird nur bei passender Protokollversion und Request-ID akzeptiert.
- **Negativfall/Persistenz:** In allen Fake-/Mismatch-Fällen wurden null Token-/Promptbytes geschrieben und kein Erfolg ausgegeben; Client persistiert nichts und verändert Discovery/Socket nicht.
- **Minimale Naht:** `ControlTransport` mit `validateDiscovery`, `peerIdentity`, `write`, `read`; keine universelle Netzwerkabstraktion.

### R4-IDEM-01 — Retry verwendet stabile Request-ID und mutiert höchstens einmal `[W1, rot]`

- **Given:** Erster Request wird serverseitig reserviert, H2 hält den Handler bis hinter den Client-Timeout; der CLI-Retry verwendet denselben stabilen Operation-Key. Kontrollfall sendet gleiche ID mit anderem Payload.
- **When:** Ersttransport, Timeout und Retry/Outcome-Abfrage ausgeführt werden.
- **Then:** Gleiche ID+Payload führt zu genau einer Mutation und reproduzierbarem Outcome; Retry startet keinen zweiten Agent-Auftrag. Gleiche ID mit anderem Payload wird als Idempotenzkonflikt abgelehnt.
- **Negativfall/Persistenz:** Genau ein Workspace-/PTY-Effekt und ein abgeschlossenes Idempotenzjournal; Timeout allein markiert Outcome als unbekannt, aber nicht als fehlgeschlagen. Journalzeit wird mit `ManualClock` geprüft.
- **Minimale Naht:** persistierbarer `RequestOutcomeStore` hinter kleinem Protokoll plus Handler-Gate; CLI-Parser akzeptiert/reused den Operation-Key.

### R4-WAIT-01 — `new → wait --ref` lädt spätes Binding nach `[W0 Oracle/W1 Fix, rot]`

- **Given:** `new` liefert lokale `chatID`; erster Workspace-Read hat kein externes Binding. H2 persistiert danach Claim/Transcriptpfad und erhöht Workspace-Revision, bevor der nächste Poll freigegeben wird.
- **When:** `wait --ref` mindestens zwei Polls beziehungsweise einen Event-Wakeup verarbeitet.
- **Then:** Jeder Poll liest Revision und löst die Row neu auf; nach Änderung gelangen neue Provider-ID, Pfad, Generation und Recovery-State an den Probe, der das erwartete Ereignis erkennt.
- **Negativfall/Persistenz:** Ohne Revisionsänderung darf ein Cache wiederverwendet werden; mit Änderung nie. `wait` mutiert Workspace nicht, das Claim ist die einzige Row-Persistenz.
- **Minimale Naht:** `workspaceSnapshotProvider`-Closure und ManualPollScheduler statt unveränderlichem Entry-Array.

### R4-WAIT-02 — Wait-Cursor ist pro Session monoton und bewahrt Übergänge `[W0 Oracle/W1 Fix, rot]`

- **Given:** Session A startet bei Revision/Dateigröße 10.000, B bei 10 und wechselt über `working` auf 20/`idle`; zweite Tabelle rotiert/trunkiert B. H2 ordnet alle Probes.
- **When:** Multi-Session-Wait mit per-ID-Cursor reevaluieren soll.
- **Then:** B wird unabhängig von As größerem Wert erkannt; `attention` sieht den Übergang `working → idle`, nicht nur eine neue Baseline. Rotation/Truncation erzeugt neue Dateigeneration statt rückwärts laufendem Cursor.
- **Negativfall/Persistenz:** Aktivität von A maskiert B nie; Cursor von A wird nicht auf B angewandt. Cursor bleibt ephemer oder in einem ausdrücklich separaten Wait-Checkpoint, niemals als Chat-Row-Feld.
- **Minimale Naht:** `WaitCursor(sessionKey, fileIdentity, revision, previousStatus)` plus ManualPollScheduler.

### R4-PROF-01 — `session.new` stempelt denselben Profil-/Backend-/Context-Snapshot wie die UI `[W1, rot]`

- **Given:** Aktives Claude-Account-Profil `firma`, GPT-Backend-Modell und Context-Profil mit explizitem UI-Override; zweiter Fall hat nur Projektdefault, dritter ein inzwischen gelöschtes Profil. Feste Clock/UUID-Quelle macht Row-Vergleich deterministisch.
- **When:** Control-CLI und UI jeweils dieselbe Session-Erstellungsanforderung an den gemeinsamen Launch-Service geben.
- **Then:** Persistierte Rows tragen feldgleich `claudeProfileName`, `claudeBackendModel` und den zum Erstellungszeitpunkt aufgelösten `contextProfileID`; Command-Builder startet im gleichen Config-Root/Account und mit denselben Backend-Argumenten.
- **Negativfall/Persistenz:** Gelöschtes/uneindeutiges Accountprofil startet nicht still als Main; Fehler persistiert keine halbe Session. Projektdefault ist zulässiger Fallback nur dann, wenn kein expliziter Session-Override angefordert war.
- **Minimale Naht:** gemeinsamer `SessionLaunchContextProvider` und eine `createSession`-Operation; keine View-Abhängigkeit.

## 2.5 Erledigte Phase-0-Charakterisierungen

Diese Gates sind bereits grün und bleiben als W1-Regressionsschutz verlinkt; sie werden nicht erneut als rote Arbeit ausgegeben.

| Finding / Commit | Bestehende Tests | Vertrag, Negativfall und Persistenz |
|---|---|---|
| `R4-VC-11` / `e104706` | `AgentCLIArgumentsTests.testIDCommandRejectsPathTraversal`, `testIDCommandAcceptsGeneratedShortIDFormat`; `AgentJobStoreTests.testRemoveJobRejectsSymlinkOutsideRoot` | Ungültige IDs und Symlink-Escape werden vor Dateizugriff abgelehnt; außerhalb des Job-Roots wird nichts gelöscht oder verändert. |
| `R4-AS-03` / `d375855` | `AgentWorktreeManagerTests.testDefaultRunnerDrainsLargeStatusOutput`, `testDefaultRunnerTerminatesAfterDeadline` | stdout/stderr werden unter Pipe-Druck drainiert; manuelle Deadline terminiert statt Deadlock; Worktree-Persistenz ändert sich im Fehlerfall nicht. |
| `R4-VC-03` / `3086b9e` | `CLIAudioExtractorTests.testFFmpegFallbackDoesNotDeadlockOnLargeStdout`, `testFFmpegRunnerDrainsCompleteLargeStderr`, `testFFmpegRunnerTerminatesAfterDeadline` | ffmpeg-Pipes werden vollständig drainiert und Deadline beendet den Prozess; keine unvollständige Audioausgabe wird als Erfolg persistiert. |

---

## 3. Empfohlene Einführungsreihenfolge

1. **Nähte verhaltensneutral:** H1/H2, H3a/H3b, H6a/H6b und H10a/H10b nur dort extrahieren, wo ein konkreter Test sie braucht. Kein God-Spy und keine Soll-Semantik im Seam-Change.
2. **W0-Charakterisierung grün:** A01, A03–A06 und die bestehenden Coordinator-Statusfälle. A02/A02-S01–S08, C07-1–C07-6 sowie die beiden WAIT-Oracles zunächst rot materialisieren; keine Identitätsimplementierung vor beobachtetem Rot.
3. **Bereits erfüllte Gates festhalten:** R4-AS-11, B19-Teilabdeckung, B21, B22-Teilabdeckung und Phase-0-Charakterisierungen bleiben grün.
4. **W1 Crash/Datenverlust einzeln:** B01–B05, B07/B08, B10/B11 und B15. Kein Sammel-Fix ohne jeweils beobachtetes Rot→Grün.
5. **W1 fehlende Pakete einzeln:** B18 Environment, B19 Rest-Oracles, B20 Stale-Apply und B22 Profilisolation in getrennten Changes; B21 benötigt keinen erneuten Produktfix.
6. **Runde-4-Aktivschaden:** R4-AUTH-01 vor R4-AUTH-02, danach R4-IDEM-01, R4-WAIT-01/02 und R4-PROF-01. Jeder Fix bewahrt die vorherigen roten und grünen Oracles.
7. **W2/W3 separat:** Erst nach dem W0/W1-Gate B06, B09, B12–B14 beziehungsweise B16/B17 umsetzen; sie zählen nicht zur Freigabe von W0/W1.

Die Reihenfolge priorisiert atomare Identität, Security/Datenhoheit und aktiven Datenverlust. Jeder zeitliche Vertrag läuft über ManualClock/Scheduler/Gate; jeder negative Claim-, Auth- oder Stale-Fall weist explizit nach, dass keine fachliche Row-Persistenzmutation erfolgt.
