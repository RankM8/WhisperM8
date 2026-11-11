# Plan: `make dev` ohne Chat-Abbruch

**Stand:** 11.11.2026 · **Status:** Beratung mit Empfehlung, Vorversuch und Freigabe offen, kein App-Code geändert
**Herkunft:** Wunsch vom 11.11.2026 nach der Wettbewerbsanalyse ([`wettbewerb-orca-t3code/auswahl.md`](wettbewerb-orca-t3code/auswahl.md), Punkt 5)

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

## Offene Entscheidungen

- Gilt die Übergabe später auch für Cmd+Q („Beenden, Chats laufen weiter“) und für das Update über Homebrew? Für den Einstieg nur `make dev`.
- Wie lange wartet der Aufbewahrer, wenn die App nicht wieder startet? Vorschlag: bis alle Chats von selbst enden, die Chats arbeiten solange unsichtbar weiter.
