---
status: roh
updated: 2026-10-17
description: Workflow A, A3 Agent-Kern Laufzeit — Rohbefunde des GPT-Finders (aus der strukturierten Rückgabe erzeugt, noch unverifiziert).
---

# A3 Agent-Kern Laufzeit

> Unverifiziert. Schweregrade sind die Einschätzung des Finders; Workflow C prüft sie gegen.

## Kurzfazit

Statisches A3-Audit abgeschlossen: 15 Befunde, davon 3 P0, 11 P1 und 1 P2. Schwerpunkt sind verlorene Einstellungen/Aufträge, falsche Transcript-Zuordnung und konkurrierende Prozesszustände. Datenfluss: CommandBuilder → echte CLI im PTY/Supervisor → Hook-Dateien und Transcript → Statuskoordinator → Status, Mitteilungen und Folgeaufträge. Positiv: OSC-52-Lesen wird verweigert; Feed-Batching begrenzt Speicher und erhält FIFO; beobachtete Dateien und Job-Locks nutzen close-on-exec; explizit terminierte PTY-Kinder werden abgeholt. Die dokumentierten Guards für Fork-Bindung, native Kontext-Aliasse und Attach-Kontextwerte sollten erhalten bleiben. Es wurden weder Builds/Tests ausgeführt noch Produktdateien verändert. Die beiden angeforderten Markdown-Dateien wurden wegen der übergeordneten Vorgabe gegen Reportdateien nicht angelegt; sämtliche Befunde stehen in dieser Rückgabe.

## Befunde

### LR-AK-017 (A3-01) · [A3-01] Theme-Synchronisierung überschreibt konkurrierende Nutzereinstellungen

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-02  ·  **Alt-ID:** R4-AS-01

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:108-119`, `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift:132-153`, `WhisperM8/Support/ThemeManager.swift:80-90`

**Szenario:** Der Theme-Writer liest settings.json. Danach speichert die laufende CLI eine neue Einstellung, etwa eine Permission-Regel. Anschließend ersetzt der Writer die komplette Datei mit seinem älteren Snapshot plus theme. Die neue Nutzereinstellung verschwindet; atomarer Dateiersatz verhindert diesen Lost Update nicht.

**Fix:** Theme möglichst als sessionspezifisches Settings-Fragment transportieren statt die globale Fremddatei umzuschreiben. Native CLI, bestehende Nutzereinstellungen und Terminal-Palettenwechsel erhalten; konkurrierende externe Writes gezielt testen.

### LR-AK-018 (A3-02) · [A3-02] Queue bestätigt Aufträge und Reservierungen trotz fehlgeschlagener Persistenz

*P0 · Launch-Blocker · datenintegritaet · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AUT-01

**Beleg:** `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:49-60`, `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:68-78`, `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift:149-166`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:41-71`

**Szenario:** Bei voller Platte oder nicht beschreibbarem Queue-Verzeichnis meldet enqueue trotzdem Erfolg; nach Neustart fehlt der Auftrag. Scheitert stattdessen das Speichern von delivering, wird der Prompt dennoch gesendet, während auf Disk pending bleibt: Nach Absturz kann derselbe Auftrag erneut ausgeführt werden. Zusätzlich wird ein Decode-Fehler als leere Queue behandelt, die reconcileOnLaunch anschließend zurückschreibt.

**Fix:** Lesen und Speichern mit explizitem Fehlerzustand versehen. Reservierung erst nach erfolgreichem durable Write zurückgeben, sonst nicht senden. Bei Decode-Fehler Original sichern und Schreibzugriffe sperren statt [] zurückzuschreiben. FIFO und die bewusste unknown-statt-Auto-Retry-Semantik erhalten.

### LR-SH-001 (A3-03) · [A3-03] Unbeteiligte Parent-Secrets gelangen ungefiltert in Kindprozesse

*P0 · Launch-Blocker · security · Konfidenz hoch · Aufwand M · Risiko hoch*

