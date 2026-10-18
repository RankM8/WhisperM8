---
status: beschlossen
updated: 2026-10-18
description: Welle W4b des Launch-Readiness-Plans — Agent Chats: Status und Zustellung. Befunde, Abnahmekriterien, Tests zuerst.
---

# W4b · Agent Chats: Status und Zustellung

Der Status stimmt für Claude und Codex, und Prompts kommen genau einmal und vollständig an: Codex-Rollouts werden verstanden, der Registry-Weg hat ein Versions-Gate, delegierte Arbeit blockiert die Zustellung nicht, getippte Entwürfe werden nie mitgeschickt.

**Umfang:** 16 Befunde · P1 1, P2 10, P3 5 · 1 Launch-Blocker · Aufwand S×9, M×7

## Abnahmekriterien der Welle

- [ ] Codex-Status aus echten Rollout-Fixtures korrekt (der Test mit erfundenem Format ist ersetzt, Testmatrix Schwäche 5).
- [ ] Ältere Claude-Versionen ohne Registry-Eintrag bekommen automatisch den vollen Hook-Satz (Gate per Version oder fehlendem Eintrag).
- [ ] `chats send`/Queue: kein Anhängen an einen getippten Entwurf, keine Zustellung während `launching`, keine Fertig-Meldung nach echtem Turn-Ende innerhalb der 10-s-Marke verschluckt.
- [ ] Nach `/clear` beobachtet der Watcher das neue Transcript; Warte-Art stimmt.
- [ ] Send-Guard ist fail-open bei Token-I/O-Fehlern und konsumiert ein Token genau einmal.

## Lückenschluss zu Beginn (Kritiker Delta-Lauf)

- Chat-CLI-Nebenbefehle (archive, unarchive, snapshot, tail, anomaly, move-account): Exit-Codes gegen den Skill-Text abgleichen.

## Feature-Erhalt

Vor dem ersten Commit die Invarianten lesen und je Fix prüfen, welche berührt sind: [oracle/agent-laufzeit.md](../../00-scope/oracle/agent-laufzeit.md). Dazu die Zeilen der [Testmatrix](../anforderungs-testmatrix.md) für diese Features.

## Befunde

| ID | Schwere | Blocker | Aufwand | Risiko | Status | Titel |
|---|---|---|---|---|---|---|
| LR-AK-006 | P1 | ja | M | mittel | geplant · bestätigt | Der Codex-Statusparser versteht das verwendete Rollout-Format nicht |
| LR-AK-011 | P2 | — | M | mittel | geplant · teilbestätigt | resumeScans umgeht Single-Flight und kann Account-Stempel zurücksetzen |
| LR-AK-019 | P2 | — | S | mittel | geplant · bestätigt | [A3-04] Nach externer ID-Umbindung beobachtet der Watcher weiterhin das alte Transcript |
| LR-AK-021 | P2 | — | M | mittel | geplant · teilbestätigt | [A3-06] Bereits gestarteter Chat ohne Bindung wird still als neuer Chat gestartet |
| LR-AK-026 | P2 | — | S | mittel | geplant · teilbestätigt | [A3-12] Send-Guard blockiert Erstzustellungen bei Token-I/O-Fehlern |
| LR-AK-034 | P2 | — | S | mittel | geplant · unverifiziert | Abbruch-Merker (10 s) verschluckt ein echtes Turn-Ende und strandet vorgemerkte Folgeauftraege |
| LR-AK-035 | P2 | — | M | mittel | geplant · unverifiziert | Reduzierter Hook-Satz ohne Versions- oder Registry-Gate: aeltere Claude-Versionen verlieren Status, Permission-Erkennung und ID-Nachbindung |
| LR-AK-037 | P2 | — | M | mittel | geplant · unverifiziert | Registry-`busy` umfasst delegierte Arbeit: Send, Queue, Fertig-Meldung und `wait --until idle` haengen an Subagents und Hintergrund-Tasks |
| LR-CLI-002 | P2 | — | S | niedrig | geplant · unverifiziert | send und Queue-Zustellung haengen den Agent-Prompt an einen vom User getippten Entwurf und schicken beides ab |
| LR-CLI-003 | P2 | — | S | niedrig | geplant · unverifiziert | `chats enqueue` stellt bei launching sofort zu und umgeht den Readiness-Guard, den die Fehlermeldung als Ausweg empfiehlt |
| LR-CLI-008 | P2 | — | M | mittel | geplant · unverifiziert | Handler-Timeout 10 s passt nicht zu move-account: Antwort `Zustand unklar` waehrend der Umzug weiterlaeuft |
| LR-AK-016 | P3 | — | S | niedrig | geplant · teilbestätigt | Dauernde externe Transcript-Writes können die Erkennung endlos verschieben |
| LR-AK-020 | P3 | — | M | mittel | geplant · teilbestätigt | [A3-05] Ignorierte Background-Forks verändern trotzdem den Vordergrundstatus |
| LR-AK-027 | P3 | — | S | mittel | geplant · teilbestätigt | [A3-13] Zustell-Token kann mehrfach erfolgreich konsumiert werden |
| LR-AK-036 | P3 | — | S | niedrig | geplant · unverifiziert | Warte-Art aus Registry: veraltetes letztes Tool und vorlaeufige Art in der Benachrichtigung |
| LR-AK-038 | P3 | — | S | niedrig | geplant · unverifiziert | Registry-FSEvents werden per exaktem Pfad-String den Profilen zugeordnet; Symlink-Config-Dirs liefern keine Live-Updates |

