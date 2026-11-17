---
status: aktiv (Paket 1: Kern und Kommandozeile, ohne Ansicht; Labs, ab Werk aus)
updated: 2026-11-17
---

# Geplante Aufgaben

Wiederkehrende Claude-Läufe, die WhisperM8 selbst startet: ein Auftrag (Text oder `/skill …`) in festem
Projektordner und Konto, zu festen Zeiten. Jeder Lauf ist ein normaler `claude -p`-Chat, den die App wie jeden
anderen findet. Plan und Entscheidungen: [`../plans/geplante-aufgaben.md`](../plans/geplante-aufgaben.md),
Entwurf der Ansicht: [`../design/geplante-aufgaben.html`](../design/geplante-aufgaben.html).

Stand Paket 1 (WM8-110): Kern, Starter, Nachholen, Kommandozeile `whisperm8 schedule`, Schalter unter
Einstellungen › Labs › Scheduled tasks. Die Ansicht in der Seitenleiste (Paket 2), Mitteilungen bei Fehlschlag
und „Mitlesen“ (Paket 3) fehlen noch.

## Wann ein Lauf startet

- **Nur mit laufender App** (Entscheidung E2). Das Fenster darf zu sein.
- Ein Zeitgeber steht auf dem nächsten Termin, spätestens 15 Minuten. Er ist an die Wanduhr gebunden: Schläft
  der Mac über den Termin, feuert er beim Aufwachen. Zusätzlich lösen Aufwachen, Uhr- und Zeitzonenwechsel und
  der App-Start einen Durchlauf aus.
- **Pünktlich** heißt bis 5 Minuten nach dem Termin. **Nachholen** (ab Werk an) bis 12 Stunden danach; der Lauf
  trägt dann `trigger: catchUp`. Älter, oder Nachholen aus: Der Termin wird als „verpasst“ eingetragen, ohne Lauf.
- Mehrere verpasste Termine zählen als einer, den jüngsten.
- Termine vor dem Anlegen, während einer Pause oder vor einer Zeitplan-Änderung laufen nie nach.

Die Rechnung ist rein und getestet: `ScheduledTaskCalendar` (`ScheduledTaskCalendarTests`).

## Kein Lauf doppelt

- Der fällige Termin wird in `lastSlot` gespeichert, **bevor** der Lauf startet. Stirbt die App dazwischen, ist
  der Termin verbraucht (höchstens einmal).
- Arbeitet der vorige Lauf derselben Aufgabe noch, startet kein zweiter: Der Termin steht als „übersprungen“
  da. Das gilt auch über einen App-Neustart, denn die App erkennt laufende Läufe an PID und Prozess-Startzeit
  aus `run.json` wieder.
- Gezählt wird dabei immer der jüngste **gestartete** Lauf, nicht der jüngste Ordner: Einträge „übersprungen“
  oder „verpasst“ haben keinen Prozess und liegen oft vor einem Lauf, der noch arbeitet. Gesucht wird in den
  jüngsten 50 Ordnern; eine Aufgabe, die lange nicht startet, kostet so keine Tausenden Lesezugriffe.
- `whisperm8 schedule run` verweigert, solange ein Lauf arbeitet oder gerade startet.
- Termin, Nachholen und Handstart laufen durch einen Actor (`ScheduledTaskScheduler`).
- Nur eine App-Instanz plant: Sie hält `scheduled-tasks/scheduler.lock` per `flock`. Eine zweite Instanz mit
  denselben Daten ändert nichts.

## Ein Lauf

Vor dem Start prüft der Planer Projektordner, Konto (kein Ausweichen auf `main`) und `claude auth status`. Ist
der Login abgelaufen oder niemand angemeldet, startet nichts; der Lauf steht als „nicht gestartet, Login
abgelaufen“ da, ohne Chat.

Gestartet wird `/bin/sh` mit einem festen Skript, das `claude` aufruft und danach den Exit-Code schreibt:

```
claude -p "<Auftrag>" --output-format json --session-id <uuid> --name "<Aufgabe> · <Datum>" \
       --disallowedTools Bash Monitor WebFetch WebSearch "mcp__*" "Edit(/.claude/**)" "Edit(/.git/**)" \
                         "Edit(/.mcp.json)" --strict-mcp-config \
       --permission-mode dontAsk --allowedTools <Werkzeuge…>
```

- Eigene Sitzung und Prozessgruppe (`POSIX_SPAWN_SETSID`), stdin `/dev/null`, stdout nach `result.json`, stderr
  nach `stderr.log`. Alle Deskriptoren der App bleiben zu (`POSIX_SPAWN_CLOEXEC_DEFAULT`), Signale auf Standard.
  Ein App-Neustart (`make dev`, Update, Absturz) beendet den Lauf deshalb nicht.