**Features:** F-AC-02, F-AC-12  ·  **Alt-ID:** N09

**Beleg:** `WhisperM8/Services/Shared/LoginShellEnvironment.swift:91-127`, `WhisperM8/Services/Shared/LoginShellEnvironment.swift:145-151`, `WhisperM8/Views/AgentTerminalView.swift:879-908`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:208-211`

**Szenario:** Wird die App aus einer Umgebung mit beispielsweise AWS_SECRET_ACCESS_KEY oder einem Deployment-Token gestartet, übernimmt processEnvironment diese Werte unverändert. Damit erhalten sämtliche Chat-/Shell-/Subagent-Prozesse auch Zugangsdaten, die für ihren jeweiligen Launch nicht benötigt werden. Dies verletzt die ausdrückliche Launch-Vorgabe gegen Secrets in vererbten Kindumgebungen.

**Reproduktion:** processEnvironment(base: ["AWS_SECRET_ACCESS_KEY": "dummy"]) liefert den dummy-Wert weiterhin; dieser Resolver speist die genannten Spawn-Pfade.

**Fix:** Umgebungen nach Prozessklasse aus einer Allowlist aufbauen und erforderliche Authentisierung explizit ergänzen. PATH, Locale, Terminal-Fähigkeiten, bewusste Profil-Overrides und die vorgesehene Session-Identität erhalten; fremde Cloud-/Deployment-Secrets nicht pauschal weiterreichen.

### LR-AK-019 (A3-04) · [A3-04] Nach externer ID-Umbindung beobachtet der Watcher weiterhin das alte Transcript

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand S · Risiko mittel*

**Features:** F-AC-06, F-AC-07

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:141-170`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:186-198`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:649-663`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:780-798`

**Szenario:** Eine laufende Session hat bereits eine aufgelöste Transcript-URL. Nach /clear oder /resume bindet der Koordinator eine neue externe ID und ruft attachWatch auf. watch ändert zwar externalSessionID, behält aber die vorhandene URL und ihre Caches. Status-Fallback, Aktivitätszeile, Abort-mtime und Turn-Ende-Erkennung lesen weiter die alte Datei.

**Reproduktion:** Session mit vorhandener Datei A beobachten, anschließend watch mit derselben lokalen UUID und externer ID B aufrufen; bei weiterhin vorhandener Datei A bleibt transcriptURL A.

**Fix:** Bei Änderungen von externer ID, cwd oder Provider URL, Stat-/Event-/Activity-Caches und Event-Source invalidieren. Den bereits vorhandenen expliziten Rebind-Pfad verwenden oder dessen Verhalten in watch vereinheitlichen; Generation-Guard und stat-first erhalten.

### LR-AK-020 (A3-05) · [A3-05] Ignorierte Background-Forks verändern trotzdem den Vordergrundstatus

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-06, F-AC-11

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:330-355`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:729-735`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:201-226`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:595-608`, `Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift:173-192`

**Szenario:** Ein als fork erkannter Background-Agent schreibt über dieselbe Hook-Datei wie das Vordergrundterminal. Seine ID wird korrekt nicht gebunden, seine späteren Prompt-/Stop-/Permission-Events werden aber ohne ID-Filter auf den Vordergrundzustand angewendet. Ein Fork-Stop kann deshalb einen noch arbeitenden Vordergrundchat als fertig melden und eine Queue-Zustellung für dessen PTY auslösen.

**Fix:** Binding-Entscheidung und Status-Zuständigkeit getrennt behandeln: Events bekannter ignorierter Fork-IDs nicht auf den Vordergrundstatus anwenden. Pending-Neubindungen und legitime In-Place-Wechsel weiter zulassen. Regressionstest muss neben der gebundenen ID auch Status und Queue-/Notification-Effekte prüfen.

### LR-AK-021 (A3-06) · [A3-06] Bereits gestarteter Chat ohne Bindung wird still als neuer Chat gestartet

*P1 · Launch-Blocker · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-02  ·  **Alt-ID:** C09

**Beleg:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:561-578`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:704-715`, `WhisperM8/Views/AgentSessionDetailView.swift:540-545`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:751-756`