### LR-AK-006 · Der Codex-Statusparser versteht das verwendete Rollout-Format nicht

*P1 · Launch-Blocker · agent-kern / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:112-153`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:285-292`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:461-471`, `Tests/WhisperM8Tests/AgentTestSupport.swift:43-61` (Stand `a8e0f35`)

**Fehlerbild:** Ein Codex-Chat schreibt `event_msg` mit payload.type `task_complete`, wie die echte Repo-Fixture. parseCodexLine erwartet stattdessen type `event` und subtype `turn.completed`; die echte Abschlusszeile wird .other. Die App zeigt noch bis zum 30-Sekunden-Heuristikwechsel working und meldet niemals turnFinished für diesen Turn. Bei einem langen stillen Tool-Lauf werden dieselben realen Events ebenfalls nur als .other behandelt und nach 30 Sekunden fälschlich idle. Turn-Ende-abhängige Titel und Benachrichtigungen bleiben aus.

**Fix:** Alte Formate als Kompatibilität behalten ist ok; wichtig: token_count und turn_context als .meta behandeln, nicht als Aktivität, sonst bleibt 'working' nach task_complete hängen.

*Ursprünglicher Vorschlag:* Die tatsächlichen event_msg-/response_item-Payloads abbilden, insbesondere task_started, task_complete und Abbrüche; token_count als statusneutrale Metadaten überspringen. Dieselben realen Rollout-Fixtures für Reader und Statusparser verwenden; alte Formate als Kompatibilität erhalten.

**Test zuerst:** AgentTranscriptStatusTests: parseLine(CodexRolloutFixtures.taskComplete, .codex) == .assistantMessageStopped; taskStarted/userMessage(event_msg) -> .userMessage bzw. working; tokenCount -> .meta. Danach decide(lastEvent: ...) liefert .idle + turnFinished. Heute .other.

<details><summary>Prüfurteil</summary>

parseCodexLine kennt nur die Formate type=event/subtype=turn.completed und type=item; die echten Rollouts (CodexRolloutFixtures) liefern type=event_msg/response_item/session_meta mit payload.type=task_complete usw. Jede echte Codex-Zeile landet bei .other. Der Status eines Codex-Chats fällt auf die reine mtime-Heuristik zurück (working bis 30 s nach dem letzten Write, danach idle, auch bei langem stillem Tool-Lauf), und turnFinished kommt nie, weshalb auch Fertig-Notification, Stop-Sound und die turn-end-getriebene Titelübernahme für Codex ausbleiben (Codex hat keine Hooks als Gegenpol). Es ist ein degradierter, kein totaler Ausfall, daher P1; Codex gehört zu F-AC-02/06 (Kern), W4 nennt allerdings Claude.

</details>

### LR-AK-011 · resumeScans umgeht Single-Flight und kann Account-Stempel zurücksetzen

*P2 · agent-kern / race · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:90-108`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:120-128`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:159-198`, `WhisperM8/Services/AgentChats/AccountMoveService.swift:66-67` (Stand `a8e0f35`)

**Fehlerbild:** Scan A läuft bereits und hat einen alten Transcript-Root erfasst. Ein Kontoumzug suspendiert neue Scans, bewegt das Transcript und setzt den neuen Profilstempel. resumeScans ruft anschließend direkt startScan auf, obwohl A noch inFlight ist. Damit läuft B parallel. Committen B und danach der alte Snapshot A, schreibt A den alten Account-Stempel wieder in den Workspace; ein Resume kann nun im falschen Config-Dir suchen. Beide Scans schreiben außerdem unabhängig denselben Index-Cache.

**Fix:** resumeScans über requestScan-Pfad (ohne Cooldown) führen ist einfach; Scan-Generation zum Verwerfen alter Snapshots ist größer als nötig.

*Ursprünglicher Vorschlag:* Auch den Resume-Pfad über eine Single-Flight-Zustandsmaschine führen. Kontoumzüge erhöhen eine Scan-Generation; Resultate früherer Generationen vor dem Merge verwerfen. Einen frischen Folge-Scan nach Abschluss sicher nachholen, ohne den Account-Move-Cooldown anzuwenden. Invariante: höchstens ein gültiger Scan-Commit und kein Stempel-Rollback durch alte Snapshots.

**Test zuerst:** AgentScanCoordinator-Test mit injizierbarem Scan-Runner: requestScan(.launch) hält Scan A offen, dann suspend/resume; erwartet genau einen laufenden Scan und danach einen Nachholscan. Heute starten zwei parallel.

<details><summary>Prüfurteil</summary>

Der Code stimmt: resumeScans ruft startScan direkt auf, auch bei inFlight=true; danach setzt der ältere Scan inFlight=false, während der neue noch läuft, und beide mergen/speichern den Index-Cache. Für den Stempel-Rollback muss Scan A (früher gestartet, alte Roots) NACH Scan B committen, was bei gleichem Arbeitsumfang unwahrscheinlich ist; zudem ist die Stempel-Selbstheilung im Merge selbst die Korrektur, und der nächste Foreground-/FS-Scan stellt den Stempel nach spätestens ~30 s wieder her. Betrifft nur Kontoumzug (Erweitert) im Fenster eines laufenden Scans; kein Datenverlust, das Transcript liegt an der richtigen Stelle.

</details>

### LR-AK-019 · [A3-04] Nach externer ID-Umbindung beobachtet der Watcher weiterhin das alte Transcript

