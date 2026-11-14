---
status: aktiv (Kern, Kommandozeile, Skill, Einstellungen und die lesende Ansicht in der App, Stufe 1)
updated: 2026-11-14
---

# Tickets: Linear und die Chats, die daran arbeiten

WhisperM8 verbindet die Tickets im Ticket-Werkzeug mit den Chats der App. Ein Chat hängt sich an sein
Ticket; daraus ergibt sich, wer woran sitzt, welche Chats laufen und welche Tickets niemanden haben.

Stand 14.11.2026: Es gibt den Kern, die Kommandozeile `whisperm8 tickets`, den Skill `tickets` im Plugin, die
Seite „Tickets“ in den Einstellungen (Labs) und die Ansicht im Agent-Chats-Fenster (Board und Backlog, nur
lesend, Stufe 1). Knöpfe, die Tickets ändern (Stufe 2), gibt es nicht. Plan:
[`../plans/ticket-board.md`](../plans/ticket-board.md), Entwurf
[`../design/ticket-board.html`](../design/ticket-board.html).

## Wer mit dem Ticket-System spricht

- **Die Kommandozeile** liest und schreibt. Jeder Schreibzugriff auf Linear kommt aus einem `tickets`-Befehl.
- **Die App** liest nur, und nur bei eingeschaltetem Labs-Schalter `ticketBoardEnabled` (ab Werk aus): für die
  Ticket-Ansicht das Board eines Teams und ein Ticket, für die Einrichtung das Konto und die Teams eines Keys.
  Sie ändert in Linear nichts. Schalter aus heißt: keine Verbindung zu `api.linear.app`, kein Griff in den
  Schlüsselbund.
- **Abseits des Main Threads:** Der Key wird über einen blockierenden Kindprozess gelesen. In der App läuft das
  nie auf dem Main Thread; `TicketsSettingsModelTests` prüft das für jeden Schlüsselbund-, Datei- und
  Netzzugriff der Einstellungen. Der Kindprozess läuft auf einer eigenen Dispatch-Queue
  (`TicketBlockingWork`), nicht auf dem Thread-Pool von Swift Concurrency: Ein offener Dialog des
  Schlüsselbunds belegte sonst den gemeinsamen Pool.
- **Frist:** Der Aufruf von `security` wartet höchstens 60 Sekunden auf den Kindprozess (etwa bei einem Dialog
  des Schlüsselbunds) und beendet ihn danach. Für die Oberfläche sieht das aus wie „kein Key“. macOS kann eine
  Pipe nicht in einem Zug mit close-on-exec anlegen; erbt ein gleichzeitig startender Chat ihre Enden, greift
  dieselbe Frist, statt dass der Aufruf hängt.

## Bedienung

`whisperm8 tickets --help` listet alle Befehle. Die wichtigsten:

| Zweck | Befehl |
|---|---|
| Wer sitzt woran | `tickets board` |
| Gefiltert | `tickets list --mine`, `--unassigned`, `--person NAME`, `--no-agent`, `--with-agent`, `--project`, `--status` |
| Ein Ticket | `tickets show WM8-12` |
| Chat ans Ticket | `tickets link WM8-12`, `tickets done WM8-12 --built "…" --status "Merge-bereit"`, `tickets unlink WM8-12` |
| Status und Text | `tickets status`, `tickets note` (Stand-Zeile), `tickets comment` |
| Entscheidung festhalten | `tickets decide WM8-12 --question "…" --option "A" --option "B" --chosen "A"` |
| Kästchen unter „Fertig, wenn“ | `tickets check WM8-12` (zeigen), `tickets check WM8-12 2 "Detail"` (abhaken), `--uncheck` |
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
| Status | Backlog · Todo · In Progress · Merge-bereit · Wartet aufs Ausliefern · Done · Canceled |
| Labels | `Handtest` und `Entscheidung` (wartet auf den Nutzer), `Selbst erfasst` (vom Supervisor von sich aus angelegt, nicht beauftragt), dazu `Bug`, `Feature`, `Improvement` |
| Vorhaben | je größerem Thema ein Projekt in Linear, bei Bedarf mit Meilensteinen |
| Chat-Titel | `WM8-16 Fin · Insel: Tastatur-Entwurf`; ohne offenes Ticket `Ole · Terminal-Tab: …` |

