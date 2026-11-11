# Plan: `make dev` ohne Chat-Abbruch

**Stand:** 11.11.2026 · **Status:** Vorversuch abgeschlossen, Urteil „bauen mit Änderung“ (Router übergibt seinen Socket, statt abzubrechen), Freigabe für den Bau offen, kein App-Code geändert
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
| Prozessende eines übernommenen Chats | Die neue App ist nicht mehr Elternprozess. Ende und Exit-Code bekommt sie über `kqueue` (`NOTE_EXIT`, `NOTE_EXITSTATUS`), siehe Vorversuch. |

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

## Offene Entscheidungen

- Gilt die Übergabe später auch für Cmd+Q („Beenden, Chats laufen weiter“) und für das Update über Homebrew? Für den Einstieg nur `make dev`.
- Wie lange wartet der Aufbewahrer, wenn die App nicht wieder startet? Vorschlag: bis alle Chats von selbst enden, die Chats arbeiten solange unsichtbar weiter.
