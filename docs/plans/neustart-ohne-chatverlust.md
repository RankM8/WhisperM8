# Plan: `make dev` ohne Chat-Abbruch

**Stand:** 11.11.2026 · **Status:** Vorversuch läuft (Zwischenstand unten), kein App-Code geändert
**Herkunft:** Wunsch vom 11.11.2026 nach der Wettbewerbsanalyse (Punkt 5 der Auswahl, Branch `docs/wettbewerb-orca-t3code`)

## Ziel

Nach `make dev` stehen alle Chats an ihrem Platz und arbeiten weiter. Ein Chat, der gerade mitten in einem Arbeitsschritt war, läuft durch. Kein Neuanstoßen, kein verlorener Turn.

## Was heute passiert

1. `make dev` baut zuerst, die App läuft dabei weiter. Erst danach kommt `_dev_finish`: `kill` → `_install_bundle` (rsync) → `open`. Die Lücke ohne App ist also kurz.
2. `kill` schickt SIGTERM. Die App macht daraus ein reguläres Beenden (`WhisperM8App.swift`, SIGTERM-Quelle → `NSApp.terminate`).
3. Beim Beenden schickt die App **jedem laufenden Chat zweimal Ctrl+C** (`AgentTerminalRegistry.captureAllSnapshotsForAppQuit`). Ein arbeitender Chat wird damit aktiv unterbrochen.
4. Danach schließt der Prozess. Jedes Terminal gehört der App (SwiftTerm, `forkpty`), mit ihr schließt die Terminal-Leitung, und `claude`/`codex` bekommen ein SIGHUP und enden.
5. Nach dem Start sind Tabs und Fenster wieder da, aber kein Chat läuft. Nach `make dev` wird bewusst nichts automatisch fortgesetzt (`AgentCrashRecovery`: sauberes Ende löscht den Marker).

Der Abbruch hat also zwei Ursachen: das absichtliche Ctrl+C und das Schließen der Terminal-Leitung. Beide lassen sich vermeiden.

## Empfehlung: Übergabe statt Dauer-Halter

In der Auswahl stand für Punkt 5 ein kleiner Halter je Chat, über den jedes Terminal dauerhaft läuft. Für `make dev` gibt es einen kleineren Weg, der den Alltag nicht anfasst:

**Die App gibt ihre Terminal-Leitungen vor dem Beenden an einen Aufbewahrer ab und holt sie nach dem Start zurück.**

```
alte App ──(gibt Leitungen ab)──► Aufbewahrer ──(gibt Leitungen zurück)──► neue App
   │                                  │                                       │
 beendet sich                 hält die Leitungen offen,               zeigt die Chats wieder an,
 ohne Ctrl+C                  sammelt die Ausgabe                     Aufbewahrer beendet sich

claude / codex laufen die ganze Zeit weiter, mit derselben Prozessnummer
```

Der Aufbewahrer ist dasselbe Programm in einem internen Modus, so wie heute schon der Supervisor für Codex-Jobs (`agent-supervise`, `AgentSupervisorLauncher`). Der überlebt `make dev` bereits heute, das Muster ist also im Haus erprobt.

### Warum dieser Weg

| | Übergabe (Empfehlung) | Dauer-Halter (Weg B aus Punkt 5) |
|---|---|---|
| Normalbetrieb | **unverändert**, die Terminals gehören weiter der App | jedes Terminal läuft dauerhaft über ein Zwischenstück |
| Wirkt bei | geplantem Neustart: `make dev`, später Update und „Beenden, Chats laufen weiter“ | zusätzlich bei Absturz der App |
| Wenn es schiefgeht | Rückfall auf den heutigen Stand, der Chat wird wie nach einem Absturz fortgesetzt | Fehler im Zwischenstück trifft jeden Chat, jeden Tag |
| Prozessnummer von Claude | bleibt gleich, Status und Ressourcenansicht passen weiter | Zwischenstück muss die echte Nummer melden |
| Umfang | mittel | mittel bis groß |

Die Übergabe ist zugleich der erste Baustein für den Dauer-Halter: Aufbewahrer und das Wiederanhängen in der App werden dort wiederverwendet. Wer später auch Abstürze abdecken will, baut darauf auf.

## Ablauf im Detail

