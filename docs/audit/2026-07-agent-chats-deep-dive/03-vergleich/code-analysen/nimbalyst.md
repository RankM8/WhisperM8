# nimbalyst

## Kurzfazit

Nimbalyst besitzt zwei technisch unterschiedliche Claude-Code-Pfade. Der Provider `claude-code` verwendet das Agent SDK; dort werden Nimbalyst-Session-ID und Provider-Session-ID getrennt modelliert, beim Laden explizit restauriert, sofort persistiert und bei einem Resume auf Identitätsgleichheit geprüft. Der Provider `claude-code-cli` startet dagegen die echte interaktive `claude`-CLI in einem `node-pty`.

Im echten CLI-Pfad wird für den Normalfall absichtlich dieselbe UUID als Nimbalyst- und Claude-Session-ID benutzt. Existiert die erwartete JSONL, wird `--resume <id>` statt `--session-id <id>` verwendet. Eine Verifikation der von der CLI tatsächlich aktiven Session-ID, eine eigene Resume-Fehlerklassifikation und ein echter Fork mit `--fork-session` sind in diesem Pfad nicht auffindbar.

Für WhisperM8 ist Nimbalyst deshalb zugleich Positiv- und Negativreferenz: Die Identitätsinvarianten des SDK-Pfads sind stark, müssen aber um die echte CLI herum nachgebaut werden. Der CLI-Pfad selbst zeigt zwei konkrete Risiken: Der Sessionimport kann bei `App-ID != Claude-ID` eine zweite Session erzeugen, und ein fehlendes JSONL wird als Anlass für einen Fresh-Start mit derselben App-ID behandelt, nicht als eigener, erklärbarer Resume-Zustand.

## Projektüberblick

### Stack und Ausführungsmodell

- TypeScript-Monorepo mit Electron, React 19 und Vitest; die Workspaces umfassen unter anderem `packages/electron` und `packages/runtime` (`package.json:17-28`, `package.json:47-88`, `package.json:90-101`).
- PTY-Backend ist `node-pty` (`package.json:103-122`). Die echte interaktive Claude-CLI wird als PTY gestartet und nicht durch eine eigene Chat-Runtime ersetzt (`packages/electron/src/main/services/ai/ClaudeCliSessionLauncher.ts:1-23`, `packages/electron/src/main/services/TerminalSessionManager.ts:945-1012`).
- Das Terminal-Frontend ist Ghostty-Web; jedes Terminal erhält wegen eines Shared-Memory-Fehlers eine eigene WASM-Instanz (`packages/electron/src/renderer/components/Terminal/TerminalPanel.tsx:309-320`, `packages/electron/src/renderer/components/Terminal/TerminalPanel.tsx:403-415`).
- Parallel existiert ein Agent-SDK-Provider. Dessen robuste Resume-/Fork-Logik ist eine konzeptionelle Referenz, aber kein direkt übernehmbarer Ersatz für WhisperM8s CLI-Host-Modell (`packages/runtime/src/ai/server/providers/ClaudeCodeCliProvider.ts:1-25`, `packages/runtime/src/ai/server/providers/ClaudeCodeCliProvider.ts:46-74`).

### Relevante Dateien

| Datei | Relevanz |
|---|---|
| `packages/electron/src/main/services/ai/ClaudeCliSessionLauncher.ts:1-23,113-176,275-316` | Allokation vor Spawn, Auswahl `--session-id`/`--resume`, PTY-Start |
| `packages/electron/src/main/services/ai/claudeCliSpawnConfig.ts:230-261,325-361` | Gegenseitig ausschließende CLI-Flags und bereinigte Umgebung |
| `packages/electron/src/main/services/ai/claudeCliJsonlPath.ts:1-21,26-57` | Deterministische JSONL-Adresse und Resume-Heuristik |
| `packages/electron/src/main/services/ai/claudeCliErrorClassifier.ts:15-21,66-101` | Fehlerklassen des echten CLI-Proxy-Pfads |
| `packages/runtime/src/ai/server/providers/ProviderSessionManager.ts:47-70,96-125` | Getrennte App-/Provider-ID im SDK-Pfad |
| `packages/runtime/src/ai/server/providers/claudeCode/sdkOptionsBuilder.ts:480-500` | Getrennte Resume- und Fork-Übergänge im SDK-Pfad |
| `packages/runtime/src/ai/server/providers/ClaudeCodeProvider.ts:1137-1157,1288-1318,1811-1821` | Resume-Mismatch und autoritative Expiry-Klassifikation |
| `packages/electron/src/main/ipc/ClaudeCodeSessionHandlers.ts:22-47,55-129,144-173` | Session-Scan, Deduplizierung und Import-IPC |
| `packages/electron/src/main/services/ClaudeCodeSessionSync.ts:502-570,576-684` | Import-Upsert und Nachrichtenfortschreibung |
| `packages/electron/src/main/services/TerminalSessionManager.ts:161-207,274-361,869-943,945-1065` | PTY-Lebenszyklus und Persistenz |
| `packages/electron/src/renderer/components/Terminal/TerminalPanel.tsx:309-400,483-650` | Restore-Rennen, Sequenzen, Snapshot und Auto-Restart |
| `packages/electron/src/renderer/store/atoms/sessions.ts:91-96,1681-1762,2053-2064` | Aktive UI-Auswahl und ID-spezifisches Laden |
| `packages/electron/src/renderer/store/atoms/openProjects.ts:355-383` | Schutz beim Workspace-/Fensterkontext-Wechsel |

