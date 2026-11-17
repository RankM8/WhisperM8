---
status: aktiv (Paket 1 Kern und Kommandozeile, Paket 2 Ansicht, Paket 3 Meldungen und Chat; Labs, ab Werk aus)
updated: 2026-11-17
---

# Geplante Aufgaben

Wiederkehrende Claude-Läufe, die WhisperM8 selbst startet: ein Auftrag (Text oder `/skill …`) in festem
Projektordner und Konto, zu festen Zeiten. Jeder Lauf ist ein normaler `claude -p`-Chat, den die App wie jeden
anderen findet. Plan und Entscheidungen: [`../plans/geplante-aufgaben.md`](../plans/geplante-aufgaben.md),
Entwurf der Ansicht: [`../design/geplante-aufgaben.html`](../design/geplante-aufgaben.html).

Stand (WM8-110): Kern, Starter, Nachholen, Kommandozeile `whisperm8 schedule`, Schalter unter
Einstellungen › Labs › Scheduled tasks (Paket 1); Abschnitt „Geplant“ in der Seitenleiste, Detail und Blatt zum
Anlegen (Paket 2); Mitteilung bei Fehlschlag, Login-Warnung, „Mitlesen“ und Archiv (Paket 3). Die Übernahme der
PM-Analyse (Paket 4) fehlt noch.

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
| Wege nach außen | `SendMessage`, `ListAgents` (andere lokale Claude-Sitzungen, die Bash haben), `RemoteTrigger` (Cloud-Routinen), `CronCreate`, `CronDelete`, `PushNotification`, `DesignSync`, `EnterWorktree`, `ExitWorktree` (anderer Arbeitsordner verschöbe die Schreibregeln) | je Werkzeug `--allow <Name>`; `Agent` und `Workflow` bleiben offen, Subagents erben die Sperren |

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
  scheduled-tasks/archive/<Aufgaben-ID>/<Lauf-ID>/   ältere Läufe, gleicher Inhalt (Paket 3)
```

Ordner 0700, Dateien 0600. Die Lauf-ID beginnt mit der UTC-Zeit, die Ordner sortieren also nach Zeit. Kann die
App `scheduled-tasks.json` nicht lesen (kaputt oder von einer neueren Version), ändert sie die Datei nicht.
Felder werden nur ergänzt, nie umbenannt (`runArchiveDays` kam mit Paket 3, fehlt es, gilt 14). Löschen einer
Aufgabe nimmt ihre Lauf-Ordner und ihr Archiv mit, sofern keiner arbeitet; die Chats bleiben.

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
whisperm8 schedule edit <aufgabe> [Optionen]          # auch --archive-runs 14|7|never
whisperm8 schedule remove|run|pause|resume <aufgabe>
```

Zeitplan-Angaben: `täglich 07:00`, `werktags 07:00, 22:30`, `wöchentlich so 15:45`, `stündlich :15` (auch
englisch: `daily`, `weekdays`, `weekly mon,wed`, `hourly`). `<aufgabe>` ist Name, ID oder ID-Anfang ab vier
Zeichen. `list` und `show` lesen von Disk und gehen auch ohne App; alles andere läuft über den Socket
(`schedule.*`, `AgentControlRequestHandler+Schedule`), die App schreibt. Mit ausgeschaltetem Schalter antwortet
die App „aus“.

## Ansicht

- **Abschnitt „Geplant“** fest unten in der Seitenleiste, direkt über der Fußzeile und durch eine dünne Linie
  getrennt; die Chat-Liste scrollt darüber (Entscheidung 17.11.2026 — vorher hing er am Ende der Chat-Liste,
  wo er bei vielen Chats nicht zu finden war). Nur mit Schalter; ohne Schalter bleibt kein Rand stehen.
  Zuklappbar (`agentScheduledTasksSectionCollapsed`): zu eine Zeile mit Zahl der Aufgaben und roter Fehlerzahl,
  auf höchstens ein Drittel der Seitenleiste (120–240 pt, `maxListHeight(sidebarHeight:)`) mit eigenem
  Scroll. „+“ steht immer im Kopf und legt an. Per Controller ist der Abschnitt wie bisher nicht erreichbar
  (seine Zeilen sind keine Listenzeilen der Controller-Navigation). Je Aufgabe eine Zeile wie ein Chat: Zustand,
  Name, rechts der nächste Termin als feste Uhrzeit („morgen 07:00“), sonst „läuft“, „Fehler“ oder „pausiert“.
  Der Pfeil klappt die letzten drei Läufe auf; ein Klick auf einen Lauf öffnet seinen Chat, ein Klick auf die
  Aufgabe ihr Detail. Läufe ohne Chat (nicht gestartet) oder solche, die noch arbeiten, führen ins Detail.