*P2 · agent-kern / korrektheit · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:141-170`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:186-198`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:649-663`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:780-798` (Stand `a8e0f35`)

**Fehlerbild:** Eine laufende Session hat bereits eine aufgelöste Transcript-URL. Nach /clear oder /resume bindet der Koordinator eine neue externe ID und ruft attachWatch auf. watch ändert zwar externalSessionID, behält aber die vorhandene URL und ihre Caches. Status-Fallback, Aktivitätszeile, Abort-mtime und Turn-Ende-Erkennung lesen weiter die alte Datei.

**Fix:** Fix ist klein und passt: in watch() bei geänderter externalSessionID die Rebind-Logik von setExternalSessionID nutzen (URL neu auflösen, lastStat/cachedLastEvent/cachedActivity nullen, Event-Source neu anhängen, generation erhöhen).

*Ursprünglicher Vorschlag:* Bei Änderungen von externer ID, cwd oder Provider URL, Stat-/Event-/Activity-Caches und Event-Source invalidieren. Den bereits vorhandenen expliziten Rebind-Pfad verwenden oder dessen Verhalten in watch vereinheitlichen; Generation-Guard und stat-first erhalten.

**Test zuerst:** AgentSessionRuntimeWatcherTests mit injiziertem urlResolver/statProvider: watch(local, extID A) -> URL A aufgelöst; erneut watch(local, extID B) mit Resolver, der für B eine andere URL liefert; erwartet: Watcher-Eintrag zeigt URL B und gelöschte Caches. Heute bleibt URL A.

**Delta 76256ad:** Der Mechanismus besteht weiter: Der Watcher behaelt nach /clear das alte Transcript. Die Folge hat sich verschoben. Registry-live Sessions beziehen den Status nicht mehr aus dem Transcript, das stille 180-s-Netz ist dort aus. Dafuer liest jetzt `registryAwaitingKind` das Detail aus dem veralteten Tail der alten Datei. Nach /clear kann damit die Warte-Art falsch sein (siehe Befund Warte-Art). Weiter relevant bleiben Stand-Zeile und Turn-Ende-Bookkeeping fuer den Auto-Namer. Die Zeilenangaben des Registers sind verschoben.

<details><summary>Prüfurteil</summary>

Der Mechanismus ist real: watch() behält bei vorhandener transcriptURL die alte URL und ruft bei geänderter externer ID weder Cache-Reset noch Event-Source-Rebind auf; der saubere Pfad setExternalSessionID im Watcher hat keinen Aufrufer (nur Definition). Der Coordinator ruft nach /clear bzw. /resume-Rebind attachWatch -> watch. Folge: Fallback-Status, Aktivitätszeile, Abort-mtime und Heilung lesen die alte Datei. Die primäre Statusquelle sind aber Hooks (hook-live), das Transcript ist Fallback; relevant wird es vor allem beim stillen Netz (Decider-idle der alten Datei + working + >180 s ohne Hook-Event -> falsches turnAborted bei langem stillen Tool-Lauf) und bei veralteter Stand-Zeile. Das ist eine echte Korrektheitslücke nach /clear, aber ein Sekundärpfad ohne Datenverlust; P2 statt P1, kein Launch-Blocker.

</details>

### LR-AK-021 · [A3-06] Bereits gestarteter Chat ohne Bindung wird still als neuer Chat gestartet

*P2 · agent-kern / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:561-578`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:704-715`, `WhisperM8/Views/AgentSessionDetailView.swift:540-545`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:751-756` (Stand `a8e0f35`)

**Fehlerbild:** Nach einem Launch mit ausgefallener Hook-Bindung ist hasLaunchedInitialPrompt true, externalSessionID aber nil. Sowohl der vorgelagerte Repair als auch der Builder lassen diesen Zustand passieren. Der nächste Start enthält kein --resume und keinen initialen Prompt: Im bisherigen Chat-Tab erscheint eine neue leere Unterhaltung statt einer erklärten Wiederaufnahme-Störung.

**Fix:** Der vorgeschlagene harte Abbruch bei hasLaunched && ID nil ist riskant: er bricht den Normalfall 'Chat geöffnet, nie benutzt' und würde dort ständig Fehlermeldungen erzeugen. Nur abbrechen/warnen, wenn nachweislich ein Transcript zum Chat existiert (z. B. Event-File/Indexer-Treffer im ±Fenster) und die Bindung fehlt.

*Ursprünglicher Vorschlag:* Für bereits gestartete normale Claude-Chats ohne ID zuerst eine eindeutige Bindungsreparatur versuchen und andernfalls mit einer handlungsorientierten Meldung abbrechen. Einen Neustart nur ausdrücklich anbieten; frische Chats und echte Forks unverändert unterstützen.

**Test zuerst:** AgentCommandBuilderTests: Session mit hasLaunchedInitialPrompt=true, externalSessionID=nil, aber vorhandenem Hook-Event-File mit SessionStart-ID und Transcript: Erwartung Binding-Reparatur bzw. --resume statt Frischstart; Gegentest ohne jedes Transcript bleibt Frischstart.

<details><summary>Prüfurteil</summary>

Der Zustand hasLaunchedInitialPrompt=true bei externalSessionID=nil führt tatsächlich ohne --resume zu einem frischen Start (Builder und Repair lassen ihn durch). Er ist aber auch der legitime Normalfall für einen Chat, der gestartet, aber nie beschrieben wurde: Claude legt vor dem ersten Prompt kein Transcript an, es gibt nichts zum Fortsetzen. Der vom Finder geforderte Abbruch würde diese Fälle fälschlich blockieren. Für den echten Fehlerfall (Hook-Bindung fällt aus) existiert zusätzlich der Indexer-basierte Fallback bindExternalSessionIDWhenAvailable sowie ClaudeExternalIDRecovery; ein Verlust erfordert, dass beides versagt. Damit selten, ohne harten Datenverlust (Transcript bleibt auf Disk), kein Nutzerweg verletzt.

</details>

### LR-AK-026 · [A3-12] Send-Guard blockiert Erstzustellungen bei Token-I/O-Fehlern

*P2 · agent-kern / robustheit · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:82-98`, `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:104-119`, `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:178-192`, `WhisperM8/CLI/ChatsPromptGuardCommand.swift:46-66` (Stand `a8e0f35`)

