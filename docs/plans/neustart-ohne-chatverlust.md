# Plan: Neustart ohne Chatverlust

**Stand:** 12.11.2026 · **Status:** Bau läuft seit 12.11.2026 (Pakete 0 und 1, 2 und 3 parallel in eigenen Branches), alle neun Entscheidungen getroffen
**Herkunft:** Wunsch vom 11.11.2026 nach der Wettbewerbsanalyse ([`wettbewerb-orca-t3code/auswahl.md`](wettbewerb-orca-t3code/auswahl.md), Punkt 5)
**Festgelegt vom User (12.11.2026):** kein Warten auf das Ende laufender Chats vor dem Neustart; kein Umweg über Claudes Hintergrund-Agents (`/background`, `claude --bg`, `attach`) als Hauptweg. Gebaut wird der eigene Aufbewahrer: Die Terminal-Leitungen gehen per `SCM_RIGHTS` an einen Aufbewahrer und nach dem Neustart zurück.

## Ziel

Jederzeit `make dev`, später auch jedes App-Update: Alle Chats laufen weiter und stehen danach wieder in ihren Tabs. Ein Chat mitten im Turn arbeitet durch, eine laufende Antwort reißt nicht ab, eine offene Rückfrage bleibt offen. Das gilt für Claude-Chats (mit und ohne GPT-Backend), GPT-Chats, Codex-Chats, Terminal-Tabs und angedockte Hintergrund-Chats. `make dev` wartet dabei auf nichts außer dem eigenen Build.

## Kurzfassung

- **Aufbewahrer:** Vor dem Beenden gibt die App die PTY-Leitung jedes laufenden Chats an einen kurzlebigen Aufbewahrer ab (dasselbe Binary, eigener Modus, ohne AppKit). Der hält die Leitungen, liest die Ausgabe in ein Terminal ohne Fenster und beantwortet Rückfragen der TUIs. Die neue App holt alles zurück, der Aufbewahrer beendet sich. Die Prozesse von `claude`, `codex` und der Shells bleiben dieselben.
- **Router als eigener Dienst:** Der GPT-Router zieht aus der App in einen eigenen kleinen Prozess, der den Neustart gar nicht bemerkt. Nur so muss `make dev` nicht warten, bis laufende Antworten durch sind (Entscheidung 1). Ändert sich der Router selbst, übernimmt eine neue Router-Generation den lauschenden Socket; die alte bringt ihre laufenden Antworten in Ruhe zu Ende, niemand wartet.
- **GPT-Proxy** wird beim Neustart nicht mehr beendet, sondern über eine Registerdatei übernommen.
- **Ursache des Fehlers „zweite Übergabe scheitert“ ist gefunden:** Ein Prozess, der einen Deskriptor per `SCM_RIGHTS` verschickt, hat sich beendet, bevor der Empfänger ihn abgeholt hatte. Mit Empfangsbestätigung liefen 120 von 120 Übergaben fehlerfrei (Abschnitt „Ursache der gescheiterten zweiten Übergabe“). Daraus folgt eine harte Protokollregel.
- **Unterwegs gefunden, sofort beheben:** Jeder Chat-Prozess erbt heute die PTY-Master *anderer* Chats (fehlendes close-on-exec in SwiftTerm). Ein Chat kann damit die Terminals anderer Chats lesen und beschreiben. Das ist unabhängig von diesem Projekt ein Fehler (Paket 0).
- **Rückfall ist immer der heutige Stand plus automatisches Fortsetzen** per `--resume`. Schlechter als heute wird es nie, und es laufen nie zwei Prozesse auf derselben Sitzung.
- Alles hinter einem Labs-Schalter, ab Werk aus. Sieben Pakete, Größe insgesamt L bis XL.

## Was heute passiert (Stand main 5fd0768b)

1. `make dev` baut, dann `_dev_finish`: `kill` (SIGTERM, nach 5 s SIGKILL) → `_install_bundle` (`rsync -a --delete`, ersetzt Dateien per Umbenennen) → `open` (`Makefile:96-108`, `:254-273`).
2. SIGTERM wird zu einem regulären Beenden (`WhisperM8App.swift:244-251`). `applicationShouldTerminate` ruft `endRunCleanly()` (Wiederaufnahme-Marker weg) und `captureAllSnapshotsForAppQuit()`: zweimal Ctrl+C an jeden Chat außer angedockten Hintergrund-Tabs (`AgentTerminalView.swift:472-485`, seit 9945501a).
3. `willTerminate` beendet den GPT-Router und den selbst gestarteten GPT-Proxy samt Profil-Instanzen (`ClaudeCodeProxyManager.swift:302-310`).
4. Mit dem Prozess schließen die PTY-Master, die Chats bekommen SIGHUP.
5. Nach dem Start sind Tabs da, kein Chat läuft. Gestartet wird ein Chat erst, wenn sein Tab angezeigt wird (`AgentSessionDetailView.swift:135-211`).

Neu festgestellt beim Planen:
- **Ein Terminal-Bild wird nicht mehr gesichert.** Der Snapshot wurde am 01.08.2026 ersatzlos entfernt (86696d21). Die Namen `captureAllSnapshotsForAppQuit`/`captureSnapshotForAppQuit` sind Reste, sie rufen nur `flushPendingOutput()` auf.
- **PTY-Master ohne close-on-exec.** SwiftTerm öffnet den Master per `forkpty` ohne `FD_CLOEXEC` (`Pty.swift:97` im Fork). Jeder später gestartete Chat erbt alle offenen Master. Gemessen an der laufenden App: sechs Claude-Prozesse halten je 4 bis 6 PTY-Master (`lsof`, 12.11.2026). Folgen: Ein Chat kann fremde Terminals lesen und beschreiben; beim Beenden hängt das SIGHUP davon ab, in welcher Reihenfolge die Prozesse sterben. Das verletzt die Invariante „Neue Dateideskriptoren close-on-exec“.
- Der Kommentar in `ClaudeCodeProxyOrphanGuard.swift:6-8` („bei SIGTERM läuft kein willTerminate, der Proxy überlebt“) ist veraltet, seit SIGTERM zu einem regulären Beenden wird.

## Architektur

### Bausteine

| Baustein | Prozess | Lebensdauer | Neu oder geändert |
|---|---|---|---|
| App | `WhisperM8.app` | wie heute | Abgabe beim Beenden, Übernahme beim Start |
| Aufbewahrer | `WhisperM8 handover-keeper --root <instanz> --run <id>` | Sekunden bis Minuten: vom Beenden der alten bis zur Übernahme durch die neue App | neu |
| Router-Dienst | `WhisperM8 gpt-router --root <instanz>` | solange das GPT-Backend an ist, über App-Neustarts hinweg | neu, ersetzt den Router in der App |
| GPT-Proxy | `claude-code-proxy serve` (main und Profile) | wie heute, aber beim Neustart nicht mehr beendet | geändert |
| Auslöser | `whisperm8 app handover` (Makefile), Menüpunkt „Neu starten, Chats laufen weiter“, Update-Hinweis | einmalig | neu |

Alle neuen Prozesse starten über `Process` (posix_spawn, close-on-exec als Standard) mit `setsid()`, ohne AppKit und ohne LaunchServices. Damit zählen sie nicht als zweite App-Instanz (`WhisperM8App.swift:15-25`), wie heute schon `agent-supervise`. Sie loggen in das bekannte Subsystem (Kategorie `handover` bzw. `gpt-router`) und zusätzlich in eine Datei unter `Application Support/WhisperM8/handover/`.

### Ablauf bei `make dev`

1. **Bauen** wie heute. Die App läuft weiter.
2. **Übergabe anstoßen:** `_dev_finish` ruft `/Applications/WhisperM8.app/Contents/MacOS/WhisperM8 app handover --timeout 15`. Ist der Labs-Schalter aus, antwortet die App „nicht aktiv“, kennt sie den Befehl nicht oder antwortet sie nicht, läuft der heutige Weg mit `kill`.
3. **Die App gibt ab** (im Hauptthread, vor `.terminateNow`):
   1. Für jeden laufenden Chat: Lesen anhalten, gepufferte Ausgabe verarbeiten, Bild mit Schaltern sichern. Erst danach ist der Stand eingefroren. Die Reihenfolge ist Pflicht, sonst fehlen Bytes oder eine Steuersequenz wird zerschnitten (Vorversuch, Frage 2: 54 von 1.087 Leseblöcken endeten mitten in einer Sequenz).
   2. Aufbewahrer starten und je Chat Begleitdaten, Bild und Leitung übergeben. Jede Leitung bestätigt der Aufbewahrer einzeln.
   3. Erst wenn alle bestätigt sind: Marker auf „übergeben“ setzen, kein Ctrl+C, Proxy nicht beenden, Stores festschreiben, Control-Socket und Lock freigeben, beenden.
   4. Scheitert ein Schritt: Abbruch, der Aufbewahrer gibt seine Kopien frei, die App beendet sich auf dem heutigen Weg, setzt aber den Marker „fortsetzen“. Die Chats starten danach per `--resume`.
4. **rsync und `open`** wie heute. Der Aufbewahrer läuft aus dem alten Binary weiter. rsync ersetzt die Dateien per Umbenennen, der laufende Prozess behält seine Datei.
5. **Die neue App übernimmt** früh in `applicationDidFinishLaunching`, vor Absturz-Wiederaufnahme, `markStaleRunningSessionsClosed`, Aufräumen alter Event-Dateien und dem ersten Statusscan. Für jeden Chat: Bild und gesammelte Ausgabe ins Terminal, Leitung übernehmen, Größe setzen (die TUI zeichnet neu), Controller als laufend eintragen. Danach beendet sich der Aufbewahrer.

Gemessen im Vorversuch: Sichern 26 ms je Chat im Debug-Build, Einspielen 130 ms. Bei zehn Chats dauert die Übergabe also unter einer Sekunde.

### Der Aufbewahrer

- **Start:** von der alten App, nur für eine Übergabe. Höchstens ein Aufbewahrer je Instanz-Wurzel (Lock-Datei mit `flock`). Die Test-Instanz hat ihren eigenen.
- **Was er hält:** je Chat den PTY-Master, die Begleitdaten (siehe Protokoll) und ein **SwiftTerm-Terminal ohne Fenster**, gefüttert erst mit dem Bild, dann mit allem, was der Chat in der Lücke schreibt. Damit gibt es keine Puffergrenze: Die neue App bekommt nicht einen Byte-Haufen, sondern ein frisches Bild vom Stand der Übergabe.
- **Rückfragen der TUIs:** Codex fragt beim Start und nach Größenänderungen die Cursorposition ab, beide TUIs fragen Farben und Fähigkeiten (Vorversuch: `ESC[6n`, OSC 10/11, DA, Kitty-Abfrage). Das Terminal im Aufbewahrer beantwortet sie wie die App. Dabei gilt dieselbe Regel wie im `AgentTerminalLinkInterceptor`: **Zwischenablage-Lesen per OSC 52 wird verweigert.**
- **Prozessende in der Lücke:** über `kqueue` (`NOTE_EXIT | NOTE_EXITSTATUS`). Ende und Exit-Code werden vermerkt, das letzte Bild bleibt erhalten. Die neue App zeigt den Chat dann als beendet mit seiner letzten Ausgabe.
- **Ende:**
  - alle Chats übernommen und bestätigt → sofort;
  - keine App meldet sich → nach einer Frist geordnet beenden (Entscheidung 2): zweimal Ctrl+C an TUIs wie heute, Leitungen schließen, Marker „fortsetzen“ bleibt. Der nächste App-Start setzt per `--resume` fort;
  - SIGTERM → wie Fristende;
  - Absturz des Aufbewahrers → die Leitungen schließen, die Chats bekommen SIGHUP und enden. Der Marker steht auf „übergeben“, die neue App findet keinen Aufbewahrer und setzt per `--resume` fort. Das ist der heutige Stand nach einem Absturz.