## Identitätsmodell: Prozess, persistente ID und UI-Auswahl

### SDK-Pfad: drei getrennte Dinge

Im SDK-Pfad sind die Rollen sauber getrennt:

- Die Nimbalyst-App-ID ist der Schlüssel für DB, UI und Provider-Instanz.
- Die Provider-ID ist die von Claude oder Codex gelieferte persistente Konversations-ID. `ProviderSessionManager` führt dafür eine Map `Nimbalyst session ID -> provider session ID` (`packages/runtime/src/ai/server/providers/ProviderSessionManager.ts:47-77`).
- Die aktive Session ist lediglich eine Renderer-Auswahl. `activeSessionIdAtom` entscheidet, welches Panel gezeigt wird; `setActiveSessionAtom` setzt nur diese App-ID und markiert sie als gelesen (`packages/electron/src/renderer/store/atoms/sessions.ts:91-96`, `packages/electron/src/renderer/store/atoms/sessions.ts:2053-2064`).

Eine neu beobachtete Provider-ID wird idempotent erfasst und per Event sofort nach außen gegeben (`ProviderSessionManager.ts:55-70`). Beim Laden wird die persistierte ID ohne Event restauriert, um keine Persistenzschleife zu erzeugen (`ProviderSessionManager.ts:107-125`). Vor jeder Nachricht restauriert der Streaming-Handler die DB-ID erneut und liest sie sofort zurück. Eine Abweichung bricht hart ab, statt still eine neue Konversation zu beginnen (`packages/electron/src/main/services/ai/MessageStreamingHandler.ts:650-690`). Neue IDs werden unmittelbar persistiert; das Speichern am Turn-Ende ist nur ein zweites Sicherheitsnetz (`MessageStreamingHandler.ts:977-998`, `MessageStreamingHandler.ts:2476-2487`).

Die DB bildet die Trennung ebenfalls ab: `ai_sessions.id` und `provider_session_id` sind eigene Spalten (`packages/electron/src/main/services/PGLiteSessionStore.ts:356-416`). Branch-Herkunft ist nochmals getrennt von der hierarchischen Parent-Beziehung, und beim Laden wird die Provider-ID der Quell-Session per Join aufgelöst (`PGLiteSessionStore.ts:526-580`).

### Echter CLI-Pfad: absichtliche Gleichsetzung im Normalfall

Der CLI-Pfad allokiert die Nimbalyst-ID vor dem Prozessstart, weil dieselbe ID bereits in MCP-URLs und Beobachtungskomponenten stecken muss (`ClaudeCliSessionLauncher.ts:6-20`). Bei einer frischen UUID wird sie mit `--session-id` auch der echten CLI vorgegeben. Existiert die erwartete JSONL, wird dieselbe UUID mit `--resume` verwendet (`ClaudeCliSessionLauncher.ts:152-176`; `claudeCliSpawnConfig.ts:252-261`). Die Tests sichern genau diese beiden Flag-Kombinationen ab (`packages/electron/src/main/services/ai/__tests__/ClaudeCliSessionLauncher.test.ts:370-412`, `packages/electron/src/main/services/ai/__tests__/claudeCliSpawnConfig.test.ts:45-68`).

Das reduziert Mapping-Fehler für neue Sessions, ist aber keine vollständige Identitätsmodellierung. Der Launcher akzeptiert auch eine explizite `resumeSessionId`, die von der Nimbalyst-ID abweichen darf (`ClaudeCliSessionLauncher.ts:113-123,162-176`). Trotzdem bleiben PTY, MCP-Konfiguration, Beobachtung und Terminal-Events unter der Nimbalyst-ID registriert (`ClaudeCliSessionLauncher.ts:178-180,225-230,293-309`). Im gefundenen CLI-Pfad gibt es nach dem Spawn keine Prüfung, welche Claude-Session-ID die CLI tatsächlich angenommen hat.

### Wann wird die aktive ID tatsächlich getauscht?