**Fehlerbild:** Der Send-Token kann wegen voller Platte oder defekter Verzeichnisrechte nicht geschrieben beziehungsweise gelesen werden. stage verschluckt den Fehler und der Prompt wird trotzdem eingefügt. consume liefert bei I/O-Fehler dasselbe false wie bei einer echten Wiedervorlage. Der Hook blockiert deshalb die erste legitime Zustellung mit Exit 2 statt wie dokumentiert fail-open zu reagieren.

**Fix:** Dreistufiges Token-Lookup ist korrekt; bei I/O-Fehler fail-open wiegt aber gegen das Ziel des Guards (Doppel-Ausführung verhindern). Besser: stage-Fehler an Sender zurückgeben und Zustellung melden statt blind fail-open.

*Ursprünglicher Vorschlag:* Token-Lookup mindestens dreistufig modellieren: vorhanden, sicher nicht vorhanden, I/O-Fehler. Bei nicht verlässlich prüfbarem Zustand die vorgesehene fail-open-Politik anwenden oder die Zustellung vorher explizit als fehlgeschlagen melden; niemals Erstzustellung als Duplikat ausgeben.

**Test zuerst:** SendDeliveryTokenStoreTests: Store mit nicht lesbarem Token-Verzeichnis (chmod 000) -> consume muss einen unterscheidbaren I/O-Fehlerzustand liefern; ChatsPromptGuard.decide mit consumeToken-Fehler darf Erstzustellung nicht als Duplikat blocken (Verdict .allow).

<details><summary>Prüfurteil</summary>

Der Code verhält sich wie beschrieben: stage loggt Fehler nur, consume liefert bei Verzeichnis-/Lesefehler false, ChatsPromptGuard.decide blockt dann einen Marker-Prompt mit Exit 2. Auslöser sind jedoch volle Platte oder defekte Verzeichnisrechte im Application-Support-Pfad, also ein Zustand, in dem die App ohnehin an vielen Stellen scheitert. Der Block ist harmlos behebbar (Hinweistext nennt 'chats send' erneut) und betrifft nur Prompts mit [via whisperm8 chats]-Marker (Jarvis/CLI-Send, Erweitert), nie normale Eingaben. Die kommentierte Designentscheidung 'Guard failt Richtung Block' ist beabsichtigt; der Widerspruch zur fail-open-Doku ist ein Dokumentations-/Randfall-Thema.

</details>

### LR-AK-034 · Abbruch-Merker (10 s) verschluckt ein echtes Turn-Ende und strandet vorgemerkte Folgeauftraege

*P2 · agent-kern / korrektheit · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:545-548`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:689-692`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:673-676`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:323-327` (Stand `76256ad`)

**Fehlerbild:** Der Merker entsteht allein aus einem ESC im Terminal oder aus `chats interrupt`, solange der Status noch `working` zeigt. Er wird nicht gegen das Transcript geprueft. Der User drueckt ESC kurz vor oder waehrend Claude fertig wird; der Registry-Wechsel kommt nach FSEvents-Latenz erst danach. Oder Jarvis unterbricht einen Chat, dessen Turn gerade endete. Oder ESC wirkt nicht, etwa waehrend nur delegierte Arbeit laeuft. Das folgende echte `idle` innerhalb von 10 s wird als Abbruch gewertet (`.idle(interrupted:true)` -> `.ready` ohne `.turnCompleted`). Die Folge: kein Ton, keine Fertig-Meldung, und `AgentPromptQueueDelivery.deliverNext` laeuft nur ueber `turnCompleted`. Ein per `chats enqueue` vorgemerkter Folgeauftrag bleibt bei einem ruhenden Chat dauerhaft offen, bis irgendein spaeterer Turn endet. Vor 17.10. war ein ESC ohne Aktivitaetsstille folgenlos (5-s-Verifikation).

**Fix:** Den Merker nur dann als Abbruch werten, wenn der Transcript-Decider den Abbruch bestaetigt (`decision.turnAborted` bzw. Marker `[Request interrupted by user]`) oder das Transcript nach dem Merker nicht mehr gewachsen ist. Alternativ bei verworfenem `turnCompleted` offene Queue-Auftraege trotzdem nach dem Settle-Delay zustellen, sobald der Status stabil `idle` ist. Den Merker beim ersten Hook- oder Registry-Wechsel nach `busy` verwerfen.

**Test zuerst:** Reducer/Coordinator-Test: Merker setzen, danach busy -> idle innerhalb 2 s ohne Transcript-Abbruch-Marker; erwartet turnCompleted oder Queue-Zustellung. Plus Test, dass ein bestaetigter Abbruch weiterhin still bleibt.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AK-035 · Reduzierter Hook-Satz ohne Versions- oder Registry-Gate: aeltere Claude-Versionen verlieren Status, Permission-Erkennung und ID-Nachbindung

