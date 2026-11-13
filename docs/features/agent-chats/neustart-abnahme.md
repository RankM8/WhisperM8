# Abnahme: Neustart ohne Chatverlust

**Stand:** 13.11.2026 · **Plan:** [neustart-ohne-chatverlust.md](../../plans/neustart-ohne-chatverlust.md) · **Zweite Meinung:** [neustart-zweite-meinung.md](../../plans/neustart-zweite-meinung.md) · **Aufbewahrer:** [neustart-aufbewahrer.md](neustart-aufbewahrer.md)

Zwei Skripte prüfen die Übergabe in der Test-Instanz. Den guten Fall prüft `scripts/handover-soak.sh`. Die Rückfall-Wege prüft `scripts/handover-soak-faults.sh`, indem es absichtlich Fehler auslöst. Beide fassen nur die Test-Instanz an (`scripts/test-instance.sh`, eigene Wurzel, eigene Bundle-ID), nie die laufende App und nie echte Chats.

Das Test-Bundle muss aus dem Sammel-Branch `neustart/integration` gebaut sein, sonst fehlt Paket 1.

## Aufruf

```
scripts/test-instance.sh build                       # Test-Bundle aus dem aktuellen Ordner
scripts/handover-soak.sh capabilities                # was Paket 4 schon liefert
scripts/handover-soak.sh run --rounds 5              # Pflichttest aus dem Plan
scripts/handover-soak-faults.sh run [--only <szenario>] [--signing dev|adhoc]
scripts/handover-soak.sh self-test                   # Prüf-Funktionen ohne App
scripts/handover-soak-faults.sh self-test
```

Läuft die Test-Instanz schon, etwa für einen anderen Chat, brechen beide Skripte ab; `--use-running` übersteuert das. `WHISPERM8_TEST_ROOT` muss ein absoluter Pfad sein, sonst spräche die CLI die Produktiv-App an.

## Ergebnisse

Jede Prüfung meldet **OK**, **FEHLER** oder **FEHLT**. FEHLT heißt: Ein Befehl oder Messpunkt aus Paket 4 ist noch nicht da, deshalb wurde nicht geprüft. Exit 0 heißt alles OK, Exit 1 heißt mindestens ein FEHLER, Exit 2 heißt nur FEHLT. Bricht ein Lauf ab, entstehen trotzdem Bericht und Aufräumen, und er endet mit Exit 1, auch wenn bash 3.2 selbst Status 0 meldet. Der Bericht liegt unter `<Test-Wurzel>/soak/report.md` oder unter `--report`.

## Chats im Lauf

- **Chat-Start:** Ein Chat startet erst, wenn sein Tab oder Pane angezeigt wird. Ohne `chats new --start` startet das Skript die Test-Instanz deshalb sichtbar (`WHISPERM8_TEST_VISIBLE=1`), legt die Chats in einen eigenen Grid-Workspace und öffnet ihn nach jedem Start wieder. Ole hat entschieden, dass das so bleibt; einen zweiten Startweg ohne Anzeige gibt es nicht.
- **Claude und Codex:** Sie laufen als Prozesse mit (Start, PID, Doppelstart-Sperre, Token aus dem Chat). Die Test-Instanz hat keinen Login (Entscheidung des Users), deshalb entfallen ihre Inhaltsprüfungen mit FEHLT. Das sind API-Fehler, offene Rückfrage, vollständige Antworten und Fertig-Meldungen. Den Inhalt prüft der User am Ende von Hand (unten).
- **Ersatz-Chats:** Sie brauchen `chats new --provider terminal --command` aus Paket 4.
  - Zähler: schreibt alle 0,2 s `Nummer Zeitstempel`. Geprüft wird, dass keine Zeile fehlt, keine doppelt kommt und die Zeit nie rückwärts läuft. Gemeldet wird die längste Lücke, also die Dauer der Übergabe aus Sicht des Chats.
  - Echo: wartet auf Eingabe und gibt sie nummeriert zurück. Nach jedem Neustart schickt das Skript eine Probe. Sie muss genau einmal und lückenlos nummeriert ankommen; das belegt Eingabe und Bild nach der Übernahme.