1. **UI-Auswahl:** Ein Klick wählt eine Nimbalyst-App-ID aus. Die Sessiondaten werden unter einem ID-spezifischen Atom geladen; parallele Loads werden je App-ID dedupliziert (`packages/electron/src/renderer/store/actions/sessionHistoryActions.ts:99-178,213-268`; `packages/electron/src/renderer/store/atoms/sessions.ts:1681-1762`). Das ist kein Provider-Resume und ändert keine Claude-ID.
2. **Resume:** Im SDK-Pfad bleibt die App-ID stabil; nur die für den nächsten Provideraufruf verwendete Provider-ID wird aus der DB restauriert. Im CLI-Pfad bleibt ebenfalls die App-ID stabil, und der Spawn wechselt von `--session-id appID` zu `--resume appID` oder zu `--resume expliziteClaudeID`.
3. **Import:** Der Import aktualisiert die Sessionliste, setzt aber nicht direkt `activeSessionIdAtom` (`packages/electron/src/renderer/dialogs/dataDialogs.tsx:126-155`). Ein aktiver Wechsel erfolgt erst durch eine spätere explizite UI-Auswahl.
4. **Branch:** Eine neue Nimbalyst-App-ID wird erzeugt und danach als neue UI-Auswahl geöffnet (`packages/runtime/src/ai/server/SessionManager.ts:925-1017`; `packages/electron/src/renderer/store/actions/sessionHistoryActions.ts:351-375`). Wie unten gezeigt, ist aber nur der SDK-Pfad auch ein echter Claude-Fork.

## 1. Aktive Session und Schutz gegen Cross-Window-Vermischung

### Was Nimbalyst konkret tut

- Provider-Objekte werden unter `${providerType}-${appSessionId}` gecacht. Provider-seitiger Zustand kann dadurch nicht versehentlich von einer anderen App-Session wiederverwendet werden (`packages/runtime/src/ai/server/ProviderFactory.ts:18-30,44-92`).
- PTYs liegen in einer Map unter der Terminal-/Session-ID; der CLI-Launcher hat zusätzlich eine `launchInFlight`-Map je App-ID. Vor und während eines Starts werden doppelte PTYs abgefangen (`TerminalSessionManager.ts:161-165,980-983`; `packages/electron/src/main/services/ai/claudeCliLauncherSingleton.ts:185-225`).
- Auf einem Projektwechsel wird `activeSessionIdAtom` synchron auf die Auswahl des neuen Workspace gesetzt oder gelöscht. Der Kommentar nennt explizit das Leaken der alten Workspace-Session als zu verhindernden Fehler (`packages/electron/src/renderer/store/atoms/openProjects.ts:355-383`).
- Die CLI startet erst, wenn ihr Bereich sichtbar und genau dieses Betriebssystemfenster fokussiert ist. Dies behebt den dokumentierten Fall, dass nach einem Neustart alle wiederhergestellten Fenster gleichzeitig echte CLI-Prozesse starteten (`packages/electron/src/renderer/components/UnifiedAI/ClaudeCliTerminalStrip.tsx:23-59,72-114`).
- Agent-Nachrichten werden inzwischen nur an das Fenster des unveränderlichen Session-Workspace geschickt. Der Code dokumentiert, dass vorheriger All-Window-Fan-out zu Loads mit dem Workspace eines falschen Fensters führte (`MessageStreamingHandler.ts:240-270`).
- Terminalausgabe und Exit werden dagegen weiterhin an alle Browserfenster gesendet (`TerminalSessionManager.ts:907-933,1305-1314`). Der Renderer filtert exakt auf `data.sessionId === sessionId` und verwirft alte Sequenzen (`TerminalPanel.tsx:483-506,627-650`).

### Bewertung

**Besser als ein rein UI-globales Modell:** Session-spezifische Provider/PTY-Maps, workspace-spezifisches Laden, Fokus-Gating und exakte Renderer-Filter reduzieren Cross-Window-Vermischung deutlich.

**Schwächer als eine Ende-zu-Ende-Bindung:** Terminalevents enthalten nur Session-ID und Sequenz, aber keinen Workspace, keine Prozessgeneration und keinen Fenster-Owner. Der Main-Prozess broadcastet weiterhin an jedes Fenster und verlässt sich auf alle Renderer als Filter. Wenn dieselbe App-Session in zwei Fenstern montiert wird, sehen beide denselben PTY und können grundsätzlich beide Eingaben senden; eine Single-Writer-Lease war nicht auffindbar. Auch eine explizite Prüfung `appSessionId -> erwartete CLI-ID -> beobachtete CLI-ID` fehlt im echten CLI-Pfad.

## 2. Fork und Resume als getrennte Identitätsübergänge

### SDK-Pfad

Der SDK-Pfad modelliert die beiden Übergänge richtig verschieden:

- **Resume:** Existiert für die aktuelle App-ID bereits eine Provider-ID, wird `options.resume` auf genau diese ID gesetzt (`sdkOptionsBuilder.ts:480-485`). Wenn Claude anschließend eine andere ID meldet, bricht der Provider mit einem Resume-Mismatch ab (`ClaudeCodeProvider.ts:1137-1157`).
- **Fork:** Die neue App-Session trägt eine `branchedFromSessionId`. Der Builder nimmt die Provider-ID der Quelle, setzt `options.resume = sourceProviderId` und `options.forkSession = true` (`sdkOptionsBuilder.ts:486-500`). Eine abweichende neu gemeldete Provider-ID ist hier beabsichtigt und wird deshalb von der Resume-Gleichheitsprüfung ausgenommen (`ClaudeCodeProvider.ts:1143-1157`).
- Die Branch-Erzeugung vergibt zuerst eine neue App-ID und speichert die Quell-App-ID separat (`SessionManager.ts:925-990`). Die Quell-Provider-ID wird im Rückgabeobjekt mitgeführt; persistiert wird sie indirekt über den Join auf die Quell-Session (`SessionManager.ts:967-1013`; `PGLiteSessionStore.ts:533-580`).

Eine Schwachstelle bleibt: Ist nur die Quell-App-ID vorhanden und kann daraus keine Provider-ID aufgelöst werden, loggt der Builder nur eine Warnung und setzt keinen Fork (`sdkOptionsBuilder.ts:491-498`). Das ist fail-open und kann eine vermeintliche Branch still zu einer frischen Konversation machen.

### Echter CLI-Pfad

Im untersuchten Electron-CLI-Pfad ist kein `--fork-session` auffindbar. Der Spawn-Builder kennt nur `--resume`, `--continue` und `--session-id` (`claudeCliSpawnConfig.ts:252-261`). Das normale Terminal-Frontend übergibt beim Start außerdem keine abweichende `resumeSessionId`, sondern nur die neue App-ID (`TerminalPanel.tsx:120-141`).

Folge: Die generische Branch-Aktion erzeugt zwar eine neue Nimbalyst-Session, für `claude-code-cli` wird daraus im gefundenen Pfad aber ein Fresh-Start mit der neuen ID, nicht ein Fork der Claude-Konversation. Es existiert weder ein belegter Flag-Übergang `--resume <source> --fork-session` noch die anschließende Erfassung der neuen Ziel-ID. Tests für CLI-Fork oder Cross-Branch-Schutz wurden nicht gefunden.

Das ist für WhisperM8 die wichtigste Negativreferenz: Eine neue Wrapper-ID allein ist noch kein Fork. Der Prozessstart muss Quell-ID, Fork-Flag und erwartete neue Zielidentität als zusammengehörige Transition behandeln.

## 3. Verlorene oder nicht wiedergefundene Sessions

### Gute Mechanismen

- Frische CLI-Sessions erhalten deterministisch die vorher allokierte UUID. Dadurch ist der erwartete JSONL-Pfad vor dem Start bekannt (`claudeCliJsonlPath.ts:26-49`).
- Vor einem Re-Spawn prüft der Launcher diesen Pfad. So kollidiert er nicht erneut mit `--session-id`, sondern nimmt `--resume` (`ClaudeCliSessionLauncher.ts:162-176`).
- JSONL-Import parst zeilenweise tolerant; eine defekte Zeile verwirft nicht die ganze Datei (`packages/electron/src/main/services/ClaudeCodeSessionSync.ts:144-166`). Persistierte große Toolresultate und Subagent-Sidecars werden ebenfalls eingelesen (`ClaudeCodeSessionSync.ts:590-613`).
- Beim Scan wird nach Claude-Session-ID dedupliziert und sowohl nach direkter App-ID als auch über eine Provider-ID-Map gesucht (`ClaudeCodeSessionHandlers.ts:65-98`).
- Wiederholte `tool_result`-Blöcke werden über `tool_use_id` dedupliziert. Beim Resume wird das In-Memory-Set aus bereits persistierten Zeilen vorbefüllt, damit der erste wiederholte Request nicht alles doppelt schreibt (`packages/electron/src/main/services/ai/claudeCliObservationSingleton.ts:175-195`; `packages/electron/src/main/services/ai/claudeCliToolResultLog.ts:89-140`).

### Konkrete Import-Lücke: Scan erkennt das Mapping, Sync ignoriert es

Der Scan kann eine vorhandene native Nimbalyst-Session finden, deren `id` von `providerSessionId` abweicht (`ClaudeCodeSessionHandlers.ts:83-97`). `syncSession` wiederholt diese Auflösung aber nicht. Es fragt ausschließlich `sessionStore.get(metadata.sessionId)` ab (`ClaudeCodeSessionSync.ts:615-618`). Bei Nichtfund erzeugt es eine neue DB-Session, deren App-ID und Provider-ID beide auf die Claude-ID gesetzt werden (`ClaudeCodeSessionSync.ts:620-641`).