*P2 · agent-kern / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:162-164`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:258-276`, `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:47`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:385-390` (Stand `76256ad`)

**Fehlerbild:** `usesReducedHooks` prueft nur den Kill-Switch und `isBackground`, nicht die installierte Claude-Version und nicht, ob die CLI ueberhaupt `<config>/sessions/<pid>.json` schreibt. Eine aeltere oder angepinnte `claude`-Version erhaelt trotzdem nur SessionStart/SessionEnd. Dann fehlt jede Registry-Quelle, der Status kommt wie bei Codex nur aus dem Transcript. `PermissionRequest` entfaellt, ein Permission-Dialog wird nicht als `awaitingInput` erkannt. `resolvePendingBinding` loest eine nach `/clear` oder `/background` zurueckgestellte ID nie auf, weil es keine Turn-Hooks mehr gibt und `bindPendingExternalID` die Registry braucht. Der Chat bleibt an der alten ID, und `--resume` laedt den Verlauf von vor `/clear`; das ist die Klasse des Vorfalls vom 30.09. Die Hook-Datei ist beim Launch fixiert, ein spaeteres Erkennen hilft nicht. Das Mindestalter der Registry ist im Plan nicht belegt.

**Fix:** Beim Launch die Claude-Version lesen (`claude --version`, einmal gecacht ueber `AgentCommandBuilder.commandPath`) und den reduzierten Satz nur ab der Version waehlen, in der die Registry belegt ist (2.1.302 gemessen; kleinste funktionierende Version ermitteln). Sonst den vollen Hook-Satz nehmen. Ersatzweise `PermissionRequest` und `UserPromptSubmit` in den reduzierten Satz aufnehmen (kein Tool-Hook, nur seltene Events).

**Test zuerst:** Coordinator-Test mit injizierter Versionsabfrage: unter der Mindestversion muss `prepareLaunch` den vollen Satz schreiben und die Session als hook-live fuehren.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AK-037 · Registry-`busy` umfasst delegierte Arbeit: Send, Queue, Fertig-Meldung und `wait --until idle` haengen an Subagents und Hintergrund-Tasks

*P2 · agent-kern / ux · Aufwand M · Risiko mittel*

**Beleg:** `docs/plans/claude-status-aus-registry.md:42-46`, `WhisperM8/Services/AgentChats/ClaudeSessionRegistry.swift:157-165`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:141`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:178-183` (Stand `76256ad`)

**Fehlerbild:** Laut Plan steht `busy` auch fuer 'delegierte Arbeit (Subagents, Hintergrund-Tasks)'. Gemessen wurde nur Bash mit `run_in_background` (-> `shell`), nicht ein Task-Subagent im Hintergrund. Hat ein Chat die Antwort fertig geschrieben, delegierte Arbeit laeuft aber 30 Min weiter, zeigt die Sidebar 'arbeitet'. `chats send` meldet 'Ziel ist working' (Default erlaubt nur awaitingInput/idle). `enqueue` wird erst nach dem Ende der Hintergrundarbeit zugestellt, 'fertig' (Ton, Meldung) kommt erst dann, und `chats wait --until idle` bzw. Jarvis wartet entsprechend lange. Vorher setzte der Stop-Hook den Chat nach dem Turn auf idle. Der Plan nennt Send, Queue und `wait` als Folge nicht.

**Fix:** Mit einem Live-Test bestaetigen (Task-Subagent im Hintergrund, Registry-Wert mitschreiben). Falls bestaetigt: fuer die Sidebar eine eigene Anzeige 'wartet auf Hintergrundarbeit' (Registry busy + Transcript-Turn-Ende erkannt), die send/enqueue/Fertig-Meldung freigibt. Das Verhalten im Skill 'whisperm8-chats' dokumentieren.

**Test zuerst:** Live-Messung: Task-Subagent run_in_background starten, danach `chats list --json` und Registry-Datei alle 1 s protokollieren, bis der Subagent endet.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-CLI-002 · send und Queue-Zustellung haengen den Agent-Prompt an einen vom User getippten Entwurf und schicken beides ab

*P2 · cli-control / datenintegritaet · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:159-201`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:61-67`, `WhisperM8/Views/AgentTerminalView.swift:726-740`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:92-130` (Stand `76256ad`)

**Fehlerbild:** Der User tippt im Terminal eines idle-Chats eine halbe Nachricht, schickt sie aber nicht ab. Jarvis ruft `chats send` auf, oder ein vorgemerkter Queue-Auftrag wird zugestellt (Status idle). Beide pruefen nur den Runtime-Status. pastePrompt fuegt den Text ans Ende des Entwurfs und sendet Enter. Claude bekommt Entwurf und Auftrag als eine verfaelschte Nachricht, und der Entwurf des Users ist verloren. shouldClearBeforeSubmit gibt bei mayHaveUnsentInput bewusst false zurueck, der Entwurf bleibt also stehen. Nur der Kontowechsel wertet mayHaveUnsentInput aus.

**Fix:** In sessionSend und deliverNow composerDraft.mayHaveUnsentInput pruefen. Bei Entwurf: send liefert conflict (neuer Code oder unsentInput, Ausweg enqueue). Die Queue-Zustellung bleibt mit retry zurueckgestellt und wird beim naechsten Turn-Ende erneut versucht. --force darf die Pruefung aufheben.