- **Eine Regel für „fertig“:** Der arbeitende Chat hängt sich an sein Ticket, gibt es als „Merge-bereit“ ab
  (`tickets done <Ticket> --built "…" --commit … --status "Merge-bereit"`) und meldet das dem Supervisor. Nach
  dem Merge steht das Ticket auf „Wartet aufs Ausliefern“, bis die installierte App den Stand hat. Auf „Done“ setzt
  nur der Supervisor, nach Prüfung und Merge. Die Kommandozeile erinnert einen anderen Chat mit einer Absage
  daran (siehe „Grenzen“).
- **Neue Tickets** legt der Supervisor an, nach dem Ja des Nutzers; was er von sich aus erfasst, trägt
  `Selbst erfasst`.
- **Ansichten in Linear:** „Wartet auf mich“, „Handtests“, „Entscheidungen“, „Gerade in Arbeit“, „Als Nächstes“,
  „Blockiert“, „Mit Agent“, „Ohne Agent“, „Laufende Vorhaben“.

### Bereiche, Doku und Projekte

Ein Projekt in Linear ist ein dauerhafter Bereich der App, ein Vorhaben ist ein Meilenstein darin. Jedes offene
Ticket hat genau ein Projekt. Diese Tabelle sagt, wo die Doku eines Bereichs liegt; `tickets doctor` prüft sie
gegen Linear und das Dateisystem (eingerichtet mit `tickets setup --team WM8 --project <Ordner> --areas
docs/features/tickets.md`).

| Bereich | Ordner | Linear-Projekt |
|---|---|---|
| Diktat | `docs/features/dictation`, `docs/features/speech-callouts.md`, `docs/features/voice-gate.md` | Diktat |
| Agent Chats | `docs/features/agent-chats` | Agent Chats |
| Kommandozeile, Skills, Supervisor | `docs/features/agent-chats-cli.md`, `docs/features/jarvis-board.md`, `docs/features/cli` | Chats-CLI, Skills und Jarvis |
| Konten und Zugänge | `docs/features/agent-chats/claude-konten.md`, `docs/features/agent-chats/gpt-konten.md` | Konten und Zugänge |
| Tickets | `docs/features/tickets.md` | Tickets |
| Controller | `docs/features/controller.md` | Controller |
| Insel und Pille | `docs/features/notch.md` | Insel und Pille |
| Einstellungen | `docs/features/settings` | Einstellungen |
| App-Hülle und Neustart | `docs/features/app-shell` | App-Hülle und Neustart |
| Werkzeuge | `docs/features/clipboard-history.md`, `docs/features/statistics.md`, `docs/features/keyboard-cleaning.md` | Werkzeuge |
| Entwicklung und Release | `docs/DEVELOPMENT.md`, `docs/features/ui-testing.md`, `docs/features/performance-messung.md` | Entwicklung und Release |

## Entscheidung, Abschluss, Kästchen

Was sonst nur in einem Chat-Verlauf stünde, steht in festem Aufbau am Ticket. Beides ist in einer Minute
gelesen und enthält keine Rohdaten aus dem Chat.

- **Entscheidung** (`tickets decide`): ein Kommentar mit Überschrift „Entscheidung“ samt Datum und Uhrzeit,
  dann Frage, Möglichkeiten, Gewählt, „Entschieden von“ und „Festgehalten von“. Festgehalten wird nur, was der
  Nutzer wirklich entschieden hat, mit seinen Möglichkeiten; mindestens zwei Möglichkeiten. Chats dürfen
  festhalten (oft fällt eine Entscheidung direkt in einem Chat), aber aus einem Chat ist `--by` Pflicht und wird
  nicht aus dem Zugang geraten; im Terminal steht ohne `--by` die Person, der der Zugang gehört. „Festgehalten
  von“ nennt immer den Rufnamen des Chats oder „im Terminal“. Eigene Entscheidungen eines Chats tragen dessen
  Namen unter „Entschieden von“. Sterne in den Feldern werden entschärft, damit kein Text wie ein zweites Feld
  aussieht.