1. `make dev` baut wie heute.
2. Statt `kill` ruft das Makefile `whisperm8 app handoff` (über den Control-Socket). Antwortet die App nicht oder kennt sie den Befehl nicht, läuft der alte Weg mit `kill`.
3. Die App schreibt ihre Stores fest, sichert je Chat das Terminal-Bild, startet den Aufbewahrer mit den Terminal-Leitungen aller laufenden Chats und beendet sich. **Ohne Ctrl+C.**
4. Der Aufbewahrer hält die Leitungen offen und liest die Ausgabe in einen begrenzten Puffer je Chat, damit kein Chat beim Schreiben hängen bleibt.
5. rsync und Start wie heute.
6. Die neue App fragt beim Start den Aufbewahrer, übernimmt je Chat Leitung, Prozessnummer und gesammelte Ausgabe, spielt Bild und Ausgabe ins Terminal und lässt die TUI einmal neu zeichnen. Der Aufbewahrer beendet sich.
7. Klappt die Übernahme für einen Chat nicht, wird er wie nach einem Absturz über `--resume` fortgesetzt. Das ist der heutige Stand, schlechter wird es nie.

## Was dafür geändert werden muss

| Stelle | Änderung |
|---|---|
| SwiftTerm-Fork (`LocalProcess`) | zwei neue Wege: Leitung abgeben, ohne sie zu schließen und ohne SIGTERM; mit vorhandener Leitung und Prozessnummer starten statt mit `forkpty` |
| Neuer interner Modus im Binary | Aufbewahrer: Leitungen halten, Ausgabe puffern, über einen Socket zurückgeben, sich danach beenden |
| `AgentTerminalController` / Registry | Startweg „übernommen“; kein Ctrl+C für übergebene Chats beim Beenden |
| `AgentSessionTokenRegistry` | Die Tokens der Chats liegen nur im Speicher. Ohne Mitgabe lehnte die neue App jeden `whisperm8 chats`-Aufruf aus einem überlebenden Chat ab. Sie müssen in die Übergabe (Datei mit 0600). |
| `AgentCrashRecovery` | Übernommene Chats dürfen nie zusätzlich per `--resume` starten. Zwei Prozesse auf derselben Session wären der schlimmste Fehler dieses Vorhabens. Regel: vor jedem Fortsetzen prüfen, ob der alte Prozess noch lebt. |
| Makefile | `handoff` vor `kill`, Aufbewahrer aus `GUI_PIDS` ausnehmen wie `agent-supervise` |
| Prozessende eines übernommenen Chats | Die neue App ist nicht mehr Elternprozess. Das Ende bemerkt sie weiter, den Exit-Code bekommt sie nicht. |

Nicht betroffen, weil sie am Prozess von Claude oder an festen Pfaden hängen: Status aus Claudes Registry (`sessions/<pid>.json`), Hooks, Ressourcenansicht, Control-Socket, Plugin, Router-Token (liegt als Datei, überlebt Neustarts) und Router-Port (Einstellung).

## Drei Dinge, die vor einer Zusage bewiesen sein müssen

Ohne diese Belege wäre „robust“ eine Behauptung.

1. **Die Lücke im GPT-Router.** Bei aktivem GPT-Backend laufen die Anfragen aller Claude-Chats über den Router in der App (`ANTHROPIC_BASE_URL`, `AgentCommandBuilder`). Während des Neustarts ist er einige Sekunden weg, eine laufende Antwort reißt ab. Claude Code wiederholt abgebrochene Anfragen von selbst; ob das mitten im Turn zuverlässig trägt, muss ein Versuch zeigen. Dazu gehört der Proxy: der Start-Guard ersetzt einen veralteten Waisen-Proxy, das wäre eine zweite Unterbrechung für GPT-Chats.
2. **Das Bild nach der Übernahme.** Claude Code läuft bei uns im normalen Modus (`"tui": "default"`). Auf das Neuzeichnen hin malt es den unteren Bereich neu, den Verlauf darüber nicht. Der Verlauf muss also aus dem gesicherten Terminal-Bild kommen. Erste Stufe als reiner Text, mit Farben erst, wenn das Bild sauber wiederhergestellt wird.
3. **Zugriffsrechte nach dem Elternwechsel.** macOS rechnet Dateizugriffe eines Chats der App zu, die ihn gestartet hat. Ob das hält, wenn diese App beendet ist, zeigt der Supervisor für Codex-Jobs im Ansatz, für Claude-Chats in geschützten Ordnern (Dokumente, Schreibtisch) fehlt der Beleg.

Dazu kleiner: Was im Speicher eines Chats liegt und den Neustart nicht übersteht (Entwurf im Eingabefeld, vorgemerkter Kontowechsel nach dem Turn), kommt in die Impact-Analyse.