Damit ist folgender Ablauf durch den Code möglich:

1. Vorhanden: App-ID `A`, `providerSessionId = C`.
2. Scan der JSONL `C.jsonl`: Status wird korrekt gegen App-Session `A` bestimmt.
3. Import/Update von `C`: `syncSession` sucht nur App-ID `C`, findet `A` nicht und erzeugt eine zweite Session `C`.

Die eigene `checkSyncStatus`-Funktion beschreibt das fehlende Query-by-provider-ID sogar als TODO (`ClaudeCodeSessionSync.ts:511-526`). Ein Test für den Fall `appSessionId != providerSessionId` war nicht auffindbar; der vorhandene Importtest prüft nur den Gleichheitsfall, in dem die importierte ID zugleich als `providerSessionId` gespeichert wird (`packages/electron/src/main/services/__tests__/ClaudeCodeImport.v2format.test.ts:285-310`).

### Weitere Wiederfindungsrisiken

- Die Resume-Entscheidung des echten CLI-Pfads ist ein einzelnes Boolean `jsonlExists` (`claudeCliJsonlPath.ts:52-57`). Ein fehlender Pfad kann aber auch aus anderem CWD-Encoding, verschobenem Workspace, anderem Account/HOME, Löschung oder einem Import-Mapping entstehen. Nimbalyst startet dann mit `--session-id` unter derselben App-ID, ohne diesen Kontextverlust als eigenen Zustand sichtbar zu machen.
- Import-Updates verwenden die Anzahl vorhandener DB-Nachrichten als Offset und schneiden die neu gemergte, nach Zeit sortierte Liste mit `slice(skipCount)` ab (`ClaudeCodeSessionSync.ts:615-618,655-680`). Gleichzeitig dokumentiert der Code, dass JSONL und DB wegen verworfener Nicht-Konversations-Events gerade keine gleichen Counts besitzen (`ClaudeCodeSessionSync.ts:544-547`). Wenn sich Sidecars oder Filterung zwischen Imports verändern, ist ein reiner Count-Offset kein stabiler Cursor; Überspringen oder Duplizieren ist möglich.
- Der Importdialog fällt bei leerem Workspace-Scan auf eine globale Liste zurück (`SessionImportDialog.tsx:67-82`). Der anschließende Import ruft den Main-Prozess jedoch wieder mit dem aktuellen Workspace-Filter auf (`dataDialogs.tsx:135-145`; `ClaudeCodeSessionHandlers.ts:153-155`). Aus einem anderen Workspace ausgewählte Fallback-Sessions können deshalb als nicht gefunden enden.

## 4. Resume-Fehlerklassifikation: echte Expiry versus falsche Diagnose

### SDK-Pfad: gute Trennung

Der SDK-Pfad klassifiziert `session expired` nur bei inhaltlich passenden Providerfehlern wie `no conversation found`, `session not found` oder `conversation not found`. Authentifizierung und Serverfehler haben eigene Regeln (`packages/runtime/src/ai/server/providers/claudeCode/resultChunkUtils.ts:24-55`). Nur diese Expiry-Klasse löscht die Provider-ID und erklärt, dass die sichtbare Historie erhalten bleibt (`ClaudeCodeProvider.ts:1288-1318`; `ProviderSessionManager.ts:95-105`; `MessageStreamingHandler.ts:977-987`).

Besonders übertragbar ist die explizite Korrektur einer früheren Fehldiagnose: Ein Fehlen in `history.jsonl` wird nur noch geloggt. Der Kommentar nennt den Lookup wegen Rennen und programmgesteuerter Sessions nicht autoritativ; allein der SDK-Fehler ist die Quelle für echte Expiry (`ClaudeCodeProvider.ts:1811-1821`).

### Echter CLI-Pfad: Resume semantisch nicht klassifiziert

Der Fehlerklassifikator des echten CLI-Proxy-Pfads unterscheidet Kontextlimit, Rate Limit, Overload, Auth, API-Fehler und Generic (`packages/electron/src/main/services/ai/claudeCliErrorClassifier.ts:15-21,70-101`). Klassen für `resume_target_missing`, `session_expired`, `resume_rejected`, `resume_identity_mismatch`, `wrong_account` oder `corrupt_transcript` gibt es dort nicht.

Aus dem untersuchten Code ist damit nicht belegbar, dass ein PTY-Exit nach `--resume` semantisch ausgewertet oder die von Claude aktive ID verifiziert wird. JSONL-Existenz ist nur eine Spawn-Heuristik. Sie ist weder ein Beweis, dass Resume gelingt, noch beweist ihr Fehlen eine remote oder semantisch abgelaufene Session.