- **Projektordner:** `/private/tmp/whisperm8-soak-<uid>/project`, absichtlich außerhalb des echten Home. Claude sucht `.mcp.json` auch in übergeordneten Ordnern und blieb sonst im Dialog „new MCP servers found“ stehen.

## Prüfungen

| Prüfung | Was sie misst |
|---|---|
| gleiche PIDs | Jeder Chat läuft nach dem Neustart mit derselben PID weiter. |
| ein Prozess je Sitzung | Claudes Registry hat je Sitzung höchstens einen lebenden Prozess. Die Fehler-Szenarien prüfen das etwa jede Sekunde, für Codex über die Prozessliste. |
| Token aus dem Chat | `chats list` plus ein mutierender Aufruf (Pin setzen und entfernen) mit der Identität des Chats. |
| kein Erbe | Per `lsof`: Kein Kind der Test-App hält einen Unix-Socket der App. Das gilt für per `Process` gestartete Helfer und für Chats aus `forkpty`. Laut Review ist das neben dem Geheimnis die zweite echte Grenze. |
| Aufbewahrer weg | Nach der Übergabe kein Aufbewahrer, kein Socket, keine Discovery-Datei. |
| Zähler, Echo | siehe Ersatz-Chats |
| Inhalt (mit Login) | kein „API Error“/„Retrying“, Rückfrage offen, Antworten vollständig, genau eine Fertig-Meldung |

## Signaturarten

Releases sind ad hoc signiert, Dev-Builds tragen das Zertifikat „WhisperM8 Local Dev“ ohne Team-ID. Deshalb fährt die Abnahme den Austausch einmal je Art (Vics Auflage 4 aus seinem Urteil zum Schlüsselbund vom 13.11.2026). Ad hoc ist der Fall aller Brew-Nutzer und war bis dahin in keinem Test:

```
scripts/handover-soak-faults.sh run --only binary-swap --signing dev     # Dev-Build auf Dev-Build (make dev)
scripts/handover-soak-faults.sh run --only binary-swap --signing adhoc   # ad hoc auf ad hoc (Brew-Update)
```

Ohne `--signing` gilt die Art, mit der `scripts/test-instance.sh build` das Bundle signiert hat. `--signing` signiert das Test-Bundle vor dem Start in dieser Art und den neuen Build beim Austausch ebenso, mit demselben Befehl wie das Makefile. Der neue Build entsteht vor der Abgabe, damit `codesign` nicht im Messfenster liegt; der Wächter zählt nur SecurityAgent-Prozesse, die danach neu auftauchen. Der Bericht nennt beide CDHashes; bleibt der CDHash gleich, ist das ein FEHLER, weil dann kein neuer Build getestet wurde. Eine laufende Instanz (`--use-running`) wird nie umsigniert. `scripts/test-instance.sh build` stellt die Dev-Signatur wieder her.

## Fehler-Szenarien

| Szenario | Auslöser | Erwartung |
|---|---|---|
| `kill-mid-take` | SIGKILL an den Aufbewahrer, wenn mindestens ein Chat übernommen ist und mindestens einer nicht | Übernommene laufen weiter, der Rest wird fortgesetzt; nie zwei Prozesse |
| `hold-deadline` | `test-instance.sh handover`, keine neue App bis nach der Haltefrist | Aufbewahrer endet selbst, alte Prozesse sind weg, nach dem Start wird fortgesetzt |
| `secret-missing`, `secret-wrong` | Stellschraube `handoverSecretOverride` | Die App beendet den Aufbewahrer über die PID aus STATUS, statt die Frist abzuwarten; dann Fortsetzen |
| `binary-swap` | Bundle unter dem laufenden Aufbewahrer ersetzt: neue Build-Nummer, gleiches Zertifikat, `rsync --delete` wie bei `make dev` | Übernahme klappt trotz ersetzter Datei |
| `double-restart` | zweiter Neustart, während die Übernahme des ersten läuft | Übernahme, kein zweiter Prozess |
| `router-switch` | Lauf mit Schalter aus (GPT-Router in der App), dann Schalter an und `restart --keep-chats` | Keine Übergabe, Hinweis „wirkt erst ab diesem Neustart“, klassischer Neustart, Fortsetzen |
| `router-service` | gewöhnlicher `restart --keep-chats`, nach `router-switch` der zweite Neustart (Router als Dienst) | Übernahme mit denselben PIDs |