## Vorgehen

1. **Vorversuch** in der isolierten Test-Instanz (`scripts/test-instance.sh`), ohne die Arbeits-App anzufassen: Punkte 1 bis 3 belegen oder widerlegen. Ergebnis ist ein Ja oder Nein mit Messwerten.
2. **Impact-Analyse** über Stoppen, Fortsetzen, Kontowechsel, Wiederaufnahme, Prompt-Queue, mit Tests vor dem Umbau.
3. **Bau** hinter einem Labs-Schalter, ab Werk aus. Ohne Schalter läuft `make dev` wie heute.
4. **Feldtest** mit echtem `make dev` und arbeitenden Chats (Claude, GPT, Codex, Terminal), danach Entscheidung über den Standard.

Eigener Branch, eigener Arbeitsordner, eigener Chat.

## Ergebnis des Vorversuchs

**Zwischenstand vom 11.11.2026, 19:50.** Frage 0 und 2 sind fertig, Frage 1 zum größten Teil, Frage 3 steht noch aus. Alle Prototypen liegen außerhalb des Repositorys, am App-Code ist nichts geändert.

### Kurzfassung

Die Übergabe der Terminal-Leitungen funktioniert, und das Bild lässt sich verlustfrei wiederherstellen. Der Haken sitzt woanders: **Reißt der Router mitten in einer laufenden Antwort ab, wiederholt Claude Code die Anfrage nicht, der Turn endet mit einem Fehler.** Der Plan in seiner jetzigen Form würde also bei jedem Chat, der beim Neustart gerade schreibt, genau den Turn verlieren, den er retten soll. Das ist lösbar, ändert aber den Ablauf (siehe Folgerung unten).

### Frage 0: Die Mechanik selbst — belegt

**Aufbau:** Python-Prototyp mit drei Rollen. Ein Halter startet ein Kind per `forkpty` wie heute die App, gibt die Leitung per `SCM_RIGHTS` an einen abgekoppelten Aufbewahrer ab und beendet sich ohne `close` und ohne Signal. Ein dritter Prozess übernimmt die Leitung vom Aufbewahrer. Das Kind ist ein Shell-Skript, das jede Sekunde tickt und SIGHUP und SIGWINCH protokolliert.

| Messung | Ergebnis |
|---|---|
| Kontrolle: Halter endet ohne Übergabe | Kind bekommt SIGHUP 70 ms später und endet |
| Mit Übergabe | kein SIGHUP; Kind läuft weiter, Elternprozess wird `launchd` (PID 1), 6 s Lücke nur mit Aufbewahrer |
| Übernahme durch dritten Prozess | Größe setzen wirkt (Kind meldet SIGWINCH mit 100×30), Schreiben kommt an, Lesen läuft weiter |
| Ausgabe über alle drei Prozesse | lückenlos (Tick 1 bis 15 ohne Sprung), Puffer des Aufbewahrers bytegleich übergeben |
| Ende eines fremden Kindes | `waitpid` geht nicht (ECHILD), aber `kqueue` mit `NOTE_EXIT \| NOTE_EXITSTATUS` liefert Ende **und Exit-Code** (gemessen: Status 7) |

Der letzte Punkt vereinfacht den Plan: In der Tabelle „Was dafür geändert werden muss“ steht, die neue App bekomme den Exit-Code nicht. Sie bekommt ihn über `kqueue`.

**Lesepause (niemand liest die Leitung 30 s lang):** Aufbau mit einem eigenen PTY-Host auf Basis von SwiftTerm ohne Fenster (Claude Code 2.1.322 und Codex 0.160.1 echt, mit Giulianos Login, in Scratchpad-Ordnern).

| Fall | Ergebnis |
|---|---|
| Claude, Folge von 14 Bash-Schritten | arbeitet in der Pause normal weiter (4 Schritte in 30 s, Takt 6–10 s wie vorher), Turn endet sauber |
| Claude, lange gestreamte Antwort (260 Zeilen) | Antwort reißt nicht ab; bei Pausenbeginn war Zeile 136 gelesen, beim Weiterlesen lagen 27,5 KB bis Zeile 227 an, am Ende alle 260 Zeilen vollständig und in Reihenfolge |
| Codex, Folge von 12 Shell-Schritten | arbeitet in der Pause normal weiter (6 Schritte im gewohnten Takt von 4–6 s) |