**Szenario:** Nach einem Launch mit ausgefallener Hook-Bindung ist hasLaunchedInitialPrompt true, externalSessionID aber nil. Sowohl der vorgelagerte Repair als auch der Builder lassen diesen Zustand passieren. Der nächste Start enthält kein --resume und keinen initialen Prompt: Im bisherigen Chat-Tab erscheint eine neue leere Unterhaltung statt einer erklärten Wiederaufnahme-Störung.

**Fix:** Für bereits gestartete normale Claude-Chats ohne ID zuerst eine eindeutige Bindungsreparatur versuchen und andernfalls mit einer handlungsorientierten Meldung abbrechen. Einen Neustart nur ausdrücklich anbieten; frische Chats und echte Forks unverändert unterstützen.

### LR-AK-022 (A3-07) · [A3-07] Background-Logs können den Prozessrunner am vollen Pipe-Puffer blockieren

*P1 · robustheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-11

**Beleg:** `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:269-274`, `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:280-299`, `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:79-86`

**Szenario:** claude logs schreibt mehr als die Kapazität seiner stdout-Pipe. Der DefaultProcessRunner liest erst im terminationHandler, das Kind kann wegen der vollen Pipe aber nicht terminieren. Nach dem Timeout wird der gültige Logs-Aufruf als fehlgeschlagen abgebrochen. Gleiches gilt für große stderr-Ausgaben.

**Reproduktion:** Runner mit einem Testprozess aufrufen, der vor Exit 0 mehrere MiB nach stdout beziehungsweise stderr schreibt; statisch entsteht das gegenseitige Warten vor dem terminationHandler.

**Fix:** stdout und stderr ab Prozessstart unabhängig drainen, Abschluss mit tatsächlichem Exit und Stream-Ende koordinieren. Timeout inklusive Kill-Eskalation beibehalten; den bereits gehärteten AgentHeadlessCLI-Ansatz wiederverwenden, ohne echte CLI-Kommandos zu ersetzen.

### LR-AK-023 (A3-08) · [A3-08] Frühes Stop-Signal verhindert den späteren Codex-Start nicht

*P1 · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-12  ·  **Alt-ID:** N14

**Beleg:** `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-56`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:100-126`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:277-284`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:133-166`

**Szenario:** Ein Stop erreicht den Supervisor während Preflight/Schema-/Git-Vorbereitung oder zwischen process.run und Veröffentlichung des Prozesshandles. requestStop setzt seinen Latch, runner.terminate findet aber noch keinen Prozess. Anschließend läuft der Codex-Turn trotzdem und kann Änderungen durchführen; der Latch wird vor dem Start nicht erneut berücksichtigt.

**Fix:** Stop-Latch und Prozessregistrierung in einen gemeinsamen start/cancel-Vertrag überführen. Ein vorregistrierter Stop muss Start verhindern oder das frisch registrierte Kind sofort beenden. Abschluss als stopped melden und die echte CLI sowie dauerhafte Thread-ID-Sicherung erhalten.

### LR-AK-024 (A3-09) · [A3-09] Orphan-Korrektur kann einen neueren Jobzustand überschreiben

*P1 · race · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-12  ·  **Alt-ID:** N12

**Beleg:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:264-276`, `WhisperM8/Services/AgentChats/AgentJobStore.swift:281-305`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:83-87`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:211-215`

**Szenario:** Ein Leser hält einen alten spawning-Snapshot ohne PID, der bereits über 30 Sekunden alt ist. Währenddessen schreibt der gestartete Supervisor running, PID und gegebenenfalls Thread-ID. correctIfOrphaned speichert anschließend seinen alten Snapshot als failed zurück. Der laufende Job verliert seine Metadaten und kann den späteren done-Übergang nicht mehr durchführen.