- **Wer ihn beendet:** er sich selbst; `make kill` und `test-instance.sh stop` müssen ihn ausnehmen; `make clean-install` (`pkill -9 -f WhisperM8`) trifft ihn absichtlich.
- **Sicherheit:** Socket in einem 0700-Ordner der Instanz (Muster `AgentControlServer`, Pfad unter 104 Zeichen). Der Aufbewahrer prüft die Gegenseite per `getpeereid` (gleiche UID) und per `proc_pidpath` (gleiches Binary wie das Bundle der Instanz). Tokens liegen nur im Speicher von Aufbewahrer und App, nie auf der Platte.

### Übergabeprotokoll

Unix-Socket, Nachrichten als Länge plus JSON, Deskriptoren per `SCM_RIGHTS` an der Nachricht, große Daten (Bilder) direkt danach im Strom.

**Harte Regel (aus der Fehlersuche):** Wer einen Deskriptor verschickt, schließt ihn und beendet sich erst, wenn der Empfänger ihn mit `ACK` bestätigt hat. Ohne diese Regel kann der Kernel einen Deskriptor, der noch im Socket steckt, beim Aufräumen für verwaist halten und den Socket dauerhaft lahmlegen. Bei einer PTY-Leitung hieße das im schlimmsten Fall: Leitung zu, Chat tot.

| Phase | Richtung | Nachrichten |
|---|---|---|
| Abgabe | alte App → Aufbewahrer | `HELLO {protokoll, build, appPid}` → `OK`; je Chat `DEPOSIT {manifest}` + Leitung + Bild → `ACK {chat}`; `COMMIT` → `OK` (oder `ABORT`) |
| Übernahme | neue App → Aufbewahrer | `HELLO {protokolle: [min, max], build}` → `OK {protokoll}` oder `INCOMPATIBLE`; `LIST` → Manifeste samt Ende-Status; je Chat `TAKE {chat}` → Aufbewahrer hält das Lesen an, sichert sein Terminal-Bild, schickt `CHAT {manifest}` + Leitung + Bild → App `ACK {chat}` → Aufbewahrer schließt seine Kopie; `DONE` |
| Freigabe | neue App → Aufbewahrer | `RELEASE` bei unverträglicher Version oder gescheiterter Übernahme: geordnet beenden wie bei Fristende, die App setzt danach per `--resume` fort |
| Status | CLI → Aufbewahrer | `STATUS` für `whisperm8 app handover-status` |

**Manifest je Chat** (Felder werden nur ergänzt, nie umbenannt):
- Sitzungs-ID in WhisperM8 und Art (Claude, Codex, Terminal, Attach);
- PID samt Startzeit (gegen wiederverwendete PIDs, `ProcessStartTime`);
- das vollständige `AgentLaunchCommand` (Tastaturprofil, Attach-Kennung, `sendsInterruptOnStop`);
- das Control-Token, Spalten und Zeilen, Fenstertitel;
- Hook-Cursor (Byte-Position in der Event-Datei);
- Arbeitet-seit für Statistik und Wach-Knopf;
- Entwurf-im-Eingabefeld, vorgemerkter Kontowechsel, Konto- und GPT-Profil;
- externe Sitzungs-ID von Claude oder Codex.

**Versionen:** Die neue App spricht das eigene Protokoll und das vorige. Passt nichts, gilt `RELEASE`. Das Bild ist ein ANSI-Strom und damit unabhängig von der Version.

### Bild und Schalter

Ein Serialisierer (neu, im SwiftTerm-Fork) schreibt den Puffer als ANSI-Strom:
- Zeilen mit Umbruchmarken, Farben (256 und TrueColor), Stile, Unterstreichungsart;
- Alt-Screen samt Inhalt des Hauptpuffers, Cursor;
- die Schalter, die TUIs nur beim Start setzen: Kitty-Tastaturprotokoll (Claude Stufe 5, Codex Stufe 7), Mausmodus samt SGR-Kodierung, Bracketed Paste, Fokus-Meldungen, Cursor sichtbar, Application Cursor/Keypad.

Im Vorversuch war das Bild nach dem Einspielen bei Claude und Codex mit 0 abweichenden Zellen identisch, auch bei Übernahme mitten in einer Antwort (260 von 260 Messpunkten). Ohne Schalter kommen Shift+Enter und Mausklicks nach der Übernahme falsch an. Größe und Scrollback bleiben wie in der App. Nicht im Bild enthalten sind Bilder im Terminal (Sixel, Kitty-Grafik); sie fehlen nach der Übernahme, was bei Claude und Codex nicht vorkommt.

### Rückholen in die neue App

- **SwiftTerm-Fork:** zwei neue Wege in `LocalProcess`:
  - `detachForHandover() -> fd`: Lesen anhalten, ausstehende Blöcke verarbeiten, Master per `dup` zurückgeben, ohne zu schließen und ohne Signal;
  - `adopt(masterFd:pid:)`: Lesen starten, Ende über `kqueue` mit Exit-Code, `running = true`.
  
  Dazu:
  - `processTerminated` meldet für fremde Prozesse keinen erfundenen Status 0 (heute `waitpid` → ECHILD → 0, `LocalProcess.swift:365-370`);
  - nach dem Einrichten der Überwachung prüft `kill(pid, 0)` samt Startzeit, ob der Prozess vorher schon gestorben ist.
- **Controller ohne View:** Heute entsteht ein Controller nur über `startController` mit `forkpty`, und das Prozessende wird über Closures der View gemeldet (`AgentSessionDetailView.swift:531-536`). Neu sind `AgentTerminalRegistry.adoptController(...)` und eine Ende-Meldung, die in Registry und Status-Koordinator lebt, nicht in der View. Das ist der größte Umbau auf App-Seite. Er nützt auch Grid-Panes, die nie angezeigt wurden.
- **Tabs:** Die View findet den übernommenen Controller über die Registry. `allowsTriggeredLaunch(controllerIsRunning: true)` verhindert schon heute einen zweiten Start.

### Router-Dienst und GPT-Proxy

**Warum der Router aus der App zieht:** Der Router in der App kann eine laufende Antwort nur zu Ende bringen, solange die App lebt. Ein Abriss mitten in der Antwort kostet den Turn (Vorversuch: Claude wiederholt nicht, und „mach weiter“ fängt von vorn an). Bleibt der Router in der App, müsste `make dev` warten, bis alle laufenden Antworten durch sind. Gemessen waren das 24 und 35 s, einzelne Antworten liefen 170 s. Genau dieses Warten ist ausgeschlossen. Ein eigener Router-Prozess merkt vom App-Neustart nichts. Selbst Anfragen aus der Lücke werden sofort bedient.

- **Lauschen auf BSD-Sockets** statt `NWListener`. Das ist in jedem Fall nötig: Network.framework kann keinen vorhandenen Socket übernehmen, weder `NWListener` noch `NWConnection`. Vorlage ist der Control-Server (`AgentControlServer.swift`: `socket`/`bind`/`listen`, `DispatchSourceRead`). Die HTTP-Logik (Kopfzeilen, Modellwahl, Token, Profil-Routing, Fehlerkörper, Überlauf-Probe) bleibt; ausgetauscht wird nur die Ein- und Ausgabe von `ClientConnection`.
- **Einstellungen:** Der Router liest heute schon alles über Resolver aus `AppPreferences`, der Token-Datei und dem Codex-Katalog. Ein Prozess aus dem App-Binary liest dieselbe Defaults-Domain (wie `agent-supervise`; in Paket 3 als Erstes prüfen, auch für die Test-Instanz mit eigener Bundle-ID). Neu ist nur die Profil-Portliste, die aus der Registerdatei des Proxys kommt (unten). Braucht ein Profil eine Instanz, die nicht läuft, meldet der Router das wie heute mit 503 und bittet die App über den Control-Socket, sie zu starten.
- **Neue Router-Version:** Beim Start fragt die App den Router-Dienst nach seinem Build. Ist er älter, startet sie eine neue Generation mit `--take-over`. Die holt sich den lauschenden Socket direkt von der alten (mit `ACK`, siehe Regel). Die alte nimmt nichts Neues mehr an, bringt laufende Antworten zu Ende und beendet sich. Niemand wartet.
- **Absturz des Router-Dienstes:** Die App überwacht ihn per `kqueue` und startet ihn neu. In der Lücke lehnt der Port Verbindungen ab, und Claude wiederholt bis etwa 3 Minuten (Vorversuch). Eine Antwort, die gerade strömt, ist verloren. Das ist der seltene Fall.
- **Ende:** wenn das GPT-Backend ausgeschaltet wird und bei echtem Beenden der App (Cmd+Q ohne Neustart). Dann gilt Auslaufen wie bei der Generationsübergabe.
- **GPT-Proxy:** Bei einer Übergabe beendet `willTerminate` den Proxy nicht mehr. Die App schreibt main- und Profil-Instanzen in `gpt-proxies.json` (PID, Startzeit, Port, Profil, Binary). Die neue App übernimmt sie nach Prüfung von PID und Startzeit als selbst gestartet. Damit funktionieren „Proxy stoppen“ und „Zum Hauptkonto machen“ weiter, und keine Profil-Instanz wird doppelt gestartet.
- **Waisen-Guard:** Er ersetzt keinen übernommenen Proxy. Das passt zur Invariante „Der GPT-Proxy wird zur Laufzeit nie neu gestartet“. Ein neueres Proxy-Binary wirkt erst beim nächsten echten Neustart, wenn kein GPT-Chat läuft.

### Je Chat-Art

| Art | Was passiert | Besonderheit |
|---|---|---|
| Claude, ohne GPT-Backend | Leitung übergeben, Claude spricht direkt mit Anthropic | nichts weiter |
| Claude, mit GPT-Backend (auf diesem Mac alle) | Leitung übergeben, Router-Dienst läuft durch | ist der Labs-Schalter aus, gilt die Router-Lücke aus dem Vorversuch |
| GPT-Chat | wie Claude mit GPT-Backend; Profil-Header ist in der Umgebung des Prozesses fest | Proxy-Register |
| Codex | Leitung übergeben; Rückfragen beantwortet der Aufbewahrer | Der Codex-Hintergrunddienst (`app-server`, hier 0.167.1 bei CLI 0.160.1) ist davon unabhängig, die TUI behält ihre Verbindung zu ihm |
| Terminal-Tab | Leitung übergeben, die Shell und laufende Befehle (Build, `top`, Server) laufen weiter | heute enden Shells und werden nicht fortgesetzt; das wird erstmals besser |
| Angedockter Hintergrund-Chat (`claude attach`) | wie alle anderen übergeben (Entscheidung 7) | Der Worker im Claude-Daemon überlebt ohnehin; scheitert die Übergabe, dockt der vorhandene Fallback neu an |
| Hintergrund-Shells, Monitore, Subagents eines Chats | laufen weiter, weil der Claude-Prozess weiterläuft | |

### Identität, Hooks, Status

- **Tokens:** Das Control-Token jedes Chats geht im Manifest mit. Die neue App trägt es wieder ein (`AgentSessionTokenRegistry`, neue Funktion `register(token:for:)`). Sonst scheitern alle `whisperm8 chats`-, `board`- und `speak`-Aufrufe aus überlebenden Chats (`AgentControlRequestHandler.swift:41-45`).
- **Hooks:** Claude hängt Ereignisse unabhängig von der App an die Event-Datei an, die Lücke ist auf der Platte vollständig. Die neue App ruft für übernommene Chats **kein** `prepareSettingsFile` auf, sonst wäre die Datei leer. Sie liest ab dem übergebenen Cursor weiter statt ab 0, sonst kämen alte Ereignisse samt Fertig-Meldungen ein zweites Mal (`ClaudeHookBridge.swift:104-105`, `:138`).
- **Status:** Übernommene Sitzungen gelten sofort als laufend. Registry-Einträge (`sessions/<pid>.json`), die der erste Scan wegen fehlendem Terminal verworfen hat, werden nach der Übernahme neu gelesen (`AgentSessionStatusCoordinator.swift:603-625`). Die PID bleibt gleich, Ressourcenansicht, Prozessbaum und Jobzuordnung gelten weiter.
- **Ansagen und Notch:** In der Lücke gibt es keine Ansagen. Was in der Lücke fertig wurde, holt die neue App als Status nach, ohne Ansage (Entscheidung 5).
- **Statistik und Wach-Knopf:** „Arbeitet seit“ geht im Manifest mit, damit Zeiten stimmen und der Wach-Knopf nicht kurz abfällt.