**Test zuerst:** Pure Entscheidungsfunktion mit (runtime, lifecycle, mayHaveUnsentInput): idle + Entwurf ergibt Ablehnung, idle ohne Entwurf ergibt allowed.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-CLI-003 · `chats enqueue` stellt bei launching sofort zu und umgeht den Readiness-Guard, den die Fehlermeldung als Ausweg empfiehlt

*P2 · cli-control / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlRequestHandler.swift:1064-1070`, `WhisperM8/Services/AgentChats/AgentPromptQueueDelivery.swift:39-76`, `WhisperM8/Services/AgentChats/ChatsSendReadinessGuard.swift:4-55` (Stand `76256ad`)

**Fehlerbild:** Direkt nach `chats resume` meldet der Chat launching, was auf runtimeStatus idle abbildet. `send` lehnt korrekt mit notReady ab und rat zu `chats enqueue`. enqueue sieht runtime == .idle und ruft sofort AgentPromptQueueDelivery.deliverNow auf. deliverNow kennt ChatsSendReadinessGuard nicht, pastet blind in die noch ladende TUI und markiert den Auftrag als delivered. Es ist genau der stille Verlust aus dem Vorfall 2026-07-26, jetzt ueber den empfohlenen Umweg. Der Auftrag ist als zugestellt markiert, kommt aber nie an, und niemand bekommt eine Warnung.

**Fix:** Den lifecycleState-Check (ChatsSendReadinessGuard.decide) in deliverNow aufnehmen: bei .notReady retry zurueckstellen und beim ersten bestaetigten Turn-Ende oder nach Ablauf des launching-Fensters erneut zustellen. Die Sofortzustellung in queueMutation nur bei lifecycle != launching ausloesen.

**Test zuerst:** deliverNow gegen einen Fake mit lifecycle=.launching: erwartet markFailed(retry:true), kein sendPrompt, Eintrag bleibt offen.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-CLI-008 · Handler-Timeout 10 s passt nicht zu move-account: Antwort `Zustand unklar` waehrend der Umzug weiterlaeuft

*P2 · cli-control / robustheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentControlServer.swift:297-309`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler+AccountMove.swift:93-100`, `WhisperM8/Services/AgentChats/AgentControlRequestHandler+AccountMove.swift:237-251`, `WhisperM8/Services/AgentChats/AccountMoveStopResume.swift:186-190` (Stand `76256ad`)

**Fehlerbild:** `chats move-account --stop-and-resume` auf mehrere laufende Chats: prefetch liest beim ersten Lauf ganze Transcripts (ClaudeBackgroundTaskMonitor, bei 100-MB-Dateien mehrere Sekunden), danach terminate-Wartezeit und ein Exit-Waiter bis 5 s, dann das Verschieben der Transcripts. Zusammen sind das leicht mehr als 10 s. serveConnection antwortet mit `Handler-Timeout — Zustand unklar` (Exit 4, conflict), der Task laeuft aber weiter und fuehrt den Umzug aus. Der Agent oder User wiederholt den Befehl und plant damit eine zweite Bewegung oder haelt den Chat fuer nicht umgezogen, obwohl er laeuft und im neuen Konto ist. Der Client-Read-Timeout von 12 s hat dasselbe Limit.

**Fix:** Lang laufende Methoden (session.moveAccount, close --stop mit vielen Zielen) als Job modellieren: sofort `accepted` mit jobID, dann pollbar. Alternativ methodenabhaengiges Server- und Client-Timeout (z. B. 45 s) und im Timeout-Pfad den echten Zustand liefern.

**Test zuerst:** Fake-Handler, der 11 s schlaeft: Client bekommt Timeout. Dann Pruefung des Job-Pfads, der ueber `jobs.get` das Endergebnis liefert.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AK-016 · Dauernde externe Transcript-Writes können die Erkennung endlos verschieben

*P3 · agent-kern / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift:88-90`, `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift:112-126`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:130-136` (Stand `a8e0f35`)

**Fehlerbild:** Eine extern gestartete, noch nicht überwachte Session schreibt über Minuten alle zwei bis vier Sekunden relevante JSONL-Änderungen. Jeder FSEvents-Burst cancelt den fünfsekündigen Debounce-Task. requestScan wird während dieses gesamten Zeitraums nie aufgerufen; der Zehnsekunden-Cooldown kann deshalb nicht helfen. Ohne Foreground-Wechsel oder manuelles Aktualisieren bleibt die neue Session bis zu einer ausreichend langen Schreibpause unentdeckt.

**Fix:** Trailing-Debounce um eine maximale Wartezeit oder einen führenden, gedrosselten Trigger ergänzen. Unabhängig von weiterem Streaming muss nach einer begrenzten Zeit ein Scan angefordert werden; Single-Flight und bestehende Cooldowns beibehalten.

**Test zuerst:** In AgentDirectoryEventMonitor die Scan-Anforderung als Closure injizieren (requestScan: (Reason) -> Void) und handleEvents intern testbar machen. Mit debounceInterval 0,2 s zehnmal im 0,1-s-Takt einen relevanten Pfad melden (1 s Dauerlast). Erwartung: mindestens ein requestScan, weil die Höchstwartezeit greift. Heute keiner.

### LR-AK-020 · [A3-05] Ignorierte Background-Forks verändern trotzdem den Vordergrundstatus

*P3 · agent-kern / korrektheit · Aufwand M · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:330-355`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:729-735`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:201-226`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:595-608` (Stand `a8e0f35`)

**Fehlerbild:** Ein als fork erkannter Background-Agent schreibt über dieselbe Hook-Datei wie das Vordergrundterminal. Seine ID wird korrekt nicht gebunden, seine späteren Prompt-/Stop-/Permission-Events werden aber ohne ID-Filter auf den Vordergrundzustand angewendet. Ein Fork-Stop kann deshalb einen noch arbeitenden Vordergrundchat als fertig melden und eine Queue-Zustellung für dessen PTY auslösen.

**Fix:** Der Filter darf nur Events ignorierter Fork-IDs (forkExternalIDs[localID]) verwerfen. Events mit unbekannter oder nil-Session-ID müssen weiter durchgehen (Pending-Neubindung, Codex ohne ID), und der Fork-Status darf nicht verloren gehen, wenn der bg-Fork selbst als Session getrackt wird (isBackgroundSession).

*Ursprünglicher Vorschlag:* Binding-Entscheidung und Status-Zuständigkeit getrennt behandeln: Events bekannter ignorierter Fork-IDs nicht auf den Vordergrundstatus anwenden. Pending-Neubindungen und legitime In-Place-Wechsel weiter zulassen. Regressionstest muss neben der gebundenen ID auch Status und Queue-/Notification-Effekte prüfen.

**Test zuerst:** AgentSessionStatusCoordinatorTests: Vordergrund-ID 'A' gebunden, Status working per userPromptSubmit(A). sessionStart('F', source: fork) dann hookEvent(.stop, sessionID: 'F'). Erwartet: states[sessionID] bleibt working, kein Sound/Notification und kein AgentPromptQueueDelivery-Aufruf. Heute geht der Status auf idle und der Effekt feuert.

**Delta 76256ad:** Im Standardpfad (Registry an, Vordergrund-Chat) weitgehend entschaerft: Der reduzierte Hook-Satz enthaelt keine Prompt-/Stop-/Permission-Events mehr, Fork-Records (`kind: bg`) werden in `handleRegistryRecord` ignoriert, und registry-live Sessions werten Hook-Signale nur als Schatten. Es besteht weiter fuer Background-Agents, die den vollen Hook-Satz behalten, bei ausgeschaltetem Kill-Switch und bei Sessions ohne Registry-Eintrag (aeltere Claude-Version, siehe Befund reduzierter Hook-Satz). Schweregrad im Standardpfad niedriger.

<details><summary>Prüfurteil</summary>

Technisch korrekt: Bei .ignoreFork wird die ID nur nicht gebunden. Direkt danach läuft handleHookEvent weiter bis apply(signal, to: localID) ohne ID-Filter, und der Test in AgentSessionStatusCoordinatorTests:173-181 sendet Fork-Prompt und Fork-Stop durch, prüft aber nur die Bindung, nicht den Status. Ein Fork-Stop kann also turnCompleted auslösen (Sound, Notification, Queue-Zustellung an die PTY des Vordergrunds). Der Normalfall ist aber /background: Dort wird der Vordergrund gerade zur leeren Session, und der Fork-Turn kann den Status nur flackern lassen, nicht einen echten laufenden Turn überschreiben. Betroffen ist das Erweiterte Feature F-AC-11, es führt zu einer falschen Statusanzeige und im ungünstigen Fall zu einer verfrühten Queue-Zustellung. Das ist kein Datenverlust und kein Kern-Hänger, und es greift nur mit parallelem bg-Fork und Vordergrund. Kein Launch-Blocker.

</details>

### LR-AK-027 · [A3-13] Zustell-Token kann mehrfach erfolgreich konsumiert werden

*P3 · agent-kern / race · Aufwand S · Risiko mittel*

**Beleg:** `WhisperM8/Services/AgentChats/SendDeliveryTokenStore.swift:104-117` (Stand `a8e0f35`)

**Fehlerbild:** Zwei Hook-Prozesse lesen dasselbe noch vorhandene Token, bevor einer es löscht. Beide geben true zurück, weil das Löschergebnis ignoriert wird. Auch ein dauerhaft fehlgeschlagenes Löschen lässt dasselbe Token immer wieder passieren. Der Guard autorisiert damit mehr Submissions als die App Zustellungen freigegeben hat.

**Fix:** Atomaren Claim per rename(2) der Token-Datei (z. B. in .claimed/) nutzen. Ein Fehlschlag beim Claim muss der Fail-open-Politik folgen und darf keinen Block auslösen. Ein Lock wäre teurer und fehleranfälliger als rename.

*Ursprünglicher Vorschlag:* Token prozessübergreifend atomar beanspruchen, etwa durch einen gemeinsamen Lock oder exklusives Umbenennen. Nur der erfolgreiche Claim darf autorisieren; Lösch-/Claim-Fehler getrennt gemäß fail-open-Politik behandeln. Mehrere gleichartige Zustellungen an verschiedene Ziele müssen weiterhin jeweils genau ein Token konsumieren.

**Test zuerst:** SendGuardTests: stage() einmal, dann consume() zweimal mit einem Verzeichnis, in dem removeItem fehlschlägt (z. B. Verzeichnis read-only via chmod 0o500 nach dem Stage). Erwartet: zweiter consume liefert false. Heute true. Der Zwei-Prozess-Fall braucht einen Claim per rename(2) in ein Unterverzeichnis.

<details><summary>Prüfurteil</summary>

consume() ignoriert das Ergebnis von removeItem, daher kann ein Token statisch mehrfach 'true' liefern. Der konkrete Schaden ist aber winzig. Zwei gleichzeitige Hook-Prozesse mit gleichem Prompt-Hash lesen nur dann dasselbe Token, wenn dieselbe Nachricht zeitgleich zweimal submittet wird. Bei Zustellung an zwei Ziele existieren zwei Tokens, und beide Submissions sind legitim. Das unverbrauchte zweite Token ist dann nur ein einzelner zusätzlicher Freipass bis zum TTL (30 min) für denselben Marker-Text. removeItem schlägt nur bei Rechte- oder Dateisystemproblemen fehl, und der Guard ist laut Konzept fail-open. Betroffen ist das unsichtbare Zusatz-Sicherheitsnetz F-AC-10, nicht der Nutzerweg. Kein Launch-Blocker, kein Race mit plausibler Wirkung.

</details>

### LR-AK-036 · Warte-Art aus Registry: veraltetes letztes Tool und vorlaeufige Art in der Benachrichtigung

*P3 · agent-kern / korrektheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:648-660`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:693-705`, `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:315-321`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:909-912` (Stand `76256ad`)