### Erforderliche Klassifikation für WhisperM8

WhisperM8 sollte für den echten CLI-Prozess mindestens folgende, nicht zusammenfallende Zustände führen:

| Zustand | Autoritative Evidenz | Reaktion |
|---|---|---|
| `resume_target_missing_local` | Erwartete JSONL für Workspace, Account und CLI-ID fehlt | Nicht als expired bezeichnen; alternative Pfade/Account prüfen, Nutzerentscheidung anbieten |
| `resume_rejected_by_cli` | Spezifische CLI-Ausgabe oder Exit nach `--resume` | Ausgabe und Exitgrund erhalten; kein stiller Fresh-Start |
| `resume_identity_mismatch` | Hook/JSONL meldet eine andere ID als `--resume` | PTY quarantänisieren oder stoppen; Binding nicht überschreiben |
| `session_not_found_authoritative` | Eindeutige CLI-Fehlermeldung für die Ziel-ID | CLI-ID als nicht resumierbar markieren, Historie erhalten |
| `auth_or_account_mismatch` | Login-/Credential-Fehler oder anderer gebundener Account | Account korrigieren; Session-ID nicht löschen |
| `transcript_corrupt_or_unreadable` | Datei vorhanden, Parsing/CLI-Load scheitert | Datei nicht als abgelaufen behandeln; Diagnose/Recovery anbieten |

Nur der autoritative `session_not_found`-Fall darf das Resume-Binding entwerten. Ein Fresh-Start sollte eine neue Wrapper-/Branch-Identität bekommen, statt unter der alten Session still den Kontext auszutauschen.

## 5. Terminal-/PTY-Robustheit und Persistenz über Neustarts

### Robuste Muster

- Terminalmetadaten und begrenzter Scrollback werden pro Session persistiert; gespeichert werden unter anderem CWD, Größe, Cursor und Screen-Lines (`TerminalSessionManager.ts:167-207,215-246,274-361`).
- Output hat eine monotone Sequenznummer. Vor dem Restore wird der Live-Listener registriert; neue Ausgabe wird gepuffert und nach dem Snapshot nur oberhalb der letzten Sequenz angewendet (`TerminalSessionManager.ts:875-913`; `TerminalPanel.tsx:483-510,615-625`).
- Für die Fullscreen-Claude-TUI wird nicht blind der rohe Scrollback plus Screen erneut abgespielt. Stattdessen wird nur der sichtbare Snapshot gesetzt, dann erzwingt Resize einen Live-Repaint (`TerminalPanel.tsx:511-530`).
- Ein versteckt gemountetes Terminal startet sein Backend trotzdem und wartet ohne kurze Sichtbarkeits-Deadline auf eine messbare View. So bleibt ein lebender PTY beim Sessionwechsel nicht als getrennt liegen (`TerminalPanel.tsx:384-400`).
- Ein langsamer Backendstart darf nach dem UI-Timeout noch erfolgreich fertig werden und löst dann genau einen Re-Init aus (`TerminalPanel.tsx:326-381`). Ein sehr schneller Exit wird einmal automatisch neu gestartet, ohne eine Endlosschleife (`TerminalPanel.tsx:627-650`).
- Der echte CLI-PTY benutzt kein Shell-Bootstrap und keine Shell-History-Injektion. Ein gelöschtes CWD fällt vor Spawn auf Workspace oder Home zurück; der PID-State-Watcher wird beim Exit abgebaut (`TerminalSessionManager.ts:945-1065`).

### Persistenzgrenze

Der PTY-Prozess selbst überlebt keinen App-Neustart. Die aktive PTY-Map ist nur im Main-Prozess (`TerminalSessionManager.ts:161-165`), und beim Exit wird der Eintrag gelöscht (`TerminalSessionManager.ts:915-937`). Persistiert werden Darstellung und Metadaten; semantische Kontinuität entsteht nach Neustart ausschließlich durch neuen Spawn plus `--resume` und Claude-JSONL.

Das ist für WhisperM8 das passende Modell: Prozesspersistenz nicht vortäuschen. Stattdessen müssen drei Dinge getrennt abgesichert werden: visuelle Terminalwiederherstellung, robuste Prozessgeneration und semantisch verifizierter Resume.

## 6. Multi-Account-Isolation

Für den echten CLI-Pfad ist keine produktseitige Account-Identität pro Session auffindbar. Der Resolver nimmt bevorzugt die Installation unter `~/.claude/local`, danach den ersten `claude` im Login-Shell-PATH (`packages/electron/src/main/services/ai/claudeExecutableResolver.ts:1-17,53-89`). Die Spawn-Umgebung entfernt `ANTHROPIC_API_KEY` und `CLAUDECODE`, damit ein geerbter API-Key nicht die Subscription-CLI und Abrechnung überschreibt (`claudeCliSpawnConfig.ts:155-166,325-361`). Das ist ein wichtiger Billing-Schutz, aber keine Multi-Account-Isolation.