### Prompt-Queue, Entwurf, Kontowechsel

- **Prompt-Queue:** Die Aufträge liegen schon in einer Datei. Ein Turn-Ende in der Lücke würde verloren gehen, deshalb prüft die neue App nach der Übernahme jeden ruhenden Chat einmal auf ausstehende Aufträge.
- **Entwurf im Eingabefeld:** Das Flag geht im Manifest mit. Ist es unbekannt, gilt „Entwurf vorhanden“. Sonst könnte die Queue oder `chats send` in einen halb getippten Text schreiben (`TerminalComposerDraftTracker.swift:36/41`).
- **Kontowechsel nach dem Turn:** Der vorgemerkte Wechsel (heute nur im Speicher, `AccountSwitchCoordinator.pending`) geht im Manifest mit (Entscheidung 9).

### Absturz-Wiederaufnahme und Schutz vor Doppelstarts

Der Marker bekommt einen dritten Zustand neben „sauber beendet“ und „fortsetzen“: **„übergeben“** mit PID des Aufbewahrers und je Chat PID samt Startzeit. Beim Start gilt:

1. Der Aufbewahrer lebt und spricht ein verträgliches Protokoll → übernehmen.
2. Der Aufbewahrer lebt nicht, ist unverträglich oder eine Übernahme scheitert → für jeden Chat prüfen, ob sein Prozess noch lebt. Nur tote Chats werden per `--resume` fortgesetzt. Lebt ein Prozess noch, wird er zuerst geordnet beendet (über den Aufbewahrer, sonst per Signal) und erst nach seinem Ende fortgesetzt.
3. **Neue harte Sperre vor jedem `--resume`**, auch außerhalb dieses Features: Gibt es in Claudes Registry einen lebenden Prozess mit derselben Sitzungs-ID, startet kein zweiter. Heute schützt der Builder nur vor Hintergrund-Workern (`AgentCommandBuilder.swift:766-790`). Zwei Prozesse auf einer Sitzung wären der schlimmste Fehler dieses Vorhabens.

`markStaleRunningSessionsClosed`, das Aufräumen alter Event-Dateien (`AgentSessionRetentionService.pruneAtLaunch`) und der Absturz-Koordinator laufen erst nach der Übernahme und kennen die übernommenen Sitzungen.

### Cmd+Q, Neustart-Menü, App-Update per Brew

- **Cmd+Q bleibt echtes Beenden** mit dem heutigen Dialog (Entscheidung 3).
- **Neuer Menüpunkt „Neu starten, Chats laufen weiter“:** Übergabe wie bei `make dev`. Danach startet der Aufbewahrer die App selbst neu (`open` auf das Bundle der Instanz), weil die alte App nach dem Beenden nichts mehr anstoßen kann.
- **Update per Brew:** Der Cask beendet die App nicht, er ersetzt das Bundle unter der laufenden App (kein `uninstall quit:`, `scripts/update-cask.sh:40-53`). Die App erkennt beim Aktivieren, dass die Version auf der Platte neuer ist als die laufende, und zeigt „Update installiert, neu starten, Chats laufen weiter“. Das ist derselbe Weg wie der Menüpunkt. Ein Selbst-Update gibt es nicht und kommt hier auch nicht hinzu.
- **Labs-Schalter** `restartKeepsChatsEnabled` in der Labs-Gruppe der Einstellungen, ab Werk aus. Neuer Eintrag in der Kill-Switch-Liste von `CLAUDE.md`. Ist er aus, laufen Router, Proxy und Beenden wie heute.

## Fehlerfälle

| Fall | Was passiert | Ergebnis für den User |
|---|---|---|
| Aufbewahrer stirbt vor der Übernahme | Leitungen zu, Chats bekommen SIGHUP und enden; neue App findet Marker „übergeben“ ohne Aufbewahrer und setzt per `--resume` fort | wie heute nach einem Absturz, Turns in der Lücke verloren, Tabs kommen von selbst wieder |
| Aufbewahrer stirbt mitten in der Übernahme | bestätigte Chats laufen in der App, die übrigen enden und werden fortgesetzt | teilweise wie heute |
| Neue App startet nicht (Build kaputt, Absturz beim Start) | Aufbewahrer hält, liest mit, beantwortet Rückfragen; `whisperm8 app handover-status` zeigt den Stand; nach der Frist geordnet beenden (Entscheidung 2) | Chats arbeiten unsichtbar weiter, bis die App kommt oder die Frist abläuft |
| Version wechselt, Protokoll unverträglich | `RELEASE`: geordnet beenden, danach `--resume` | wie heute plus automatisches Fortsetzen |
| Zweimal `make dev` hintereinander, die neue App übernimmt noch | `app handover` antwortet „belegt“, das Makefile wartet bis zu 15 s und versucht es erneut | normale zweite Übergabe |
| Zweimal `make dev`, die neue App ist noch nicht gestartet | kein App-Prozess, `kill` hat nichts zu tun, rsync, `open`; die neue App übernimmt vom ersten Aufbewahrer (gleiches Protokoll oder das vorige) | normal |
| Zweiter Aufbewahrer, während der erste noch Chats hält | verhindert über die Lock-Datei; die App gibt nur ab, wenn kein Aufbewahrer mit unübernommenen Chats lebt, sonst heutiger Weg mit Marker „fortsetzen“ | sicher |
| App stürzt ab statt sauber zu beenden | keine Übergabe möglich; nach dem close-on-exec-Fix bekommen alle Chats sauber SIGHUP; Wiederaufnahme wie heute | wie heute (ein Dauer-Halter würde das abdecken, siehe unten) |
| Übergabe hängt | eigene Frist in der App (z. B. 8 s), danach `ABORT` und heutiger Weg; das Makefile beendet nach 15 s wie heute | wie heute plus automatisches Fortsetzen |
| PID wiederverwendet | Startzeit im Manifest passt nicht → kein Übernehmen dieses Prozesses, Fortsetzen per `--resume` | sicher |
| Router-Dienst stirbt | App startet ihn neu; Claude wiederholt abgelehnte Verbindungen bis etwa 3 min, eine gerade strömende Antwort ist verloren | selten, ein Turn |
| Proxy stirbt | wie heute | wie heute |
| Chat endet in der Lücke | Aufbewahrer vermerkt Exit-Code, letztes Bild bleibt; die App zeigt „beendet“ | korrekt |

Nicht abgedeckt und bewusst nicht Teil dieses Plans: der Absturz der App selbst. Das deckt erst ein Dauer-Halter ab, bei dem jedes Terminal immer über ein Zwischenstück läuft. Aufbewahrer, Protokoll und Übernahme sind dafür wiederverwendbar.

## Ursache der gescheiterten zweiten Übergabe

**Befund:** Wird ein lauschender TCP-Socket per `SCM_RIGHTS` weitergereicht und beendet sich der Sender, bevor der Empfänger die Nachricht abgeholt hat, ist der Socket danach in vielen Fällen dauerhaft kaputt. Der Kernel nimmt Verbindungen noch an, aber jede angenommene Verbindung ist sofort tot (`getpeername` → `EINVAL`, der Client bekommt `ECONNRESET`). Der Fehler bleibt in allen folgenden Generationen, er hängt am Socket, nicht am Prozess.

**Versuche** (Scratchpad, eigener Steuerprozess, nur `127.0.0.1`, je Kette sechs Generationen alt → Aufbewahrer → neu, jede Generation ein eigener abgekoppelter Prozess):

| Variante | Ergebnis |
|---|---|
| Aufbewahrer und alte Generation beenden sich direkt nach dem Senden (wie im Vorversuch) | 15 Ketten: nur 4 fehlerfrei; die übrigen scheitern ab Generation 2 bis 6 und bleiben kaputt |
| dasselbe mit schlichter `accept`-Schleife statt Pythons `socketserver` | 10 Ketten: 1 fehlerfrei |
| neue Generation ruft nach der Übernahme `listen()` erneut auf | keine Besserung (4 von 15) |
| Aufbewahrer bleibt nach dem Senden am Leben | 10 von 10 fehlerfrei |
| **Empfänger bestätigt, Sender schließt erst danach** | **20 von 20 Ketten fehlerfrei (120 von 120 Übergaben)** |

Widerlegt: `socketserver`, nicht blockierende Flags (alle Sockets blockierend gemessen), der Prozess als „letzter Benutzer“ des Sockets.

**Erklärung:** Ein Deskriptor, der noch in einem Unix-Socket steckt, gehört keinem Prozess. Schließt der Sender seine Seite, räumt der Kernel solche Deskriptoren auf. Hält er sie dabei für unerreichbar, leert er den Socket und markiert ihn als „empfängt nichts mehr“. Die Erklärung passt zu allen Messungen: zufällig, weil sie vom Zeitpunkt des Aufräumens abhängt; dauerhaft, weil die Markierung am Socket bleibt; nie mit Bestätigung. Im Kernel direkt beobachtet habe ich das nicht.

**Folge:** Protokollregel `ACK` vor Schließen, für Router-Sockets und für PTY-Leitungen. Im Vorversuch zu Frage 0 hatte die alte App zufällig auf eine Antwort gewartet, deshalb fiel es dort nicht auf. Pflichttest bleibt mehrfaches `make dev` hintereinander.

## Impact-Analyse

Gelesen auf main 5fd0768b. „Test da“ nennt vorhandene Tests, die den heutigen Stand halten; „Test fehlt“ ist vor dem Umbau zu schreiben (Paket 0), soweit es den heutigen Stand betrifft, sonst im jeweiligen Paket.