- `--session-id`: Die App kennt den Chat des Laufs, bevor er existiert. `--name` nur, wenn die Claude-Version
  ihn kennt (ab 2.1.325) und `claudeNativeNameEnabled` an ist.
- Startordner ist der Projektordner der Aufgabe; unter diesem Projekt steht der Chat.
- Umgebung wie bei Chats: Login-Shell-PATH, Plugin `whisperm8`, `CLAUDE_CONFIG_DIR` für Nicht-`main`-Konten.
  Dazu `WHISPERM8_SCHEDULED_TASK_ID` und `WHISPERM8_SCHEDULED_RUN_ID`, an denen Hooks und Mods einen geplanten
  Lauf erkennen (etwa um ihm keine Supervisor-Hinweise einzuschieben, WM8-130). `WHISPERM8_SESSION_ID` und
  `WHISPERM8_SESSION_TOKEN` entfernt der Starter: Ein Lauf spricht nie mit der Kennung eines Chats.
- Kein `--model`: Welches Modell läuft, entscheidet Claude Code.

### Rechte

Ein `-p`-Lauf kann nicht nachfragen. `--permission-mode dontAsk` verweigert alles, was nicht erlaubt ist; Claude
meldet das in `permission_denials`, und der Lauf gilt als „geklappt mit Hinweis“.

Erlaubt wird per `--allowedTools`:

| `--access` | Werkzeuge |
|---|---|
| `project` (ab Werk) | `Read`, `Glob`, `Grep`, `Edit(/**)`, `Skill` |
| `read-only` | `Read`, `Glob`, `Grep`, `Skill` |
| `custom` | nur die mit `--allow` genannten |

Freigaben aus der `settings.json` des Kontos gelten zusätzlich (dort stehen etwa `Bash(git:*)`), ebenso
`allowed-tools` eines Skills. Damit Bash, Web und MCP trotzdem nur per ausdrücklicher Freigabe je Aufgabe gehen
(Entscheidung 17.11.2026), sperrt jeder Lauf diese Familien:

| Familie | Sperre | aufgehoben durch |
|---|---|---|
| Befehle | `--disallowedTools Bash` | `--allow Bash` oder `--allow "Bash(…)"` |
| Befehle im Hintergrund | `Monitor` | `--allow Monitor` oder eine Bash-Freigabe |
| Web | `WebFetch`, `WebSearch` | `--allow WebFetch` bzw. `--allow WebSearch` |
| MCP | `mcp__*` und `--strict-mcp-config` (lädt keinen MCP-Server) | irgendein `--allow mcp__…` |

Eine Sperre schlägt jede Freigabe, auch die des Kontos und die eines Skills. Ist eine Familie per `--allow`
offen, gelten für sie auch die Freigaben des Kontos: `--allow "Bash(whisperm8 tickets *)"` erlaubt also
zusätzlich alles, was die `settings.json` an Bash freigibt, und eine MCP-Freigabe lädt alle MCP-Server des Kontos.
`--strict-mcp-config` hält auch dann, wenn eine ältere Claude-Version das Muster `mcp__*` nicht kennt.

Was die Stufen wirklich heißen:

- **Lesen ist nicht auf den Projektordner begrenzt.** Ein nacktes `Read` (ebenso `Glob`, `Grep`) liest die ganze
  Platte, soweit der Nutzer sie lesen darf; ein Lauf mit Auftrag aus fremder Quelle könnte also Dateien außerhalb
  des Projekts lesen. Ins Netz bringt er sie ohne Bash, Web und MCP nicht.
- **Schreiben** geht nur im Projektordner: `Edit(/**)` deckt Edit und Write, eine Regel mit führendem `/` hängt bei
  CLI-Optionen am Startordner (Claude-Code-Doku „permissions“, „Where a pattern anchors“). Echt gemessen ist das
  noch nicht (Handtest am Ticket).
- **Nie schreibbar**, in jeder Stufe und gegen jede Freigabe: `.claude/`, `.git/` und `.mcp.json` im
  Projektordner. Dort stünden Hooks, `settings.local.json`, Git-Hooks und MCP-Server, die der nächste
  unbeaufsichtigte Lauf ausführte — an der Bash-Sperre vorbei. Edit-Regeln gelten auch für Write.
- **`read-only` ist nur lesend, solange Bash gesperrt ist.** Mit `--allow "Bash(…)"` kann ein Befehl schreiben.

## Dateien

