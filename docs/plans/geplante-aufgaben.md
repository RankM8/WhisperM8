---
status: Entwurf, Entscheidung offen (E1 Ort in der App, E2 Weg ohne App)
stand: 2026-11-15
feature: Geplante Aufgaben — wiederkehrende Claude-Läufe in WhisperM8 anlegen, sehen, von Hand starten, pausieren und ihren Chat öffnen
branch: design/WM8-110-geplante-aufgaben
---

# Geplante Aufgaben: Plan

Wunsch (Ticket `WM8-110`): wiederkehrende Claude-Läufe in WhisperM8 anlegen, auf einen Blick sehen, von Hand
starten, pausieren und den Chat eines Laufs öffnen, egal welches Konto gerade aktiv ist. Vorbild ist die tägliche
PM-Analyse, die seit dem 15.11.2026 von Hand über launchd eingerichtet ist
(`~/.claude/skills/pm-analyse/run.sh`, `~/Library/LaunchAgents/com.giuliano.pm-analyse.plist`).

Freigegeben ist nur der Entwurf: [`../design/geplante-aufgaben.html`](../design/geplante-aufgaben.html) und die
zwei Grundfragen. Gebaut wird erst nach der Entscheidung.

## Kurz

- **Chat eines Laufs:** geht schon heute. Die App findet `claude -p`-Sitzungen, zeigt sie während des Laufs als
  „arbeitet“ und danach als „fertig“, im richtigen Konto. Es fehlen nur ein Titel, ein festes Projekt und die
  Verbindung von Aufgabe zu Sitzung. Alle drei liefert der Start selbst (`--name`, fester Startordner,
  `--session-id`).
- **Ohne App:** Empfehlung ist, dass die App die Läufe selbst startet (Weg A). Verpasste Läufe holt sie nach dem
  Aufwachen und beim Start nach. Ein Hintergrunddienst im App-Paket (Weg C) kann später dazukommen. Einen Eintrag je
  Lauf in `~/Library/LaunchAgents` (Weg B) empfehle ich nicht.
- **Ort in der App:** Empfehlung ist eine eigene Ansicht hinter einem Knopf in der Titelzone, genau wie die
  Tickets (Variante B im Entwurf).

## Teil 1a: Läuft der Plan, wenn die App beendet ist?

Drei Wege. A und B hat Jarvis vorgegeben, C ist ein dritter, der beim Nachlesen auffiel.