- **Abschluss** (`tickets done`): Pflicht beim Abgeben. Ein Kommentar „Abschluss“ mit Zeit und Rufname des
  Chats: was gebaut wurde (`--built`), Commit, was bewusst nicht dazugehört (`--not`), Schritte für den Handtest
  als Kästchen (`--test`, mehrfach), auf Wunsch ein Bild (`--image`, nur png, jpg, gif, webp bis 5 MB; geprüft
  wird auch der Anfang der Datei, nicht nur die Endung). Das Bild sieht jeder im Workspace. Der Kommentar wird zuerst geschrieben; scheitert er,
  ist am Ticket nichts umgestellt. Scheitert danach Verknüpfung oder Status, sagt die Meldung, dass der
  Abschluss schon steht und der Rest mit `--no-summary` nachgeholt wird. Für Arbeit ohne Bau (Analyse,
  Entscheidung) gibt es `--no-summary`; wer nach dem Merge auf einen „erledigt“-Status setzt, braucht keine.
- **Kästchen** (`tickets check`): die Punkte unter „Fertig, wenn“ (auch „Done when“, „Acceptance criteria“).
  Abgehakt wird per Nummer oder mit einem Stück Text, das auf genau ein Kästchen passt; alle anderen Zeilen der
  Beschreibung bleiben, wie sie sind. Hat ein Ticket keinen solchen Abschnitt, zählen alle Kästchen. Der Befehl
  arbeitet nur auf der Beschreibung, nicht auf Kommentaren (die Handtest-Kästchen im Abschluss hakt ab, wer
  testet). Codeblöcke mit ``` oder ~~~ zählen nicht mit; ein nur mit vier Leerzeichen eingerückter Block gilt
  nicht als Code.
- **Fortschritt:** Jedes Ticket trägt „erledigt von gesamt“ (`show`, `board`, in `--json` unter `criteria`).
  Die Ansicht in der App zeigt ihn später auf der Karte.

## Prüfung der Ordnung

`tickets doctor` meldet neben Zugang und Zuordnung, was beim Aufräumen jemand ansehen sollte. Das sind
Hinweise („ACHTE“), der Bericht bleibt grün:

| Hinweis | Gemeint ist |
|---|---|
| ohne Projekt | offenes Ticket, das keinem Bereich zugeordnet ist |
| ohne „Fertig, wenn“ | eingeplant oder in Arbeit, aber ohne den Abschnitt und ohne Kästchen; im Backlog darf er fehlen |
| in Arbeit, nie ein Chat | Status in Arbeit, aber keine Verknüpfung, auch keine beendete |
| seit über 3 Wochen unberührt | eingeplant oder in Arbeit und in Linear 21 Tage nicht geändert |
| Bereiche | Projekt fehlt in der Tabelle, steht nur in der Tabelle, hat keine Doku, oder die Doku fehlt |

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

### In der App: Einstellungen › Tickets

Die Seite steht in der Gruppe „Labs“ und richtet nach denselben Regeln ein wie `tickets setup`. Anders als die
Kommandozeile kann sie einen Key und eine Zuordnung auch entfernen:

- **Schalter „Show tickets in Agent Chats“** (`ticketBoardEnabled`). Solange er aus ist, zeigt die Seite nur
  ihn und liest nichts.
- **Zugang:** je Workspace eine Zeile mit Zustand (verbunden, kein Key, geht nicht) und den Teams, die der Key
  sieht. Ein neuer Key wird bei Linear geprüft und unter dem Workspace abgelegt, den Linear zu ihm nennt.
  „Remove Key…“ löscht nur den Schlüsselbund-Eintrag. Der Workspace bleibt eingerichtet und steht danach als
  „kein Key“ da, die Zuordnungen bleiben. Aus der Einrichtung nimmt die Seite ihn nicht: Ein Team ohne festen
  Workspace fiele sonst still dem einzigen verbliebenen zu.
- **Projekte und Teams:** Projektordner → Team, wählbar aus den Projekten der App oder per Ordner-Auswahl. Ein
  Kürzel, das schon zu einem anderen Workspace gehört, hängt die Seite nicht um; dafür gibt es
  `tickets setup --reassign`.

`tickets.json` hat damit zwei Schreiber, Kommandozeile und Einstellungen. Beide lesen vor jeder Änderung neu
und schreiben atomar; wer zuletzt schreibt, gewinnt. Die Seite ändert nichts an einer Datei, die sich nicht
lesen lässt (die Kommandozeile finge in dem Fall leer an).

## Mehrere Workspaces

Wer für mehr als eine Firma arbeitet, hat mehr als einen Workspace. Jeder ist ein eigener Mandant mit eigenem
Key, eigenen Teams und eigener Rechnung.

- **Weg der Auflösung:** Ticket-Nummer → Team (`DS-12` → `DS`) → Workspace (`tickets.json`) → Key dieses
  Workspaces. Bei `board`, `list` und `new` kommt das Team aus dem Projekt des aktuellen Ordners oder `--team`.
- **Nie geraten:** Gibt es nur einen Workspace, liegt jedes Team dort. Bei mehreren muss das Team zugeordnet
  sein (`tickets setup --team <Kürzel>`); sonst bricht der Befehl ab, bevor er Linear fragt.
- **Schreibsperre über die Projektgrenze:** Ein Chat schreibt nur in den Workspace seines Projekts, egal in
  welchem Ordner seine Shell steht (`/tmp`, Home, eine Arbeitskopie neben dem Projekt). Ruft kein Chat oder ist
  dessen Projekt keinem Workspace zugeordnet, zählt der Ordner. Ein Chat der einen Firma kann die Tickets der
  anderen lesen, aber nicht ändern, und er hängt sich nicht an deren Tickets. Der Befehl endet mit Exit 4, bevor
  die fremde Quelle gefragt wird. Verlangt der Nutzer es ausdrücklich, hebt `--other-workspace` die Sperre für
  diesen einen Aufruf auf. Ein Mensch im Terminal außerhalb jedes zugeordneten Ordners hat keine Grenze.
- **Ein Kürzel, ein Workspace:** `tickets.json` kennt je Team-Kürzel genau einen Workspace. Gibt es dasselbe
  Kürzel in zwei Workspaces, ist nur das zugeordnete Team erreichbar; `doctor` nennt das Kürzel. `setup` hängt
  ein schon zugeordnetes Kürzel nicht still um, sondern nur mit `--reassign`: Sonst schriebe jeder Ordner dieses
  Teams in den anderen Workspace, ohne dass die Sperre es merkt.
- **`mine`** fragt alle eingerichteten Workspaces: Ein Chat kann an Tickets mehrerer gehangen haben.
- **`doctor`** prüft jeden Zugang einzeln und meldet einen Key, der unter dem falschen Workspace liegt.
- Der Linear-MCP kennt diese Sperre nicht. Wer ihn je Projekt begrenzen will, sperrt den Server des anderen
  Workspaces in der `.claude/settings.json` des Projekts.
- **Test-Instanz:** Sie hat einen eigenen Schlüsselbund-Dienst (`whisperm8-linear-api-key.test`) und eine eigene
  `tickets.json`. Ohne dort eingerichteten Key spricht sie mit keinem Ticket-System; den echten Key liest,
  überschreibt und löscht sie nicht. Wer dort einen echten Key einträgt, liest das echte Linear.

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
Services/Tickets/TicketChecklist.swift       Kästchen unter „Fertig, wenn“ lesen und setzen
Services/Tickets/TicketRecordText.swift      fester Aufbau für Entscheidung und Abschluss
Services/Tickets/TicketHygiene.swift         Ordnung der Tickets, Tabelle der Bereiche, Bild-Typen
Services/Tickets/TicketBoardStore.swift      Abzug mit Takt für die Ansicht
Views/Tickets/TicketErrorText.swift          Fehler als übersetzter Satz für die Oberfläche
Views/Tickets/TicketBoardPresentation.swift  fertig gerechneter Inhalt, Zustand der Ansicht (Filter, Auswahl), Live-Zustand der Chats
Views/Tickets/TicketBoardView.swift          Kopf, Umschalter Board/Backlog, Filter
Views/Tickets/TicketCardView.swift           Karte und Spalten
Views/Tickets/TicketBacklogListView.swift    Liste nach Projekt, Leiste „Chats ohne Ticket“
Views/Tickets/TicketDetailPanel.swift        Detail rechts
Views/Tickets/TicketDescriptionBlocks.swift  Beschreibung leicht gesetzt (Überschriften, Kästchen, Listen)
Views/Tickets/TicketBoardText.swift          Texte und kleine Bausteine (Status-Punkt, Priorität, Person)
Views/Settings/Models/TicketsSettingsModel.swift   Zustand und Regeln der Einstellungsseite
Views/Settings/Pages/TicketsSettingsPage.swift     Einstellungen › Tickets
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
- Schlüsselbund: Dienst `whisperm8-linear-api-key` (Test-Instanz: `…-key.test`), je Workspace ein Eintrag mit
  dem Kürzel als Konto.
- Netz: `https://api.linear.app/graphql`, wenn ein `tickets`-Befehl läuft oder wenn in der App der
  Labs-Schalter an ist (Einstellungen › Tickets, später die Ansicht). `done --image` schickt die Bilddatei
  zusätzlich an die Adresse, die Linear zum Hochladen nennt (https, ohne den Key).