**Fix:** Orphan-Korrekturen unter demselben Job-Lock durchführen, dort frisch lesen und die geprüfte Laufgeneration/PID erneut vergleichen. Alle zustandsändernden Schreiber müssen den gemeinsamen Transaktionsvertrag beachten; atomare Dateien und vorhandene Transition-Guards erhalten.

### LR-AU-001 (A3-10) · [A3-10] UI-Composer umgeht die gehärtete Supervisor-PID-Transaktion

*P1 · race · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-12  ·  **Alt-ID:** N13

**Beleg:** `WhisperM8/Views/SubagentJobDetailView.swift:481-496`, `WhisperM8/Services/AgentChats/AgentJobStore.swift:164-170`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:83-87`, `WhisperM8/CLI/AgentCLICommand.swift:519-548`

**Szenario:** Nach einem Folge-Prompt liest die UI für ihren ungeschützten PID-Nachtrag noch spawning. Der Supervisor schreibt parallel bereits running. Der anschließende UI-Vollsnapshot setzt den Zustand wieder auf spawning zurück. Der tatsächlich erfolgreiche Turn scheitert danach an spawning → done. Der CLI-Pfad enthält bereits einen gelockten, zustandsabhängigen PID-Nachtrag; die UI dupliziert ihn ungepatcht.

**Fix:** Den gemeinsamen launchDetachedSupervisor-Ablauf aus UI und CLI verwenden und Fehler typisiert zurückgeben. PID nur unter Job-Lock und nur in der passenden spawning-Generation ergänzen; Claim, Composer-Inhalt bei Fehler und Thread-ID erhalten.

### LR-AK-025 (A3-11) · [A3-11] Background-Task-Cache verwirft gültige Resets auf kleinere Transcripts

*P1 · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-KO-02

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:40-48`, `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:159-181`, `WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift:132-145`

**Szenario:** Für eine lokale Session ist ein großes Transcript gecacht. Nach /clear oder Dateiersatz wird ein kleineres Transcript gelesen; der Tracker erkennt dessen neue Dateiidentität korrekt und setzt sich zurück. updatedTracker verwirft dieses Ergebnis jedoch, weil der alte Cache den größeren Offset besitzt. Neue offene Background-Tasks bleiben unsichtbar oder alte Tasks bleiben offen. Dadurch kann der Kontowechsel trotz laufender Tasks freigegeben werden oder dauerhaft warten.

**Reproduktion:** Denselben Monitor zuerst mit Datei A ohne offene Tasks und großem Offset aufrufen, dann mit Datei B derselben lokalen Session und einem offenen Task bei kleinerem Offset. Der zweite Aufruf liefert weiterhin den A-Tracker.

**Fix:** Cache-Konflikte nur innerhalb derselben Transcript-Identität und Generation anhand des Offsets entscheiden. Pfad-/Inode-Wechsel und Kürzung als neue Generation speichern; parallel verspätete Reads der alten Generation verwerfen. Background-Task-Schutz vor dem Anhalten erhalten.

### LR-AK-026 (A3-12) · [A3-12] Send-Guard blockiert Erstzustellungen bei Token-I/O-Fehlern

*P1 · Launch-Blocker · robustheit · Konfidenz hoch · Aufwand S · Risiko mittel*

**Features:** F-AC-10

**Beleg:** `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:82-98`, `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:104-119`, `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:178-192`, `WhisperM8/CLI/ChatsPromptGuardCommand.swift:46-66`

**Szenario:** Der Send-Token kann wegen voller Platte oder defekter Verzeichnisrechte nicht geschrieben beziehungsweise gelesen werden. stage verschluckt den Fehler und der Prompt wird trotzdem eingefügt. consume liefert bei I/O-Fehler dasselbe false wie bei einer echten Wiedervorlage. Der Hook blockiert deshalb die erste legitime Zustellung mit Exit 2 statt wie dokumentiert fail-open zu reagieren.