| | **A · Die App startet** | **B · Je Lauf ein LaunchAgent** | **C · Ein Dienst im App-Paket** |
|---|---|---|---|
| Wie | Zeitgeber in der App, Start als losgelöster Prozess | Die App schreibt je Aufgabe eine plist nach `~/Library/LaunchAgents` und lädt sie mit `launchctl` | Eine feste plist liegt im App-Paket und wird mit `SMAppService.agent` angemeldet. Sie stößt alle 5 Minuten `whisperm8 schedule tick` an, der fällige Läufe startet |
| Läuft bei beendeter App | nein | ja | ja |
| Läuft bei geschlossenem Fenster | ja (das letzte Fenster zu schließen beendet die App nicht) | ja | ja |
| Mac schläft zur Startzeit | Der Zeitgeber steht still. Die App holt beim Aufwachen nach (`didWakeNotification`), das muss sie selbst können | launchd startet beim Aufwachen, mehrere verpasste Termine zusammen nur einmal (`man launchd.plist`, `StartCalendarInterval`) | wie B, wenn die plist `StartCalendarInterval` nimmt. Mit `StartInterval` fiele der Termin im Schlaf ersatzlos weg |
| Mac aus zur Startzeit | Nachholen beim nächsten App-Start | Termin entfällt | wie B, der Tick sieht aber den verpassten Termin und holt nach |
| App-Neustart während eines Laufs (`make dev`, Update, Absturz) | Der Lauf muss losgelöst starten (eigene Prozessgruppe, Ausgabe in Datei), sonst stirbt er mit der App. Gilt für alle drei Wege gleich | wie A | wie A |
| Wie erfährt die App vom Ergebnis | direkt, sie hat gestartet | Der Lauf schreibt eine Ergebnis-Datei, die App liest sie beim Start und per Ordner-Beobachtung | wie B |
| Beim Deinstallieren | bleibt nichts | Die plists bleiben liegen und feuern täglich ins Leere, bis jemand sie löscht. `brew uninstall` ohne `--zap` räumt sie nicht weg | Die plist liegt im Paket und geht mit der App. macOS listet den Eintrag unter Anmeldeobjekte, bis er verschwindet |
| Schreibzugriff außerhalb der eigenen Daten | keiner | ja, neuer Eintrag in der Ausnahmeliste der CLAUDE.md, dazu `launchctl bootstrap/bootout` | keiner unter `~/Library/LaunchAgents`, die Anmeldung macht das System |
| Was der Nutzer sieht | nichts Neues | Hinweis „Hintergrundobjekt hinzugefügt“ je plist | einmal „Hintergrundobjekt hinzugefügt“. Schaltet er es in den Systemeinstellungen ab, muss die App das erkennen (`SMAppService.status`) |
| Zusammenspiel mit dem Wach-Knopf | Stufe „am Strom, solange ein Chat arbeitet“ zählt den Lauf mit, weil er als „arbeitet“ im Status-Speicher steht (gemessen, siehe 1b). Den Mac zum Termin wecken kann kein Weg | wie A, solange die App läuft. Ohne App hält nur Claude Codes eigenes `caffeinate` während eines Turns wach, zugeklappt nicht | wie B |
| Aufwand | klein: Zeitgeber, Nachholen, Starter | mittel: plist schreiben, laden, entladen, mit den Aufgaben abgleichen, Aufräumen bei Löschen, Umbenennen, Deinstallieren | mittel: plist im Bundle (`Package.swift` **und** Makefile `_bundle`), Tick-Befehl, Anmeldung, Zustand „vom Nutzer abgeschaltet“. Offen, ob `SMAppService` die mit dem lokalen Zertifikat signierte App annimmt (`TeamIdentifier=not set`), das braucht einen Spike |

**Empfehlung: A jetzt, C später, B nicht.**

- A erfüllt „läuft auch ohne offenes Fenster“ wörtlich. Die App startet beim Anmelden (Schalter in den
  Einstellungen) und läuft praktisch immer, Jarvis lebt in ihr.
- Den Mac zum Termin wecken kann keiner der drei Wege. Dafür bräuchte es `pmset schedule wake` als root, und die
  vorhandene sudo-Regel erlaubt nur `disablesleep`. Verpasste Läufe holt die App deshalb in jedem Fall nach.
- B verteilt den Zustand auf zwei Orte (Aufgabenliste und plists), die auseinanderlaufen können, und hinterlässt
  beim Deinstallieren aktive Einträge. C hat dieselbe Wirkung ohne diese Nachteile, sobald der Spike zeigt, dass
  `SMAppService` mit unserer Signatur funktioniert.
- Wer die PM-Analyse trotzdem ohne App braucht: Ihr launchd-Eintrag bleibt, bis C steht oder Giuliano ihn
  abschaltet.

## Teil 1b: Was ist „der Chat eines Laufs“?

Gemessen am 15.11.2026, Claude Code 2.1.325.

**Die PM-Analyse in der Chat-Liste (vor eigenen Läufen):**

| Lauf | Sitzung | Projekt in der App | Konto | Titel |
|---|---|---|---|---|
| 15:19 | `08e84aa7` | akquise-ai | main | „Claude 08e84aa7“ |
| 15:29 | `91f9337c` | pm-analyse (`~/Archiv/pm-analyse`) | main | „Claude 91f9337c“ |

- Der Indexer nimmt `claude -p`-Sitzungen (`entrypoint: sdk-cli`) wie jede andere auf. Das Projekt ist der Ordner,
  in dem der Lauf startet: Der erste Lauf stand noch im Ordner akquise-ai, erst danach kam `cd ~/Archiv/pm-analyse`
  in `run.sh`.
