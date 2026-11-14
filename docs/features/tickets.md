---
status: aktiv (Kern, Kommandozeile und Skill; die Ansicht in der App fehlt noch)
updated: 2026-11-14
---

# Tickets: Linear und die Chats, die daran arbeiten

WhisperM8 verbindet die Tickets im Ticket-Werkzeug mit den Chats der App. Ein Chat hängt sich an sein
Ticket; daraus ergibt sich, wer woran sitzt, welche Chats laufen und welche Tickets niemanden haben.

Stand 14.11.2026: Es gibt den Kern, die Kommandozeile `whisperm8 tickets` und den Skill `tickets` im
Plugin. Die sichtbare Ansicht (Board und Backlog im Agent-Chats-Fenster) ist geplant:
[`../plans/ticket-board.md`](../plans/ticket-board.md), Entwurf [`../design/ticket-board.html`](../design/ticket-board.html).

## Bedienung

`whisperm8 tickets --help` listet alle Befehle. Die wichtigsten:

| Zweck | Befehl |
|---|---|
| Wer sitzt woran | `tickets board` |
| Gefiltert | `tickets list --mine`, `--unassigned`, `--person NAME`, `--no-agent`, `--with-agent`, `--project`, `--status` |
| Ein Ticket | `tickets show WM8-12` |
| Chat ans Ticket | `tickets link WM8-12`, `tickets done WM8-12 --status "Merge-bereit" --note "…"`, `tickets unlink WM8-12` |
| Status und Text | `tickets status`, `tickets note` (Stand-Zeile), `tickets comment` |
| Anlegen und zuordnen | `tickets new`, `tickets assign`, `tickets label` |
| Einrichten und prüfen | `tickets setup`, `tickets doctor` |

Jeder Befehl kennt `--json`; schreibende Befehle antworten dann mit `{"ok": true, "key": …, "message": …}`,
`doctor` schreibt seinen Bericht immer nach stdout. Wer welchen Status setzt und wie Chats und Supervisor damit arbeiten, steht im
Skill `tickets` (`WhisperM8/Resources/whisperm8-tickets-skill.md`) und im Jarvis-Skill, Abschnitt 11.

## So arbeitet dieses Projekt

Die Skills der App nennen kein Team und keine Labels, weil sie mit der App ausgeliefert werden. Was für
WhisperM8 selbst gilt, steht hier:

| | |
|---|---|
| Werkzeug | Linear, Workspace „WhisperM8“ (`linear.app/whisperm8`, Kürzel `whisperm8`) |
| Team | `WM8`, zugeordnet dem Projektordner des Repos |
| Status | Backlog · Todo · In Progress · Merge-bereit · Done · Canceled |
| Labels | `Handtest` und `Entscheidung` (wartet auf den Nutzer), `Selbst erfasst` (vom Supervisor von sich aus angelegt, nicht beauftragt), dazu `Bug`, `Feature`, `Improvement` |
| Vorhaben | je größerem Thema ein Projekt in Linear, bei Bedarf mit Meilensteinen |
| Chat-Titel | `WM8-16 Fin · Insel: Tastatur-Entwurf`; ohne offenes Ticket `Ole · Terminal-Tab: …` |

- **Eine Regel für „fertig“:** Der arbeitende Chat hängt sich an sein Ticket, gibt es als „Merge-bereit“ ab
  (`tickets done <Ticket> --status "Merge-bereit" --note "…"`) und meldet das dem Supervisor. Auf „Done“ setzt
  nur der Supervisor, nach Prüfung und Merge. Die Kommandozeile sagt einem anderen Chat dabei ab.
- **Neue Tickets** legt der Supervisor an, nach dem Ja des Nutzers; was er von sich aus erfasst, trägt
  `Selbst erfasst`.
- **Ansichten in Linear:** „Wartet auf mich“, „Handtests“, „Entscheidungen“, „Gerade in Arbeit“, „Als Nächstes“,
  „Blockiert“, „Mit Agent“, „Ohne Agent“, „Laufende Vorhaben“.

## Einrichtung

1. **Zugang:** `pbpaste | whisperm8 tickets setup --key-stdin` prüft den kopierten Linear-Key bei Linear und
   legt ihn in den Login-Schlüsselbund (Eintrag `whisperm8-linear-api-key`, Konto = Kürzel des Workspaces). Zu
   welchem Workspace der Key gehört, sagt Linear; er lässt sich nicht unter dem falschen ablegen. Ein
   abgelehnter Key wird nicht gespeichert.