- Schreibzugriffe auf Linear lösen nur die Befehle `link`, `done`, `unlink`, `status`, `note`, `comment`, `new`,
  `assign`, `label`, `decide` und `check` (mit Verweis) aus. `done --image` lädt zusätzlich eine Bilddatei zu
  Linear hoch; der Key geht dabei nicht an den Speicher-Dienst.

## Die Ansicht in der App

Die Ansicht liest nur. Bilder: `make snapshots ONLY=tickets` (Board, Backlog, Detail, Leerzustände), Beispiele
in [`../design/ticket-board/`](../design/ticket-board/).

### Einstieg

- **Knopf in der Titelzone:** Ist der Schalter „Show tickets in Agent Chats“ an, steht neben dem Knopf für die
  Seitenleiste ein Ticket-Knopf. Er schaltet den Bereich unter der Tab-Leiste zwischen Chats und Tickets um;
  Seitenleiste und Tabs bleiben stehen. Ist der Schalter aus, gibt es den Knopf nicht.
- **Welches Projekt:** das im Fenster gewählte. Ein Klick auf ein Projekt in der Seitenleiste wechselt das
  Board; Filter und Auswahl gehören zum Projekt und werden dabei verworfen.
- **Zurück zu den Chats:** derselbe Knopf, ⌘W, oder alles, womit der Nutzer einen Chat oder Workspace wählt
  (Klick in Seitenleiste oder Tab-Leiste, ⌘1 bis ⌘9, Ctrl+Tab, Controller, „Zum Chat“ am Ticket, ein Workspace,
  eine Mitteilung). Rückt die Auswahl nur nach, weil ein Tab geschlossen oder ein Chat archiviert wurde, bleiben
  die Tickets stehen.