- Der Titel fehlt, weil der Auftrag mit einem Befehl beginnt (`/pm-analyse …`). Der Indexer überspringt Befehle
  bei der Titelsuche und fällt auf „Claude <id>“ zurück (`ClaudeSessionIndexer.swift`, Zeile 233).

**Zwei Probeläufe** im Konto PowerUser, in einem Wegwerf-Ordner im Scratchpad, mit
`claude -p … --session-id <uuid> --name "Probe WM8-110 Lauf" --output-format json`:

- **Während des Laufs** legt Claude `sessions/<pid>.json` an, mit `entrypoint: sdk-cli`, `status: busy` und dem
  Namen aus `--name`. Die App zeigte die Sitzung 10 bis 25 Sekunden nach dem Start als „arbeitet“ (Quelle
  `claudeRegistry`), ohne Tab, Senden gesperrt.
- **Danach** „fertig, ungelesen“ (`freshDone`), Titel „Probe WM8-110 Lauf“, Konto PowerUser, Projekt =
  Ordnername.
- **Ergebnis** liefert `--output-format json`: `subtype`, `is_error`, `result`, `permission_denials`,
  `total_cost_usd` und `credential_expires_at` (Enddatum des Logins, bei jedem Lauf frisch).
- **Kosten:** Selbst der kleinste Lauf kostete rechnerisch 0,48 $ (der erste Aufruf schreibt den ganzen
  Systemkontext in den Cache), die PM-Analyse 1,42 bis 1,56 $. Im Abo zählt das gegen das Nutzungslimit.

**Fortsetzen im richtigen Konto:** Ein geschlossener Chat startet mit `claude --resume`. Das Konto nimmt
`AgentCommandBuilder` aus dem Ablageort des Verlaufs (`/.claude-profiles/<Konto>/projects/…`), nicht aus dem gerade
aktiven Konto. Die PM-Sitzungen stehen mit `canOpen: true` in der Liste. Im laufenden Fenster habe ich das Öffnen
bewusst nicht ausgelöst, um keine Tabs in Giulianos Fenster zu legen. Es ist derselbe Weg wie bei jedem
geschlossenen Chat.

**Was daraus für den Bau folgt:**

- Jeder Lauf startet mit `--session-id`. So kennt die App die Sitzung, bevor sie existiert, und muss nichts aus
  Protokollen lesen.
- `--name "<Aufgabe> · <Datum>"` gibt jedem Lauf einen lesbaren Titel.
- Startordner ist immer der Projektordner der Aufgabe. Das ist ein Pflichtfeld, sonst landet der Chat wie beim
  ersten PM-Lauf im falschen Projekt.
- **Öffnen, solange der Lauf arbeitet:** heute ginge `--resume` auf eine Sitzung, in die der Lauf noch schreibt.
  Zwei Prozesse auf einer Sitzung darf es nicht geben. Bis zum Ende gibt es deshalb nur „Mitlesen“ (Verlauf,
  `TranscriptTextView`), „Fortsetzen“ erst danach. Diese Sperre gilt für jeden Chat ohne Tab, dessen Status aus
  der Registry „arbeitet“ sagt, nicht nur für geplante Läufe.
- **Jeden Tag ein neuer Chat:** Nach einem Jahr wären es 365 je Aufgabe. Die Läufe einer Aufgabe stehen deshalb in
  ihrem Detail; in der Seitenleiste bleibt nur der neueste. Ältere gehen nach 14 Tagen ins Archiv (das gibt es
  schon), einstellbar je Aufgabe.
- **Rechte:** Ein `-p`-Lauf kann nicht nachfragen. Was er darf, steht vorher fest (`--allowedTools`). Verweigerte
  Werkzeuge stehen in `permission_denials`. Ein Lauf mit Verweigerungen gilt als „geklappt, mit Hinweis“, nicht
  still als Erfolg.

