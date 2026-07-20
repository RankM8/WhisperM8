---
status: spezifikation
updated: 2026-07-18
description: Test-Spezifikationen für Absicherungs- und rot-nach-grün-Tests der Wellen 0/1 mit P0-Priorisierung, deterministischen Fakes und konkreten Codebelegen.
---

# Test-Spezifikationen Welle 0/1

> **Identitäts-Gate für die G4-Revision:** Tests der Session-Bindung müssen gegen die Capability-Zustände `hostAssignedUnsupported`/`hostAssignedVerified` und die Claim-API aus [`identitaetsmodell-spec.md` §2.2](identitaetsmodell-spec.md) geschrieben werden. A02 ist in seiner heutigen Form überholt und wird in der G4-Revision durch capability-/claim-spezifische Oracles ersetzt.

## 0. Geltungsbereich und Ausführungsregel

Dieses Dokument spezifiziert ausschließlich Tests; es enthält keinen Test- oder Produktcode. Kategorie 1 friert korrektes Ist-Verhalten als Refactoring-Gate ein. Diese Tests müssen **vor** der jeweiligen Produktionsänderung grün sein. Wo der heutige Code harte Framework-Abhängigkeiten besitzt, ist zuerst nur eine verhaltensneutrale Naht zu extrahieren; erst wenn der Test gegen den unveränderten Altpfad grün ist, beginnt der Fix. Kategorie 2 beschreibt dagegen bewusst zunächst rote Bug-Soll-Tests, die im selben Change wie der jeweilige Fix grün werden.

Die vorhandene Suite erreicht bei Recorder und Terminal nur vorgelagerte pure Funktionen beziehungsweise Container, nicht die besitzenden Lifecycle-Pfade (`Tests/WhisperM8Tests/AudioFormatDecisionTests.swift:5-7`, `docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde2-tests-qualitaet-codex.md:80-82`). Die vorgeschlagenen Hilfen folgen der Repository-Konvention aus Closure-DI, kleinen Protokollen und Spies; `AgentTestSupport` enthält derzeit nur Codex-Fixtures und zwei Temp-Helfer (`Tests/WhisperM8Tests/AgentTestSupport.swift:4-10`, `Tests/WhisperM8Tests/AgentTestSupport.swift:73-86`).

### 0.1 Neue gemeinsame Helfer-Kürzel

| Kürzel | Ergänzung in `AgentTestSupport.swift` | Zweck |
|---|---|---|
| H1 | `TemporaryTestRoot` / `withTemporaryDirectory` | Throw-sicheres automatisches Cleanup, optionaler Fake-Home und benannte Unterpfade. |
| H2 | `ManualSleeper`, `ManualClock`, `ManualGate` | Suspension-Points und Reihenfolgen ohne Wanduhr-Sleeps steuern. |
| H3 | `ProcessRunnerSpy` + `ControllableProcessHandle` | executable, argv, cwd, Environment, Prozessidentität, Ready/Exit, Signale und Output beobachten. |
| H4 | `IsolatedPreferencesScope` | `AppPreferences.shared` serialisiert und auch bei async/throw/cancellation sicher restaurieren. |
| H5 | `AudioEngineSpy` / `AudioRecordingBackendSpy` | Formatfolgen, Tap, Converter, Start/Stop und Observer deterministisch protokollieren. |
| H6 | `TerminalPTYSpy` | Interrupts, PID/Spawn-Token, Output-Drain, Exit und Snapshot-Reihenfolge steuern. |
| H7 | `KeychainClientSpy` | Security-Status für Copy/Update/Add/Readback ohne echten Schlüsselbund vorgeben. |
| H8 | `PasteTargetSpy` | App-, Fenster- und Agent-Session-Identität sowie Aktivierung/Cmd+V beobachten. |
| H9 | `TranscriptDiagnosticSpy` + providerübergreifende Golden-Fixtures | Schema-Drift, unbekannte Events und parallele Tool-Korrelation prüfen. |
| H10 | `AgentPipelineHarness` | Temp-Store, Hook-Bridge, Watcher-Spy, Status-Koordinator und Persistenz-Spy gemeinsam aufbauen. |