- **Steuerkanal:** Wählt `whisperm8 chats focus`, `chats open` oder `workspace open` einen Chat, bleiben die
  Tickets ebenfalls stehen; die Auswahl wechselt dahinter. Ausnahme: ein Chat, der erst starten muss
  (`chats start`, `chats resume`), siehe Grenzen.
- **Was hinter den Tickets nicht gilt:** Der gewählte Chat ist kein Ziel für das Diktat, ein Subagent-Ergebnis
  gilt nicht als gelesen, und das Projekt des Boards folgt einer Auswahl aus dem Steuerkanal nicht. Beim
  Verlassen der Tickets wird beides für den gewählten Chat nachgeholt: Das Projekt folgt ihm, sein Ergebnis gilt
  als gelesen.
  Fertig-Ton, Mitteilung, Ansage und Notch melden einen verdeckten Chat wie jeden anderen; sie prüfen nirgends,
  ob ein Chat gerade zu sehen ist.
- **Je Fenster, nicht gespeichert:** Jedes Fenster schaltet für sich. Nach einem Neustart zeigt jedes Fenster
  wieder Chats. Wer zwischen Chats und Tickets wechselt, sieht beim Zurückkommen sofort den letzten Stand; der
  frische Abruf läuft dahinter.
- **Controller und Tastatur:** Solange Tickets den Chat verdecken, meldet das Fenster dem Controller keinen
  gewählten Chat. Bestätigen, Abbrechen und Diktat per Controller treffen ihn dann nicht. ⌃⌘Pfeil wechselt den
  Fokus im verdeckten Raster nicht.
- **Fenster schließen:** gibt Modus und Stand der Ticket-Ansicht dieses Fensters frei.

### Abruf

- Abgerufen wird beim Zeigen sofort, danach alle 120 Sekunden, dazu der Knopf im Kopf. Ist das Fenster verdeckt,
  minimiert oder geschlossen, zeigt es Chats, oder ist der Schalter aus, gibt es keinen Abruf.