Jedes Szenario prüft danach:

- Die Chats kommen zurück, die PIDs bleiben einige Sekunden stabil.
- Es gibt keine Leichen: kein Aufbewahrer, kein Socket, keine fremde Datei im Ordner des Aufbewahrers, kein Claude-Prozess ohne Chat.
- `geheimnis-datei`: Das Einmal-Geheimnis `take-secret` (Option A) liegt nach dem Szenario nicht mehr da. Die neue App löscht es nach dem Lesen, der Aufbewahrer bei seinem Ende. Der Bericht sagt, ob der Wächter die Datei während der Übergabe gesehen hat. Der Dauerlauf prüft dasselbe nach jeder Runde.
- Kein Kind erbt einen Socket.
- Start ohne Auswahl: Jeder Chat, der vorher einen Prozess hatte, hat nach 20 s wieder einen, ohne dass er ausgewählt wurde. Sonst ist das ein FEHLER; danach wählt das Skript die fehlenden Chats per `chats open` aus, damit die übrigen Prüfungen laufen (Befund vom 13.11.: Nach dem Rückfall startete nur der ausgewählte Chat im Grid).
- Codex ohne Login legt keine Sitzung an. Ohne Sitzungs-ID baut die App kein `codex resume`, ein solcher Chat kann im Rückfall also nicht zurückkommen. Das Skript prüft bei ihm nur die Übernahme und trägt das Fortsetzen als FEHLT ein (gemessen am 13.11.: kein Codex-Prozess nach dem Rückfall, auch nicht nach Auswahl).
- Eine PID je Sitzung: Wird die PID eines Chats über seine Prozessumgebung bestimmt (`WHISPERM8_SESSION_ID` in der Wurzel der Test-Instanz) und gibt es dabei mehr als einen obersten Prozess, ist das der FEHLER `zwei-prozesse-umgebung`. Das Skript wählt dann keine der PIDs aus.
- Kein Schlüsselbund-Dialog: Der Wächter meldet jeden laufenden `SecurityAgent`. Das kann auch eine fremde App sein, deshalb steht der Hinweis „Bildschirm prüfen“ dabei.
- Rechte: Ordner des Aufbewahrers 0700, `take-secret` und jede unbekannte Datei 0600, solange sie existiert. Ausgenommen sind die Dateien aus Paket 2 und 4 (`keeper.lock`, `keeper.log`, Socket, `last-take.json`, `take.lock`).

Am Ende des Laufs prüft `geheimnis-muster` das System-Log der Test-App seit Laufbeginn (mit `--info --debug`), `keeper.log` und das Log der Test-Instanz auf eine Zeile mit „secret“ und einem Hex-Wert ab 7 Zeichen; UUIDs zählen nicht. Der Bericht zeigt davon höchstens die ersten 6 Zeichen. Das greift auch, wenn das Geheimnis im Schlüsselbund liegt (Befund vom 13.11.: `handover_take_plan` schrieb den Anfang des Geheimnisses ins System-Log).

Danach prüft `geheimnis-im-log`, dass kein Geheimnis-Kandidat in einem Log steht. Kandidaten sind `take-secret` und jede kleine unbekannte Datei im Ordner des Aufbewahrers; der Wächter sichert ihren Inhalt alle 0,3 s, solange sie liegen (nur im Zustandsordner des Laufs, 0600, am Ende gelöscht). Gesucht wird roh, als Hex und als Base64 in `keeper.log`, im Log der Test-Instanz und im System-Log seit Laufbeginn. Hat der Wächter `take-secret` nie gesehen, steht der Punkt als FEHLT da.

## Was Paket 4 dafür liefern muss

Solange es fehlt, steht der Punkt als FEHLT im Bericht. Die Namen sind Vorschläge an Ole; das Skript passt sich an.