**Fehlerbild:** `registryAwaitingKind` ordnet jedes `.tool`-Detail als `permission` ein (ausser ExitPlanMode), auch wenn `waitingFor` etwas anderes sagt (`input needed`, `dialog open`, `worker request`). Das Detail ist der letzte Tool-Aufruf des Turns und kann bereits abgeschlossen sein. Beispiel: MCP-Elicitation nach einem Bash-Aufruf wird als `permission` angezeigt, die Stand-Zeile lautet 'Freigabe: Bash ...'. Ausserdem feuert `.inputRequested(kind)` sofort beim Registry-Wechsel mit der vorlaeufigen Art, wenn der Transcript-Tail noch nicht gelesen wurde (Default permission). `refineRegistryAwaiting` zieht nur den Zustand nach; die Benachrichtigung bleibt falsch ('Freigabe' statt 'Frage' oder 'Plan').

**Fix:** `waitingFor == "input needed"` vor dem `.tool`-Detail auswerten. Nur ein offenes Tool (ohne Ergebniszeile) als Freigabe-Tool nehmen. Die Benachrichtigung um ca. 300 ms verzoegern oder bei Artwechsel nachschieben.

**Test zuerst:** Pure Tests fuer `registryAwaitingKind`: (waitingFor input needed, detail .tool Bash) -> question; Notification-Kind nach Tail-Nachzug.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