- Meldet Linear „Rate limited“, ruht der Takt 15 Minuten (`TicketBoardStore.rateLimitPause`), auch über
  Verdecken und Zeigen hinweg. Der Knopf fragt trotzdem, einmal je Druck.
- Wird das Fenster wieder aktiv, liest die Ansicht Zuordnung und Schlüssel neu. Wer in den Einstellungen etwas
  einrichtet und zurückkommt, sieht das Board ohne weiteren Klick.
- Ändert sich etwas an den Chats der App (neuer Chat, neuer Titel, Chat beendet), gleicht die Ansicht nach
  zwei Sekunden Ruhe neu ab, ohne Linear zu fragen. Eine neue Verknüpfung (`tickets link`) liegt bei Linear und
  steht deshalb erst nach dem nächsten Abruf auf der Karte, spätestens nach 120 Sekunden oder mit dem Knopf.
  Der Zustand eines Chats folgt sofort.
- Signposts in der Stufe `.detail`: `tickets.fetch` (ein Abruf bei Linear), `tickets.chats` (Liste der Chats
  lesen, Main Thread), `tickets.build` (Abgleich abseits des Main Threads).

### Was ein Abruf bei Linear kostet

Linear zählt je Key und Stunde 2.500 Anfragen und 3.000.000 „Complexity“-Punkte. Derselbe Key trägt die Ansicht
und jeden `tickets`-Befehl aller Chats: Ist das Budget weg, steht beides. Gemessen am 14.11.2026 über die
Kopfzeilen der Antworten (`X-Complexity`, `X-RateLimit-Requests-Remaining`, `X-RateLimit-Complexity-Remaining`):

| Team | offene Tickets | Anfragen je Abruf | Punkte vorher | Punkte jetzt |
|---|---|---|---|---|
| WM8 | 74 | 2 | 230 | 140 |
| DEA | 4 | 2 | 230 | 140 |
| PRB | 108 | 3 | 310 | 175 |

„Vorher“ holte je Ticket 20 Labels, 20 Anhänge und 20 Beziehungen. Jetzt holt das Board 8 Labels, 8 Anhänge
(nur die Verknüpfungen mit Chats) und 6 Beziehungen (`LinearTicketSource.boardFields`); das einzelne Ticket
bleibt bei den vollen Listen. Die Punkte hängen an der Abfrage, nicht an der Zahl der Tickets; je weitere
100 offene Tickets kommt eine Anfrage dazu.

Ein sichtbares Fenster mit dem Board von WM8 braucht damit je Stunde 60 Anfragen (2,4 % des Budgets) und
4.200 Punkte (0,14 %). Beim alten Takt von 30 Sekunden wären es 240 Anfragen gewesen (9,6 %). Knapp sind also
die Anfragen, nicht die Punkte. Der Takt von 120 Sekunden ist ein Startwert.

Die Zahlen lassen sich jederzeit nachmessen: `whisperm8 tickets doctor` nennt je Team die Kosten eines Abrufs
und den Rest des Budgets („Budget WM8“). Jede Anfrage schreibt außerdem `linear_cost complexity=…
remaining_complexity=… remaining_requests=…` ins Debug-Log; der Schlüssel steht nicht darin.

### Was die Ansicht statt des Boards zeigt

| Zustand | Text | Knopf |
|---|---|---|
| kein Projekt gewählt | „Choose a project“ | keiner |
| Ordner gehört zu keinem Team | „This project is not linked to a team“ | zu den Ticket-Einstellungen |
| kein Schlüssel für den Workspace | „No Linear key for this workspace“ | zu den Ticket-Einstellungen |
| erster Abruf läuft | „Loading tickets…“ | keiner |
| erster Abruf gescheitert | „Tickets could not be loaded“ mit dem Grund | „Try Again“ |
| Schalter ging aus, während die Ansicht offen war | das Fenster kehrt zu den Chats zurück | |

Scheitert ein späterer Abruf, bleibt das Board stehen, und eine Zeile nennt den Grund und die Uhrzeit des
gezeigten Stands.

### Inhalt