**Fix:** Token-Lookup mindestens dreistufig modellieren: vorhanden, sicher nicht vorhanden, I/O-Fehler. Bei nicht verlässlich prüfbarem Zustand die vorgesehene fail-open-Politik anwenden oder die Zustellung vorher explizit als fehlgeschlagen melden; niemals Erstzustellung als Duplikat ausgeben.

### LR-AK-027 (A3-13) · [A3-13] Zustell-Token kann mehrfach erfolgreich konsumiert werden

*P1 · Launch-Blocker · race · Konfidenz hoch · Aufwand S · Risiko mittel*

**Features:** F-AC-10

**Beleg:** `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:104-117`

**Szenario:** Zwei Hook-Prozesse lesen dasselbe noch vorhandene Token, bevor einer es löscht. Beide geben true zurück, weil das Löschergebnis ignoriert wird. Auch ein dauerhaft fehlgeschlagenes Löschen lässt dasselbe Token immer wieder passieren. Der Guard autorisiert damit mehr Submissions als die App Zustellungen freigegeben hat.

**Reproduktion:** Zwei consume-Aufrufe nach dem Decode derselben Datei synchronisieren und erst dann beide fortsetzen. Aktuell liefert auch der zweite Aufruf nach fehlgeschlagenem removeItem true.

**Fix:** Token prozessübergreifend atomar beanspruchen, etwa durch einen gemeinsamen Lock oder exklusives Umbenennen. Nur der erfolgreiche Claim darf autorisieren; Lösch-/Claim-Fehler getrennt gemäß fail-open-Politik behandeln. Mehrere gleichartige Zustellungen an verschiedene Ziele müssen weiterhin jeweils genau ein Token konsumieren.

### LR-AK-028 (A3-14) · [A3-14] Codex-Exit 0 gilt auch ohne nachgewiesenes Turn-Ende als Erfolg

*P1 · korrektheit · Konfidenz hoch · Aufwand M · Risiko mittel*

**Features:** F-AC-12  ·  **Alt-ID:** N08