## Abgelaufener Login

- **Vorher erkennen:** `claude auth status` sagt ohne Modellaufruf `loggedIn` und `loginExpiresAt` und endet mit
  Exit 1, wenn niemand angemeldet ist (gemessen an einem leeren Konto-Ordner). Der Starter fragt das vor jedem Lauf.
  Ist das Konto abgemeldet, startet der Lauf gar nicht. Ergebnis „Login von <Konto> abgelaufen“, mit Knopf
  „Erneuern…“ (vorhandener Weg über `ClaudeLoginRenewer`).
- **Rechtzeitig warnen:** Die App kennt das Enddatum jedes Logins schon (`ClaudeLoginExpiry`, warnt ab 7 und 3
  Tagen). Die Übersicht zeigt an der Aufgabe „Login endet vor dem nächsten Lauf“, wenn das Ende vor dem nächsten
  Termin liegt.
- **Mitten im Lauf abgelaufen:** Der Lauf endet mit `is_error` oder einem Exit ungleich 0, die Übersicht zeigt
  „fehlgeschlagen“ mit der Meldung aus dem Ergebnis. Den genauen Wortlaut bei abgelaufenem Login habe ich nicht
  gemessen. Kein Konto war gerade abgelaufen, und ein dritter Lauf war nicht freigegeben. Das gehört in den
  Handtest von Paket 1.

## Teil 2: Wo es in der App wohnt

Entwurf mit allen Zuständen: [`../design/geplante-aufgaben.html`](../design/geplante-aufgaben.html).

| | Für | Wider |
|---|---|---|
| **A · Abschnitt „Geplant“ in der Seitenleiste** zwischen Workspaces und Chats, je Aufgabe eine Zeile wie ein Chat (Punkt, Name, rechts der nächste Termin). Klick öffnet das Detail im Inhaltsbereich | immer im Blick, ein Fehlschlag steht sofort sichtbar links; dieselbe Zeile wie ein Chat | Die Seitenleiste ist für Chats und wird länger. Zeilen mit Zeitangaben rechnen bei jedem Aufbau der Seitenleiste mit, die heute schon ein Performance-Budget hat |
| **B · Eigene Ansicht wie die Tickets** (Empfehlung): Knopf mit Uhr neben dem Ticket-Knopf in der Titelzone, schaltet den Bereich unter der Tab-Leiste um. Liste links, Detail rechts, wie beim Ticket-Board | Bedienung ist bekannt (Knopf, ⌘W zurück, Detail mit „Zum Chat“); die Seitenleiste bleibt, wie sie ist; Platz für Läufe, Ergebnis und Fehler. Ein Fehlschlag färbt den Knopf, schickt eine Mitteilung und zeigt den Chat des Laufs mit Fehler-Punkt in der Seitenleiste | ein Knopf mehr in der Titelzone; nicht dauernd sichtbar, man muss umschalten |
| **C · Seite in den Einstellungen** (Agent Chats › Geplante Aufgaben) | passt zum Anlegen und Ändern, kein neuer Platz im Fenster | Einstellungen sind für Konfiguration, nicht zum Nachsehen. „Zum Chat“ springt aus dem Einstellungsfenster ins Hauptfenster. Ein Fehlschlag fällt dort niemandem auf |

**Verworfen: Teil des Ticket-Boards.** Das Board gehört zu einem Projekt, liest nur Linear und hängt am Schalter
`ticketBoardEnabled`. Geplante Aufgaben laufen über Projekte und Konten hinweg und sind keine Tickets. Beides in
einer Ansicht machte das Board voller und die Aufgaben schwerer zu finden.

**Was alle Varianten teilen** (im Entwurf zu sehen):

- Übersicht je Aufgabe: Name, Zeitplan in Worten („werktags 07:00“), Konto, Projekt, nächster Termin, letzter
  Lauf mit Ergebnis.