### LR-AK-038 · Registry-FSEvents werden per exaktem Pfad-String den Profilen zugeordnet; Symlink-Config-Dirs liefern keine Live-Updates

*P3 · agent-kern / robustheit · Aufwand S · Risiko niedrig*

**Beleg:** `WhisperM8/Services/AgentChats/ClaudeRegistryStatusSource.swift:32-40`, `WhisperM8/Services/AgentChats/ClaudeRegistryStatusSource.swift:194-206`, `WhisperM8/Services/AgentChats/ClaudeRegistryStatusSource.swift:211-215` (Stand `76256ad`)

**Fehlerbild:** `directoryProfiles` ist ein Dictionary mit `root.url.path` als Schluessel. FSEvents liefert kanonische (aufgeloeste) Pfade. Ist `~/.claude` oder ein Profil-Ordner ein Symlink (Dotfile-Manager, `/var` -> `/private/var`), findet `profiles[url.deletingLastPathComponent().path]` nichts, und jedes Event wird still verworfen. Der Status kommt dann nur noch im 10-s-Takt des Voll-Scans. Sidebar, Fertig-Ton und Queue-Zustellung reagieren bis zu 10 s spaeter; es gibt kein Log dazu. Der Voll-Scan nutzt die Originalpfade und funktioniert, deshalb faellt es nicht auf.

**Fix:** Beim Aufbau von `watchedRoots` zusaetzlich `realpath` je Ordner als Schluessel eintragen und beim Event den Schluessel ueber realpath oder Praefixvergleich aufloesen. Verworfene Events einmal pro Start mit `Logger.warning` melden.

**Test zuerst:** Test mit Symlink auf einen sessions-Ordner: Datei schreiben, `handleEventsOffMain` mit dem aufgeloesten Pfad aufrufen, `apply(pid:record:)` muss feuern.

**Verifikation:** noch ungeprüft. Der Test muss den Befund vor dem Fix reproduzieren, sonst wird er als `widerlegt` mit Begründung geschlossen.

## Nachtrag 18.10.2026

### LR-AK-039 · Selbstheilung toter Session-Zeiger belegt nach jedem App-Start rund zwei Minuten einen Kern

*P2 · agent-kern / performance · Aufwand M · Risiko niedrig · gefunden beim E2E-Test von W0*

**Fehlerbild:** Nach `make dev` 100–115 % CPU und bis 2 GB RSS für ~2 min. Im Sample entfielen 2908 von 3687 Samples auf `ClaudeExternalIDRecovery.recoveries`, weil die Event-Dateien pro Kandidat neu zerlegt werden.

**Fix:** Event-Datei je Hook-Pfad einmal lesen und indizieren; Kandidaten begrenzen; negativ cachen (Pfad+Größe+mtime); off-main mit Budget-Signpost.

**Test zuerst:** 500 Kandidaten, eine große Event-Datei. Sie wird genau einmal zerlegt, das Ergebnis ist identisch zum alten Pfad.