| Bereich | Stelle | Heute | Änderung | Tests |
|---|---|---|---|---|
| PTY öffnen | SwiftTerm `Pty.swift:97` | Master ohne close-on-exec | `FD_CLOEXEC` setzen | fehlt: Master hat close-on-exec; kein Chat erbt fremde Master |
| PTY Ende | `LocalProcess.swift:365-370`, `:515-522` | `waitpid` + Prozessquelle; fremde PID ergibt Status 0 | `kqueue` mit Exit-Code, Prüfung nach dem Einrichten | fehlt (Fork) |
| PTY Abgabe/Übernahme | `LocalProcess.swift:349-362`, `:546-571` | `deinit`/`terminate` schließen den Master | `detachForHandover`, `adopt` | fehlt (Fork) |
| Größe | `MacLocalTerminalView.swift:97-103` | TIOCSWINSZ nur bei `running` | nach `adopt` gilt `running` | fehlt |
| Beenden | `AgentTerminalView.swift:472-485` | Ctrl+C an alle außer Attach | im Übergabemodus nichts senden | da: `testAttachClientsGetNoInterruptOnStop`; fehlt: heutiges Ctrl+C an TUI-Chats beim SIGTERM-Quit |
| Controller | `AgentTerminalView.swift:395-418`, `AgentSessionDetailView.swift:531-536` | nur `startController`; Ende über View-Closures | `adoptController`, Ende in Registry/Koordinator | da: `AgentTerminalRegistryTests` (terminateAll); fehlt: Ende-Meldung ohne View |
| Quit-Entscheidung | `WhisperM8App.swift:512-554` | System-Quit → fortsetzen; Cmd+Q mit Dialog; sonst `endRunCleanly` | Übergabe vor `.terminateNow`, Marker „übergeben“ | da: `QuitConfirmationTests`, `testKeepForResumeLeavesMarkerWithRunningChats`; fehlt: Entscheidungstabelle als reine Funktion |
| Proxy beim Beenden | `ClaudeCodeProxyManager.swift:302-310` | beendet main + Profile | bei Übergabe nicht; Register schreiben | da: `testWillTerminateStopsOnlySelfStartedProxy` |
| Proxy übernehmen | `ClaudeCodeProxyManager.swift:178`, `:250`, `:646-662` | Handles nur im Speicher; fremder Proxy = `.external` | Register `gpt-proxies.json` | da: `testInstanceOriginForMainDistinguishesSelfStartedExternalAndNotRunning`; fehlt: Leck von Profil-Instanzen nach Neustart |
| Waisen-Guard | `ClaudeCodeProxyOrphanGuard.swift`, `WhisperM8App.swift:439-446` | ersetzt veraltete Waisen | übernommene nie | da: 10 Tests in `ClaudeCodeProxyOrphanGuardTests` |
| Router | `ClaudeGPTMixRouter.swift:265-419`, `:757-1050`, `:1328-1355` | `NWListener`/`NWConnection` in der App, `stop()` ohne Auslaufen, Upstream-Frist 600 s | BSD-Sockets, eigener Prozess, Auslaufen, Generationsübergabe | da: `ClaudeGPTMixRouterTests` (Kopfzeilen, Token, 503, Modelle); fehlt: Ende-zu-Ende-Strom über lokalen Upstream (vor dem Umbau!) |
| Router-Start | `ClaudeCodeProxyManager.swift:376-387` | Router-Fehler beendet frisch gestarteten Proxy | Router-Dienst statt `routerStarter` | da: `testRouterFailureTerminatesProcessStartedBySameAttempt` |
| Tokens | `AgentSessionTokenRegistry.swift:18` | nur im Speicher | Token im Manifest, `register(token:for:)` | da: `ChatsControlTests`, `ChatsAddressAuditTests`; fehlt: Token übersteht Übergabe |
| Control-Server | `AgentControlServer.swift:120-160` | Lock + Retry | Aufbewahrer hält nie den Lock; neuer Befehl `app handover` mit eigener Frist | da: `AgentControlServerHardeningTests` |
| Hooks | `ClaudeHookBridge.swift:104-105`, `:138` | prepare leert Event-Datei; Tracking ab 0 | bei Übernahme kein prepare, Tracking ab Cursor | fehlt: heutiges Replay-Verhalten, dann Cursor-Übernahme |
| Registry-Status | `AgentSessionStatusCoordinator.swift:181`, `:603-625` | Eintrag nur mit eigenem Terminal | Neuscan nach Übernahme | da: `testRecordWithoutOwnTerminalIsIgnored` |
| Wiederaufnahme | `AgentCrashRecovery.swift:58-178` | zwei Zustände | dritter Zustand „übergeben“ | da: `testSecondInstanceNeitherStealsNorDeletesRunningAppsMarker`, `testAfterCrashFlagsResume…` |
| Doppelstart | `AgentCommandBuilder.swift:766-790` | schützt nur vor Hintergrund-Workern | Sperre über Registry mit lebender PID | fehlt: heutiges Verhalten + neue Sperre |
| Aufräumen | `AgentSessionStore.swift:593-603`, `AgentSessionRetentionService.swift:51-62` | schließt `.running` ohne Controller; löscht alte Event-Dateien | nach der Übernahme, übernommene ausgenommen | da: `AgentSessionStoreTests` (:453/:473), `testPruneAtLaunchProtectsChatsAboutToResume` |
| Prompt-Queue | `AgentPromptQueueStore.reconcileOnLaunch`, `AgentPromptQueueDelivery.swift:58-75` | Zustellung nur bei Turn-Ende | Anstoß nach Übernahme | da: `testReconcileOnLaunchMarksInterruptedDelivery`, `testRestartMarksInFlightAsUnknownNotPending` |
| Entwurf | `TerminalComposerDraftTracker.swift:36/41` | startet mit „kein Entwurf“ | Wert aus dem Manifest, sonst „Entwurf“ | fehlt |
| Kontowechsel | `AccountSwitchCoordinator.swift:58` | nur im Speicher | im Manifest | fehlt |
| Ende fremder Kinder | `AccountMoveStopResume.swift:157-162` | Reaper räumt bei ECHILD auf | passt | da: `testReaperCollectsZombie` |
| Statistik | `StatisticsCollectors.swift:117-118` | beim Start arbeitet nichts | „arbeitet seit“ übernehmen | fehlt |
| Fenster | `AgentWindowStore.swift:59-65` | offene Tabs beim Start | unverändert | da: `testSuspendedCloseTrackingKeepsWindowForRestore` |
| Makefile | `Makefile:96-108`, `:252` | `kill` trifft alles auf `/WhisperM8` außer `agent-supervise` | `app handover` vor `kill`; Aufbewahrer und Router-Dienst ausnehmen | fehlt: Test, der die Ausnahmen in `GUI_PIDS` prüft (wie `DocsLintTests`) |
| Test-Instanz | `scripts/test-instance.sh:34-38` | `pids()` über `comm` trifft jeden Prozess des Binarys | Aufbewahrer und Router-Dienst ausnehmen; neues `restart --keep-chats` | – |
| Lokalisierung | neue Texte (Menüpunkt, Update-Hinweis, Labs) | – | Englisch + Deutsch | `LocalizationCatalogTests` |
| Einstellungen | `PreferenceBedienweg.swift` | – | Labs-Schalter mit UI-Weg | `PreferenceBedienwegGuardTests` |

## Tests vor dem Umbau (Feature-Erhalt)

Diese Tests halten den **heutigen** Stand fest und laufen grün auf main, bevor eine Zeile Feature-Code entsteht. Sie gehören in Paket 0.

1. Beenden per SIGTERM: Ctrl+C an Claude-, Codex- und Terminal-Controller, keins an Attach-Clients, Marker danach „sauber beendet“. Als reine Entscheidungsfunktion herausziehen, ohne AppKit.
2. Cmd+Q-Entscheidung: Dialog nur bei arbeitenden Chats, System-Quit setzt „fortsetzen“.
3. Hook-Bridge: `prepareSettingsFile` legt eine leere Event-Datei an, `startTracking` liest ab 0. Damit ist das spätere Abweichen sichtbar.
4. Builder: `--resume` wird für eine Sitzung gebaut, auch wenn ein Vordergrund-Prozess mit derselben Sitzungs-ID in der Registry steht. Der Test hält den heutigen Stand fest; die Sperre aus Paket 0 kehrt ihn danach bewusst um.
5. Router Ende zu Ende: Ein lokaler Upstream streamt SSE, der Router reicht Kopfzeilen, Chunks und Abschluss unverändert durch. Auch ein 401 ohne Token und ein 503 für ein unbekanntes Profil gehören dazu. Das ist die Abnahme für den Wechsel auf BSD-Sockets.
6. Proxy: `willTerminate` beendet main und Profile; die App startet nach einem Neustart eine Profil-Instanz neu (heutiges Leck sichtbar machen).
7. Prompt-Queue: Zustellung nur bei Turn-Ende.
8. Makefile: `GUI_PIDS` nimmt `agent-supervise` aus (Textprüfung). Neue Ausnahmen kommen später dazu.
9. Statusquelle: Registry-Eintrag ohne eigenes Terminal wird verworfen (vorhanden, Ergänzung um „Eintrag kommt später“).

### Stand nach Paket 0 (12.11.2026)

- Erledigt: 2 (Cmd+Q-Dialog, vorhandene Tests), 3 (Hook-Bridge), 4 (Sperre gegen Doppelstart, jetzt umgesetzt), 5 (Router-Strom, `testRouterDispatchesToBothLocalUpstreamsAndStreamsResponses`), 7 (Prompt-Queue, vorhandene Tests), 8 (Makefile).
- Teilweise: 1. Ctrl+C an Chats, keins an angedockte Tabs und eine gemeinsame Wartezeit sind getestet. Die Marker-Entscheidung beim SIGTERM-Quit als reine Funktion fehlt noch und kommt in Paket 4, wo sie sich ändert.
- Verschoben: 6 (Leck von Profil-Proxys) nach Paket 3, 9 (Registry-Eintrag kommt nach dem Terminal) nach Paket 4.

### Nachträge aus dem Review von Paket 0

1. **Deskriptoren im Kind schließen.** Das Kind schließt vor `execve` alle Deskriptoren ab 3. close-on-exec am Master deckt nur die eigenen PTYs ab. Jeder Deskriptor, der ohne das Flag entsteht (fremde Bibliotheken, per `SCM_RIGHTS` empfangene Leitungen im Aufbewahrer), würde sonst weiter vererbt. Gilt für den Fork (Paket 1) und für den Aufbewahrer (Paket 2).
2. **Sperrmeldung mit Ort und Aktionen.** Die Meldung nennt heute nur die PID. Besser: wo die Sitzung läuft (anderer Tab, Terminal außerhalb der App) und eine Aktion wie „Zum Chat wechseln“. Kommt mit Paket 4.
3. **Fehlende Tests.**
   - Neustart eines Tabs über den echten Weg (Beenden, sofort neu bauen, Sperre greift nicht).
   - Die offenen Punkte oben.
   - Die Makefile-Prüfung ist eine Textprüfung und damit fragil. Sie wird ersetzt, sobald `GUI_PIDS` in Paket 4 ohnehin umgebaut wird.

### Stand nach Paket 1 (12.11.2026)

Fork-Branch `whisperm8-handover` (auf `whisperm8-pty-cloexec`), Pin in `Package.swift`. Was Paket 2 und 4 davon nutzen:

- **`Terminal.serializeScreen() -> [UInt8]`:** Bild und Schalter als ANSI-Strom. Einspielen heißt: frisches Terminal mit gleichen Spalten, Zeilen und gleichem Scrollback, Strom per `feed(byteArray:)`, sonst nichts. Eine am Ende angeschnittene Steuersequenz oder ein angeschnittenes UTF-8-Zeichen hängt der Strom selbst an; dafür merkt sich jedes Terminal seine letzten 32 KB Eingabe. Der Aufrufer muss den Schnittpunkt also nicht sauber wählen. Nicht enthalten: Bilder (Sixel, Kitty), Paletten-Änderungen (OSC 4), linke und rechte Ränder, Zeichensatz-Umschaltungen, ein offener Umbruch genau am rechten Rand.
- **`LocalProcess.detachForHandover(timeout:) -> HandoverHandle?`:** hält das Lesen an, ohne das Terminal zu schließen und ohne Signal, liefert alles schon Gelesene an den Delegate aus und gibt eine Kopie des Masters (close-on-exec) samt PID zurück. Nur im Main-Queue-Betrieb und nur auf dem Main Thread. Danach meldet die Instanz das Prozessende nicht mehr. Reihenfolge in der App: `detachForHandover`, dann die eigene Drosselung leeren (`flushPendingOutput`), dann `serializeScreen`. Endet das Anhalten nicht rechtzeitig, liest die Instanz weiter, und nichts wird übergeben.
- **`LocalProcess.adopt(_:) -> Bool`:** liest von der übergebenen Leitung und überwacht eine PID, die kein eigenes Kind sein muss. Das Ende kommt genau einmal, mit dem Wait-Status aus `kqueue` (`NOTE_EXITSTATUS`), sonst `nil`. Ein schon vorher beendeter Prozess wird sofort gemeldet.
- **Ehrlicher Exit-Status:** `nil` statt erfundener 0, wenn `waitpid` nichts abholen kann. Die App wertet `nil` schon heute wie ein normales Ende (`AgentAttachRecovery.decode`, Zustandsmaschine), am Verhalten ändert sich nichts.
- **Kind schließt vor `execve` alle Deskriptoren ab 3** (Nachtrag 1 aus dem Review von Paket 0).
- **Im Aufbewahrer angebunden:** `HandoverTerminalSerializer` ist dessen Standard; der Nur-Text-Platzhalter bleibt für Tests.
- **Nach dem Review (Fork `4c3b0fa`):**
  - Die Abgabe wartet nur noch auf den letzten Lesevorgang. Ein offener Schreibauftrag an einen Chat, der seine Eingabe nicht liest, blockiert sie nicht mehr.
  - Ein übernommener Zombie wird als beendet gemeldet.
  - Scrollbereich und gesicherter Zustand des Hauptpuffers sind auch unter dem Alt-Screen dabei.
  - Ein offener Umbruch am rechten Rand und ein offener Link werden nachgebaut.
  - Überlange Sequenzen werden verschluckt statt als Text gedruckt.
  - Das Kind schließt nur die tatsächlich offenen Deskriptoren, statt bis zu 61.440 `close()` (27 ms je Chat-Start).