Claude blockiert also nicht, wenn niemand liest, sondern sammelt im eigenen Speicher. Der Aufbewahrer muss deshalb nicht zwingend mitlesen, damit nichts hängt. Er sollte es trotzdem tun (wie im Plan), damit kein Chat unbegrenzt Speicher aufbaut und die Ausgabe der Lücke vollständig bei der neuen App ankommt.

### Frage 2: Das Bild nach der Übernahme — belegt, mit einer Bedingung

**Aufbau:** Im selben PTY-Host hängen mehrere SwiftTerm-Terminals am selben Chat: A sieht alles (wie eine App, die nie neu gestartet wäre), B bekommt ein gesichertes Bild von A und danach die weitere Ausgabe, D ist ein frisches Terminal ohne Bild. Verglichen wird Zelle für Zelle: Zeichen, Farben, Stile, dazu die Schalter, die die TUI gesetzt hat (Bracketed Paste, Fokus-Meldungen, Kitty-Tastaturprotokoll, Maus, Cursor). Das Sichern ist ein kleines Serialisieren des SwiftTerm-Puffers in einen ANSI-Strom (Text, Farben, Zeilenumbrüche, Alt-Screen, Cursor, Schalter).

| Messung | Claude | Codex |
|---|---|---|
| Gesichertes Bild in frischem Terminal | 341 Zeilen, 37.510 Zellen, **0 Abweichungen**, Schalter gleich; 30 KB, Sichern 26 ms, Einspielen 130 ms (Debug-Build) | 0 Abweichungen, Schalter gleich, 3 KB |
| Nur Text ohne Farben | 0 Zeichenfehler, 1.332 Zellen mit anderer Farbe | – |
| Größenänderung ohne gesichertes Bild (D) | Claude zeichnet nur den sichtbaren Bereich neu (5 KB); Schirm stimmt, **Verlauf fehlt** (292 von 352 Zeilen) und die Schalter fehlen | Codex zeichnet den ganzen Schirm neu (Alt-Screen); Schirm stimmt, **Schalter fehlen** |
| Mit gesichertem Bild weiterarbeiten (B) | nach zwei Größenänderungen und einem weiteren Turn mit Tabelle und Codeblock 0 Abweichungen (372 Zeilen) | 0 Abweichungen |
| Übernahme mitten in einer laufenden Antwort | 190 Zeitpunkte während einer Antwort: 190 von 190 identisch | 70 Zeitpunkte: 70 von 70 identisch |

**Die Bedingung:** Ohne gesichertes Bild fehlen nicht nur Verlauf und Farben, sondern auch die Schalter, die Claude und Codex nur beim Start setzen. Claude setzt das Kitty-Tastaturprotokoll (Stufe 5), Codex Stufe 7 und Mausmeldungen. Fehlen die, kommen Tasten wie Shift+Enter oder Mausklicks falsch an. Das Bild muss deshalb immer mit Schaltern gesichert werden, auch in einer ersten Stufe „nur Text“.

**Der Übergabepunkt:** 54 von 1.087 gelesenen Blöcken endeten mitten in einer Steuersequenz, 5 mitten in einem UTF-8-Zeichen. Das Bild muss genau an der Stelle gesichert werden, ab der der Aufbewahrer liest. Das ergibt sich von selbst, wenn die alte App erst aufhört zu lesen, dann den Rest verarbeitet, dann sichert und abgibt. In allen 260 Messpunkten war das Ergebnis dann identisch.

Nicht gemessen: das Zeichnen im echten Fenster (`MacLocalTerminalView`). Der Puffer ist derselbe, die Darstellung kann ich ohne Fenster nicht vergleichen.

### Frage 1: Die Lücke im Router — Ergebnis kippt den Ablauf

**Aufbau:** Test-Instanz mit eingeschaltetem GPT-Backend (Router auf Port 28766, Proxy auf 28765; das Proxy-Programm aus der Arbeits-App kopiert, kein Login kopiert). Ein Claude-Chat läuft außerhalb der App im PTY-Host mit derselben Umgebung, die die App setzen würde (`ANTHROPIC_BASE_URL` auf den Router, `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL`, Profil-Header). Nachgewiesen per `lsof`, dass die Anfragen über Port 28766 laufen. Die Test-Instanz wird mitten im Turn mit `scripts/test-instance.sh stop` beendet (SIGTERM, wie `make dev`) und nach 5, 15 oder 30 s neu gestartet. Ein Beobachter protokolliert, wann der Port zu und wieder offen ist. Dazu ein eigener Durchreich-Router, der eine Antwort gezielt nach 25 Textstücken kappt.