**Beleg:** `WhisperM8/Services/AgentChats/CodexExecRunner.swift:488-497`, `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-119`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:133-149`

**Szenario:** Ein Codex-Wrapper beziehungsweise ein inkompatibler CLI-Lauf beendet sich mit Exit 0, ohne turn.completed und ohne letzte Nachricht zu erzeugen. Der Runner speichert keinen Completion-Nachweis. mapOutcome liefert trotzdem done, der Supervisor erhöht turns und die Aufrufer erhalten Erfolg für einen nicht belegten Auftrag.

**Reproduktion:** mapOutcome mit exitCode 0, threadID nil, lastMessage nil, turnFailedMessage nil und stalled false liefert derzeit .done.

**Fix:** Explizite erfolgreiche Turn-Finalität im Streamzustand erfassen und als Abschlussbedingung verlangen. Einen fehlenden oder nicht parsebaren Report weiterhin gesondert tolerant behandeln; diese bewusste Report-Toleranz darf nicht mit fehlender Ausführung verwechselt werden.

### LR-TRM-001 (A3-15) · [A3-15] Alle Chats stoppen blockiert den Main Thread linear pro PTY

*P2 · Launch-Blocker · performance · Konfidenz hoch · Aufwand S · Risiko niedrig*

**Features:** F-AC-02  ·  **Alt-ID:** C10, R3-TERM-G01

**Beleg:** `WhisperM8/Views/AgentTerminalView.swift:350-351`, `WhisperM8/Views/AgentTerminalView.swift:432-436`, `WhisperM8/Views/AgentTerminalView.swift:914-924`, `WhisperM8/Models/AppState.swift:137-150`

**Szenario:** Bei zehn laufenden Vordergrundchats ruft terminateAll zehnmal den Einzelstopp mit 80 ms plus 180 ms usleep auf dem MainActor auf. Schon die festen Pausen blockieren die App mindestens 2,6 Sekunden; bei zwanzig Chats 5,2 Sekunden, zusätzlich zu Flush/Teardown. Das verletzt W5 unabhängig von einer Performance-Messung.

**Fix:** terminateAll auf den bereits vorhandenen gemeinsamen terminate(sessionIDs:)-Pfad umstellen; längerfristig Grace-Wartezeiten suspendierend statt per usleep abwickeln. Zwei Interrupts, FIFO-Flush, Prozess-Reaping und Rückgabe aller gestoppten IDs erhalten.

## Nicht abgedeckt

- Keine dynamische Verifikation: keine Builds, Tests, App-Starts, echten CLI-Aufrufe, Signalversuche, Prozess-/FD-Messungen oder Performance-Lastläufe. Repro-Angaben beschreiben gezielte nachgelagerte Prüfungen, keine ausgeführten Experimente.
- Die explizit ausgeklammerten AgentChatsView-/Workspace-/Grid-/Sidebar-/TabSwitcher-Dateien, AgentWindowStore, Layout-Services, Control-Server/Handler, Chats-CLI/Guards/Journale und Plugin-Ressourcen wurden nicht inhaltlich geprüft.
- Account-Profilweitergabe bei Background-Lifecycle-Aufrufen und die vollständige Resume→Attach-Statusverdrahtung bleiben für den Delta-Lauf offen, weil ihre entscheidenden Caller in ausgeschlossenen View-Dateien liegen.
- Session-Token-Widerruf hat im durchsuchten Produktcode keinen Aufrufer; seine tatsächlichen Folgen wurden nicht als Befund eingestuft, weil die Autorisierungs- und Lebenszyklusprüfung des ausgeschlossenen Control-Servers fehlt.
- W4: Geführte Installation und Login bei fehlender CLI wurden nicht end-to-end geprüft; die Laufzeit meldet commandNotFound, der gesamte Onboarding-/Settings-Pfad gehört nicht zu A3.
- W7: Deinstallation, Beendigung externer Supervisor-/Proxy-Prozesse und Wiederherstellung globaler Fremdänderungen wurden nicht praktisch geprüft.
- Hook-Drain-Reihenfolge nach stopTracking, parallele Hook-Appends, Bytebudgets der vollständigen Hook-Payloads und adversariale Terminal-URL-Schemes benötigen eigene deterministische Tests; daraus wurden hier keine zusätzlichen ungesicherten Befunde abgeleitet.
- Die genannten A3-Produktdateien wurden vollständig gelesen. Supporting Files AgentSessionDetailView.swift, AgentSessionStore.swift und AppState.swift sowie AgentSessionStatusCoordinatorTests.swift wurden nur in den relevanten Abschnitten gelesen. REFACTORING-AUDIT.md und die historische Roadmap-Matrix wurden ausschließlich thematisch durchsucht und deshalb nicht als vollständig gelesene Dateien aufgeführt.
- Rohbericht und Lagebild-Karte wurden entsprechend der übergeordneten Anweisung nicht als Markdown-Dateien geschrieben; report_path bleibt leer.

## Gelesene Dateien

74 Dateien:

- `docs/audit/2026-10-launch-readiness/00-scope/launch-definition.md`
- `docs/audit/2026-10-launch-readiness/00-scope/feature-inventar.md`
- `docs/audit/2026-07-agent-chats-deep-dive/04-verifikation/runde4-findings-matrix.md`
- `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift`
- `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift`
- `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift`
- `WhisperM8/Services/AgentChats/AgentSessionNotifier.swift`
- `WhisperM8/Services/AgentChats/AgentAlertLevel.swift`
- `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift`
- `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift`
- `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift`
- `WhisperM8/Services/AgentChats/ExternalClaudeHooksInspector.swift`
- `WhisperM8/Services/AgentChats/ClaudeExternalIDRecovery.swift`
- `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift`
- `WhisperM8/Services/AgentChats/AgentSessionTokenRegistry.swift`
- `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift`
- `WhisperM8/Services/AgentChats/AgentChatLaunchService.swift`
- `WhisperM8/Services/AgentChats/AgentPromptQueue.swift`
- `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift`
- `WhisperM8/Services/AgentChats/AgentPromptQueueStore.swift`
- `WhisperM8/Services/AgentChats/AgentPromptRoutingService.swift`
- `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift`
- `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift`
- `WhisperM8/Services/AgentChats/BackgroundRouterLaunchGuard.swift`
- `WhisperM8/Services/AgentChats/ActiveBackgroundSessionTracker.swift`
- `WhisperM8/Services/AgentChats/ClaudeActiveSessionTracker.swift`
- `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift`
- `WhisperM8/Services/AgentChats/SupervisorJobReader.swift`
- `WhisperM8/Services/AgentChats/SupervisorRosterReader.swift`
- `WhisperM8/Services/AgentChats/AgentSupervisorLauncher.swift`
- `WhisperM8/Services/AgentChats/AgentJobStore.swift`
- `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift`
- `WhisperM8/Services/AgentChats/AgentJobState.swift`
- `WhisperM8/Services/AgentChats/AgentJobID.swift`
- `WhisperM8/Services/AgentChats/AgentJobRuntimeModel.swift`
- `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift`
- `WhisperM8/Services/AgentChats/AgentJobDirectoryMonitor.swift`
- `WhisperM8/Services/AgentChats/AgentHeadlessCLI.swift`
- `WhisperM8/Services/AgentChats/AgentWorktreeManager.swift`
- `WhisperM8/Services/AgentChats/CodexExecEvent.swift`
- `WhisperM8/Services/AgentChats/CodexExecEventParser.swift`
- `WhisperM8/Services/AgentChats/CodexExecRunner.swift`
- `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift`
- `WhisperM8/Services/AgentChats/CodexAgentPreflight.swift`
- `WhisperM8/Services/AgentChats/CodexReportSchema.swift`
- `WhisperM8/Services/AgentChats/CodexSyntheticOverflowProbe.swift`
- `WhisperM8/Services/AgentChats/CodexModelCatalogWatcher.swift`
- `WhisperM8/Services/AgentChats/ProcessAncestry.swift`
- `WhisperM8/Services/AgentChats/AgentResourceMonitor.swift`
- `WhisperM8/Services/AgentChats/ClaudeThemeWriter.swift`
- `WhisperM8/Services/AgentChats/ClaudeNativeContextAlias.swift`
- `WhisperM8/Services/AgentChats/AgentSessionRetentionService.swift`
- `WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift`
- `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift`
- `WhisperM8/Services/Shared/LoginShellEnvironment.swift`
- `WhisperM8/Services/Shared/FileEventSource.swift`
- `WhisperM8/Support/ThemeManager.swift`
- `WhisperM8/Views/AgentTerminalView.swift`
- `WhisperM8/Views/AgentTerminalLinkInterceptor.swift`
- `WhisperM8/Views/AgentTerminalPalette.swift`
- `WhisperM8/Views/TerminalFeedBatcher.swift`
- `WhisperM8/Views/TerminalLinkResolver.swift`
- `WhisperM8/Views/TerminalMetalWarmup.swift`
- `WhisperM8/Views/SubagentJobDetailView.swift`
- `WhisperM8/Views/BackgroundDispatchModal.swift`
- `WhisperM8/CLI/AgentCLICommand.swift`
- `WhisperM8/CLI/AgentCLIArguments.swift`
- `WhisperM8/CLI/AgentSuperviseCommand.swift`
- `WhisperM8/CLI/ChatsPromptGuardCommand.swift`
- `Tests/WhisperM8Tests/AgentSessionRuntimeWatcherTests.swift`
- `Tests/WhisperM8Tests/AgentSessionStatusCoordinatorTests.swift`
- `WhisperM8/Views/AgentSessionDetailView.swift`
- `WhisperM8/Services/AgentChats/AgentSessionStore.swift`
- `WhisperM8/Models/AppState.swift`
