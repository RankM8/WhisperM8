---
status: beschlossen
updated: 2026-10-18
description: Welle W8 des Launch-Readiness-Plans — Erweitert und Labs härten (nach dem Launch, D3). Befunde, Abnahmekriterien, Tests zuerst.
---

# W8 · Erweitert und Labs härten (nach dem Launch, D3)

Restliche Mängel in Konten, GPT-Backend, Subagent-Jobs und Chats-CLI. Kein Launch-Blocker nach der Definition (Erweitert blockiert nur bei P0), betrifft aber den Alltag von Power-Usern.

**Umfang:** 16 Befunde · P2 11, P3 5 · 0 Launch-Blocker · Aufwand S×5, M×11

## Abnahmekriterien der Welle

- [ ] Jeder Fix mit Regressionstest; keine Änderung am Standardverhalten von Kern-Features.
- [ ] Totes Layout-Paket (~1.400 Zeilen) entfernt oder eingebunden; Ableitung läuft nicht mehr bei jedem Laden.

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/konten-gpt.md](../../00-scope/oracle/konten-gpt.md), [oracle/agent-laufzeit.md](../../00-scope/oracle/agent-laufzeit.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-AK-022 | P2 | — | M | mittel | geplant · bestätigt | [A3-07] Background-Logs können den Prozessrunner am vollen Pipe-Puffer blockieren |
| LR-AK-023 | P2 | — | M | mittel | geplant · teilbestätigt | [A3-08] Frühes Stop-Signal verhindert den späteren Codex-Start nicht |
| LR-AK-025 | P2 | — | M | mittel | geplant · bestätigt | [A3-11] Background-Task-Cache verwirft gültige Resets auf kleinere Transcripts |
| LR-AK-028 | P2 | — | M | mittel | geplant · teilbestätigt | [A3-14] Codex-Exit 0 gilt auch ohne nachgewiesenes Turn-Ende als Erfolg |
| LR-CLI-009 | P2 | — | M | niedrig | geplant · unverifiziert | `chats watch` liest und dekodiert das komplette Status-Journal (bis 2 MB) alle 2 s je Jarvis-Session |
| LR-GPT-004 | P2 | — | M | mittel | geplant · teilbestätigt | Ein paralleler Start kann den Proxy nach Stop oder App-Quit weiterlaufen lassen |
| LR-GPT-005 | P2 | — | M | mittel | geplant · teilbestätigt | GPT-Hauptkonto wird auch bei weiterhin lebenden alten Proxys ausgetauscht |
| LR-KO-004 | P2 | — | M | mittel | geplant · teilbestätigt | Vorgemerkte Kontowechsel können zwischenzeitlich eingegebene Entwürfe verwerfen |
| LR-KO-006 | P2 | — | S | niedrig | geplant · bestätigt | Profil-Rename bricht profilgebundene Plugin-Registrierungen für alle Konten |
| LR-KO-007 | P2 | — | S | niedrig | geplant · bestätigt | Ein Keychain-Lesefehler wird beim Rename als fehlender Login behandelt |
| LR-KO-009 | P2 | — | S | niedrig | geplant · bestätigt | Teilweise fehlgeschlagenes Rückgängig löscht auch die noch offenen Journal-Einträge |
| LR-AK-012 | P3 | — | M | mittel | geplant · teilbestätigt | Retention löscht Sessions anhand eines nach await veralteten Schutz-Snapshots |
| LR-AK-031 | P3 | — | M | mittel | geplant · teilbestätigt | Job-State-Korrektur und PID-Nachtrag überschreiben neuere Zustände |
| LR-AU-020 | P3 | — | S | niedrig | geplant · unverifiziert | Etwa 1.400 Zeilen Layout-Paket (WorkspaceLayout, LayoutEngine, WorkspaceLayoutView) sind nirgends eingebunden, ihre Ableitung läuft aber bei jedem Laden und wird mitpersistiert |
| LR-CLI-010 | P3 | — | S | niedrig | geplant · unverifiziert | `chats wait` pollt doppelt, probt jede Session zweimal beim Start und beobachtet bei leerem Scope alle Chats der letzten 14 Tage |
| LR-GPT-006 | P3 | — | M | mittel | geplant · teilbestätigt | Waisen-Schutz beendet auch bewusst extern gestartete Hintergrund-Proxys |

### LR-AK-022 · [A3-07] Background-Logs können den Prozessrunner am vollen Pipe-Puffer blockieren

*P2 · agent-kern / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:269-274`, `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:280-299`, `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:79-86` (Stand `a8e0f35`)

**Fehlerbild:** claude logs schreibt mehr als die Kapazität seiner stdout-Pipe. Der DefaultProcessRunner liest erst im terminationHandler, das Kind kann wegen der vollen Pipe aber nicht terminieren. Nach dem Timeout wird der gültige Logs-Aufruf als fehlgeschlagen abgebrochen. Gleiches gilt für große stderr-Ausgaben.

**Fix:** Statt eines neuen Runners die vorhandene Drain-Technik aus AgentHeadlessCLI wiederverwenden (readabilityHandler oder asynchrones Lesen ab Start). Das Timeout mit terminate() muss erhalten bleiben und die echten claude-Kommandos dürfen nicht ersetzt werden.

*Ursprünglicher Vorschlag:* stdout und stderr ab Prozessstart unabhängig drainen, Abschluss mit tatsächlichem Exit und Stream-Ende koordinieren. Timeout inklusive Kill-Eskalation beibehalten; den bereits gehärteten AgentHeadlessCLI-Ansatz wiederverwenden, ohne echte CLI-Kommandos zu ersetzen.

**Test zuerst:** BackgroundAgentSpawnerTests oder neuer DefaultProcessRunnerTests: run(executable: /bin/sh, arguments: [-c, 'head -c 300000 /dev/zero / tr \\0 a'], timeout: 5). Erwartet exitCode 0 und stdout.count == 300000. Heute läuft der Test in SpawnError.timedOut.

<details><summary>Prüfurteil</summary>

Der DefaultProcessRunner liest stdout/stderr erst im terminationHandler. Schreibt das Kind mehr als die Pipe-Kapazität (ca. 64 KiB), blockiert es und terminiert nie, bis der Timeout greift. Das ist ein echter Klassiker. Betroffen sind aber nur `claude logs` und eventuell stop/rm mit sehr viel Ausgabe, spawn schreibt nur eine Zeile. Folgen: Die Log-Ansicht eines langlaufenden Background-Agents schlägt mit Timeout fehl, und der Start-Health-Check (10 s) meldet .error. Der Health-Check lässt die Session bei .error bewusst in Ruhe, es gibt also keinen Folgeschaden. Das Feature ist Erweitert (F-AC-11), der Nutzer kommt nicht in Kern-Wege nicht weiter. P2, weil es kein Kern-Feature ist, aber echt reproduzierbar.

</details>

### LR-AK-023 · [A3-08] Frühes Stop-Signal verhindert den späteren Codex-Start nicht

*P2 · agent-kern / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:44-56`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:100-126`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:277-284`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:327-335` (Stand `a8e0f35`)

**Fehlerbild:** Ein Stop erreicht den Supervisor während Preflight/Schema-/Git-Vorbereitung oder zwischen process.run und Veröffentlichung des Prozesshandles. requestStop setzt seinen Latch, runner.terminate findet aber noch keinen Prozess. Anschließend läuft der Codex-Turn trotzdem und kann Änderungen durchführen; der Latch wird vor dem Start nicht erneut berücksichtigt.

**Fix:** Fix ist sinnvoll und klein (Latch vor runner.run prüfen und nach Prozess-Registrierung erneut prüfen); Report-Toleranz und echte CLI unverändert lassen.

*Ursprünglicher Vorschlag:* Stop-Latch und Prozessregistrierung in einen gemeinsamen start/cancel-Vertrag überführen. Ein vorregistrierter Stop muss Start verhindern oder das frisch registrierte Kind sofort beenden. Abschluss als stopped melden und die echte CLI sowie dauerhafte Thread-ID-Sicherung erhalten.

**Test zuerst:** AgentJobSupervisorTests mit Spy-Runner: requestStop() vor superviseCurrentTurn aufrufen; erwartet: Runner.run wird nie gestartet und Job endet als stopped. Heute läuft der Turn und endet done.

**Zusammengeführt mit:** LR-AK-032

<details><summary>Prüfurteil</summary>

Die Lücke existiert: requestStop setzt nur den Latch und runner.terminate ist No-op ohne Prozess; superviseCurrentTurn prüft den Latch vor dem Start nicht erneut, und zwischen process.run() und dem Setzen von self.process (lock) gibt es ein Mikrofenster. Das Zeitfenster (Preflight, Schema-Write, Git-Root-Auflösung, Prozessstart) liegt aber nur im Bereich weniger hundert Millisekunden nach dem Supervisor-Start, ein Stop müsste genau dann ankommen. Betrifft die Erweitert-Funktion Codex-Subagents (CLI whisperm8 agent), keine Kern-Nutzerwege; Folge ist ein ungewollt gelaufener Turn, kein Datenverlust im Kern.

</details>

### LR-AK-025 · [A3-11] Background-Task-Cache verwirft gültige Resets auf kleinere Transcripts

*P2 · agent-kern / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:40-48`, `WhisperM8/Services/AgentChats/ClaudeBackgroundTasks.swift:159-181`, `WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift:132-145` (Stand `a8e0f35`)

**Fehlerbild:** Für eine lokale Session ist ein großes Transcript gecacht. Nach /clear oder Dateiersatz wird ein kleineres Transcript gelesen; der Tracker erkennt dessen neue Dateiidentität korrekt und setzt sich zurück. updatedTracker verwirft dieses Ergebnis jedoch, weil der alte Cache den größeren Offset besitzt. Neue offene Background-Tasks bleiben unsichtbar oder alte Tasks bleiben offen. Dadurch kann der Kontowechsel trotz laufender Tasks freigegeben werden oder dauerhaft warten.

**Fix:** Tracker um eine Generation/fileIdentity erweitern: parallelen Gewinner nur dann bevorzugen, wenn dieselbe fileIdentity vorliegt. Bei abweichender Identität gewinnt der neuere Tracker (der aktuelle Aufruf), nicht der größere Offset.

*Ursprünglicher Vorschlag:* Cache-Konflikte nur innerhalb derselben Transcript-Identität und Generation anhand des Offsets entscheiden. Pfad-/Inode-Wechsel und Kürzung als neue Generation speichern; parallel verspätete Reads der alten Generation verwerfen. Background-Task-Schutz vor dem Anhalten erhalten.

**Test zuerst:** ClaudeBackgroundTasksTests: gleiche sessionID, Datei A (groß, ohne Tasks) -> openTaskCount; danach Datei B (neue Inode, klein, mit einem offenen Task-Start-Marker) -> openTaskCount. Erwartet 1, heute 0 wegen des alten Trackers.

<details><summary>Prüfurteil</summary>

updatedTracker verwirft einen frisch zurückgesetzten Tracker, sobald der gecachte einen größeren Offset hat (Zeile 'current.offset > tracker.offset'), ohne die Dateiidentität zu vergleichen. Nach /clear zeigt die Session auf ein neues, kleineres Transcript, der Tracker erkennt den Wechsel korrekt, wird aber verworfen. Der gecachte alte Tracker bleibt im Dictionary, das Problem bleibt bestehen, bis das neue Transcript den alten Offset überholt. Folge: neue Background-Tasks bleiben für den Kontowechsel unsichtbar, der Wechsel könnte einen Chat mit laufenden Tasks anhalten. Betroffen ist aber nur Erweitert (F-KO-02), es erfordert /clear (oder Transcript-Wechsel) bei großem Vorgänger-Transcript plus Background-Tasks plus Kontowechsel in diesem Zustand. Der Schaden ist ein beendeter Task, kein Datenverlust.

</details>

### LR-AK-028 · [A3-14] Codex-Exit 0 gilt auch ohne nachgewiesenes Turn-Ende als Erfolg

*P2 · agent-kern / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/CodexExecRunner.swift:488-497`, `WhisperM8/Services/AgentChats/CodexTurnExecutor.swift:83-119`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:133-149` (Stand `a8e0f35`)

**Fehlerbild:** Ein Codex-Wrapper beziehungsweise ein inkompatibler CLI-Lauf beendet sich mit Exit 0, ohne turn.completed und ohne letzte Nachricht zu erzeugen. Der Runner speichert keinen Completion-Nachweis. mapOutcome liefert trotzdem done, der Supervisor erhöht turns und die Aufrufer erhalten Erfolg für einen nicht belegten Auftrag.

**Fix:** Fix sinnvoll, aber vorsichtig: Completion-Nachweis nur verlangen, wenn die Eventstream überhaupt Events lieferte oder threadID/lastMessage fehlen; ältere codex-Versionen ohne turn.completed-Event sonst nicht fälschlich als failed einstufen (Kompatibilität prüfen).

*Ursprünglicher Vorschlag:* Explizite erfolgreiche Turn-Finalität im Streamzustand erfassen und als Abschlussbedingung verlangen. Einen fehlenden oder nicht parsebaren Report weiterhin gesondert tolerant behandeln; diese bewusste Report-Toleranz darf nicht mit fehlender Ausführung verwechselt werden.

**Test zuerst:** CodexTurnExecutorTests: mapOutcome(result: CodexTurnResult(exitCode: 0, threadID: nil, lastMessage: nil, stderrTail: "", turnFailedMessage: nil, stalled: false)) erwartet .failed (heute .done).

**Zusammengeführt mit:** LR-AK-030

<details><summary>Prüfurteil</summary>

mapOutcome liefert bei exitCode 0 ohne turn.failed, threadID und lastMessage tatsächlich .done; ein expliziter Beleg für turn.completed wird nicht verlangt. Das Szenario setzt aber einen Wrapper bzw. inkompatiblen Codex-Lauf voraus, der mit Exit 0 endet, ohne irgendein Event zu erzeugen; die echte codex-CLI liefert bei Fehlern Exit != 0 oder turn.failed, was beides abgefangen wird. Die Toleranz bei nicht parsebarem Report ist dokumentiert beabsichtigt. Hardening-Punkt für Erweitert-Funktion (Subagents), kein realer Auslöser mit der unterstützten CLI.

</details>

### LR-CLI-009 · `chats watch` liest und dekodiert das komplette Status-Journal (bis 2 MB) alle 2 s je Jarvis-Session

*P2 · cli-control / performance · Aufwand M · Risiko niedrig*

**Beleg:** `WhisperM8/CLI/ChatsChangesCommand.swift:140-160`, `WhisperM8/Services/AgentChats/ChatsStatusJournal.swift:164-200`, `WhisperM8/Resources/claude-plugin/hooks/register.tsx:253-262` (Stand `76256ad`)

**Fehlerbild:** Die Mod startet je aktivem Board (Jarvis-Session) einen Dauerprozess `whisperm8 chats watch --interval 2`. Jede Runde ruft ChatsStatusJournal.changes auf: readAll liest die ganze Datei als String, splittet und JSON-dekodiert jede Zeile, danach wird gefiltert. Bei einem vollen Journal (2 MB, einige 10k Eintraege) sind das dauerhaft zweistellige Millisekunden CPU pro Runde, rund ein bis wenige Prozent Dauerlast je Watcher, auch wenn nichts passiert. Mit mehreren Jarvis-Sessions oder `since`-Pollern vervielfacht sich das. Das passt nicht zum Leerlauf-Ziel in der Definition of Done (<2 %). Die Zahl ist geschaetzt und nicht gemessen.

**Fix:** Stat-first: Groesse und mtime der Journal-Datei merken, bei Gleichstand ohne Lesen weiterschlafen. Sonst nur ab dem gemerkten Byte-Offset lesen, statt die Datei neu zu dekodieren. Alternativ den Watch ueber einen Vnode-FileEventSource wie den Runtime-Watcher aufwecken.

**Test zuerst:** Test: viele Journalzeilen und zwei changes()-Aufrufe ohne neue Zeilen. Der zweite darf die Datei nicht erneut dekodieren (Zaehler im injizierten Reader). Messung mit scripts/perf-report.sh.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-GPT-004 · Ein paralleler Start kann den Proxy nach Stop oder App-Quit weiterlaufen lassen

*P2 · gpt-backend / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:404-435`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:457-462`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:761-777`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:603-612` (Stand `a8e0f35`)

**Fehlerbild:** ensureRunning hält ensureLock, hat aber seinen gerade startenden main-Prozess noch nicht veröffentlicht. Parallel läuft Stop oder der willTerminate-Hook: stopIfSelfStarted sieht keinen Handle und stoppt keinen Router. Erst das abschließende stopAllProfileInstances wartet auf ensureLock. Dazwischen veröffentlicht ensureRunning den main-Prozess und startet den Router; anschließend stoppt der wartende Aufruf ausschließlich Profilinstanzen. Der neue main-Prozess bleibt bestehen und überlebt gegebenenfalls das App-Ende beziehungsweise die Deinstallation entgegen W7.

**Fix:** Der Fix des Finders (gemeinsame Lifecycle-Serialisierung mit Stop-Generation) ist größer als nötig. Minimal: stopIfSelfStarted/willTerminate nehmen zuerst ensureLock und stoppen danach den main-Handle und den Router. Achtung: willTerminate blockiert dann bis zum Ende eines laufenden Starts (max. einige Sekunden, bei Download länger), deshalb mit Timeout bzw. Abbruch-Flag für den Start.

*Ursprünglicher Vorschlag:* Start, Stop und Quit über dieselbe Lifecycle-Serialisierung mit Stop-/Shutdown-Generation führen. Vor einem Start-Commit einen inzwischen gesetzten Stop-Zustand beachten; alle selbst gestarteten Instanzen und der eigene Router müssen in derselben Zustandsänderung erfasst werden. Externe Prozesse weiterhin unangetastet lassen.

**Test zuerst:** ClaudeCodeProxyManagerTests: processLauncher blockiert über Semaphore; in einem zweiten Thread stopIfSelfStarted() aufrufen, dann den Launcher freigeben. Erwartet: der gestartete Fake-Handle wird terminiert (isRunning == false) und der Router gestoppt. Heute bleibt der Handle laufen.

<details><summary>Prüfurteil</summary>

Der Ablauf stimmt: stopIfSelfStarted liest selfStartedProcess ohne ensureLock. Ist ensureRunning noch vor dem Veröffentlichen des Handles (Binary-Installation, Launch) und wartet das abschließende stopAllProfileInstances auf ensureLock, dann veröffentlicht ensureRunning anschließend den main-Prozess, und stopAllProfileInstances stoppt nur Profilinstanzen. Der main-Proxy kann den Quit überleben. Das Fenster ist eng: Der Quit muss in den ersten Sekunden des ersten GPT-Starts fallen, oder während eines Binary-Downloads. Danach räumt der Waisen-Schutz die Waise beim nächsten App-Start auf (Binary älter/anderer Pfad), und das Feature ist Labs und standardmäßig aus. Der Proxy läuft dann ohne Nutzerdaten-Risiko weiter. W7 (zap-Deinstallation direkt nach so einem Quit) ist nur theoretisch verletzt. P2, kein Blocker.

</details>

### LR-GPT-005 · GPT-Hauptkonto wird auch bei weiterhin lebenden alten Proxys ausgetauscht

*P2 · gpt-backend / datenintegritaet · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:662-675`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:677-681`, `WhisperM8/Services/AgentChats/GPTAccountProfiles.swift:462-485` (Stand `a8e0f35`)

**Fehlerbild:** Beim Promote reagiert main oder die Profilinstanz innerhalb der etwa drei Sekunden nicht auf SIGTERM. Nach Ablauf der Schleife wird isRunning nicht erneut als Abbruchbedingung geprüft: moveGrant tauscht trotzdem den Grant und entfernt das Profil. Ein alter lebender main-Prozess kann danach weiterhin mit seinem bisherigen Konto antworten oder einen alten Refresh-Grant zurückschreiben. Der anschließende ensureRunning kann ihn wegen erfolgreicher Health-Probe sogar wiederverwenden. Die angezeigte neue Kontoidentität stimmt dann nicht mit dem tatsächlich verwendeten Login überein.

**Fix:** Fix passt: nach der Schleife erneut isRunning prüfen, bei Timeout vor moveGrant mit einer klaren Fehlermeldung abbrechen (ggf. begrenzte SIGKILL-Eskalation nur für eigene Prozesse). Zu beachten: stopInstanceLocked/replaceSelfStartedProcess haben das Profil bereits aus der Registry entfernt, beim Abbruch sollte der Handle für spätere Bereinigung erhalten bleiben.

*Ursprünglicher Vorschlag:* Den Grant erst nach positiv nachgewiesenem Ende beider konkreten Prozesse austauschen. Bei Timeout vor jeder Dateimutation abbrechen und Handles zur weiteren kontrollierten Bereinigung behalten; gegebenenfalls begrenzte Eskalation für ausschließlich eigene Prozesse anbieten. Tests mit einem Handle ergänzen, der trotz terminate weiterlebt.

**Test zuerst:** ClaudeCodeProxyManagerTests: Fake-ProcessHandle, dessen terminate() isRunning nie auf false setzt; replaceMainGrant(withProfile:) mit moveGrant-Closure; erwartet Failure und moved == false. Heute wird moveGrant nach 30 Sleeps trotzdem ausgeführt.

<details><summary>Prüfurteil</summary>

Die Schleife in replaceMainGrant (ClaudeCodeProxyManager.swift:662-681) wartet höchstens retryAttempts*retryDelay (30*0.1 s = 3 s) und ruft danach unbedingt moveGrant, ohne isRunning erneut zu prüfen; das Finder-Szenario ist im Code korrekt beschrieben. Praktisch beendet sich ein Rust-Proxy auf SIGTERM in Millisekunden, hängende Prozesse sind eine seltene Ausnahme. Außerdem ist es Labs (GPT-Hauptkonto tauschen, Default aus) und ein Nutzer-ausgelöster, seltener Admin-Vorgang. Falls es eintritt, ist das Ergebnis eine Konto-Inkonsistenz, kein Verlust von Nutzerdaten.

</details>

### LR-KO-004 · Vorgemerkte Kontowechsel können zwischenzeitlich eingegebene Entwürfe verwerfen

*P2 · konten / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:175-215`, `WhisperM8/Services/AgentChats/AccountSwitchCoordinator.swift:224-245`, `WhisperM8/Services/AgentChats/AccountSwitchPlanner.swift:130-147` (Stand `a8e0f35`)

**Fehlerbild:** Zwei Chats haben Vormerkungen zu unterschiedlichen Zielkonten. Ein Timerlauf klassifiziert beide als idle und entnimmt beide aus pending. Während der erste Zielgruppenwechsel an waitForExit suspendiert, tippt der Nutzer einen neuen, ungesendeten Entwurf in den zweiten Chat oder startet dort einen Turn. Danach verarbeitet die Schleife dessen zuvor berechnete ready-Gruppe; switchRunning prüft weder Status noch Composer erneut und beendet den Prozess. Der Entwurf geht verloren beziehungsweise der neue Turn wird unerwartet abgebrochen.

**Fix:** Der Finder-Fix (Re-Check direkt vor terminate auf dem MainActor, bei Beschäftigung wieder vormerken) ist richtig, klein und unkritisch.

*Ursprünglicher Vorschlag:* Unmittelbar vor jedem terminate auf dem MainActor Status, Entwurf, Hintergrundaufgaben und Laufidentität neu prüfen. Neu beschäftigte Chats wieder vormerken statt stoppen. Das gemeinsame Journal-Batching und nachgewiesene Prozessende vor Dateibewegung erhalten. Einen Reentranztest mit zwei Zielgruppen und während des ersten waitForExit neu gesetztem Entwurf ergänzen.

**Test zuerst:** AccountSwitchCoordinatorTests: Zwei vorgemerkte Chats mit verschiedenen Zielkonten, beide idle. waitForExit des ersten Chats als Closure, die erst nach dem Setzen von mayHaveUnsentInput(chat2)=true zurückkehrt. recheckPending ausführen und erwarten, dass terminate für chat2 NICHT aufgerufen wird und chat2 wieder in pending steht (heute wird er beendet).

**Delta 76256ad:** Die Entwurf-Schaetzung wurde nur um das Restore-Flag erweitert; `mayHaveUnsentInput` und die fehlende Neupruefung vor terminate sind unveraendert. Untracked Eingaben (Rechtsklick-Paste, System-Diktat) bleiben fuer den Tracker unsichtbar (siehe Befund Composer-Clear).

<details><summary>Prüfurteil</summary>

Die Reentranz-Lücke ist im Code real: recheckPending sammelt ready je Zielkonto und entnimmt sie aus pending. Danach führt es switchRunning je Gruppe sequenziell aus, mit await waitForExit dazwischen. Status, Entwurf und Hintergrundaufgaben werden vor dem terminate der zweiten Gruppe nicht neu geprüft. Das Fenster öffnet sich aber nur, wenn gleichzeitig Vormerkungen zu zwei verschiedenen Zielkonten bestehen und beide im selben 2-s-Tick bereit werden, und der Nutzer in genau den Sekunden des ersten waitForExit im zweiten Chat tippt. Folge: der Prozess endet, der Chat wird per scheduleResume fortgesetzt, ein ungesendeter Composer-Entwurf (heuristisch erkannt) oder ein gerade begonnener Turn geht verloren. Das ist kein Transcript-Verlust. P2 statt P0, Erweitert-Feature, kein Nutzerweg W1-W7 verletzt.

</details>

### LR-KO-006 · Profil-Rename bricht profilgebundene Plugin-Registrierungen für alle Konten

*P2 · konten / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+SharedConfig.swift:82-111`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:449-463`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles+Promote.swift:81-84` (Stand `a8e0f35`)

**Fehlerbild:** Ein Plugin oder Marketplace wurde aus einem Profil installiert; die gemeinsame Registry unter main enthält daher einen installPath beziehungsweise installLocation durch ~/.claude-profiles/alt/. Das Umbenennen nach neu verschiebt alt vollständig, ohne den bei Remove und Promote vorhandenen Registry-Guard. Die registrierten alten Pfade verschwinden und das gemeinsam verwendete Plugin ist anschließend auch in main und anderen Konten nicht mehr ladbar.

**Fix:** Der Guard (Rename mit demselben Fehlertext wie Remove ablehnen) ist trivial und sicher. Ein eigener Registry-Umzug wäre riskant, weil die Registry Claudes Datei ist und die Claude-CLI sie nicht dafür vorsieht.

*Ursprünglicher Vorschlag:* Den vorhandenen pluginRegistryReferences-Guard auch vor Rename anwenden oder einen über die echte CLI kontrollierten Registry-Umzug implementieren. Gemeinsame Plugins, eigene abweichende Profilkonfigurationen und Login-Erhalt müssen unverändert funktionieren.

**Test zuerst:** ClaudeSharedConfigTests/ClaudeAccountProfilesTests: main/plugins/installed_plugins.json mit installPath unter <profiles>/alt/ anlegen; renameProfile(from:alt,to:neu) muss einen Fehler mit pluginsRegisteredViaProfile werfen und alt unverändert lassen (heute wird umbenannt).

<details><summary>Prüfurteil</summary>

renameProfile (ClaudeAccountProfiles.swift:449-478) hat keinen pluginRegistryReferences-Guard, während Promote ihn bei Zeile 81-84 und Remove ihn haben. Wird ein Profil umbenannt, dessen Ordner in installed_plugins.json/known_marketplaces.json als installPath steht (Claude schreibt den Pfad der installierenden Session), zeigen diese Einträge ins Leere. Die Plugins sind dann in main und allen Konten nicht ladbar, bis sie neu installiert werden. Das ist ein echter Fehler mit stillem Ausfall, aber ohne Datenverlust, behebbar per Neuinstallation und nur nach einer seltenen Umbenennung. Die Vorbedingung 'Plugin aus Zusatzprofil heraus installiert' ist plausibel. Daher P2 statt P1.

</details>

### LR-KO-007 · Ein Keychain-Lesefehler wird beim Rename als fehlender Login behandelt

*P2 · konten / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:457-477`, `Tests/WhisperM8Tests/ClaudeAccountProfilesTests.swift:394-406` (Stand `a8e0f35`)

**Fehlerbild:** Das Profil besitzt einen Login, aber der Schlüsselbund ist gesperrt oder der Nutzer verweigert den Lesezugriff. security liefert einen Fehlerstatus. renameProfile unterscheidet diesen Zustand nicht von ItemNotFound, verschiebt den Profilordner trotzdem und meldet Erfolg. Wegen des pfadabhängigen Keychain-Service-Namens findet der umbenannte Account den weiterhin unter dem alten Namen vorhandenen Login nicht mehr.

**Fix:** Fix korrekt: nur Status 44 (errSecItemNotFound) als loginlos werten, alles andere vor dem moveItem abbrechen. Exit-Codes von `security` sind nicht die OSStatus-Rohwerte (44 für not found); die Finder-Idee 'Security.framework statt CLI' ist optional und nicht nötig.

*Ursprünglicher Vorschlag:* Nur einen eindeutig nachgewiesenen ItemNotFound-Status als loginlos akzeptieren. Bei Zugriffs-, Interaktions- und sonstigen Lesefehlern vor jeder Dateibewegung abbrechen. Mit Security.framework die tatsächlichen OSStatus-Werte erhalten; Tests für verweigerten Zugriff und gesperrten Schlüsselbund ergänzen.

**Test zuerst:** ClaudeAccountProfilesTests: securityRunner liefert für find-generic-password (36 bzw. 128/51, 'user canceled') -> renameProfile muss werfen und configDir(alt) bleibt bestehen, neu existiert nicht. Heute: Rename gelingt, Ordner verschoben.

<details><summary>Prüfurteil</summary>

renameProfile behandelt jeden Nicht-0-Status von `security find-generic-password` als 'kein Login' (ClaudeAccountProfiles.swift:457-477), der Test testRenameProfileWithoutLoginSkipsKeychainOps (Status 44) zementiert nur den echten ItemNotFound-Fall. Bei verweigertem ACL-Zugriff/gesperrtem Schlüsselbund wird der Ordner trotzdem umbenannt, der pfadabhängige Keychain-Service passt dann nicht mehr und der Login wirkt weg. Es ist aber kein Datenverlust: das Item bleibt unter dem alten Service-Namen erhalten, Zurück-Umbenennen oder neuer Login behebt es; Auslöser ist ein selten verweigerter Prompt.

</details>

### LR-KO-009 · Teilweise fehlgeschlagenes Rückgängig löscht auch die noch offenen Journal-Einträge

*P2 · konten / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AccountMoveService.swift:137-157`, `WhisperM8/Services/AgentChats/AccountMoveService.swift:165-169`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:558-561` (Stand `a8e0f35`)

**Fehlerbild:** Ein Batch hat Chats aus zwei Herkunftsprofilen nach C verschoben. Vor Undo ist eines der Herkunftsprofile vorübergehend entfernt oder sein Ziel nicht beschreibbar. Ein Chat wird erfolgreich zurückbewegt, der andere scheitert. Weil outcome.moved nicht leer ist, entfernt clearLastBatch sämtliche Einträge außer aktuell laufenden Chats. Der fehlgeschlagene Chat verliert damit seine Undo-Information; nach Behebung des Hindernisses kann Rückgängig ihn nicht mehr zurückholen.

**Fix:** Fix passt: keeping = runningIDs plus Session-IDs aus outcome.failed plus nicht auflösbare (cwd nil); Pendelschleife bleibt vermieden, da recordInJournal false.

*Ursprünglicher Vorschlag:* Nur erfolgreich zurückgenommene Entry-/Session-IDs aus dem Batch entfernen. Fehlgeschlagene, laufende und nicht auflösbare Einträge mit ihrer Herkunft erhalten und getrennt melden. Best-effort-Teilerfolge und Vermeidung einer Undo-Pendelschleife beibehalten.

**Test zuerst:** AccountMoveServiceTests: Batch mit zwei Einträgen (A->C, B->C), Herkunftsprofil von B fehlt (targetProfileMissing); undoLastBatch -> moved=[A], failed=[B]; danach journal.lastBatch() muss B noch enthalten. Heute leer.

<details><summary>Prüfurteil</summary>

undoLastBatch löscht bei outcome.moved nicht leer den ganzen Batch bis auf laufende Chats (AccountMoveService.swift:137-169); fehlgeschlagene und wegen cwdResolver==nil verworfene Einträge verlieren ihre Undo-Information. Das ist ein echter Logikfehler, aber die Auswirkung ist klein: nur Teilerfolg-Undo mit einem zweiten Fehler, die Chats selbst bleiben intakt und lassen sich manuell über das Kontextmenü 'Zu Account verschieben' zurückbewegen. Kein Datenverlust, Zusatzfunktion.

</details>

### LR-AK-012 · Retention löscht Sessions anhand eines nach await veralteten Schutz-Snapshots

*P3 · agent-kern / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/SubagentJobRetention.swift:55-66`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:251-267`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:284-288`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:530-537` (Stand `a8e0f35`)

**Fehlerbild:** Ein alter verwaister Subagent-Spiegel ist bei der Kandidatenauswahl weder offen noch laufend. Während die Archivierung auf dem Utility-Task wartet oder andere Kandidaten bearbeitet, öffnet beziehungsweise resumed der Nutzer genau diesen Chat. Nach await löscht runRetentionIfDue trotzdem alle ursprünglich ermittelten IDs, ohne Tabs, Laufstatus oder Änderungen erneut zu prüfen. Auch die Archivierung verwendet den alten Satz. Ein inzwischen genutzter Verlauf kann dadurch aus dem Codex-Root verschoben und sein sichtbarer Workspace-Eintrag entfernt werden.

**Fix:** Billiger Fix: nach dem await die Kandidaten gegen aktuelle protectedSessionIDs/Sessionstatus erneut filtern, kein Claim-System nötig.

*Ursprünglicher Vorschlag:* Retention pro Session mit einem abbrechbaren Claim beziehungsweise einer Generation koordinieren. Öffnen/Resume muss einen noch nicht abgeschlossenen Claim aufheben; vor Datei-Bewegung und Lösch-Commit aktuelle Berechtigung prüfen. Löschung außerdem an das individuelle Archivierungsergebnis koppeln. Datei-I/O weiterhin außerhalb des Workspace-Locks ausführen; keine aktive oder gerade geschützte Session entfernen.

**Test zuerst:** Optional: AgentJobWorkspaceSync-Test mit Archiver-Spy, der während archive() die Session in protectedSessionIDs aufnimmt; deleteSessions darf diese ID nicht entfernen. Heute entfernt.

<details><summary>Prüfurteil</summary>

Technisch stimmt es: die Kandidatenliste und protectedSessionIDs werden vor dem await berechnet, nach dem Archivieren löscht deleteSessions alle ursprünglichen IDs ohne erneute Prüfung. Betroffen wären nur Subagent-Spiegel, deren Job-Verzeichnis weg ist und die >7 Tage inaktiv sind; der Nutzer müsste genau diesen Chat im Zeitfenster der Archivierung (Millisekunden bis wenige Sekunden, Intervall-gesteuert) öffnen. Das Transcript wird verschoben, nicht gelöscht (Archiv in Application Support), der Eintrag ist zudem ohne lebendes Job-Verzeichnis ohnehin Karteileiche. Praktisch irrelevant für den Launch.

</details>

### LR-AK-031 · Job-State-Korrektur und PID-Nachtrag überschreiben neuere Zustände

*P3 · agent-kern / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentJobStore.swift:164-181`, `WhisperM8/Services/AgentChats/AgentJobStore.swift:285-305`, `WhisperM8/Views/SubagentJobDetailView.swift:491-496`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:77-87` (Stand `a8e0f35`)

**Fehlerbild:** Die App liest einen aktiven Job. Bevor sie den alten Snapshot als verwaist zurückschreibt, beendet der Supervisor ihn und persistiert done; die Korrektur ersetzt den fertigen Zustand durch failed. Beim Follow-up kann entsprechend der ungesperrte PID-Nachtrag einen zuvor gelesenen spawning-Snapshot über den inzwischen unter Lock geschriebenen running-Zustand legen.

**Fix:** Alle Änderungen an state.json einschließlich Korrektur, Transition und PID-Publikation in dieselbe prozessübergreifende Transaktion aufnehmen. Innerhalb des Locks neu lesen und erwartete Generation/Zustand prüfen. Bestehenden atomaren Dateiersatz und genau-einmal-Prompt-Claim erhalten; keine rekursiven flock-Aufrufe einführen.

**Test zuerst:** AgentJobStoreTests mit injiziertem livenessProbe: Zustand running mit toter PID anlegen. Die Probe-Closure schreibt als Nebeneffekt 'done' in state.json, danach ruft der Test readCorrected auf. Erwartet: Der Zustand bleibt done, weil die Korrektur unter Lock neu liest. Heute wird er zu failed überschrieben.

**Zusammengeführt mit:** LR-AK-024, LR-AU-001

<details><summary>Prüfurteil</summary>

Beide Lücken existieren. correctIfOrphaned schreibt per writeState ohne Re-Read oder Lock ein 'failed' zurück (AgentJobStore:285-305), und der PID-Nachtrag in SubagentJobDetailView:491-496 läuft per mutateState außerhalb von withExclusiveLock. Die Zeitfenster sind aber sehr klein. Beim Korrekturpfad liegen nur readState, Liveness-Probe und Write dazwischen, der Supervisor müsste exakt dort 'done' schreiben und exiten. Beim PID-Nachtrag gewinnt normalerweise der Parent, weil der Kindprozess zuerst exec'en, Codex auflösen und den Lock nehmen muss. Folge wäre ein falsch angezeigter Jobstatus, kein Verlust von Daten oder des Reports. Subagent-Jobs sind 'Erweitert' (F-AC-12). P1 ist überhöht.

</details>

### LR-AU-020 · Etwa 1.400 Zeilen Layout-Paket (WorkspaceLayout, LayoutEngine, WorkspaceLayoutView) sind nirgends eingebunden, ihre Ableitung läuft aber bei jedem Laden und wird mitpersistiert

*P3 · agent-ui / architektur · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Views/Workspace/WorkspaceLayoutView.swift (keine Instanziierung im Produktivcode)`, `WhisperM8/Services/AgentChats/Layout/* (nur von Tests und WorkspaceLayoutView genutzt)`, `WhisperM8/Models/AgentUIState.swift:302 und :386 (WorkspaceLayoutMigration.migrate bei jedem Load)`, `WhisperM8/Services/AgentChats/Layout/WorkspaceLayoutMigration.swift:156-163 (slotIndex bildet Kapazität 5/7/8 anders ab als AgentGridAutoLayout.cell, abgeleitetes Layout stimmt für diese Stufen nicht mit dem echten Grid überein)` (Stand `76256ad`)

**Fehlerbild:** Das Paket erzeugt keine sichtbare Wirkung, ändert aber das Persistenzformat und das Fehlerrisiko des UI-States (siehe Befund zum strengen Decode). Wer später S6 auf dieses Modell stützt, übernimmt für 5/7/8er-Workspaces eine falsche Anordnung, weil die Migration die Spezialzeilen (3+2, 3+3+1, 3+3+2) nicht kennt.

**Fix:** Bis S6 entweder das Persistieren von `layouts` abschalten oder die Migration um die Spezialzeilen aus AgentGridAutoLayout.cell(forSlot:) ergänzen. Feature-Erhalt: keine Löschung ohne Entscheidung zum Workspace-Umbau.

**Test zuerst:** WorkspaceLayoutMigrationTests um Kapazität 5, 7 und 8 erweitern (Geometrie gegen AgentGridSplitContainer.blocks vergleichen).

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-CLI-010 · `chats wait` pollt doppelt, probt jede Session zweimal beim Start und beobachtet bei leerem Scope alle Chats der letzten 14 Tage

*P3 · cli-control / performance · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/CLI/ChatsWaitEngine.swift:121-122`, `WhisperM8/CLI/ChatsWaitEngine.swift:74-95`, `WhisperM8/CLI/ChatsWaitEngine.swift:364-370` (Stand `76256ad`)

**Fehlerbild:** Im Timer-Handler steht `reevaluateAll` zweimal hintereinander (Copy-Paste), jeder 10-s-Takt probt alle Sessions doppelt. Die initiale Aufnahme und die Watch-Armierung rufen ChatsStatusProbe.probe je Session zweimal. Ohne --ref nimmt der Befehl scopedEntries(all:false), also alle nicht archivierten Chats der letzten 14 Tage (bei grossem Workspace hunderte). Jeder Probe liest einen 64-KB-Tail. Dazu kommt ein Dauerlauf bis 30 min. Die Schleifen schreiben ausserdem watchedPaths und watchers aus dem Hauptthread, waehrend die Handler auf der Queue schon feuern (kleiner Data Race).

**Fix:** Doppelten Aufruf entfernen, die Probe-Ergebnisse der Startphase wiederverwenden, Watch-Armierung auf der Queue ausfuehren. Ohne --ref nur Sessions mit Status working/awaitingInput oder offenem Tab beobachten.

**Test zuerst:** Engine mit injiziertem Probe-Zaehler und 10 Fake-Sessions: ein Poll-Tick erzeugt genau 10 Probe-Aufrufe, nicht 20.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-GPT-006 · Waisen-Schutz beendet auch bewusst extern gestartete Hintergrund-Proxys

*P3 · gpt-backend / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift:55-68`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyOrphanGuard.swift:88-103`, `WhisperM8/WhisperM8App.swift:359-370`, `Tests/WhisperM8Tests/ClaudeCodeProxyOrphanGuardTests.swift:13-17` (Stand `a8e0f35`)

**Fehlerbild:** Ein Nutzer betreibt den Proxy auf dem konfigurierten Port absichtlich per launchd oder nach dem Ende seiner startenden Shell. Der Prozess hat dann PPID 1, obwohl WhisperM8 ihn nie gestartet hat. Liegt sein Binary an einem anderen Pfad als das aktuell aufgelöste Binary, klassifiziert replaceReason ihn allein deshalb als eigene veraltete Waise und sendet beim App-Start SIGTERM. Externe laufende Anfragen werden dadurch abgebrochen. Der dokumentierte Schutz fremder Instanzen wird durch die PPID-Heuristik nicht erfüllt.

**Fix:** Persistierte Ownership (PID+Startzeit) ist für ein Labs-Randthema überdimensioniert. Eine einfache Variante: Waise nur beenden, wenn das Binary im verwalteten bin-Ordner oder an einem früher von WhisperM8 aufgelösten Pfad liegt, und sonst nur Warnung/Konfliktmeldung.

*Ursprünglicher Vorschlag:* Eigene Prozesse mit persistierter Ownership aus PID, Startzeit, Benutzer, Profil und Binary-Identität kennzeichnen. Nur solche nachweislich selbst gestarteten Überreste automatisch ersetzen. Andere Listener weder allein aufgrund ihres Dateinamens noch wegen PPID 1 beenden; stattdessen eine Konfliktmeldung anbieten. Den beabsichtigten Update- und Transkriptionsrouten-Guard für eigene Waisen erhalten.

**Test zuerst:** ClaudeCodeProxyOrphanGuardTests: Listener mit PPID 1 und Pfad /opt/homebrew/bin/claude-code-proxy, resolved = verwaltetes Binary; erwarten, dass shouldReplace false liefert, sobald die Ownership-Prüfung 'nicht von uns gestartet' meldet (heute true). Ändert damit auch den bestehenden Test testReplacesOrphanRunningADifferentBinary.

<details><summary>Prüfurteil</summary>

Das beschriebene Verhalten ist beabsichtigt und getestet: testReplacesOrphanRunningADifferentBinary erwartet ausdrücklich das Beenden einer Waise (PPID 1) mit anderem Binary-Pfad, weil genau das der Befund vom 23.09.2026 war (make kill hinterließ veralteten Proxy). Betroffen ist nur, wer einen eigenen claude-code-proxy per launchd oder nohup auf exakt dem von WhisperM8 konfigurierten Port laufen lässt, und das bei aktiviertem GPT-Backend. Das ist ein Labs-Randfall, und der User hat sich mit der gleichen Port-Konfiguration ohnehin für WhisperM8s Verwaltung entschieden. Die PPID-1-Heuristik kann tatsächlich nicht zwischen 'meine Waise' und 'launchd-Dienst' unterscheiden, daher teilbestätigt, aber nur als P3-Härtung.

</details>