`CLAUDE_CONFIG_DIR` taucht im untersuchten Code nur in SDK-Crashdiagnostik auf (`packages/runtime/src/ai/server/providers/claudeCode/spawnCrashDiagnostics.ts:111`); ein Account-Profil, ein pro Session gebundener Config-Root oder ein separates HOME für CLI-Spawns war nicht auffindbar. Weil die Spawn-Umgebung vom Prozess-Environment abgeleitet wird, könnte eine extern gesetzte Variable durchgereicht werden, doch das ist kein verwaltetes oder persistentes Accountmodell.

Folglich sind JSONL-Pfad, Login und CLI-Installation faktisch an den aktuellen OS-Benutzerkontext gebunden. Zwei Claude-Accounts können nicht sicher anhand der Nimbalyst-Session unterschieden werden. Auch der Importschlüssel ist nur Session-ID/Workspace, nicht `(Account, Workspace, Claude-ID)`.

## Direkter Vergleich zu WhisperM8s CLI-Host-Ansatz

Die Vergleichsgrundlage ist ausschließlich die Aufgabenbeschreibung: WhisperM8 hostet die echte interaktive Claude-Code-CLI in SwiftTerm-PTYs sowie `claude -p` und `claude --bg`. WhisperM8-Quellcode wurde gemäß Scope nicht gelesen.

| Thema | Nimbalyst | Bewertung für WhisperM8 |
|---|---|---|
| Prozessmodell | Echter CLI-PTY existiert, aber parallel zu einem separaten SDK-Pfad | Gleiches Host-Prinzip im CLI-Pfad; SDK-Mechanik nur als Invariantenquelle nutzen |
| Frische Session | App-ID wird vor Spawn erzeugt und per `--session-id` gepinnt | Stark und direkt übertragbar |
| Resume | JSONL-Existenz schaltet auf `--resume`; keine CLI-ID-Nachprüfung | Zu schwach für WhisperM8s Schmerzpunkte |
| Fork | SDK trennt Fork sauber; echter CLI-Pfad hat keinen belegten `--fork-session`-Übergang | WhisperM8 muss dies explizit im CLI-Wrapper implementieren |
| Import | Scan versteht Provider-ID, Sync upsertet nur nach App-ID | Nicht übernehmen; Duplikatrisiko bei getrennten IDs |
| Cross-Window | Fokus-Gating und Sessionfilter stark; Terminal-Fan-out an alle Fenster | Gute Defense-in-depth, aber Main-seitiges Routing und Writer-Ownership sollten strenger sein |
| PTY-Restore | Sequenzierter Subscribe-before-restore und TUI-Snapshot sehr robust | Prinzip direkt auf SwiftTerm übertragbar, Implementierungsdetails nicht |
| Fehlerdiagnose | SDK trennt echte Expiry von Soft-Signal; CLI-Pfad nicht | SDK-Prinzip um PTY-Ausgabe, Hooks und JSONL herum nachbauen |
| Accounts | Geerbte API-Keys werden entfernt; kein Session-Accountprofil | Für echtes Multi-Account unzureichend |

## Priorisierte übertragbare Muster für WhisperM8

### P0. Explizites, unveränderliches Session-Binding mit Transition

Persistentes Modell pro Wrapper-Session:

```text
appSessionId
workspaceIdentity
accountProfileId
cliSessionId?
transition = fresh | resume | fork
sourceCliSessionId?
processGeneration
```

Zulässige Startpläne:

- Fresh: neue `cliSessionId`, Start mit `--session-id <cliSessionId>`.
- Resume: bestehende `cliSessionId`, Start mit `--resume <cliSessionId>`.
- Fork: neue App-Session, Quelle unverändert, Start mit `--resume <sourceCliSessionId> --fork-session`; die neue von Claude verwendete ID muss danach erfasst werden.

Vor dem Spawn wird der Plan atomar an die neue `processGeneration` gebunden. Nach dem Spawn bestätigt eine autoritative Beobachtung aus Hooks oder Claude-JSONL die tatsächliche ID. Bei Resume muss sie gleich der Ziel-ID sein; bei Fork muss sie eine neue, von der Quelle verschiedene ID sein. Ein Mismatch darf weder das persistente Binding noch die aktive UI-Auswahl überschreiben.

Dieses Muster überträgt Nimbalysts `ProviderSessionManager` und Resume-Mismatch-Prüfung auf den echten CLI-Host, ohne das SDK als Runtime einzuführen.