- Zustände: geplant, läuft, geklappt, geklappt mit Hinweis, fehlgeschlagen (Login abgelaufen, Fehler im Lauf,
  Ordner fehlt), verpasst und nachgeholt, pausiert.
- Knöpfe stehen sichtbar an der Zeile oder im Detail, nie nur beim Überfahren: Jetzt starten, Pausieren und
  Fortsetzen, Ändern, Zum Chat (nach dem Lauf) oder Mitlesen (während des Laufs).
- Anlegen und Ändern in einem Blatt: Name, Auftrag (Text oder Skill), Projektordner, Konto, Zeitplan,
  Rechte, Nachholen ja oder nein, Aufbewahrung der Läufe.
- Ein Fehlschlag meldet sich dreifach: Mitteilung, roter Ring am Knopf, Fehler-Punkt am Chat des Laufs.
- Kein Modell-Feld: Welches Modell ein Claude-Chat nutzt, entscheidet Claude Code (Invariante in CLAUDE.md). Die
  PM-Analyse läuft heute mit `--model opus`. Bei der Übernahme fällt das weg, oder die Invariante bekommt eine
  Ausnahme. Das entscheidet Giuliano, wenn Paket 4 ansteht.

## Grober Paketschnitt

Alles hinter einem Labs-Schalter, ab Werk aus.

1. **Kern ohne Ansicht.** Aufgaben in `scheduled-tasks.json` (App Support, die App ist einziger Schreiber).
   Zeitplan-Rechnung als reine, getestete Funktion (nächster Termin, verpasst, nachholen). Starter: `auth status`
   prüfen, losgelöst starten mit `--session-id`, `--name`, festem Ordner und `--allowedTools`, Ergebnis je Lauf
   als eigene Datei unter `scheduled-tasks/runs/<Aufgabe>/` (schreibt der Lauf, liest die App). Nachholen bei
   Aufwachen und App-Start. Kommandozeile `whisperm8 schedule list|run|pause|resume`. Handtest: abgelaufenes
   Konto, App-Neustart während eines Laufs, Mac schläft über den Termin.
2. **Ansicht.** Übersicht, Detail, Blatt zum Anlegen und Ändern in der gewählten Variante, Snapshots hell und
   dunkel.
3. **Meldungen und Chat.** Mitteilung bei Fehlschlag, Ring am Knopf, Login-Warnung vor dem nächsten Lauf,
   „Mitlesen“ statt Fortsetzen, solange ein Lauf arbeitet (gilt für alle Chats ohne Tab), Archiv für alte Läufe.
4. **PM-Analyse übernehmen.** Als Aufgabe anlegen, launchd-Eintrag erst nach Giulianos Ja entfernen.
5. **Später, nur bei Bedarf:** Weg C, zuerst als Spike, ob `SMAppService.agent` mit unserer Signatur geht.

## Bewusst nicht dabei

- **Cloud-Routinen bei Anthropic** (claude.ai): Es gibt keine offizielle Schnittstelle zum Anlegen und
  Auflisten, sie sehen keine lokalen MCP-Server und keinen Schlüsselbund.
- **Den Mac zum Termin wecken** (`pmset schedule wake`, root).
- **Modellwahl je Aufgabe** (siehe oben).
- **Codex-Läufe** (`codex exec`). Das Ticket fragt nach Claude-Läufen, der Starter ließe sich später erweitern.
- **Ketten** („B nach A“), Bedingungen, Läufe auf anderen Rechnern.
- **Ergebnisse auswerten:** Die App zeigt geklappt oder fehlgeschlagen und den letzten Satz. Was der Lauf
  inhaltlich gefunden hat, steht im Chat oder dort, wohin er schreibt (bei der PM-Analyse ein Linear-Dokument).

## Entscheidungen

- **E1 Ort in der App:** A Seitenleiste, B eigene Ansicht wie Tickets (Empfehlung), C Einstellungen. Offen.
- **E2 Weg ohne App:** A App startet (Empfehlung, C später), B je Lauf ein LaunchAgent, C gleich mit Dienst. Offen.