- **Detail** im Inhaltsbereich statt des Chats (je Fenster, flüchtig, `AgentWindowStore+ScheduledTasks`):
  Jetzt starten, Pausieren/Fortsetzen, Ändern; ein Kasten für Fehler, Arbeit oder Pause; Zeitplan, nächster
  Termin, Konto mit Login-Ende, Projekt, Rechte, Nachholen, Auftrag und die letzten 20 Läufe. Jede Navigation
  zu einem Chat oder Workspace und die Ticket-Ansicht schließen es. „Jetzt starten“ ist aus, solange ein Lauf
  arbeitet oder die Aufgabe pausiert ist.
- **Chat eines Laufs:** gesucht über die Sitzungs-ID des Laufs (`--session-id`). Steht er noch nicht in der
  Liste, stößt der Klick einen Scan an und das Detail sagt es. Arbeitet der Lauf, öffnet der Klick seinen Chat
  zum Mitlesen (siehe unten); „Mitlesen“ steht dann auch im Kasten „Arbeitet“ und an der Lauf-Zeile.
- **Überschrift „Geplant“:** zugeklappt die Zahl der Aufgaben, immer die Zahl der Aufgaben, deren letzter Lauf
  fehlschlug („1 failed“, rot).
- **Blatt** zum Anlegen und Ändern: dieselben Felder und Prüfungen wie `schedule add|edit`
  (`ScheduledTaskEditorForm`), Meldungen übersetzt; der Planer prüft beim Speichern noch einmal. Beim Ändern
  gehen nur geänderte Felder an den Planer, ein unveränderter Zeitplan behält so seinen Stand. Löschen mit
  Rückfrage, die Chats bleiben.
- **Laden** (`ScheduledTasksOverviewModel`): abseits des Main Threads, nur auf Anlass — erstes Erscheinen,
  jeder Durchlauf des Planers (Termin, Aufwachen, CLI-Änderung), Ende eines Laufs, Aktion in der Ansicht. Kein
  Polling, kein Datei-Beobachter.
- **Schalter von außen:** `defaults write com.whisperm8.app scheduledTasksEnabled -bool YES|NO` startet oder hält
  den Zeitgeber an (KVO auf genau diesen Schlüssel). Die CLI liest den Schalter aus der Domain der App, nicht aus
  der des Aufrufs (`AppPreferences.appDomain()`); vorher meldete `schedule list` über den Symlink
  `~/.local/bin/whisperm8` immer „aus“.

## Meldungen und Chat (Paket 3)

### Mitteilung bei Fehlschlag

Endet ein Lauf mit Fehler, bricht er ab (Prozess weg ohne Ergebnis) oder startet er zu seinem Termin nicht
(Login abgelaufen, Konto, Ordner oder Claude fehlt, Start schlug fehl), kommt eine macOS-Mitteilung
(`ScheduledTaskNotifications`): Titel „Geplante Aufgabe fehlgeschlagen“, darunter Name und Meldung. Ein Klick
öffnet das Detail der Aufgabe im Hauptfenster; der Knopf „Chat öffnen“ den Chat des Laufs, sofern es einen gibt
und der Indexer ihn schon kennt (sonst ebenfalls das Detail). Verpasste und übersprungene Termine melden sich
nicht, ebenso wenig ein von Hand gestarteter Lauf, der gar nicht startet: Ansicht und CLI sagen das sofort selbst.
Je Lauf höchstens eine Mitteilung. Endet ein Lauf, während die App zu ist (er läuft losgelöst weiter), kommt
keine Mitteilung: Nach dem Start erkennt die App nur arbeitende Läufe wieder. Der Fehlschlag zeigt sich dann nur
über die rote Zahl an „Geplant“ und im Detail.

### Login-Warnung