- **Board:** drei Spalten nach Art des Status (in Arbeit, als Nächstes, Backlog). In „In Arbeit“ stehen die
  Tickets nach Status in der Reihenfolge des Teams, darin nach Priorität. Jede Karte zeigt Nummer, Priorität,
  Fortschritt der Kästchen, Person, Titel, Projekt und Meilenstein, Status und Labels, und unten den Chat mit
  Status-Punkt und Zustand. Sitzt keiner daran, steht dort „Kein Agent“, bei einem abgegebenen Ticket „Abgegeben
  von …“.
- **Backlog:** dieselben Tickets als Liste, nach Projekt gruppiert.
- **Filter:** Agent (alle, mit, ohne) und Person (alle, nicht zugewiesen, je Person) lassen sich kombinieren,
  dazu die Auswahl eines Projekts. Jede Zahl gilt innerhalb der übrigen Auswahl.
- **Detail:** Eckdaten, der Chat mit „arbeitet seit …“, „Zum Chat“ und „In Linear öffnen“, darunter die
  Beschreibung, leicht gesetzt (Überschriften, Kästchen, Listen mit ihren Nummern). Escape schließt es.
- **Leiste:** laufende Chats ohne offenes Ticket, mit dem Ticket, an dem sie zuletzt saßen. Supervisor-Chats
  stehen getrennt daneben und zählen nicht als Lücke.
- **Schmales Fenster:** Die Spalten werden nicht schmaler als 260 pt, darunter scrollt das Board waagrecht.
  Unter 940 pt Breite liegt das Detail über dem Inhalt statt daneben; die Liste lässt dann Status und
  Fortschritt weg.
- **Labels auf der Karte:** höchstens zwei, zuerst alles, was etwas über den Stand sagt; die Art des Tickets
  (Linears Bug, Feature, Improvement) zuletzt und zurückhaltend. Der Status steht nur auf der Karte, wenn er
  mehr sagt als die Spalte.
- **Begriffe:** Englisch stehen Linears Wörter (Project, Milestone). Die deutsche Übersetzung sagt „Bereich“
  und „Vorhaben“, so wie dieses Projekt Linear ordnet.

So bleibt die Ansicht ruhig und billig:

- Gerechnet wird im `TicketBoardViewModel`, wenn sich der Abzug, ein Filter oder die Auswahl ändert, nie beim
  Zeichnen. Die Ansichten bekommen fertige Werte.
- Den Live-Zustand der Chats lesen nur die Status-Punkte und der Text daneben (`TicketChatStatusSource`). Ein
  Statuswechsel baut weder Karten noch Board neu auf. Der Punkt ist der gemeinsame der App
  (`AgentStatusIndicator`), Grün heißt nur „arbeitet“.
- Kein Zähler läuft mit: Im Kopf steht die Uhrzeit des letzten Abrufs. Scheitert ein Abruf, bleibt der letzte
  Stand stehen, und eine Zeile sagt, von wann er ist.
- Nichts ist nur beim Überfahren sichtbar, und es gibt kein Kontextmenü.
- Fortschritt der Kästchen und Rufnamen der abgebenden Chats rechnet der Eintrag einmal aus, nicht die Karte
  bei jedem Zeichnen. Der Zustand der Chats gehört nicht zum Vergleich des Modells: Ein neuer Abzug, in dem
  sich nur Zustände geändert haben, rechnet nichts neu.

Tickets stammen auch von anderen Leuten. In der Beschreibung bleibt ein Link nur anklickbar, wenn er mit
`http` oder `https` ins Web führt; `file:`, `smb:` und Schemata fremder Apps werden zu Text. Mehr als 400
Zeilen werden nicht gesetzt, der Rest steht in Linear.

## Grenzen

- **Die Absagen schützen vor Versehen, sie sind keine Sicherheitsgrenze.** Wer die Chat-Kennung aus der
  Umgebung nimmt, gilt als Mensch im Terminal. Supervisor ist, wessen Chat-Titel mit „Jarvis“ beginnt; wer
  seinen Supervisor anders nennt, hat für die Kommandozeile keinen. Der Linear-MCP und die Oberfläche von Linear
  setzen jeden Status ohne Rückfrage, und „verworfen“ prüft die Kommandozeile gar nicht. Die Regeln halten die
  Chats ein; das Werkzeug erinnert sie daran.