H1–H4, ein vollständiger Process-Spy und ein Pipeline-Harness entsprechen den bereits identifizierten Infrastruktur-Lücken (`docs/audit/2026-07-agent-chats-deep-dive/02-findings/runde2-tests-qualitaet-codex.md:94-103`).

---

# KATEGORIE 1 — Absicherungs-Tests für korrektes Ist-Verhalten

## A01 — Recorder-Start commitet Zustand erst nach erfolgreichem Engine-Start

- **Zweck:** Den erfolgreichen Start- und Rollback-Vertrag einfrieren, ohne die heutigen TOCTOU-/Reconfiguration-Bugs als Soll zu zementieren.
- **Setup/Fixtures:** Mikrofonfreigabe-Closure liefert `true`; H5 liefert ein stabiles, recordable 48-kHz-Stereoformat, einen erfolgreichen Converter, Tap und Engine-Start. Eine zweite Tabellenzeile lässt ausschließlich `engine.start()` fehlschlagen. `AudioRecorder` setzt heute Ressourcen zurück, bindet Gerät und Format, installiert den Tap, startet die Engine und setzt erst danach `self.engine`/`isRecording` (`WhisperM8/Services/Dictation/AudioRecorder.swift:33-51`, `WhisperM8/Services/Dictation/AudioRecorder.swift:62-120`, `WhisperM8/Services/Dictation/AudioRecorder.swift:122-178`).
- **Assertions:** Erfolgsfall: Reihenfolge `permission → engine/input → format → converter/file → tap → start`, danach `isRecording == true`; `stopRecording()` stoppt genau diese Engine und liefert genau die erzeugte M4A-URL. Fehlerfall: Tap entfernt, Datei/Converter/URL verworfen, `isRecording == false`, Startfehler unverändert weitergereicht. Der heutige Fehlerpfad entfernt Tap und Ressourcen und setzt die Recording-URL zurück (`WhisperM8/Services/Dictation/AudioRecorder.swift:157-173`, `WhisperM8/Services/Dictation/AudioRecorder.swift:182-214`).
- **Testziel:** neue `Tests/WhisperM8Tests/AudioRecorderLifecycleTests.swift`; Typ `AudioRecorder`.
- **AgentTestSupport:** **Ja — H1, H5.**

## A02 — Session-Bindung und Hook-Status bleiben ein zusammenhängender Vertrag