Endet der Login des Kontos vor dem nächsten Termin (oder ist er schon abgelaufen), zeigt das Detail einen gelben
Kasten mit dem Ende, dem Satz, dass der nächste Lauf dann nicht startet, und „Login erneuern …“ (öffnet
Einstellungen › Konten). Das Enddatum kommt aus `ClaudeLoginExpiryStore`, derselben Quelle wie die
Ablaufanzeige der Konten (Keychain, stündlich gelesen). Pausierte Aufgaben warnen nicht. Die Regel ist rein
(`ScheduledTaskLoginWarning`).

### Mitlesen

In einen Claude-Chat, dessen Tab keinen laufenden Prozess hat, schreibt gerade ein anderer Prozess: Dann wird
er nicht fortgesetzt, sondern gelesen (`AgentSessionReadAlong`). Das gilt für jeden solchen Chat, nicht nur für
geplante Läufe (Plan, Teil 1b), aber nur für normale Claude-Chats: Hintergrund-Agents (`claude --bg`) öffnet man
gerade durch Anhängen, Subagent-Jobs haben ihren eigenen Weg.

Der Status-Speicher der Chats taugt dafür nicht: Er nimmt Registry-Einträge nur für Chats mit eigenem PTY an
(sonst bliebe ein fremder Lauf, der mitten im Turn endet, für immer „arbeitet“). Gezählt werden deshalb zwei
Belege, jeder reicht:

- **Registry:** ein lebender Eintrag in Claudes Registry zu dieser Sitzung, der kein Hintergrund-Agent ist
  (`ClaudeRegistryStatusSource.records(forExternalSessionID:)`; die Quelle hält nur Einträge lebender PIDs).
- **Geplant:** ein Lauf einer geplanten Aufgabe, der mit dieser Sitzung arbeitet
  (`ScheduledTasksOverviewModel.activeRunTasksBySession`, erkannt an PID und Startzeit aus `run.json`). Das
  greift auch, wenn `claude -p` keinen Registry-Eintrag schreibt.

Neu geprüft wird bei jeder Registry-Änderung zu dieser Sitzung (`ClaudeRegistryStatusSource.changes`), bei
einem neuen Stand der laufenden Läufe (`activeRunsDidChange`), wenn der eigene Prozess erscheint oder endet, und
im Takt des Nachladens.

- Der Verlauf steht wie bei jedem geschlossenen Chat (`TranscriptTextView`, ein `NSTextView`), darüber eine
  Leiste, die den Schreiber nennt (Aufgabe, sonst PID und Konto), unten der Live-Streifen.
- Nachgeladen wird alle 3 s über den geteilten Verlaufs-Cache. Der fragt Größe und Änderungszeit der Datei ab
  und liest nur bei einer Änderung; neu gebaut wird der Text nur bei neuen Nachrichten. Endet der Lauf, holt die
  Ansicht den letzten Stand.
- Jeder Start dieses Chats (Knopf, Tab, `whisperm8 chats resume`, Controller, Rückfall der Übernahme) läuft durch
  `launchAfterCacheWarmup` und ist dort mit denselben Belegen gesperrt, mit Meldung im Chat und
  `read_along_start_blocked` im Log. Ein vorgemerkter Start aus dem Rückfall der Übernahme bleibt dabei stehen.

### Archiv

Lauf-Ordner gehen nach 14 Tagen (je Aufgabe wählbar: 7 Tage oder behalten) nach
`scheduled-tasks/archive/<Aufgabe>/`. Der Planer räumt im Durchlauf auf, höchstens einmal je Stunde. Das Alter
steht im Ordnernamen; gelesen wird nur, was alt genug ist. Ein arbeitender Lauf und die jüngsten drei Ordner
bleiben immer stehen, die Chats der Läufe ohnehin. Liegt ein gleichnamiger Ordner schon im Archiv, bekommt der neue
eine Nummer. Die Zahl im Archiv schreibt das Verschieben nach `archive/<Aufgabe>/.count`; das Detail liest nur
diese Datei, kein Listing.
Einstellbar im Blatt („Alte Läufe“) und per `--archive-runs`.

### Läufe nicht in der Chat-Liste