### P0. Zwei-Phasen-Resume mit enger Fehlerklassifikation

1. **Preflight:** Accountprofil, kanonischen Workspace/CWD und erwarteten JSONL-Pfad bestimmen. Fehlen ist ein lokales Soft-Signal, keine Expiry.
2. **Execution:** Echte CLI mit exakt einem der Identitätsflags starten. PTY-Ausgabe, Exitcode, Hook-Events und JSONL-Identität unter derselben Prozessgeneration sammeln.
3. **Commit:** Binding erst als erfolgreich resumiert markieren, wenn die Ziel-ID bestätigt ist.
4. **Failure:** Nur eine eindeutige `session not found`-Diagnose entwertet Resume. Auth, falscher Account, Datei-/Parsingfehler und generischer Exit behalten die ID und erhalten getrennte Recovery-Aktionen.

Damit wird Nimbalysts richtige SDK-Korrektur – `history.jsonl`-Miss nur als Soft-Signal – auf das CLI-PTY-Modell übersetzt.

### P0. Import-Upsert über eine kanonische Provider-Identität

Import und Live-Sessions müssen denselben eindeutigen Schlüssel benutzen, beispielsweise:

```text
(accountProfileId, canonicalWorkspaceIdentity, cliSessionId)
```

Der Scan darf nicht nur den Status über diesen Schlüssel bestimmen; auch der eigentliche Upsert muss damit die bestehende App-Session auflösen. Erst wenn keine Zuordnung existiert, wird eine neue App-ID erzeugt. Der Import gibt App-IDs zurück und tauscht die aktive Auswahl nicht implizit. Nachrichten werden über stabile Claude-UUIDs, Event-IDs oder persistente Datei-Cursor dedupliziert, nicht über `existingMessageCount`.

Pflichttests: `appID != cliID`, dieselbe CLI-ID in zwei Accounts, Workspace-/Worktree-Alias, stale Index, globale Fallback-Auswahl, Sidecars erscheinen später, wiederholter Import und Teilzeilen oder defekte JSONL.

### P1. Main-seitige Fenster-Ownership plus Event-Hülle

Jedes PTY-/Hook-/JSONL-Event sollte mindestens tragen:

```text
appSessionId, workspaceIdentity, processGeneration, sequence
```

Der Sessioncontroller routet an das besitzende Fenster statt global zu broadcasten. Der Renderer prüft die Hülle ein zweites Mal. Wenn dieselbe Session in mehreren Fenstern sichtbar ist, gibt es genau einen Writer/Owner; weitere Fenster sind Read-only-Beobachter oder müssen Ownership explizit übernehmen. Nimbalysts Fokus-Gating gegen Restart-Stampedes sollte zusätzlich übernommen werden.

### P1. PTY-Restore als Darstellung, Resume als Semantik

- Listener vor Snapshot-Restore registrieren.
- Ausgabe pro Prozessgeneration monoton sequenzieren und während Restore puffern.
- Bei Fullscreen-TUI sichtbaren Screen/Cursor statt blindem Raw-Replay wiederherstellen; anschließend Resize/Repaint auslösen.
- Hidden Mount, langsamen Spawn und genau einen Quick-Exit-Restart explizit behandeln.
- Nach App-Neustart immer einen neuen PTY-Prozess anlegen; Kontinuität nur nach verifiziertem `--resume` behaupten.

### P1. Account als Teil der Session-Identität

Ein `accountProfileId` muss CLI-Executable, HOME oder unterstützten Claude-Config-Root, Loginstatus und JSONL-Discovery binden. Import und Resume dürfen nie außerhalb dieses Profils suchen. API-Keys sind weiterhin aus dem Subscription-CLI-Environment zu entfernen. Falls die installierte Claude-CLI keinen belastbaren alternativen Config-Root unterstützt, sollte Multi-Account explizit als nicht unterstützt gelten oder OS-seitig getrennte Home-Kontexte verwenden; ein stiller Rückfall auf den global eingeloggten Account ist zu vermeiden.

## Nicht auffindbar

- Kein `--fork-session` im echten Electron-CLI-Spawnpfad.
- Keine Verifikation der tatsächlich aktiven Claude-Session-ID nach einem CLI-Spawn.
- Keine semantische Resume-/Session-expired-Fehlerklasse für den echten CLI-PTY-Pfad.
- Kein Test, der beim Import `Nimbalyst app session id != providerSessionId` abdeckt.
- Keine Single-Writer- oder Window-Owner-Lease für einen in mehreren Fenstern sichtbaren CLI-PTY.
- Kein verwaltetes Multi-Account-Profil für die echte Claude-CLI.

Diese Aussagen sind bewusst auf den untersuchten Klon begrenzt; aus nicht gefundenem Code wird keine Funktionalität außerhalb des Klons abgeleitet.