- **Befund für Aufbewahrer und App:** Ein Prozess, der mit ungelesener Ausgabe auf seinem Terminal endet, hängt in seinem Ende, bis jemand liest oder der letzte Master schließt. Wer eine Leitung hält, muss also mitlesen oder sie schließen; nur halten reicht nicht. Im Test äußerte sich das als `waitpid`, das nie zurückkam.

### Bauplan Paket 4: App setzt zusammen (Stand 13.11.2026)

Grundlage: Pakete 1 bis 3 und das Dauerlauf-Skript sind gebaut. Paket 4 verbindet sie in der App. Ist der Labs-Schalter `restartKeepsChatsEnabled` aus, ändert sich nichts; jeder Fehler endet im heutigen Weg plus Fortsetzen per `--resume`; nie zwei Prozesse auf einer Sitzung.

**Vertrag mit dem Aufbewahrer** (Dex, 661373d3, `docs/features/agent-chats/neustart-aufbewahrer.md` „Offen für Paket 4“):
1. Starten per `HandoverKeeperLauncher.launch(executable:arguments:secret:)`, das Einmal-Geheimnis geht über stdin. Vorher per `STATUS` klären, ob schon ein Aufbewahrer mit nicht übernommenen Chats lebt; dann keine neue Abgabe, sondern der heutige Weg mit Marker „fortsetzen“.
2. Abgabe mit `helloDeposit(secret:expectedRunID:expectedPID:)`. Die App schließt ihre Originale erst, wenn `commit()` ohne Fehler zurückkommt. Scheitert `commit()`, schickt der Client dem Aufbewahrer selbst SIGTERM; die App endet auf dem heutigen Weg.
3. Das Geheimnis legt die alte App vor `COMMIT` in den Schlüsselbund: ein Eintrag je Instanz, lesbar nur für die App (Zugriff an ihre Code-Signatur gebunden). Die neue App liest es für `helloTake(secret:)` beziehungsweise `release(secret:)` und löscht es danach. Ohne Geheimnis keine Übernahme: Die neue App beendet den Aufbewahrer per SIGTERM (PID aus `STATUS`), er schließt geordnet, danach `--resume`.
4. Eine übernommene Leitung erst benutzen, wenn `take()` ohne Fehler zurückkommt (es wartet auf `OK {chatID}`). Leitungen nur auf dem Main Thread übernehmen, nie während eines `forkpty` auf einem anderen Thread.
5. Manifest: `launchCommand` (das `AgentLaunchCommand` als JSON), `pendingAccountSwitch`, `terminalColors` aus der Palette der Terminal-View; die übrigen Felder wie im Plan.

**Router und Proxy** (Gus, Paket 3): `ClaudeGPTBackendHandover.setRequested(true)` vor dem Beenden mit Übergabe, wirksam nur bei `ClaudeGPTRouterMode.current == .service`. Dann laufen Router-Dienst und Proxys weiter und werden über das Proxy-Register übernommen.

**Schnitte** (je Schnitt Tests vor dem Umbau, eigener Commit):

| Schnitt | Inhalt |
|---|---|
| 4a Fundament | Manifest aus dem Controller bauen und zurücklesen (Kommando, Token, Cursor der Hooks, Entwurf, Kontowechsel, Farben, „arbeitet seit“); Schlüsselbund-Ablage des Geheimnisses je Instanz; Marker-Zustand „übergeben“ in `AgentCrashRecovery`; Entscheidungstabellen als reine Funktionen (Beenden: Übergabe ja/nein, Rückfall; Start: übernehmen, fortsetzen, nichts). Kein geändertes Verhalten. |
| 4b Abgabe | Controller-Weg „abgeben“ (`detachForHandover`, Drosselung leeren, `serializeScreen`, ohne Ctrl+C); Ablauf in einem `HandoverCoordinator`; Steuerbefehl und CLI `whisperm8 app handover`; Beenden-Weg bei SIGTERM mit Übergabe; Router/Proxy-Signal; Makefile (`app handover` vor `kill`, `GUI_PIDS` verschont `handover-keeper` und `gpt-router`); `test-instance.sh restart --keep-chats` und `stop` verschont dieselben. |
| 4c Übernahme | früh in `applicationDidFinishLaunching`, vor Absturz-Wiederaufnahme, `markStaleRunningSessionsClosed`, Aufräumen der Event-Dateien und erstem Statusscan: Controller ohne View (`adoptController`, Ende über Registry/Koordinator statt View-Closures), Bild einspielen, Leitung übernehmen, Größe setzen; Token und PID wieder eintragen; Hooks ab Cursor ohne `prepareSettingsFile`; Registry-Status nachlesen; Queue anstoßen; Entwurf und Kontowechsel übernehmen; Statistik. Rückfall je Chat: lebt der Prozess nicht, `--resume`; lebt er und die Übernahme scheitert, erst geordnet beenden, dann `--resume`. Kennlinien-Punkt 9 (Registry-Eintrag nach dem Terminal) gehört hierher. |
| 4d Bedienung | Labs-Schalter in den Einstellungen, Menüpunkt „Neu starten, Chats laufen weiter“, Hinweis nach `brew upgrade`, Sperrmeldung mit Ort und „Zum Chat wechseln“ (Nachtrag 2 aus Paket 0); Texte englisch und deutsch. |
| 4e Messpunkte für den Dauerlauf | `chats new --provider terminal`, `chats new --background`, `debug terminal <ref> --text`, `runtime.pid` in `chats show`, Logzeile `session_notification_posted kind=turnCompleted session=<id>`. |
| 4f Abnahme vor dem Einschalten | `scripts/handover-soak.sh run --rounds 5` in der Test-Instanz grün; Schlüsselbund-Prüfungen (unten); dann der Pflichttest mit echtem `make dev` durch Giuliano. |

**Schlüsselbund-Prüfungen vor dem Einschalten** (Hinweis von Jarvis):
- Zwei aufeinanderfolgende `make dev`-Builds, beide signiert mit „WhisperM8 Local Dev“: Die neue App liest das Geheimnis ohne Dialog.
- Wechsel Brew-Build ↔ Dev-Build: Der Zugriff scheitert sauber, ohne Dialog und ohne Hängen. Es gilt der Rückfall (`--resume` nach geordnetem Ende des Aufbewahrers). Abfrage nur mit `kSecUseAuthenticationUIFail` beziehungsweise ohne Benutzerinteraktion, mit kurzer Frist.
- Test-Instanz (eigene Bundle-ID): eigener Eintrag, berührt die Arbeits-App nie.

### Vor dem Einschalten des Schalters (Stand 13.11.2026, nach Vics Review von Paket 4)

Paket 4 ist mit ausgeschaltetem Schalter gemergt; die Labs-Seite ist ausgeblendet. Eingeschaltet wird erst, wenn alles hier erledigt ist:

1. **Geheimnis-Weg entschieden und gebaut.** (Erledigt: Der User hat am 13.11.2026 Option A+ gewählt, Geheimnis jetzt als Datei, später Apple-Entwicklerkonto und zurück in den Schlüsselbund; gemergt in `neustart/integration` 074af842. Abnahme mit beiden Signaturarten am 13.11.2026 in der Test-Instanz, `handover-soak-faults.sh --only binary-swap`, Bundle von a40de6ac: Dev auf Dev (CDHash a2a8c5fc → 2baa1a5a) und ad hoc auf ad hoc (53e766b2 → 5cb19c54) je 4 von 4 Chats übernommen, auch Codex; kein Schlüsselbund-Dialog, nie zwei Prozesse, keine Leichen, Geheimnis in keinem Log. Sichtprüfung nach der Dev-Übernahme: alle vier Panes zeigen ihr volles Bild in der Grid-Größe.) Einmalig beim Wechsel (Vic): Beim ersten Neustart über diesen Wechsel legt die alte App das Geheimnis noch im Schlüsselbund ab, die neue sucht die Datei; diese eine Übernahme fällt in den Rückfall (`--resume`). Der alte Schlüsselbund-Eintrag „WhisperM8 Restart Handover“ bleibt liegen; die App löscht ihn nicht (das kann einen Dialog auslösen), der User entfernt ihn von Hand in der Schlüsselbundverwaltung. Reste eines toten Aufbewahrers (Socket, socket-path, take-secret) räumt die nächste Übernahme oder der nächste Start weg. Mit Schlüsselbund scheitert die Übernahme über zwei Builds (cdhash-Bindung ohne Team-ID, gemessen in der Test-Instanz). Vorschlag Option A: Datei 0600 im 0700-Ordner des Aufbewahrers, Schlüsselbund ganz aus dem Weg, Kontoname ohne Signatur; später C (Apple-Entwicklerkonto). Abnahme mit Dev-Build auf Dev-Build und ad hoc auf ad hoc. Abschnitt „Wovor schützen wir“ entsprechend zurückschneiden.
2. **Kein Start mehr nach `COMMIT`.** Zwischen Abgabe und Beenden startet die alte App keinen Chat mehr.
3. **Abgabe-Fehler mit Fortsetzen wie im Plan:** Chats, deren Abgabe scheiterte, werden nach dem Neustart fortgesetzt.
4. **Aufbewahrer liest erst ab `COMMIT`** aus den Leitungen.
5. **`app handover` gegen Aufruf aus einem Chat sichern.**
6. **Bindungs-Befund** (zwei Chats an derselben Claude-Sitzung; Gus' Fix `fix/bindung-fremdes-transcript` bindet frische Starts über die Registry-PID). Aufteilung nach Vics Einordnung: a und b baut Gus auf main, c baut Ole im Sammel-Branch als eigenen Schritt, d gehört zu Oles Übernahme:
   - a) (Gus) **Reservierung gegen gleichzeitigen Doppelstart:** Eine ID, die gerade startet, bleibt gesperrt, bis ihr Prozess in der Registry steht. Die heutige Sperre erkennt gleichzeitige Starts (Wiederaufnahme, Grid, Rückfall von 4c) nicht.
   - b) (Gus) **Sammel-Starts vergleichen die IDs vorher** (Absturz-Wiederaufnahme, Rückfall von 4c) und starten bei einer Dopplung höchstens einen Chat; der andere bekommt einen Hinweis. Als reine Funktion mit Test neben den Entscheidungstabellen.
   - c) (Ole, eigener Schritt) **Zurückgestellte IDs und Fork-Merkliste ins Manifest** (`pendingExternalIDs` liegt nur im Speicher; nach `/clear` und Übergabe hinge der Chat sonst an der alten ID).
   - d) (Ole) nach der Übernahme die gespeicherte ID mit der Registry-PID abgleichen und korrigieren (heilt Altlasten bei übernommenen Chats).
   - e) (Ole, erledigt 13.11.2026) **Rückfall der Übernahme über den `AgentCollectiveStartPlanner`** (Vic): Je Sitzung startet höchstens ein Chat; übernommene und im selben Start schon vorgemerkte Chats führen ihre Sitzung weiter. Für Codex der einzige Schutz, dort gibt es weder Registry-Sperre noch Reservierung.
   - Abhängig, nicht hier: Bereinigung der Altlasten im Workspace (Prozess laut Registry gewinnt) und die Prüfung, wann Claude die Registry-Datei bei Resume und Fork schreibt.