2. **Zuordnung:** `whisperm8 tickets setup --team WM8 --project <Ordner>` schreibt, welches Projekt zu welchem
   Team gehört und in welchem Workspace das Team liegt. Arbeitsordner unterhalb des Projekts zählen mit. Ohne
   `--workspace` sieht die Kommandozeile nach, in welchem eingerichteten Workspace es das Team gibt.
3. **Prüfen:** `whisperm8 tickets doctor`.

Liegt ein Key schon im Schlüsselbund (von einem anderen Werkzeug abgelegt), übernimmt ihn
`whisperm8 tickets setup --workspace <Kürzel>` nach einer Prüfung bei Linear.

## Mehrere Workspaces

Wer für mehr als eine Firma arbeitet, hat mehr als einen Workspace. Jeder ist ein eigener Mandant mit eigenem
Key, eigenen Teams und eigener Rechnung.

- **Weg der Auflösung:** Ticket-Nummer → Team (`DS-12` → `DS`) → Workspace (`tickets.json`) → Key dieses
  Workspaces. Bei `board`, `list` und `new` kommt das Team aus dem Projekt des aktuellen Ordners oder `--team`.
- **Nie geraten:** Gibt es nur einen Workspace, liegt jedes Team dort. Bei mehreren muss das Team zugeordnet
  sein (`tickets setup --team <Kürzel>`); sonst bricht der Befehl ab, bevor er Linear fragt.
- **Schreibsperre über die Projektgrenze:** Aus einem Projektordner wird nur in den Workspace dieses Projekts
  geschrieben. Ein Chat der einen Firma kann die Tickets der anderen lesen, aber nicht ändern, und er hängt
  sich nicht an deren Tickets. Der Befehl endet mit Exit 4, bevor die fremde Quelle gefragt wird. Verlangt der
  Nutzer es ausdrücklich, hebt `--other-workspace` die Sperre für diesen einen Aufruf auf. Außerhalb jedes
  zugeordneten Ordners (Mensch im Terminal) gibt es keine Grenze.
- **`mine`** fragt alle eingerichteten Workspaces: Ein Chat kann an Tickets mehrerer gehangen haben.
- **`doctor`** prüft jeden Zugang einzeln und meldet einen Key, der unter dem falschen Workspace liegt.
- Der Linear-MCP kennt diese Sperre nicht. Wer ihn je Projekt begrenzen will, sperrt den Server des anderen
  Workspaces in der `.claude/settings.json` des Projekts.

### Warum der Key über `/usr/bin/security` läuft

Ein Schlüsselbund-Eintrag, den die App über die Schlüsselbund-API anlegt, ist an die Signatur des Builds
gebunden. Ohne Entwicklerkonto gilt jeder neue Build als fremde App; der Eintrag wäre nach jedem `make dev`
gesperrt oder löste eine Rückfrage aus. `TicketCredentialStore` liest und schreibt deshalb über das
System-Werkzeug `security`, so wie Claude Code es mit seinem Login macht. Geprüft am 14.11.2026 mit einem
frischen, unsignierten Build: Lesen und Schreiben ohne Rückfrage. Der Key wird über stdin übergeben, nie als
Argument, und steht in keiner Ausgabe und keiner Fehlermeldung.

## Die Verknüpfung Chat ↔ Ticket

Eine Verknüpfung ist ein Anhang am Ticket. Das Format hält `TicketChatLinkFormat` fest:

| Feld | Inhalt |
|---|---|
| Adresse | `whisperm8://chat/<Sitzungs-ID>`, eindeutig je Chat und Ticket |
| Titel | `Chat: <Titel des Chats>` |
| Untertitel | `arbeitet seit TT.MM. HH:MM · WhisperM8 · <Projekt>` oder `beendet am TT.MM. HH:MM · WhisperM8` |
| Metadaten | `source: whisperm8`, `chatId`, `shortId`, `project`, `active`, `since` |

- Der Untertitel entscheidet über „aktiv“, weil sich in Linear danach filtern lässt (Ansichten „Mit Agent“
  und „Ohne Agent“).
- Anhänge mit der Adresse, aber ohne die Marke `source: whisperm8`, zählen nicht.
- Eine beendete Verknüpfung bleibt am Ticket stehen. So ist auch später zu sehen, welcher Chat ein Ticket
  umgesetzt hat.