- **Zweck:** Die korrekte Kette `Launch → SessionStart-Bindung → Prompt → Rückfrage → Fortsetzung → Ende` vor Umbauten an Store, Hook-Bridge oder Status-Koordinator absichern.
- **Setup/Fixtures:** H10 mit einer lokalen Claude-Session ohne externe ID, Watcher-Spy, Terminal-ID-Updater-Spy, Flush-Spy, Notification-/Sound-Spies und deaktiviertem Grace-Timer. Der Koordinator behandelt Terminals separat, hängt für Chats einen Watcher an und bindet eine externe ID aus `SessionStart` mit sofortigem Flush (`WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:123-140`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345-363`).
- **Assertions:** Launch ist `idle`; `SessionStart(ext-1)` persistiert `ext-1`, aktualisiert den Terminalgriff genau einmal und hängt den Watcher mit `ext-1` an; `UserPromptSubmit` wird `working`; `PermissionRequest` wird `awaitingInput` und benachrichtigt einmal; `PostToolUse` wird wieder `working`; `SessionEnd` wird `stopped` und beendet bei Background-Sessions den Watcher. Die bereits sichtbaren Kernübergänge sind in der Coordinator-Suite als Signal→Status-Vertrag angelegt (`Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift:89-112`, `Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift:116-129`).
- **Testziel:** `Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift`; Typen `AgentSessionStatusCoordinator`, `AgentSessionStore`.
- **AgentTestSupport:** **Ja — H1, H10.**

## A03 — Terminal-Teardown ist idempotent und verliert keinen bereits gepufferten Output

- **Zweck:** Die fachlich richtigen Teile des Teardowns schützen, ohne synchrone `usleep`-Dauern festzuschreiben.
- **Setup/Fixtures:** H6 mit laufendem Controller, bereits gepuffertem Text `vor-exit`, Snapshot-Spy und Monitor-Detach-Spies. Der aktuelle Controller sendet zwei Interrupts, flusht gepufferten Output, snapshotet, terminiert und setzt `isRunning` zurück; der Exit-Callback wiederholt Flush/Snapshot idempotent (`WhisperM8/Views/AgentTerminalView.swift:775-820`, `WhisperM8/Views/AgentTerminalView.swift:969-980`).
- **Assertions:** Genau zwei graceful Interrupt-Versuche, genau ein finaler Terminate-Aufruf, Snapshot enthält `vor-exit`, Snapshot wird trotz nachfolgendem Exit-Callback nur einmal gespeichert, Monitore werden gelöst und `isRunning == false`. Keine Assertion auf 80/180 ms oder MainActor-Blockade.
- **Testziel:** neue `Tests/WhisperM8Tests/AgentTerminalControllerTests.swift`; Typen `AgentTerminalController`, `AgentTerminalRegistry`.
- **AgentTestSupport:** **Ja — H2, H6.**

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
- **Setup:** H3/H6; Identity T1/PID 4242, Exit-Barriere, danach fremde Identity T2 mit derselben PID; Signal- und Start-Spies.
- **Assertions:** Kein Signal an T2/fremde Identity; T1-Controller entfernt; genau ein neuer Start für S; Registry enthält danach nur den neuen Controller und keinen Orphan.
- **Testziel:** `Tests/WhisperM8Tests/AgentTerminalControllerTests.swift`; `AgentTerminalRegistry`, extrahierter Restart-Entscheider.
- **AgentTestSupport:** **Ja — H3, H6.**

## B07 — N07: Supervisor gilt erst nach Detach-/Ready-Handshake als gestartet

- **Bug-ID:** N07 — Launcher gibt die Kind-PID direkt nach `Process.run()` zurück, bevor der Supervisor sicher detacht ist (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:52-54`).
- **Auslöse-Szenario:** H3 startet ein Kind, hält es vor `setsid`/Prozessgruppenbildung und beendet den Waiter; zweiter Matrixfall lässt das Kind vor Ready sterben. Der heutige Launcher besitzt keinen Ready-Handshake (`WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift:30-60`).
- **Soll-Verhalten nach Fix:** Spawn setzt neue Session/Prozessgruppe früh; Launcher publiziert Erfolg/PID erst nach Ready-/Detach-Handshake, ein Vorher-Exit ist Launchfehler (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:125-139`).
- **Setup:** H2/H3 mit Zuständen `spawned`, `detachedReady`, `exited`; Persist-Spy für `supervisorPid`.
- **Assertions:** Vor Ready kein erfolgreicher Return und keine PID-Persistenz; nach Ready genau eine persistierte eigene Identität; Waiter-Abbruch nach Ready beendet Supervisor nicht; Exit vor Ready liefert Fehler und hinterlässt keine aktive Job-PID.
- **Testziel:** neue `Tests/WhisperM8Tests/AgentSupervisorLauncherTests.swift`; `AgentSupervisorLauncher` und aufrufender Startvertrag.
- **AgentTestSupport:** **Ja — H2, H3.**

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
- **Auslöse-Szenario:** H6 stellt `resume-hinweis` erst nach dem ersten Interrupt und einem expliziten Drain-/Exit-Gate bereit. Der aktuelle Teardown schläft 80/180 ms auf dem Controllerpfad und snapshotet vor `terminal.terminate()` (`WhisperM8/Views/AgentTerminalView.swift:775-795`).
- **Soll-Verhalten nach Fix:** Expliziter Zustandsautomat ordnet Interrupt, Exit-Beobachtung, Output-Drain, Snapshot und I/O-Close; Sleeps sind keine Ordnungsgarantie (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:277-286`).
- **Setup:** H2/H6, MainActor-Probe-Task, Output-Gate, Snapshot-Spy; zusätzlich drei Controller für `terminateAll`.
- **Assertions:** MainActor-Probe läuft, während Teardown wartet; Snapshot enthält `resume-hinweis`; Snapshot genau einmal nach Drain; finaler Terminate/Eskalation genau einmal; `terminateAll` wartet parallel/konstant statt N serieller 260-ms-Phasen.
- **Testziel:** `Tests/WhisperM8Tests/AgentTerminalControllerTests.swift`; `AgentTerminalController`, `AgentTerminalRegistry`.
- **AgentTestSupport:** **Ja — H2, H6.**