1. `scripts/test-instance.sh restart --keep-chats` (Neustart mit Übergabe) und `scripts/test-instance.sh handover` (abgeben, keine neue App starten).
2. `chats new --provider terminal --command '<sh>'` für die Ersatz-Chats.
3. `chats new --background` für einen angedockten Hintergrund-Chat.
4. `debug terminal <ref> --text` für „Retrying“ im Terminal.
5. Eine Logzeile je Fertig-Meldung: `session_notification_posted kind=turnCompleted session=<uuid>`.
6. `runtime.pid` in `chats show --json` für Codex und Terminal.
7. Stellschrauben nur für die Test-Instanz: `handoverHoldSeconds`, `handoverTakeDelayMs`, `handoverSecretOverride` (`missing`, `wrong`).
8. Das Geheimnis als Datei im Ordner des Aufbewahrers (`…/WhisperM8/handover/take-secret`, geliefert mit Option A, 074af842).
9. Den Ordner des Aufbewahrers auf 0700 setzen, auch wenn er schon existiert (gemessen am 13.11.: 0700).

## Bekannte Grenzen

- **Wächter:** Er sieht eine Überschneidung erst, wenn sich der neue Claude-Prozess in der Registry eingetragen hat. Am Ende prüft `check_comeback` zusätzlich, dass der alte Prozess tot ist, wenn ein neuer läuft.
- **Zurechnung durch den Kernel:** Er rechnet einen Unix-Socket dem Prozess zu, der ihn zuletzt benutzt hat, und schon `poll()` zählt dazu. Code-Prüfung und Absender-Bindung im Aufbewahrer sind deshalb Hürden, keine Garantien. Die Grenzen sind das Geheimnis und dass kein Kind den Socket erbt (Vics Urteil, Abschnitt „Wovor schützen wir“ in der Doku des Aufbewahrers).
- **GPT-Chats:** Die Test-Instanz hat kein GPT-Login, GPT-Chats fehlen im Lauf.
- **GPT-Router:** Ohne GPT-Backend startet die Test-Instanz nie einen Router. Der Router-Modus (`ClaudeGPTRouterMode.current`, ein `static let`) wird erst beim ersten Zugriff festgelegt, in der echten App beim Router-Start. `router-switch` legt ihn deshalb mit einer harmlosen Router-Anfrage über den Steuer-Socket fest, solange der Schalter aus ist (die App lehnt sie mit „Router-Dienst ist in diesem Lauf nicht aktiv“ ab). Ob laufende GPT-Antworten den Neustart über den Router-Dienst überstehen, prüft erst der Handtest.
- **Kein Erbe nach Übernahme:** Übernommene Chats sind keine Kinder der neuen App; hat sie sonst keine Kinder, steht `kein-erbe` als FEHLT da.

## Handtest des Users (mit echten, angemeldeten Chats)

Nur mit Chats, deren Verlust nicht schlimm wäre, zum Beispiel einem eigenen Projekt nur für diesen Test. Vorher den Labs-Schalter „Neustart ohne Chatverlust“ einschalten.

1. **Aufbau, alle Chats im selben Fenster sichtbar:**
   - ein Claude-Chat mit einer Folge von Bash-Schritten („führe nacheinander 20× `echo n; sleep 3` aus“);
   - ein Claude-Chat mitten in einer langen Antwort („schreibe 300 nummerierte Zeilen“);
   - ein GPT-Chat mit langer Antwort;
   - ein Codex-Chat mit Shell-Schritten;
   - ein Terminal-Tab mit `i=0; while :; do i=$((i+1)); echo $i; sleep 1; done`;
   - ein angedockter Hintergrund-Chat;
   - ein Chat mit offener Rückfrage (AskUserQuestion).
2. **Erster Neustart:** `make dev`, während alles läuft.
3. **Prüfen:**
   - Alle Tabs sind wieder da. Die PIDs sind gleich, im Terminal mit `ps -o pid,command -p <pid>` vor und nach.
   - Die lange Antwort ist vollständig, ohne „API Error“ und ohne „Retrying“.
   - Die Rückfrage ist noch offen.
   - Der Zähler im Terminal läuft ohne Sprung weiter.
   - `whisperm8 chats list` funktioniert aus einem der Chats.
   - Es kommt keine doppelte Fertig-Meldung.
4. **Zweiter Neustart:** sofort danach noch einmal `make dev`, dann dieselben Prüfungen.
5. **Schalter aus:** Labs-Schalter ausschalten und `make dev`. Die Chats enden wie bisher und kommen per Fortsetzen zurück.
6. **Bericht:** Auffälligkeiten mit Uhrzeit an Jarvis, dazu `log show --last 15m --predicate 'subsystem == "com.whisperm8.app" AND category == "handover"'`.