```
~/Library/Application Support/WhisperM8/
  scheduled-tasks.json                  Aufgaben, schreibt nur die App
  scheduled-tasks/scheduler.lock
  scheduled-tasks/runs/<Aufgaben-ID>/<Lauf-ID>/
    run.json      Start-Eintrag der App (Sitzung, Auslöser, Termin, PID, Startzeit, Grund bei „nicht gestartet“)
    result.json   Ausgabe von claude -p --output-format json (schreibt der Lauf)
    stderr.log
    exit          „<Exit-Code> <Ende in Unix-Sekunden>“, schreibt der Lauf als Letztes
```

Ordner 0700, Dateien 0600. Die Lauf-ID beginnt mit der UTC-Zeit, die Ordner sortieren also nach Zeit. Kann die
App `scheduled-tasks.json` nicht lesen (kaputt oder von einer neueren Version), ändert sie die Datei nicht.
Felder werden nur ergänzt, nie umbenannt. Löschen einer Aufgabe nimmt ihre Lauf-Ordner mit, sofern keiner
arbeitet; die Chats bleiben.

Zeitplan in der Datei: `{"kind": "weekdays", "times": ["07:00", "22:30"]}`, `{"kind": "weekly", "days": [1, 3],
"times": ["08:00"]}` (1 = Montag), `{"kind": "hourly", "minute": 15}`, `{"kind": "daily", …}`.

### Ergebnis eines Laufs

Abgeleitet aus den Dateien (`ScheduledTaskRunEvaluator`), nicht gespeichert:

| Zustand | Wann |
|---|---|
| startet | `run.json` ohne PID, jünger als 2 Minuten |
| arbeitet | keine `exit`-Datei, Wrapper lebt (PID und Startzeit stimmen) |
| geklappt | Exit 0, `is_error` falsch, keine Verweigerungen; dazu der letzte Satz aus `result` |
| geklappt mit Hinweis | wie geklappt, aber `permission_denials` nicht leer |
| fehlgeschlagen | Exit ungleich 0 oder `is_error`; Meldung aus `result` oder `stderr.log` |
| abgebrochen | keine `exit`-Datei, Prozess weg (Mac neu gestartet, beendet) |
| nicht gestartet | Login abgelaufen, Konto oder Ordner fehlt, Claude fehlt, Start schlug fehl |
| verpasst, übersprungen | Termin zu alt bzw. voriger Lauf arbeitete noch |

## Kommandozeile

```
whisperm8 schedule list [--json]
whisperm8 schedule show <aufgabe> [--json]
whisperm8 schedule add --name "Abhängigkeiten prüfen" --dir ~/repos/whisperm8 --account main \
     --schedule "wöchentlich so 15:45" --prompt "Prüfe, ob es neue Versionen gibt. Ändere nichts."
whisperm8 schedule edit <aufgabe> [Optionen]
whisperm8 schedule remove|run|pause|resume <aufgabe>
```

Zeitplan-Angaben: `täglich 07:00`, `werktags 07:00, 22:30`, `wöchentlich so 15:45`, `stündlich :15` (auch
englisch: `daily`, `weekdays`, `weekly mon,wed`, `hourly`). `<aufgabe>` ist Name, ID oder ID-Anfang ab vier
Zeichen. `list` und `show` lesen von Disk und gehen auch ohne App; alles andere läuft über den Socket
(`schedule.*`, `AgentControlRequestHandler+Schedule`), die App schreibt. Mit ausgeschaltetem Schalter antwortet
die App „aus“.

## Kosten

- Ruhend: ein Wall-Clock-Timer, drei Beobachter (Aufwachen, Uhr, Zeitzone). Kein Polling, nichts im Renderpfad.
- Je Durchlauf: `scheduled-tasks.json` lesen und je Aufgabe den jüngsten Lauf-Ordner, abseits des Main Threads.
- Je Lauf: ein `claude auth status` (rund eine Sekunde) und der Lauf selbst. Ein `claude -p`-Lauf zählt gegen das
  Nutzungslimit des Kontos; der kleinste gemessene kostete rechnerisch 0,48 $ (Plan, Teil 1b).

## Offen für spätere Pakete

- Ansicht „Geplant“ in der Seitenleiste, Blatt zum Anlegen (Paket 2).
- Mitteilung bei Fehlschlag, Login-Warnung vor dem nächsten Lauf, Mitlesen statt Fortsetzen, Archiv (Paket 3).
- Aufräumen alter Lauf-Ordner: Bis Paket 3 bleiben sie liegen (wenige KB je Lauf).
- Übernahme der PM-Analyse (Paket 4, braucht Giulianos Ja). Ihr launchd-Eintrag bleibt bis dahin unberührt.