| Fall | Lücke | Ergebnis |
|---|---|---|
| Router weg, während Antworttext fließt | 5 s, 15 s | **Turn verloren.** Kein Wiederholen. Claude zeigt „API Error: Connection lost mid-response. The response above may be incomplete.“, der bis dahin gestreamte Text ist weg, der Chat steht wieder am Eingabefeld |
| dasselbe mit eigenem Durchreich-Router (harter Abbruch nach 36 KB) | 8 s | gleiches Bild, Turn verloren |
| nach dem Abbruch „mach genau dort weiter“ geschickt | – | Claude fängt von vorn an (Zeile 1 bis 150), setzt nicht fort |
| Router weg, während ein Tool läuft; die nächste Anfrage trifft den toten Port | 5 s | **läuft durch.** Claude meldet „Connection refused · Retrying in 1s · attempt 2/10“, nach dem Neustart geht es weiter, Turn endet sauber |
| Router weg kurz nach dem Absenden, bevor Text fließt (erste Messreihe) | bis 30 s | läuft durch; bei 30 s Lücke stand Claude bei „Retrying in 33s · attempt 7/10“ und kam danach durch |

Claude Code wiederholt also Anfragen, die keine Verbindung bekommen oder vor der Antwort abreißen, mit wachsenden Wartezeiten bis zu 10 Versuchen. Eine Antwort, die schon fließt, wiederholt es nicht.

**Der Proxy für GPT-Chats** stirbt mit der App: Nach jedem Beenden der Test-Instanz lief ein neuer Proxy-Prozess (Startzeit gleich dem Neustart der App). Ursache laut Code: SIGTERM wird seit dem SIGTERM-Handler zu einem regulären Beenden, dabei räumt `ClaudeCodeProxyManager` bei `willTerminate` den selbst gestarteten Proxy ab. Der Kommentar im `ClaudeCodeProxyOrphanGuard` (Proxy überlebt als Waise) beschreibt einen älteren Stand. Für GPT-Chats gilt damit dieselbe Lücke wie für den Router, zusätzlich verschwindet der Proxy-Prozess selbst. Den GPT-Weg mit echter Antwort konnte ich nicht prüfen, weil die Test-Instanz kein GPT-Login hat und Logins nicht kopiert werden dürfen.

**Noch offen in Frage 1:** Lücke von 15 und 30 s zwischen zwei Anfragen, Lücke ganz innerhalb eines Tool-Laufs, ein Ausfall von 5 Minuten, und mit dem Durchreich-Router die Fragen, ob Claude bei einem Abriss in der Denkphase, bei einem Fehlerereignis „overloaded“ im Strom oder bei einem Abriss während eines Tool-Aufrufs wiederholt.

### Folgerung bis hierher

Wie geplant gebaut, verlöre jeder Chat, der beim Neustart gerade eine Antwort streamt, diesen Turn. Bei aktivem GPT-Backend betrifft das alle Claude-Chats, ohne GPT-Backend keinen (dann spricht Claude direkt mit Anthropic). Drei Wege, die sich andeuten:

1. **Warten auf einen ruhigen Moment.** Der Router weiß, welche Antworten gerade fließen. Die Übergabe wartet, bis keine mehr offen ist (mit Obergrenze), und neue Anfragen in der Lücke laufen ins belegte Wiederholen. Klein, aber bei vielen arbeitenden Chats kann das Warten dauern.
2. **Router und Proxy aus dem App-Prozess lösen.** Ein kleiner eigener Prozess, den der Neustart nicht berührt. Löst das Problem grundsätzlich, ist aber der größere Umbau.
3. **Lauschenden Socket mitgeben.** Der Aufbewahrer hält auch den Port des Routers, Verbindungen warten dann statt abgelehnt zu werden. Hilft nur bei neuen Anfragen, nicht bei laufenden Antworten, und ist damit allein keine Lösung.

Die Empfehlung folgt nach Abschluss von Frage 1 und 3.

### Frage 3: Zugriffsrechte — noch offen

## Offene Entscheidungen

- Gilt die Übergabe später auch für Cmd+Q („Beenden, Chats laufen weiter“) und für das Update über Homebrew? Für den Einstieg nur `make dev`.
- Wie lange wartet der Aufbewahrer, wenn die App nicht wieder startet? Vorschlag: bis alle Chats von selbst enden, die Chats arbeiten solange unsichtbar weiter.