7. **Prüfungen gegen die Wirklichkeit:** Bild im echten Fenster samt Größe und Neuzeichnen nach der Übernahme (Vic, Befund 8: das Terminal bekommt erst die Manifest-Größe, die echte erst mit der Ansicht; dass der Prozess die echte Größe dann bekommt, belegt `testAdoptedChatGetsTheRealSizeOnceTheViewIsLaidOut`, die Sichtprüfung im echten Fenster bleibt), Dauerlauf grün mit Dex' absichtlichen Fehlern, Dauer von Abgabe und Übernahme bei zehn Chats (erledigt 13.11.2026, Test-Instanz, Bundle von `fix/handover-dex-befunde` 0b4697e3, Dev-Signatur, 9 Claude + 1 Codex ohne Login: Abgabe in der App 134 ms, `app handover` bis Ende der alten App 1,34 s, Übernahme vom Plan bis fertig 179 ms, Start der neuen App bis Bericht 2,33 s, 10 von 10 übernommen), Abnahme Dev-Build auf Dev-Build und ad hoc auf ad hoc, fünfmal `make dev`, der erste echte Lauf nur mit Chats, deren Verlust nicht schlimm wäre.
9. **„Arbeitet seit“ ins Manifest** (Vic, Befund 7): Statistik und Wach-Knopf starten nach einer Übernahme sonst neu.
10. **`make dev` ohne Steuer-Socket** (Vic, Befund 6): Läuft die App, ist ihr Socket aber nicht erreichbar (etwa `agentControlServerEnabled` aus), wartet `_handover` bis zu 15 s. Nur warten, wenn die App gerade startet.
   - Bekannte Grenze (Vic, 13.11.2026): Dauert eine Übernahme länger als etwa 65 s (15 s Warten in `_handover`, dazu bis zu 60 s auf `take.lock` in `app handover`), kommt `make dev` zu `kill` und nach 5 s zu SIGKILL. Dann enden die schon übernommenen Chats (ihre Leitung lag nur noch bei der App) und werden beim nächsten Start über den Absturz-Marker fortgesetzt; der Rest liegt weiter beim Aufbewahrer, der nächste Start übernimmt ihn. Bei zehn Chats dauert die Übernahme deutlich kürzer (Messung c).
   - Einmalig nach dem Merge der Ablehnungs-Kennung (Vic, 13.11.2026): Der Aufbewahrer stammt immer aus dem ALTEN Build. Beim ersten `make dev` danach kennt er das Feld `rejection` noch nicht; lehnt er das Geheimnis ab, beendet die neue App ihn nicht (einmal Dex' Befund 2, er hält bis zur Frist). Das heilt mit dem nächsten Start. Das Feld ist abwärtsverträglich, keine neue Protokollversion. Dasselbe gilt für das kurze Abwarten bei „belegt“ (bis 2 s): Es wirkt erst einen Neustart später, weil es im Aufbewahrer liegt.
   - Randfall der Wartemeldung (Vic, 13.11.2026): `app handover` schreibt sie direkt ans Terminal, wenn stderr aufgefangen wird. Hat das Terminal `tostop` gesetzt und läuft `make dev` im Hintergrund (`&`), hält dieses Schreiben den Befehl an (SIGTTOU), bis er wieder im Vordergrund ist. Standard ist `tostop` aus; aus einem Claude-Chat gibt es kein steuerndes Terminal, die Meldung landet dann in der Ausgabe des Befehls (für Codex-Chats ungeprüft).
11. **Rückfall für Chats ohne Sitzungs-ID** (Messung c und Dex, 13.11.2026): Ein Chat ohne `externalSessionID` lässt sich nicht fortsetzen (`AgentCommandBuilder` wirft `missingExternalSessionID`); der Rückfall merkt ihn vor, gestartet wird er nie. In der Test-Instanz ohne Login trifft das jeden Codex-Chat, im echten Betrieb jeden Chat, der vor seiner Bindung in den Rückfall fällt (Codex vermutlich vor dem ersten Turn; ob Codex mit Login die Sitzung erst dann anlegt, ist ungeprüft). Entscheidung (Jarvis, 13.11.2026): Nur wenn der Chat nachweislich noch keinen Turn hatte (kein `UserPromptSubmit` in seiner Hook-Event-Datei, kein Turn im Status-Journal, kein `lastTurnAt`), startet er im Rückfall neu, im selben Ordner mit demselben Anbieter. Hat er schon Turns, bleibt er gestoppt, denn ein frischer Start hängte seinen Verlauf von jedem Tab ab. In beiden Fällen ein Hinweis im vorhandenen Meldungsbanner (englisch, deutsch übersetzt). Nur im Rückfall der Übernahme; normaler Resume-Weg und Absturz-Wiederaufnahme bleiben. Bau als eigener Branch mit Tests für beide Zweige, Claude und Codex.
8. **Labs-Seite einhängen** (`RestartSettingsPage`, liegt samt Übersetzung bereit) und den Eintrag in `PreferenceBedienweg` streichen. Das kommt als Letztes.
12. **Übergabe nur mit Router-Dienst** (Vic, Gesamt-Review Teil 2): Der Router-Modus steht einmal je App-Lauf fest. Wurde der Schalter erst in diesem Lauf eingeschaltet, gibt es einen klassischen Neustart mit Fortsetzen (Grund `routerInApp`) und eine erklärende Zeile in `make dev`. Erledigt auf `fix/handover-review-teil1`.

**Vor dem Handtest beim User** (Vic, Gesamt-Review Teil 2, drei Pflichtpunkte): Punkt 12 (Ole), Handtest-Liste mit „nur Testchats“, ehrlichem schlimmsten Fall und zwei Notausgängen (Ole, [Handtest](neustart-ohne-chatverlust-handtest.md)), Dauerlauf und Fehler-Szenarien einmal grün auf genau dem Stand, mit dem der User testet (Dex).

**Vor dem Merge nach `main`** (später): voller Pflichttest mit allen sieben Chat-Arten (Abschnitt „Pflichttest“ unten), ein bis zwei Tage Alltag mit eingeschaltetem Schalter, die Manifest-Regel in `CLAUDE.md` (die Datei steht bei 14.910 von 15.000 erlaubten Zeichen; Mechanik gehört in die Feature-Doku), Labs-Seite einhängen (Punkt 8).

**Später: Apple-Entwicklerkonto (Option C, Teil von A+).** Mit einer Signatur samt Team-ID und gehärteter Laufzeit bindet der Schlüsselbund an das Team statt an den Build; dann wäre er wieder eine echte Grenze. Der Wechsel zurück ist eine Zeile in `HandoverSecretStores.live` (`HandoverSecretStore.live` statt `HandoverFileSecretStore`); die Übernahme umhüllt die Ablage mit `HandoverLazySecretStore`, damit ein normaler Start die Signatur auch dann nicht liest. Dazu: Dev-Builds mit dem Team signieren, Abnahme beider Wege wiederholen, Abschnitt „Wovor schützen wir“ wieder anheben.

## Bau-Reihenfolge

Jedes Paket hat einen eigenen Branch und Arbeitsordner, wird einzeln reviewt und geht erst nach grüner Suite in main. Ist der Labs-Schalter aus, ändert keins das heutige Verhalten. Ausnahme ist Paket 0, das sind Fehlerbehebungen.

| Paket | Ergebnis | Tests | Risiko | Größe |
|---|---|---|---|---|
| **0 Vorarbeiten** | PTY-Master mit close-on-exec im SwiftTerm-Fork; Sperre gegen Doppelstart über die Registry; Tests vor dem Umbau (Liste oben) | Kennlinien-Tests 1–9; `lsof`-Prüfung an der Test-Instanz: kein Chat hält fremde Master | gering; der close-on-exec-Fix ändert, welche Prozesse beim Beenden SIGHUP bekommen, und macht es eindeutiger | S |
| **1 SwiftTerm-Fork** | `detachForHandover`, `adopt`, Ende per `kqueue` mit Exit-Code, ehrlicher Exit-Status; Serialisierer für Bild und Schalter | im Fork: Terminal ohne Fenster, Claude- und Codex-Mitschnitte aus dem Vorversuch als Testdaten, 0 abweichende Zellen, Übernahme an jeder Stelle eines Mitschnitts; Kind-Prozess über zwei Prozesse hinweg | mittel; eigener Fork-Code, Upstream-fähig halten | M |
| **2 Aufbewahrer** | interner Modus `handover-keeper`, Protokoll v1 mit `ACK`-Regel, Terminal ohne Fenster mit Antworten auf Rückfragen und OSC-52-Sperre, Fristen, Lock, Logs, `app handover-status` | ohne App: Tests mit `/bin/sh`-Kindern über `forkpty`, Abgabe → Übernahme → Abgabe zehnmal hintereinander, Aufbewahrer-Absturz (SIGKILL) → Kinder bekommen SIGHUP, unverträgliches Protokoll → `RELEASE` | mittel | M |
| **3 Router-Dienst** | Router auf BSD-Sockets, eigener Prozess `gpt-router`, Generationsübergabe mit Auslaufen, Proxy-Register, kein Proxy-Ende bei Übergabe, Waisen-Guard-Regel; hinter dem Labs-Schalter, sonst Router in der App wie heute | Router-Ende-zu-Ende-Test aus Paket 0 gegen beide Varianten; Generationsübergabe zehnmal mit laufendem Strom; Absturz und Neustart des Dienstes | hoch; alle Claude-Chats auf diesem Mac laufen über den Router | L |
| **4 App: Abgabe und Übernahme** | Quit-Weg ohne Ctrl+C, `adoptController`, Tokens, Hooks ab Cursor, Status, Marker „übergeben“, Aufräumen nach der Übernahme, Queue-Anstoß, Entwurf, Kontowechsel, Statistik, Makefile `app handover` + Ausnahmen, `test-instance.sh restart --keep-chats`, Labs-Schalter | Entscheidungstabellen als reine Funktionen; Test-Instanz: Übergabe mit Claude, Codex, Terminal, Attach; `whisperm8 chats list` aus einem übernommenen Chat | hoch; viele Stellen, Doppelstart ist der Hauptschaden | L |
| **5 Neustart-Menü und Update** | Menüpunkt „Neu starten, Chats laufen weiter“, Aufbewahrer startet die App neu, Update-Hinweis nach `brew upgrade` | Test-Instanz; Hinweis bei geänderter Bundle-Version (reine Funktion) | gering | S |
| **6 Feldtest** | Dauerlauf-Skript `scripts/handover-soak.sh` für die Test-Instanz; danach echtes `make dev` durch Giuliano | siehe Pflichttest | – | S |

**Pflichttest (Abnahme vor jedem Einschalten außerhalb der Test-Instanz):** fünfmal `make dev` hintereinander, ohne Pause, mit gleichzeitig arbeitenden Chats.

Beteiligte Chats:
- ein Claude-Chat mit Bash-Schritten;
- ein Claude-Chat mitten in einer langen gestreamten Antwort über den Router;
- ein GPT-Chat mit langer Antwort;
- ein Codex-Chat mit Shell-Schritten;
- ein Terminal-Tab mit laufendem Befehl (Zähler);
- ein angedockter Hintergrund-Chat;
- ein Chat mit offener Rückfrage.

Prüfungen nach jedem Durchgang:
- gleiche PIDs;
- keine Meldung „API Error“ und kein „Retrying“;
- Antworten vollständig;
- Rückfrage noch offen;
- Zähler lückenlos;
- kein zweiter Prozess auf einer Sitzung (Registry);
- `whisperm8 chats list` aus jedem Chat funktioniert;
- keine doppelte Fertig-Meldung;
- Speicher des Aufbewahrers nach dem Ende freigegeben.

Die Test-Instanz deckt alles außer dem GPT-Chat ab (kein GPT-Login, Logins werden nicht kopiert). Den GPT-Teil prüft Giuliano mit echtem `make dev`.

**Reihenfolge-Begründung:** Paket 0 lohnt sich auch ohne das Feature, der close-on-exec-Fix ist ein Sicherheitsfehler. Pakete 1 bis 3 sind unabhängig voneinander baubar und testbar, ohne die App zu verändern. Paket 4 setzt sie zusammen. Ohne Paket 3 würde Paket 4 auf diesem Mac jede gerade strömende Antwort abreißen. Deshalb kommt 3 vor 4, und eingeschaltet wird erst, wenn beide da sind.

### Nacharbeit Paket 3 (aus dem Opus-Review vom 12.11.2026)

Behoben vor dem Merge: `gptRouter.startProfile` nur im Dienst-Modus und nur der Profilpfad; Socket-Übergabe nur an dasselbe Programm (Code-Signatur über `LOCAL_PEERTOKEN`, bei jeder Nachricht), Test-Upstreams nur im Debug-Build, `--root` nur der Ordner der App; verwaister Dienst ohne `router.sock` wird vom Port geräumt; ohne `released` gibt die neue Generation auf; anderer Programmort startet frisch, statt bei jedem Chat-Start eine Übernahme zu versuchen.

Später:
- ~~**Main Thread:** Stop-Knopf und `willTerminate` warten bis zu 2 s auf den Steuer-Socket des Dienstes.~~ Erledigt 13.11.2026: `stop()` schickt `shutdown`, ohne auf Antwort oder ein laufendes `ensureRunning` zu warten; aufgeräumt wird im Hintergrund.
- **Tests:** feste Sleeps durch Bedingungen ersetzen; Prozess-Tests werden still übersprungen, wenn das Binary fehlt (in der CI sichtbar machen); Router-Dienste nach einem Absturz von xctest bleiben als Waisen (Aufräumen per Prozessgruppe).
- **Leerlauf-Frist** (Entscheidung des Users 13.11.2026, umgesetzt): Der Dienst beendet sich geordnet, wenn 30 Minuten lang keine App verbunden war (`attach`-Verbindung der Aufsicht) und keine Anfrage lief. Anfragen überlebender Chats zählen als Betrieb.

## Entscheidungen

Am 12.11.2026 vom User getroffen, jeweils wie empfohlen.

1. **Router: eigener Dienst oder Auslaufen in der App?**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: eigener Dienst (Paket 3 wie oben).* Nur so wartet `make dev` auf nichts.
   - Alternative: Der Router bleibt in der App, lässt beim Neustart laufende Antworten auslaufen (gemessen 24 und 35 s, einzelne bis 170 s, mit Obergrenze) und gibt dann seinen Socket über den Aufbewahrer weiter. Das ist kleiner (M statt L), aber genau das Warten, das ausgeschlossen ist. Nach der Obergrenze reißen Antworten ab.
2. **Was tut der Aufbewahrer, wenn keine neue App kommt?**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: 10 Minuten halten (Chats arbeiten unsichtbar weiter, Rückfragen werden beantwortet), dann geordnet beenden wie heute.* Der Marker „fortsetzen“ bleibt; die Chats kommen beim nächsten Start per `--resume` wieder.
   - Alternative: halten, bis alle Chats von selbst enden. Dann können unsichtbar Prozesse stundenlang laufen.
3. **Cmd+Q:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: bleibt echtes Beenden mit dem heutigen Dialog, dazu der neue Menüpunkt „Neu starten, Chats laufen weiter“.*
   - Alternative: Cmd+Q übergibt immer. Dann laufen nach jedem Beenden Chats unsichtbar weiter, das widerspricht dem, was „Beenden“ heißt.
4. **Update per Brew:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: Hinweis „Update installiert, neu starten, Chats laufen weiter“ nach erkanntem neuem Bundle.*
   - Alternative: `uninstall quit:` im Cask. Brew würde die App dann hart beenden, die Chats wären weg.
5. **Turn-Enden während der Lücke:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: still nachziehen (Status ja, Ansage und Notch-Meldung nein)*, damit nach einem Neustart keine Ansagen auf einmal kommen.
   - Alternative: eine Sammelansage „3 Chats sind fertig“.
6. **Labs-Schalter als Standard:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: ab Werk aus, nach zwei Wochen Feldtest ohne Befund an.* Danach wird der Router-Dienst die einzige Router-Variante, der Router in der App entfällt.
7. **Angedockte Hintergrund-Chats:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: übergeben wie alle anderen*, ein Weg für alles.
   - Alternative: nicht übergeben, nach dem Neustart neu andocken (geht schon heute, kostet aber das Bild).
8. **close-on-exec-Fix vorziehen:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: ja, als eigener kleiner Fix ins nächste Patch-Release (2.25.x)*, unabhängig von diesem Projekt.
9. **Vorgemerkter Kontowechsel nach dem Turn:**
   - **Entschieden: Empfehlung.**
   - *Empfehlung: im Manifest mitnehmen.*
   - Alternative: verwerfen, mit Hinweis im Log.

## Datenspuren der Versuche

**Vorversuch, 11.11.2026:** Die Test-Chats liefen mit Giulianos Login.
- Entfernt am 12.11.2026: ihre Sitzungsverläufe unter `~/.claude/projects/` (vier Ordner zu Scratchpad-Pfaden) und zwei Codex-Sitzungen unter `~/.codex/sessions/2026/11/11/`.
- Stehen geblieben: vier Vertrauenseinträge für Scratchpad-Ordner in `~/.claude.json`. Die Datei schreiben alle laufenden Claude-Prozesse mit, ein Eingriff von außen könnte sie beschädigen. Die Einträge sind harmlos und können bei Gelegenheit in einer ruhigen Minute entfernt werden.
- Das Codex-Update von damals ist zurückgenommen (CLI 0.160.1). Der Codex-Hintergrunddienst läuft seitdem in 0.167.1; er hat sich selbst aktualisiert, das kam nicht durch den Vorversuch.
- Die Test-Instanz ist zurückgesetzt (GPT-Backend aus, Proxy-Kopie entfernt).

**Fehlersuche, 12.11.2026:** nur Prozesse im Scratchpad und auf `127.0.0.1`, keine Claude- oder Codex-Sitzung, kein Daemon. Alle Prozesse und Socket-Dateien sind entfernt.

## Anhang: Ergebnis des Vorversuchs (11.11.2026)

Unverändert vom 11.11.2026. Der Abschnitt „Änderungen am Plan“ darin ist durch den Bauplan oben ersetzt; insbesondere läuft der Router nicht mehr mit Auslaufen in der App, und die gescheiterte zweite Übergabe ist geklärt.

**Stand 11.11.2026.** Alle Prototypen liegen außerhalb des Repositorys (Scratchpad), am App-Code ist nichts geändert. Gemessen mit Claude Code 2.1.322 und Codex 0.160.1, echt und mit Giulianos Login, in Scratchpad-Ordnern.

### Urteil

**Bauen mit Änderung.** Die Übergabe der Terminal-Leitungen und das Wiederherstellen des Bildes tragen. Der Router trägt in der geplanten Form nicht: Bricht er eine laufende Antwort ab, ist der Turn verloren. Er muss deshalb laufende Antworten zu Ende bringen und seinen lauschenden Socket mit übergeben. Dieser Weg ist im Prototyp belegt (Einzelheiten in Frage 1 und unter „Änderungen am Plan“).

| Frage | Urteil | Kernwert |
|---|---|---|
| 0 Mechanik | belegt | kein SIGHUP, Ausgabe lückenlos, Exit-Code über `kqueue`; 30 s ohne Leser schaden weder Claude noch Codex |
| 1 Router-Lücke | widerlegt in der geplanten Form, Lösungsweg belegt | Abriss mitten in der Antwort = Turn verloren; mit Ablassen und Socket-Übergabe 20 s Lücke ohne einen einzigen Fehler |
| 2 Bild | belegt | 0 abweichende Zellen bei Claude und Codex, auch bei Übernahme mitten in einer Antwort (260 von 260 Messpunkten); Schalter der TUI müssen mitgesichert werden |
| 3 Zugriffsrechte | auf diesem Mac kein Hindernis, allgemein nicht belegt | Zugriff bleibt nach dem Ende der App, macOS rechnet den Prozess danach sich selbst zu; Gegenprobe zeigt, dass hier auch ein Prozess ohne App liest |

### Frage 0: Die Mechanik selbst — belegt

**Aufbau:** Python-Prototyp mit drei Rollen. Ein Halter startet ein Kind per `forkpty` wie heute die App, gibt die Leitung per `SCM_RIGHTS` an einen abgekoppelten Aufbewahrer ab und beendet sich ohne `close` und ohne Signal. Ein dritter Prozess übernimmt die Leitung vom Aufbewahrer. Das Kind ist ein Shell-Skript, das jede Sekunde tickt und SIGHUP und SIGWINCH protokolliert.

| Messung | Ergebnis |
|---|---|
| Kontrolle: Halter endet ohne Übergabe | Kind bekommt SIGHUP 70 ms später und endet |
| Mit Übergabe | kein SIGHUP; Kind läuft weiter, Elternprozess wird `launchd` (PID 1), 6 s Lücke nur mit Aufbewahrer |
| Übernahme durch dritten Prozess | Größe setzen wirkt (Kind meldet SIGWINCH mit 100×30), Schreiben kommt an, Lesen läuft weiter |
| Ausgabe über alle drei Prozesse | lückenlos (Tick 1 bis 15 ohne Sprung), Puffer des Aufbewahrers bytegleich übergeben |
| Ende eines fremden Kindes | `waitpid` geht nicht (ECHILD), aber `kqueue` mit `NOTE_EXIT \| NOTE_EXITSTATUS` liefert Ende **und Exit-Code** (gemessen: Status 7) |

**Lesepause (niemand liest die Leitung 30 s lang):** Aufbau mit einem eigenen PTY-Host auf Basis von SwiftTerm ohne Fenster (derselbe Fork-Stand wie die App).

| Fall | Ergebnis |
|---|---|
| Claude, Folge von 14 Bash-Schritten | arbeitet in der Pause normal weiter (4 Schritte in 30 s, Takt 6–10 s wie vorher), Turn endet sauber |
| Claude, lange gestreamte Antwort (260 Zeilen) | reißt nicht ab; bei Pausenbeginn war Zeile 136 gelesen, beim Weiterlesen lagen 27,5 KB bis Zeile 227 an, am Ende alle 260 Zeilen vollständig und in Reihenfolge |
| Codex, Folge von 12 Shell-Schritten | arbeitet in der Pause normal weiter (6 Schritte im gewohnten Takt von 4–6 s), Turn endet sauber |

Claude und Codex blockieren also nicht, wenn niemand liest. Der Aufbewahrer muss nicht mitlesen, damit nichts hängt. Er sollte es trotzdem tun (wie im Plan), damit kein Chat unbegrenzt Speicher aufbaut und die Ausgabe der Lücke bei der neuen App ankommt.

### Frage 1: Die Lücke im Router — widerlegt in der geplanten Form, Lösungsweg belegt

**Aufbau A (echter Router):** Test-Instanz mit eingeschaltetem GPT-Backend (Router auf Port 28766). Ein Claude-Chat läuft außerhalb der App im PTY-Host mit der Umgebung, die die App setzen würde (`ANTHROPIC_BASE_URL` auf den Router, `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL`, Profil-Header); per `lsof` nachgewiesen, dass die Anfragen über den Router laufen. Die Test-Instanz wird mitten im Turn mit SIGTERM beendet (wie `make dev`) und nach der Lücke neu gestartet.

| Fall | Lücke | Ergebnis |
|---|---|---|
| Router weg, während Antworttext fließt | 5 s, 15 s | **Turn verloren.** Kein Wiederholen. „API Error: Connection lost mid-response. The response above may be incomplete.“, der bisherige Text ist weg |
| danach „mach genau dort weiter“ geschickt | – | Claude fängt von vorn an (Zeile 1 bis 150), setzt nicht fort |
| Router weg zwischen zwei Anfragen (Tool läuft, nächste Anfrage trifft den toten Port) | 5 s, 15 s, 22 s, 30 s | **läuft durch.** „Connection refused · Retrying in …s · attempt n/10“ (5, 9, 14 bzw. 17 Anzeigen), Turn endet sauber |
| dasselbe, Router 5 Minuten weg | 300 s | **Turn verloren** nach gut 3 Minuten: 10 Versuche mit Wartezeiten bis 36 s, dann „API Error: Connection refused“ |

**Aufbau B (eigener Durchreich-Router):** reicht an api.anthropic.com durch und beendet eine Antwort gezielt, sobald 25 Textstücke, 3 Denkstücke oder 3 Stücke eines Tool-Aufrufs geflossen sind. Kopfzeilen und Inhalte wurden nie protokolliert.

| Art des Abbruchs | Zeitpunkt | Ergebnis |
|---|---|---|
| harter Abbruch (wie Prozessende) | Text fließt | verloren |
| harter Abbruch | Tool-Aufruf wird gestreamt | verloren |
| harter Abbruch | Denkphase, noch kein Text | **wiederholt**, Turn vollständig |
| Fehlerereignis `overloaded_error` | Text fließt | verloren („Server error mid-response“) |
| Strom endet sauber ohne Abschluss | Text fließt | verloren |
| Fehlerereignis `api_error` | nach 4 KB Text (zweimal gemessen) und in der Denkphase | **nachgeholt** mit einer nicht gestreamten Anfrage, Turn vollständig (70 von 70 Zeilen) |
| Fehlerereignis `api_error` | nach 35 KB Text, während eines Tool-Aufrufs | verloren |

Claude Code wiederholt also nur, solange von der Antwort noch nichts Bleibendes angekommen ist. Ein Trick über Fehlerereignisse trägt nicht verlässlich.

**Der Proxy für GPT-Chats stirbt mit der App.** Nach jedem Beenden der Test-Instanz lief ein neuer Proxy-Prozess (Startzeit gleich dem Neustart). Ursache laut Code: SIGTERM wird zu einem regulären Beenden, dabei beendet `ClaudeCodeProxyManager` bei `willTerminate` den selbst gestarteten Proxy. Der Kommentar in `ClaudeCodeProxyOrphanGuard` (Proxy überlebt als Waise) beschreibt einen älteren Stand. Den GPT-Weg mit echter Antwort konnte ich nicht prüfen: Die Test-Instanz hat kein GPT-Login, und Logins werden nicht kopiert.

**Aufbau C (Lösungsweg):** ein Router, der bei der Übergabe keine neuen Verbindungen mehr annimmt (der lauschende Socket bleibt offen, neue Verbindungen warten in der Warteschlange des Kernels), laufende Antworten zu Ende bringt, den lauschenden Socket per `SCM_RIGHTS` an einen Aufbewahrer gibt und endet. Nach 20 s übernimmt ein neuer Prozess den Socket.

| Fall | Ergebnis |
|---|---|
| L1: Übergabe während einer Folge von 10 Bash-Schritten, 20 s ohne Router | **0 Fehler- oder Wiederholungsanzeigen**, die Anfrage aus der Lücke wartete und wurde vom neuen Prozess beantwortet, 10 von 10 Schritten, Turn sauber beendet |
| L3: Übergabe während einer gestreamten Antwort | der alte Router wartete 34,5 s, bis die laufende Antwort fertig war (Status 200, 171 KB, insgesamt 154 s), erst dann Übergabe; keine Fehleranzeige in der Lücke. Der Lauf war durch einen Rest aus einem abgebrochenen Versuch verunreinigt, deshalb wiederholt als L5 |
| L5: wie L3, sauber | der alte Router wartete 23,9 s, bis die laufende Antwort fertig war (Status 200, 143 KB), dann 20 s Lücke; **Antwort vollständig** (120 von 120 Zeilen, Endmarke da), **0 Fehler- oder Wiederholungsanzeigen** |
| Übergabe des lauschenden Sockets vier Mal hintereinander (Minimalversuch, blockierend und mit `poll`) | jede Generation nimmt an und antwortet |
| zweite Übergabe im HTTP-Prototyp (L4) | **gescheitert**: der Prozess, der den Socket zum zweiten Mal erbt, setzt Verbindungen zurück, ohne sie anzunehmen. Da der Minimalversuch vier Generationen schafft, liegt der Fehler im Prototyp; die Ursache habe ich nicht gefunden. Im Bau ist mehrfaches `make dev` hintereinander deshalb ein Pflichttest |

### Frage 2: Das Bild nach der Übernahme — belegt, mit einer Bedingung

**Aufbau:** Im PTY-Host hängen mehrere SwiftTerm-Terminals am selben Chat: A sieht alles (wie eine App, die nie neu gestartet wäre), B bekommt ein gesichertes Bild von A und danach die weitere Ausgabe, D ist ein frisches Terminal ohne Bild. Verglichen wird Zelle für Zelle (Zeichen, Farben, Stile) und die Schalter, die die TUI gesetzt hat (Bracketed Paste, Fokus-Meldungen, Kitty-Tastaturprotokoll, Maus, Cursor). Das Sichern serialisiert den SwiftTerm-Puffer in einen ANSI-Strom (Text, Farben, Zeilenumbrüche, Alt-Screen, Cursor, Schalter).

| Messung | Claude | Codex |
|---|---|---|
| Gesichertes Bild in frischem Terminal | 341 Zeilen, 37.510 Zellen, **0 Abweichungen**, Schalter gleich; 30 KB, Sichern 26 ms, Einspielen 130 ms (Debug-Build) | 0 Abweichungen, Schalter gleich, 3 KB |
| Nur Text ohne Farben | 0 Zeichenfehler, 1.332 Zellen mit anderer Farbe | – |
| Größenänderung ohne gesichertes Bild (D) | Claude zeichnet nur den sichtbaren Bereich neu (5 KB); Schirm stimmt, **Verlauf fehlt** (292 von 352 Zeilen), **Schalter fehlen** | Codex zeichnet den ganzen Schirm neu (Alt-Screen); Schirm stimmt, **Schalter fehlen** |
| Mit gesichertem Bild weiterarbeiten (B) | nach zwei Größenänderungen und einem weiteren Turn mit Tabelle und Codeblock 0 Abweichungen (372 Zeilen) | 0 Abweichungen |
| Übernahme mitten in einer laufenden Antwort | 190 Zeitpunkte: 190 identisch | 70 Zeitpunkte: 70 identisch |

**Die Bedingung:** Claude setzt das Kitty-Tastaturprotokoll (Stufe 5), Codex Stufe 7 und Mausmeldungen, beide nur beim Start. Ohne gesicherte Schalter kämen Tasten wie Shift+Enter oder Mausklicks nach der Übernahme falsch an. Das Bild muss deshalb immer mit Schaltern gesichert werden, auch in einer ersten Stufe „nur Text“.

**Der Übergabepunkt:** 54 von 1.087 gelesenen Blöcken endeten mitten in einer Steuersequenz, 5 mitten in einem UTF-8-Zeichen. Das Bild muss genau an der Stelle gesichert werden, ab der der Aufbewahrer liest. Das ergibt sich von selbst, wenn die alte App erst aufhört zu lesen, den Rest verarbeitet, sichert und dann abgibt. So waren alle 260 Messpunkte identisch.

Nicht gemessen: das Zeichnen im echten Fenster (`MacLocalTerminalView`). Der Puffer ist derselbe, die Darstellung lässt sich ohne Fenster nicht vergleichen.

### Frage 3: Zugriffsrechte — auf diesem Mac kein Hindernis, allgemein nicht belegt

**Aufbau:** kleiner C-Messprozess, der sich abkoppelt und alle 2 s die Ordnerlisten von Dokumente, Schreibtisch und Downloads liest und protokolliert, welchem Prozess macOS ihn zurechnet (`responsibility_get_pid_responsible_for_pid`). In der Test-Instanz wurde er über einen Vorschalter vor dem Proxy-Programm gestartet, war also Nachfahre der Test-App.

| Messung | Ergebnis |
|---|---|
| während die Test-App läuft | zugerechnet `WhisperM8Test.app`, alle drei Ordner lesbar |
| nach dem Beenden der Test-App (5 Minuten beobachtet) | macOS rechnet den Prozess **sich selbst** zu, alle drei Ordner weiter lesbar |
| nach dem Neustart der Test-App | Zurechnung bleibt beim Prozess selbst, Ordner weiter lesbar |
| Gegenprobe: derselbe Prozess über `launchd` ohne jede App gestartet | ebenfalls alle drei Ordner lesbar |

Die Gegenprobe zeigt, dass auf diesem Mac auch ein Prozess ohne App-Hintergrund dort lesen darf. Für Giulianos Rechner ist Frage 3 damit kein Hindernis. Für andere Macs bleibt ein Risiko: Nach einem Neustart rechnet macOS einen Chat sich selbst zu, Rückfragen kämen dann im Namen von `claude` oder `codex` statt WhisperM8. Für die Weitergabe als Open Source gehört das in den Feldtest.

Für den Beleg unter der echten App liegt ein Messprozess bereit (Anleitung in der Schlussmeldung). Nach der Gegenprobe ist er eine Bestätigung, keine Voraussetzung mehr.

### Änderungen am Plan

1. **Router übergibt, statt abzubrechen.** Beim Übergeben nimmt der Router keine neuen Verbindungen mehr an, wartet, bis die laufenden Antworten fertig sind, und gibt seinen lauschenden Socket mit an den Aufbewahrer. Die neue App übernimmt ihn. Anfragen aus der Lücke warten in der Warteschlange des Kernels und gehen nicht verloren. Folgen:
   - `make dev` wartet so lange wie die längste gerade laufende Antwort. Gemessen 23,9 s und 34,5 s, einzelne Antworten liefen bis zu 170 s. Nötig sind eine Obergrenze (etwa 3 Minuten) und eine Anzeige „warte auf n Antworten“. Nach der Obergrenze fällt der Weg auf den heutigen Stand zurück.
   - Der Router lauscht heute über `NWListener`. Ob der einen vorhandenen Socket übernehmen kann, ist zu prüfen; sonst braucht er einen Listener auf BSD-Sockets.
   - Die Lücke ist für Claude unkritisch, solange sie unter etwa 3 Minuten bleibt (Wiederholen bei abgelehnten Verbindungen). Mit Socket-Übergabe werden Verbindungen nicht einmal abgelehnt.
   - Ohne GPT-Backend sprechen die Chats direkt mit Anthropic, dann entfällt der Punkt ganz.
2. **Proxy weiterlaufen lassen.** Bei der Übergabe darf `willTerminate` den Proxy nicht beenden. Die neue App findet ihn erreichbar und benutzt ihn weiter (`ensureRunning` prüft heute schon die Erreichbarkeit). Ein Auto-Update des Proxys darf ihn nicht ersetzen, solange GPT-Chats laufen.
3. **Bild immer mit Schaltern sichern** (Kitty-Protokoll, Maus, Bracketed Paste, Fokus, Alt-Screen). Der Puffer wird an der Stelle gesichert, an der die alte App aufhört zu lesen.
4. **Exit-Code über `kqueue`.** In der Tabelle „Was dafür geändert werden muss“ entsprechend korrigiert.
5. **Pflichttests im Bau:** mehrfaches `make dev` hintereinander (der HTTP-Prototyp scheiterte an der zweiten Übergabe), GPT-Chat mit echter Antwort, Darstellung im echten Fenster.

Die übrigen Punkte des Plans (Aufbewahrer als interner Modus, Tokens in die Übergabe, kein doppeltes `--resume`, Labs-Schalter, Rückfall auf den heutigen Stand) bleiben, wie sie sind.

### Nebenwirkungen des Vorversuchs

- Die Test-Chats liefen echt mit Giulianos Login. Claude und Codex haben dabei Vertrauenseinträge für Scratchpad-Ordner und Sitzungsprotokolle unter `~/.claude` und `~/.codex` angelegt.
- Beim Codex-Test hat ein Enter im Update-Dialog von Codex „Update now“ gewählt. Das globale `codex` war dadurch kurz 0.167.1. Danach ist wieder 0.160.1 installiert.
- In der gemeinsamen Test-Instanz waren zeitweise das GPT-Backend eingeschaltet und das Proxy-Programm abgelegt. Beides ist zurückgenommen.