- Quelle der Wahrheit ist der Anhang in Linear. Die App führt keine eigene Zuordnung.

## Aufbau

```
Models/Tickets/Ticket.swift                  Ticket, Status-Art, Person, Verknüpfung, Abzug; TicketChat
Services/Tickets/TicketChatLinkFormat.swift  Format der Verknüpfung
Services/Tickets/TicketBoardModel.swift      wer sitzt woran, Chats ohne offenes Ticket, Supervisor; Filter, Zählungen, Spalten
Services/Tickets/TicketSource.swift          Grenze zum Ticket-Werkzeug, Fehler, Stand-Zeile
Services/Tickets/LinearGraphQLClient.swift   ein Aufruf, Fehlerübersetzung; Key im Schlüsselbund
Services/Tickets/LinearTicketSource.swift    die einzige Stelle, die Linear kennt
Services/Tickets/TicketConfig.swift          Projektordner ↔ Team ↔ Workspace (tickets.json)
Services/Tickets/TicketBoardStore.swift      Abzug mit Takt für die spätere Ansicht
CLI/TicketsCLICommand.swift                  Argumente, Hilfe, Umgebung
CLI/TicketsCLIRunner.swift                   Ausführung und Ausgabe
```

- **Werkzeug austauschbar:** Oberfläche und Kommandozeile kennen nur `TicketSource` und die Modelle.
- **Zustand der Chats:** kommt aus der laufenden App (`sessions.live` über den Control-Socket), nie aus
  Linear. Ohne App bleibt er leer.
- **Chats ohne offenes Ticket:** laufende Chats des Projekts, an denen kein Ticket mehr hängt, mit dem Ticket,
  an dem sie zuletzt saßen („WM8-12 (Merge-bereit)“ oder „WM8-29 (Done)“). Supervisor-Chats (Titel beginnt mit
  „Jarvis“) stehen getrennt.
- **Abgegebene Tickets:** in Arbeit, kein Chat sitzt mehr daran, einer hat die Verknüpfung beendet. Sie zeigen
  „abgegeben von …“ und zählen nicht als „ohne Agent“: Sie warten auf den Merge, nicht auf einen Chat.
- **Key je Prozess und Workspace einmal gelesen** (`TicketCredentialCache`); lehnt Linear ihn ab, wird er
  verworfen, damit ein ersetzter Key ohne Neustart gilt.
- **Quelle je Workspace:** Die Kommandozeile bekommt keine fertige Quelle, sondern eine Funktion
  Workspace → Quelle. `Access` in `TicketsCLIRunner` wählt sie je Team und hält die Schreibsperre ein.

## Daten und Verbindungen

- Eigene Datei: `~/Library/Application Support/WhisperM8/tickets.json` (Projektordner → Team, Team → Workspace,
  Liste der Workspaces; nichts Geheimes). Geschrieben von `whisperm8 tickets setup`.
- Schlüsselbund: Dienst `whisperm8-linear-api-key`, je Workspace ein Eintrag mit dem Kürzel als Konto.
- Netz: `https://api.linear.app/graphql`, nur wenn ein `tickets`-Befehl läuft. Die App selbst baut bisher keine
  Verbindung auf; das kommt mit der Ansicht und ihrem Schalter.
- Schreibzugriffe auf Linear lösen nur die Befehle `link`, `done`, `unlink`, `status`, `note`, `comment`, `new`,
  `assign` und `label` aus.

## Grenzen

- Ein Board lädt bis zu 500 offene Tickets (fünf Seiten zu 100).
- Linear erlaubt 2.500 Abfragen je Stunde und Person. Ein `board` braucht zwei Abfragen.
- Zyklen, Vorhaben, Meilensteine, Dokumente und Releases deckt die Kommandozeile nicht ab; dafür gibt es den
  Linear-MCP.
- Chats, die in WhisperM8 auf einem anderen Rechner laufen, erscheinen am Ticket ohne Zustand
  („anderer Rechner oder gelöscht“).

## Tests

`TicketBoardModelTests`, `LinearTicketSourceTests`, `TicketBoardStoreTests`, `TicketConfigTests`,
`TicketsCLITests`: pure Typen, Quelle gegen feste Antworten, Speicher mit eingespeister Wartefunktion,
Kommandozeile gegen eine Quelle aus Closures. Kein Test braucht Netz, Schlüsselbund oder die App.