- **Die Verknüpfung ist für alle im Workspace sichtbar:** Am Ticket steht ein Anhang „Chat: <Titel des Chats>“
  mit Projektname und Zeit. In einem Workspace mit Kollegen lesen alle den Chat-Titel mit. Entschieden am
  14.11.2026: Der Anhang bleibt in jedem Workspace an, es gibt keinen Schalter dafür.
- **Linears eigene Agent-Sitzungen nutzt WhisperM8 nicht.** Die Filter „Agent“ und „Agent Session“ in Linear
  kennen deshalb keinen unserer Chats; „Mit Agent“ und „Ohne Agent“ sind eigene Ansichten auf den Anhang.
- **Text an Tickets:** höchstens 64 KB je Text, aus Argument, stdin oder `@datei`. Was gesendet wird, liegt
  danach bei Linear. `@datei` liest jede lesbare Datei; den Inhalt prüft die Kommandozeile nicht.
- Ein Board lädt bis zu 500 offene Tickets (fünf Seiten zu 100).
- Linear erlaubt 2.500 Abfragen je Stunde und Person. Ein `board` braucht zwei Abfragen, je weitere 100 offene
  Tickets eine mehr (Messung oben unter „Was ein Abruf bei Linear kostet“).
- Zyklen, Vorhaben, Meilensteine, Dokumente und Releases deckt die Kommandozeile nicht ab; dafür gibt es den
  Linear-MCP.
- Chats, die in WhisperM8 auf einem anderen Rechner laufen, erscheinen am Ticket ohne Zustand
  („anderer Rechner oder gelöscht“).
- **Ein Chat, den die CLI startet oder fortsetzt, holt das Fenster aus den Tickets.** Ein Chat startet erst,
  wenn seine Ansicht im Fenster steht (`shouldLaunchOnOpen` im `AgentSessionDetailView`); bliebe das Fenster
  bei den Tickets, liefe er nicht an. Wer als Supervisor Chats startet, während jemand das Board liest,
  unterbricht ihn dabei. Wer das Board in Ruhe lesen will, öffnet es in einem zweiten Fenster: Neue und
  fortgesetzte Chats landen im Hauptfenster (oder in dem Fenster, das ihren Tab schon zeigt). Den Start von der
  Ansicht zu lösen, ist nicht Teil von Stufe 1.
- **Zwei Fenster mit Tickets rufen doppelt ab.** Jedes Fenster hat seinen eigenen Takt, auch für dasselbe Team.
- **Das Board zeigt je Ticket höchstens acht Verknüpfungen mit Chats,** die zuletzt geänderten zuerst; bei mehr
  fehlen die ältesten, nie die aktive. „Blockiert“ rechnet es aus höchstens sechs Beziehungen. `tickets show`
  liest die vollen Listen.
- **Die Auswahl-Abfrage beim Wiederverbinden eines Chats** kann über den Tickets erscheinen, wenn der Tab
  dahinter gewählt ist.
- **Kein Tastenkürzel für den Umschalter,** und der Umschalter für Chats mit Ctrl+Tab ist über den Tickets
  nicht zu sehen (er wechselt trotzdem).
- **„Zum Chat“ liest die Workspace-Datei auf dem Main Thread.** Das ist der vorhandene Weg der App
  (`WindowRequestCenter.requestSessionFocus`), nicht neu, aber hier ein weiterer Aufrufer.

## Tests

`TicketBoardModelTests`, `LinearTicketSourceTests`, `TicketBoardStoreTests`, `TicketConfigTests`, `TicketToolTests`,
`TicketsCLITests`: pure Typen, Quelle gegen feste Antworten, Speicher mit eingespeister Wartefunktion,
Kommandozeile gegen eine Quelle aus Closures. Kein Test braucht Netz, Schlüsselbund oder die App.

Für die Ansicht: `TicketBoardPresentationTests` (Spalten, Filter, Zählungen, Detail),
`TicketBoardControllerTests` (Zuordnung, Abruf nur bei sichtbarer Ansicht, Leerzustände, Projektwechsel, überholte
Antworten) und `AgentWindowStoreTicketsModeTests` (Umschalter je Fenster, Rückkehr zu den Chats, Schnappschuss für
den Controller). Was nur von Hand prüfbar ist, steht als Liste im Plan unter „Tests und Abnahme“.