Läufe stehen nur unter ihrer Aufgabe (Entwurf, Variante A „nur hier“). Dafür war nichts zu bauen: Ein Lauf ist ein
vom Indexer gefundener Chat, `createdManually` bleibt leer, und die Chat-Liste zeigt nur in der App angelegte
Chats. Damit fehlt er auch in Zählern, Suche und Projekt-Ansichten, selbst wenn er arbeitet oder als Tab offen
ist (`ScheduledTasksMessagesTests`). Über die Sitzungs-ID aus `run.json` findet ihn nur der Abschnitt „Geplant“.
Notch und Insel zählen ihn dagegen als „arbeitet“ bzw. „fertig“ mit (dieselbe Statusquelle wie der Wach-Knopf).

### Kleinere Punkte aus den Prüfungen

- Meldungen des Planers kommen als Fälle (`ScheduledTaskValidationProblem`, `SchedulerError`); die CLI behält
  ihren deutschen Text, die Ansicht übersetzt (`ScheduledTaskTexts.problem`, `.schedulerError`).
- Datumsangaben in der Sprache der App (`ScheduledTaskTexts.appLocale`), Formatierer je Vorlage einmal gebaut.
- `loadedAt` ändert sich nur bei neuer Übersicht oder neuem Kalendertag.
- Bei offenem Detail gibt es kein Diktat-Ziel; Auf- und Zuklappen zieht Diktat-Kontext und Controller-Leiste nach.
- Abbrechen im Blatt während der Ordnerprüfung speichert nicht; während der Planer schreibt, ist Abbrechen aus.
- Ein Laden, das vor dem Anlegen begann, verdrängt die neue Aufgabe nicht (Generationszähler).

## Kosten

- Ruhend: ein Wall-Clock-Timer, drei Beobachter (Aufwachen, Uhr, Zeitzone). Kein Polling, nichts im Renderpfad.
- Je Durchlauf: `scheduled-tasks.json` lesen und je Aufgabe den jüngsten Lauf-Ordner, abseits des Main Threads.
  Höchstens einmal je Stunde zusätzlich das Archivieren: je Aufgabe ein Verzeichnis-Listing, gelesen und
  verschoben wird nur, was älter als die Frist ist.
- Ansicht: Laden liest `scheduled-tasks.json` und je Aufgabe bis zu 20 Lauf-Ordner (je `run.json`, `exit`,
  `result.json`, Ende von `stderr.log`) und die Datei `.count` des Archivs, abseits des Main Threads, nur auf Anlass. Im
  Renderpfad nichts davon: Abschnitt und Detail sind `.equatable()` und beobachten nur die Übersicht, nie den
  Status-Speicher der Chats; das Fenster zahlt je Auswertung eine Wörterbuch-Abfrage. Die Fehler-Zahl an der
  Überschrift ist eine Zählung über die schon geladenen Aufgaben. Das Detail liest zusätzlich die Login-Fristen
  (ändern sich höchstens stündlich).
- Formatieren: ein `DateFormatter` je Vorlage, Sprache und Zeitzone für die ganze App-Laufzeit.
- Mitlesen: Jede offene Chat-Ansicht hört auf Registry-Änderungen ihrer eigenen Sitzung (gefilterter Strom) und
  auf neue laufende Läufe; je Anlass zwei Abfragen im Speicher. Solange mitgelesen wird, je 3 s eine
  Datei-Abfrage, bei neuen Nachrichten das Lesen des Datei-Endes (höchstens 512 KB) und der Neubau des Texts,
  beides abseits des Main Threads.
- Mitteilung: eine je fehlgeschlagenem Lauf.
- Je Lauf: ein `claude auth status` (rund eine Sekunde) und der Lauf selbst. Ein `claude -p`-Lauf zählt gegen das
  Nutzungslimit des Kontos; der kleinste gemessene kostete rechnerisch 0,48 $ (Plan, Teil 1b).

## Offen für spätere Pakete

- Auswahl „Skill oder Text“ aus dem Entwurf fehlt im Blatt; der Auftrag ist ein Textfeld, das beides nimmt.
- „Lauf abbrechen“ aus dem Entwurf (Kasten „Arbeitet“) ist nicht gebaut.
- Übernahme der PM-Analyse und „Nur Freigaben der Aufgabe“ (Entscheidung Giuliano 17.11.2026: Konto-Freigaben
  gelten für Läufe nicht mehr): Paket 4. Der launchd-Eintrag der PM-Analyse bleibt bis dahin unberührt.
- Probelauf mit Kosten: Versucht ein Workflow-Agent `SendMessage`, obwohl der Lauf es sperrt?