## B10 — N02: App-Quit finalisiert oder persistiert eine laufende Aufnahme

- **Bug-ID:** N02 — Quit sichert nur Terminal-Snapshots und antwortet sofort `.terminateNow`; die M4A liegt temporär (`docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/verdicts-runde2.md:32-34`).
- **Auslöse-Szenario:** Aufnahme aktiv, temporäre M4A enthält Daten; `applicationShouldTerminate` wird wie durch Menü- oder System-Quit aufgerufen. Heute setzt der Hook Close-Tracking, snapshotet Terminals und beendet sofort; `applicationWillTerminate` beendet nur Ducking und flusht Window-State (`WhisperM8/WhisperM8App.swift:343-360`).
- **Soll-Verhalten nach Fix:** `.terminateLater`; Recorder geordnet stoppen/finalisieren oder recoverbaren Pending-Record persistieren; erst danach Termination bestätigen, niemals automatisch versenden (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:84-95`).
- **Setup:** H1/H2/H5; App-Termination-Reply-Spy, aktive Recording-URL, Pending-Record-Store-Spy; Kontrollfall ohne Aufnahme.
- **Assertions:** Aktive Aufnahme: erste Antwort `.terminateLater`, Stop/Finalize oder Pending-Persistenz genau einmal, Datei nach Abschluss existent/recoverbar, dann genau ein Reply `.terminateNow`; kein Transcribe-/Paste-Aufruf. Ohne Aufnahme bleibt normaler Quit unmittelbar.
- **Testziel:** neue `Tests/WhisperM8Tests/AppTerminationRecordingTests.swift`; extrahierter Quit-Koordinator plus `AppDelegate`-Verdrahtung.
- **AgentTestSupport:** **Ja — H1, H2, H5.**

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
- **Auslöse-Szenario:** Supervisor hat `running`/PID geschrieben; H3 hält den Codex-Start zwischen `process.run()` und Veröffentlichung des Handles; in diesem Fenster `requestStop()`, dann Gate lösen. Die heutige Zuweisung folgt erst nach `process.run()` (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:274-286`), während `terminate()` ohne Handle zurückkehrt (`WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`).
- **Soll-Verhalten nach Fix:** Stop-Intent bleibt pending und wird unmittelbar bei Handle-Registrierung angewandt; TERM→KILL wirkt auf die eigene Prozessgruppe (`docs/audit/2026-07-agent-chats-deep-dive/05-roadmap/refactor-roadmap.md:127-139`).
- **Setup:** H2/H3; kontrollierbarer Runner/Prozessgruppen-Handle, Stop zwischen Launch und Publish, finaler Outcome-Sink.
- **Assertions:** Nach Publish sofort genau ein TERM an eigene Gruppe, bei ausbleibendem Exit genau ein KILL nach manueller Frist; kein Prompt-Write nach Stop; finaler Job `stopped`, nicht `running`/`done`/`failed`; fremde Gruppe unberührt.
- **Testziel:** `Tests/WhisperM8Tests/AgentJobSupervisorTests.swift`; `AgentJobSupervisor`, `CodexExecRunner`-Prozessnaht.
- **AgentTestSupport:** **Ja — H2, H3.**

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

## 3. Empfohlene Einführungsreihenfolge

1. **Test-Infrastruktur nur verhaltensneutral:** H1–H4, H5/H6-Protokolle und bestehende Proxy-Closure-DI konsolidieren. Noch keine Soll-Änderung.
2. **Kategorie 1 vollständig grün:** A01–A06 sind das Refactoring-Gate.
3. **P0 rot festhalten und einzeln grün machen:** B01 (C01), B02 (C02), B03 (N04), B04 (N05), B05 (N06). Kein Sammel-Fix ohne jeweils beobachtetes Rot.
4. **Prozess-/Terminal-Sicherheit:** B06–B10 (N01, N07, N08, C10, N02).
5. **Daten- und UI-Konsistenz:** B11–B17 (N03, N11–N16).

Die Reihenfolge setzt die vom Auftrag verlangten Crash- und Datenverlustfälle vor die übrigen hohen Findings und hält die Fixgrenzen klein genug, dass jeder Bug-Soll-Test seinen eigenen Rot→Grün-Nachweis behält.
