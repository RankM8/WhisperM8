---
status: aktiv (Kern, Kommandozeile, Skill, Einstellungen und die lesende Ansicht in der App, Stufe 1)
updated: 2026-11-17
---

# Tickets: Linear und die Chats, die daran arbeiten

WhisperM8 verbindet die Tickets im Ticket-Werkzeug mit den Chats der App. Ein Chat hängt sich an sein
Ticket; daraus ergibt sich, wer woran sitzt, welche Chats laufen und welche Tickets niemanden haben.

Stand 15.11.2026: Es gibt den Kern, die Kommandozeile `whisperm8 tickets`, den Skill `tickets` im Plugin, die
Seite „Tickets“ in den Einstellungen (Labs) und die Ansicht im Agent-Chats-Fenster: Board mit Spalten nach echtem
Status, Liste, Triage mit Kommentaren, Link und Liste kopieren (WM8-112, Paket 1 aus
[`../plans/ticket-board-alltag.md`](../plans/ticket-board-alltag.md), Entwurf
[`../design/ticket-board-alltag.html`](../design/ticket-board-alltag.html)). Die Ansicht liest nur; Knöpfe, die
Tickets ändern, gibt es nicht. Stufe 1: [`../plans/ticket-board.md`](../plans/ticket-board.md), Entwurf
[`../design/ticket-board.html`](../design/ticket-board.html).

## Wer mit dem Ticket-System spricht

- **Die Kommandozeile** liest und schreibt. Jeder Schreibzugriff auf Linear kommt aus einem `tickets`-Befehl.
- **Die App** liest nur, und nur bei eingeschaltetem Labs-Schalter `ticketBoardEnabled` (ab Werk aus): für die
  Ticket-Ansicht das Board eines Teams und ein Ticket, für `tickets open` das eine Ticket, für die Einrichtung das
  Konto und die Teams eines Keys.
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
| Ticket in der App zeigen | `tickets open WM8-12` (siehe „Ticket von außen öffnen“) |
| Chat ans Ticket | `tickets link WM8-12`, `tickets done WM8-12 --built "…" --status "Merge-bereit"`, `tickets unlink WM8-12` |
| Status und Text | `tickets status`, `tickets note` (Stand-Zeile), `tickets comment` |
| Entscheidung festhalten | `tickets decide WM8-12 --question "…" --option "A" --option "B" --chosen "A"` |
| Kästchen unter „Fertig, wenn“ | `tickets check WM8-12` (zeigen), `tickets check WM8-12 2 "Detail"` (abhaken), `--uncheck` |
| Anlegen und zuordnen | `tickets new`, `tickets assign`, `tickets label` |
| Einrichten und prüfen | `tickets setup`, `tickets doctor` |

Jeder Befehl kennt `--json`; schreibende Befehle antworten dann mit `{"ok": true, "key": …, "message": …}`,
`doctor` schreibt seinen Bericht immer nach stdout. `tickets link <Ticket> --chat <ID>` direkt nach `chats new`
findet den neuen Chat auch, bevor die App ihn gespeichert hat: Findet es eine ID (hex, ab vier Zeichen) nicht, liest
es bei laufender App bis zu zehnmal je Sekunde neu (WM8-119). Wer welchen Status setzt und wie Chats und Supervisor damit arbeiten, steht im
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

- **Eine Regel für „fertig“:** Der Supervisor hängt den Chat beim Auftrag an sein Ticket (der Chat holt es nach,
  falls nicht; WM8-127). Der Chat gibt es als „Merge-bereit“ ab
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
3. **Regel des Teams (für das Board):** `whisperm8 tickets setup --team WM8 --status "Merge-bereit=wartet"
   --waiting-labels Entscheidung,Handtest`. Siehe „Regel je Team“ unten.
4. **Prüfen:** `whisperm8 tickets doctor`.

Liegt ein Key schon im Schlüsselbund (von einem anderen Werkzeug abgelegt), übernimmt ihn
`whisperm8 tickets setup --workspace <Kürzel>` nach einer Prüfung bei Linear.

### Ein Team wieder herausnehmen

Wird ein Team in Linear gelöscht oder bekommt es ein neues Kürzel, steht das alte weiter in der Einrichtung, und
`tickets doctor` meldet es als Fehler. Der Bericht nennt dann gleich den passenden Befehl:

| Lage | Was `doctor` vorschlägt |
|---|---|
| Team nicht mehr zu sehen, kein Ordner hängt daran | `whisperm8 tickets setup --remove-team <Kürzel>` |
| Team nicht mehr zu sehen, ein Ordner hängt daran | erst den Ordner dem neuen Kürzel geben (`setup --team <Kürzel> --project <Ordner>`), dann `--remove-team <Kürzel>`. Der Bericht nennt `--with-projects` absichtlich nicht: `--remove-team` allein bricht ab und zeigt erst die Folgen für den Ordner |
| das Kürzel gibt es in einem anderen eingerichteten Workspace | beide Wege: umhängen mit `setup --team <Kürzel> --workspace <anderer> --reassign`, wenn es dasselbe Team ist, sonst `--remove-team`. Hängt ein Ordner daran, steht dabei, dass er nach dem Umhängen in den anderen Workspace schreibt |

„Nicht mehr zu sehen“ heißt: Der Key des Workspaces findet das Kürzel nicht. Das Team wurde gelöscht oder
umbenannt, oder der Key hat keinen Zugriff darauf (privates Team). Unterscheiden kann die Kommandozeile das
nicht, sie merkt sich nur das Kürzel. Ein gleiches Kürzel in einem anderen Workspace ist meist ein fremdes Team;
deshalb rät der Bericht dort nicht einfach zum Umhängen.

`--remove-team` nimmt den Workspace-Eintrag des Teams aus `tickets.json`. Hängt noch ein Ordner an dem Team,
bricht der Befehl ab, nennt ihn und sagt, was ohne das Team für ihn gilt; mit `--with-projects` löst er auch
diese Zuordnung samt der Tabelle der Bereiche. Workspace und Key bleiben. Der Befehl fragt Linear nicht und geht
deshalb auch ohne Netz und ohne Zugang.

Ein Ordner ohne eigenes Team ist nicht in jedem Fall „ohne Team“, und das gilt genauso, wenn die Einstellungen
eine Zuordnung entfernen: Liegt er in einem anderen Projektordner, erbt er dessen Team. Sonst hat er keines;
was dann gilt, steht unter „Mehrere Workspaces“ (Ordner ohne Team). Die Sperre gegen das Schreiben in einen
fremden Workspace hängt am Projekt: Für einen Ordner ohne Projekt gilt sie nicht.

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
- **Team nicht gefunden:** Sieht der Key ein Team der Einrichtung in seinem Workspace nicht mehr, steht an
  seiner Zuordnung „in <Workspace> nicht gefunden“ statt des Workspaces. „Remove“ löst dort den Ordner, und mit
  dem letzten Ordner geht auch das Team aus der Einrichtung; der Ordner steht danach wieder zur Wahl. Ein solches
  Team ohne Ordner bekommt eine eigene Zeile mit „Remove“; das entspricht `tickets setup --remove-team`. Als
  Teams eines Workspaces führt die Seite ohnehin nur, was Linear gerade nennt. Den Vermerk gibt es nur, wenn die
  Team-Liste sicher vorliegt: mit Key, ohne Störung und mit weniger als 100 Teams (mehr holt die Abfrage nicht).

`tickets.json` hat damit zwei Schreiber, Kommandozeile und Einstellungen. Beide lesen vor jeder Änderung neu
und schreiben atomar; wer zuletzt schreibt, gewinnt. Die Seite ändert nichts an einer Datei, die sich nicht
lesen lässt (die Kommandozeile finge in dem Fall leer an).

## Mehrere Workspaces

Wer für mehr als eine Firma arbeitet, hat mehr als einen Workspace. Jeder ist ein eigener Mandant mit eigenem
Key, eigenen Teams und eigener Rechnung.

- **Weg der Auflösung:** Ticket-Nummer → Team (`ABC-12` → `ABC`) → Workspace (`tickets.json`) → Key dieses
  Workspaces. Bei `board`, `list` und `new` kommt das Team aus dem Projekt des aktuellen Ordners oder `--team`.
- **Nie geraten:** Gibt es nur einen Workspace, liegt jedes Team dort. Bei mehreren muss das Team zugeordnet
  sein (`tickets setup --team <Kürzel>`); sonst bricht der Befehl ab, bevor er Linear fragt.
- **Ordner ohne Team:** Ein Ordner gehört zu einem Team, wenn er selbst oder ein Ordner über ihm zugeordnet
  ist. Aus jedem anderen Ordner gilt für Befehle ohne Ticket-Nummer und ohne `--team`:

  | | ein Workspace | mehrere Workspaces |
  |---|---|---|
  | `board`, `list` (lesen) | zeigen das einzige Team mit Ordner, wenn es genau eines gibt; sonst Abbruch mit Hinweis auf `--team` | Abbruch mit Hinweis auf `--team` |
  | `new` (schreiben) | Abbruch, nichts wird angelegt | Abbruch, nichts wird angelegt |

  Schreiben rät das Team nie. Früher ging `tickets new` aus jedem Ordner an das Team, das als einziges einen
  Ordner hatte, und für einen Ordner ohne Projekt hält auch die Schreibsperre nichts auf. Die Absage (Exit 1)
  nennt den Ordner, die eingerichteten Teams und beide Wege: `--team <Kürzel>` oder den Ordner zuordnen
  (`tickets setup --team <Kürzel> --project <Ordner>`). Ruft ein Chat, dessen Projekt zugeordnet ist, nennt sie
  sein Team als Vorschlag, nimmt es aber nicht von selbst. Lesen geht mit `--team` oder einer Ticket-Nummer
  weiter aus jedem Ordner. Befehle mit Ticket-Nummer (`comment`, `status`, `done` …) nennen ihr Team selbst;
  für sie ändert sich nichts.
- **Schreibsperre über die Projektgrenze:** Ein Chat schreibt nur in den Workspace seines Projekts, egal in
  welchem Ordner seine Shell steht (`/tmp`, Home, eine Arbeitskopie neben dem Projekt). Ruft kein Chat oder ist
  dessen Projekt keinem Workspace zugeordnet, zählt der Ordner. Ein Chat der einen Firma kann die Tickets der
  anderen lesen, aber nicht ändern, und er hängt sich nicht an deren Tickets. Der Befehl endet mit Exit 4, bevor
  die fremde Quelle gefragt wird. Verlangt der Nutzer es ausdrücklich, hebt `--other-workspace` die Sperre für
  diesen einen Aufruf auf. Ein Mensch im Terminal außerhalb jedes zugeordneten Ordners hat keine Grenze,
  solange er Team oder Ticket-Nummer nennt; dasselbe gilt für einen Chat, dessen Projekt keinem Team zugeordnet
  ist und dessen Shell in einem Ordner ohne Team steht.
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
Services/Tickets/TicketBoardModel.swift      wer sitzt woran, Chats ohne offenes Ticket, Supervisor; Filter, Zählungen, Gruppen der CLI
Services/Tickets/TicketBoardLanes.swift      Spalten des Boards nach echtem Status
Services/Tickets/TicketTeamRule.swift        Regel je Team: was ein Status bedeutet, wann ein Ticket auf mich wartet
Services/Tickets/TicketSource.swift          Grenze zum Ticket-Werkzeug, Fehler, Stand-Zeile
Services/Tickets/LinearGraphQLClient.swift   ein Aufruf, Fehlerübersetzung; Key im Schlüsselbund
Services/Tickets/LinearTicketSource.swift    die einzige Stelle, die Linear kennt
Services/Tickets/TicketConfig.swift          Projektordner ↔ Team ↔ Workspace (tickets.json)
Services/Tickets/TicketChecklist.swift       Kästchen unter „Fertig, wenn“ lesen und setzen
Services/Tickets/TicketRecordText.swift      fester Aufbau für Entscheidung und Abschluss
Services/Tickets/TicketHygiene.swift         Ordnung der Tickets, Tabelle der Bereiche, Bild-Typen
Services/Tickets/TicketBoardStore.swift      Abzug mit Takt für die Ansicht
Views/Tickets/TicketErrorText.swift          Fehler als übersetzter Satz für die Oberfläche
Models/Tickets/TicketView.swift              gespeicherte Ansichten aus Linear, Reiter und Standard (WM8-125)
Views/Tickets/TicketBoardPresentation.swift  fertig gerechneter Inhalt, Zustand der Ansicht (Auswahl), Live-Zustand der Chats
Views/Tickets/TicketBoardViewModel+Views.swift  Reiter, Aufklappen, was unter „Mehr“ steht
Views/Tickets/TicketBoardView.swift          Kopf, Umschalter Liste/Board
Views/Tickets/TicketViewTabsBar.swift        Reiterzeile, „Mehr“, Zeile unter den Reitern
Views/Tickets/TicketCardView.swift           Karte und Spalten
Views/Tickets/TicketListGrouping.swift       Gruppen, Reihenfolge und Unteraufgaben der Liste, pur
Views/Tickets/TicketListView.swift           Liste: Gruppenköpfe, Zeile wie Linear plus Chat, was bei Enge wegfällt
Views/Tickets/TicketLooseChatsBar.swift      Zeile „Chats ohne Ticket“
Views/Tickets/TicketTriageView.swift         Triage: Liste links (ziehbar), Ticket mit Eigenschaften-Zeile
Views/Tickets/TicketBoardSelection.swift     Auswahl und Tasten der Triage, pur (gewählt, nächstes, voriges, schließen, Abgleich)
Views/Tickets/TicketBoardViewModel+Triage.swift  Triage auf den Zustand der Ansicht angewendet
Views/Tickets/TicketTextDocument.swift       Titel, Beschreibung und Kommentare als ein Text, dazu die Textansicht
Views/Tickets/TicketCopyText.swift           Text für „Link kopieren“ und „Liste kopieren“, Schreiben in die Zwischenablage
Views/Tickets/TicketDescriptionBlocks.swift  Beschreibung zerlegen (Überschriften, Kästchen, Listen), sichere Links, Bilder als Verweis
Models/Tickets/TicketComment.swift           Kommentar am Ticket, Art (Entscheidung, Abschluss)
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

Die Ansicht liest nur. Bilder: `make snapshots ONLY=tickets` (Board, Liste, Triage, Leerzustände), Beispiele
in [`../design/ticket-board/`](../design/ticket-board/).

### Einstieg

- **Knopf in der Titelzone:** Ist der Schalter „Show tickets in Agent Chats“ an, steht neben dem Knopf für die
  Seitenleiste ein Ticket-Knopf. Er schaltet den Bereich unter der Tab-Leiste zwischen Chats und Tickets um;
  Seitenleiste und Tabs bleiben stehen. Ist der Schalter aus, gibt es den Knopf nicht.
- **Welches Projekt:** das im Fenster gewählte. Ein Klick auf ein Projekt in der Seitenleiste wechselt das
  Board; Filter und Auswahl gehören zum Projekt und werden dabei verworfen.
- **Platz:** Im Ticket-Modus fällt die Zeile unter den Tabs weg (Workspace mit Belegung, „Notizen zu“ und
  Raster-Auswahl bzw. der Kopf des Chats); Board und Board-Chat reichen bis an die Tabs (WM8-124). In den Chats
  bleibt sie, wie sie ist.
- **„← Chats · WM8 Aktiv“:** links im Kopf des Boards, in der Triage vor „‹ Board“ und in den Leerzuständen oben,
  immer sichtbar. Er führt dorthin, wohin L2 führt (`backPlace()`): zum vorigen Chat oder Workspace. Gibt es den
  nicht, oder ist der vorige Ort ein anderes Board, schließt er nur die Tickets und nennt, was dahinter steht. Die
  Regel ist pur (`TicketsBackLink`). Der Knopf wird nie gekürzt; Namen über 24 Zeichen enden mit „…“. Ist die Ticket-Spalte der Triage schmaler als 800 pt, steht im Kopf nur „← Chats“
  (der Name in der Hilfe), und „Link kopieren“ und „In Linear öffnen“ zeigen nur ihr Symbol.
- **Zurück zu den Chats:** derselbe Knopf, ⌘W, oder alles, womit der Nutzer einen Chat oder Workspace wählt
  (Klick in Seitenleiste oder Tab-Leiste, ⌘1 bis ⌘9, Ctrl+Tab, Controller, „Zum Chat“ am Ticket, ein Workspace,
  eine Mitteilung). Rückt die Auswahl nur nach, weil ein Tab geschlossen oder ein Chat archiviert wurde, bleiben
  die Tickets stehen.
- **Steuerkanal:** Wählt `whisperm8 chats focus`, `chats open` oder `workspace open` einen Chat, bleiben die
  Tickets ebenfalls stehen; die Auswahl wechselt dahinter. Ausnahme: ein Chat, der erst starten muss
  (`chats start`, `chats resume`), siehe Grenzen.
- **Was hinter den Tickets nicht gilt:** Der gewählte Chat ist kein Ziel für das Diktat (Ziel ist der sichtbare
  Board-Chat, siehe unten), ein Subagent-Ergebnis
  gilt nicht als gelesen, und das Projekt des Boards folgt einer Auswahl aus dem Steuerkanal nicht. Beim
  Verlassen der Tickets wird beides für den gewählten Chat nachgeholt: Das Projekt folgt ihm, sein Ergebnis gilt
  als gelesen.
  Fertig-Ton, Mitteilung, Ansage und Notch melden einen verdeckten Chat wie jeden anderen; sie prüfen nirgends,
  ob ein Chat gerade zu sehen ist.
- **Je Fenster, nicht gespeichert:** Jedes Fenster schaltet für sich. Nach einem Neustart zeigt jedes Fenster
  wieder Chats. Wer zwischen Chats und Tickets wechselt, sieht beim Zurückkommen sofort den letzten Stand; der
  frische Abruf läuft dahinter.
- **Controller und Tastatur:** Solange Tickets den Chat verdecken, meldet das Fenster dem Controller keinen
  gewählten Chat, sondern das Board (eigener Zusammenhang `tickets`, WM8-91). Bestätigen, Abbrechen und Diktat
  per Controller treffen den Chat dann nicht. Das Board ist ein Ort für L2: hin über „Wohin“ (Reiter „Tickets“)
  oder Options „Ticket-Board WM8“, zurück mit L2 getippt. Einzelheiten in
  [controller.md](controller.md#ticket-board). ⌃⌘Pfeil wechselt den Fokus im verdeckten Raster nicht.
- **Fenster schließen:** gibt Modus und Stand der Ticket-Ansicht dieses Fensters frei.

### Ticket von außen öffnen (`tickets open`, WM8-131)

`whisperm8 tickets open WM8-12` zeigt ein Ticket in der App, wenn der Nutzer ausdrücklich darum bittet. Die
Skills `tickets` und `jarvis` rufen es nicht von sich aus vor einer Frage auf: Der Befehl schaltet das zuletzt
aktive Fenster aufs Board (die Frage im Chat ist dann aus dem Blick) und macht den Board-Chat zum Diktat-Ziel.
Ob Tickets bei Fragen von selbst aufgehen, entscheidet der Nutzer später. Die Kommandozeile reicht nur die Nummer über den Control-Socket weiter (`tickets.open`); prüfen
und zeigen macht die App (`TicketOpenService`, `TicketOpenPresenter`). Auch die Adresse aus Linear geht
(`https://linear.app/<workspace>/issue/WM8-12/…`).

- **Erst prüfen, dann zeigen.** Ticket-Ansicht an, Nummer lesbar, Team eingerichtet, Projekt der App zum Team,
  Ticket bei Linear ladbar (eine lesende Abfrage). Scheitert etwas, kommt die Meldung auf stderr, und in der App
  ändert sich nichts. Exit: 1 Aufruf, 3 Ticket, Team oder Projekt unbekannt, 4 Ticket-Ansicht aus oder kein
  Fenster, 5 App oder Linear nicht erreichbar, 6 Ausgang unklar.
- **Welches Board:** das Projekt des Teams aus der Nummer, nach derselben Regel wie der Reiter „Tickets“ des
  Controllers (`TicketTeamDirectory`): das Projekt, dessen Ordner in `tickets.json` steht, sonst das erste
  Projekt der App mit diesem Team. Leitet Linear eine alte Nummer auf ein anderes Team um, kommt eine Meldung
  mit der neuen Nummer statt eines fremden Boards.
- **Welches Fenster:** das zuletzt aktive Agent-Chats-Fenster (bei vorderer App das vorderste), sonst das
  Hauptfenster, das dafür auch geöffnet wird. Es wechselt auf das Board dieses Projekts wie mit dem
  Ticket-Knopf, die App kommt nach vorn, das Fenster wird Schlüsselfenster.
- **Das Ticket groß:** Steht es in der gezeigten Liste (bzw. im Board in seiner Spalte), öffnet die Triage dort
  wie mit einem Klick, J/K blättern weiter. Sonst (erledigt, in einer anderen Ansicht, in einer zugeklappten
  Gruppe) zeigt die Triage es einzeln; Ansicht, Filter und Board/Liste bleiben, wie sie waren. Lädt das Board
  erst, wartet der Wunsch bis zu 30 Sekunden; wer vorher zu den Chats zurückgeht, verwirft ihn. Die
  Kommandozeile sagt dann „vorgemerkt“ statt „offen“ (`--json`: `"pending": true`).
- **Nichts in einen Chat:** Der Befehl schickt nichts in einen Chat und schreibt nichts nach Linear. Hatte im
  Fenster das Terminal des Board-Chats die Tastatur, gibt das Fenster sie ab: Wer gerade woanders tippte,
  schreibt danach ins Board, nicht in den Board-Chat.
- **Kosten:** im Ereignis-Pfad eine Suche über die Projekte der App und ein Lesen von `tickets.json` abseits des
  Main Threads, dazu eine Abfrage bei Linear. Im Board nichts Neues je Zeichnen; das einzelne Ticket wird mit
  der Chat-Liste des letzten Abgleichs verknüpft, ohne neuen Durchlauf über die Chats.

### Board-Chat (Seitenspalte, WM8-113)

Rechts neben Board und Triage steht der Board-Chat. Plan: [`../plans/ticket-board-alltag.md`](../plans/ticket-board-alltag.md),
Idee 3.

- **Derselbe Chat, kein zweites Terminal:** Die Spalte baut die Detailansicht über `sessionDetailContent`, wie
  Einzelansicht und Kachel. Ein Controller hat genau ein Terminal-NSView; `AgentTerminalContainerView` hängt es in
  den Host, der im Fenster steht. Weil die Tickets im Fenster Einzelansicht und Raster ersetzen, hängt es während
  der Tickets in der Spalte und danach wieder an seinem Platz (Tab, Kachel). Prozess, Verlauf, Raster und die
  Übergabe beim Neustart sind nicht beteiligt. Die Spalte zieht nie den Fokus und startet nichts von selbst
  (`suppressesAutoActivation`); ein ruhender Chat startet über ▶ im Kopf.
- **Nur ein Tab dieses Fensters:** Wie im Raster steht das Terminal nur, wenn der Chat hier ein Tab ist. Sonst
  „Läuft in Fenster 2 · Hierher holen“ (das Hauptfenster ist 1, die weiteren folgen in ihrer Reihenfolge) oder
  „In keinem Fenster offen · Hier öffnen“. Verschoben oder geöffnet wird nur auf Klick; „Hier öffnen“ legt den
  Tab an, ohne die Tickets zu verlassen.
- **Wahl (Teil c):** Im Kopf stehen Knöpfe für den Jarvis und den Produkt-Chat des Projekts (Titel enthält
  „Produkt“ oder „Product“ und ist kein Jarvis), dazu ein von Hand hineingezogener Chat. Ein Chat lässt sich aus
  Seitenleiste oder Tab-Leiste auf die Spalte ziehen. Die Wahl gilt je Projekt und bleibt gespeichert
  (`chosenSessionID`); ein Klick auf den Jarvis-Knopf löscht sie, dann übernimmt wieder der automatische Jarvis.
  Angenommen werden nur echte Agent-Chats (Claude, Codex, einzelne Hintergrund-Agents) dieses Projekts, einzeln:
  Ein Terminal-Tab, `claude agents`, ein Subagent-Job, ein archivierter Chat, ein Chat eines anderen Projekts oder
  eine Tab-Gruppe werden mit einem sichtbaren Satz abgelehnt (`BoardChatRules.rejection`). Dieselbe Prüfung gilt
  beim Lesen der gespeicherten Wahl und für den automatischen Jarvis und Produkt-Chat: In einer Shell gingen die
  Zeilenumbrüche aus Bezug und Triage als Return hinaus. Produkt-Chat heißt „Produkt“ oder „Product“ als ganzes
  Wort („Produktion“ zählt nicht). Steht der gewählte Chat in einem anderen Fenster, gilt der Hinweis
  „Läuft in Fenster 2“.
- **Welcher Chat:** von Hand gewählt (`chosenSessionID`), sonst der Jarvis des Projekts:
  Titel beginnt mit „Jarvis“ (dieselbe Regel wie `tickets board` und `tickets status`), Projekt des Boards samt
  Arbeitsordnern, laufend vor ruhend, dann zuletzt aktiv. Gesucht wird nur unter offenen Tabs und laufenden Chats
  (`BoardChatRules`, nachgeschlagen über `AgentWorkspaceUIModel.session(id:)`), nie über alle Chats; dazu der zuletzt gefundene Jarvis des
  Projekts (`lastJarvisSessionID`), damit er auch gestoppt und ohne Tab als „Hier öffnen“ erscheint. Ohne Jarvis
  sagt die Spalte, wie einer hineinkommt.
- **Fokus:** Ins Terminal der Spalte kommt der Tastaturfokus nur durch einen Klick ins Terminal. Jeder andere
  Klick im Fenster (Karte, Listenzeile, Pfeile, Knöpfe, freie Fläche) gibt ihn vorher ans Fenster zurück
  (`BoardChatFocusGuard`, Regel pur in `BoardChatFocusRule`). Sonst blieben J/K, Esc und ⌘C nach einem Klick ins
  Terminal dort, und Esc bräche den laufenden Turn ab. Wege ohne Maus (Controller) rufen
  `BoardChatFocusRule.releaseTerminalFocus(in:)`. Hört der Board-Chat auf zu laufen, gibt sein Terminal den Fokus
  ebenfalls ab (`releasesFocusWhenStopped`); sonst reagierte das Board erst nach einem Klick neben das Terminal.
- **Unter dem Chat:** nur die Bezug-Marke in einer Zeile, dazu kurz ein Hinweis, wenn nichts eingefügt wurde.
  Beim allerersten Öffnen steht einmal eine Erklärung darunter (wer hier steht und wie man wechselt, was die Marke
  tut) mit OK; danach nicht mehr, gemerkt als `introSeen` in `ticket-board-chat.json` (WM8-124).
- **Breite und Zuklappen:** Ab Werk 40 % des Bereichs aus Board und Spalte (WM8-124, Giuliano 16.11.2026),
  mindestens 280 pt. Gezogen wird am Griff auf der linken Kante (ein senkrechter Strich, immer sichtbar); die
  Breite ändert sich beim Loslassen, vorher zeigt eine Linie die neue Kante (sonst bekäme die TUI bei jedem
  Mausschritt eine neue Größe). Eine Obergrenze gibt es nicht, nur das Board behält mindestens 420 pt; die gezogene
  Breite gilt in Board und Triage gleich. Zurück zur Vorgabe geht es mit einem Doppelklick auf den Griff oder mit dem Knopf im
  Kopf der Spalte, der nur dasteht, solange eine eigene Breite gilt. Zugeklappt bleibt eine schmale Leiste mit
  Knopf. Breite, Zuklappen und Wahl gelten je Projekt und liegen in `ticket-board-chat.json`
  (`BoardChatPreferencesStore`), nicht im UI-Zustand der Fenster: Eine Änderung dort ließe alle Fenster samt
  Seitenleiste neu auswerten.
- **Reiter:** „Liste kopieren“ steht im Kopf neben „Aktualisieren“; die Reiterzeile darunter hat die ganze Breite
  des Boards. Was mit Board-Chat nicht mehr hineinpasst, steht unter „Mehr“ (WM8-125).
- **Eingaben (Teil b):** Solange die Spalte ihr Terminal zeigt, meldet sie den Chat als sichtbar an
  (`BoardChatInputs`, je Fenster, mit Zeichen gegen späte Abmeldungen). Ein Diktat per Hotkey geht dann an ihn,
  gleich wo der Tastaturfokus steht, solange ein Agent-Chats-Fenster vorn ist (`RecordingCoordinator.boardChatTarget`);
  ein ausdrückliches Ziel (Controller, Insel) bleibt. Das Ziel ist ein eigenes, `.boardChat`: Es geht nie mit
  Senden hinaus (auch nicht bei einem Stopp mit Kreuz; die Legende bietet kein Senden an, Kreuz tut nichts), und es
  prüft wie „→ Jarvis“ (`BoardChatInputRules`): offene Frage, auch mit Textfeld, Freigabe laut Sendeweg der CLI,
  Hochfahren, Limit oder eine offene Ansicht von Claude (WM8-123) heißt nur Zwischenablage, ebenso wenn der
  Board-Chat beim Ausliefern in keiner Spalte mehr steht. Pille und Insel nennen den Board-Chat. Der Board-Chat ist im Ticket-Modus auch Kontext des
  Diktats. Tastatur geht nur bei Fokus im Terminal an ihn; J/K, ⌘C und Esc im Board bleiben beim Board.
- **Bezug:** Unter dem Terminal steht „Bezug: WM8-81 ✕“ für das Ticket der Triage. Das nächste Diktat an den
  Board-Chat beginnt mit einer Zeile „Bezug: WM8-81 „Titel“ <Adresse>“, danach gilt der Bezug für dieses Ticket als
  verbraucht; ✕ nimmt ihn für dieses Ticket weg. Festgehalten wird er beim Start der Aufnahme, nicht beim
  Ausliefern: Wer währenddessen weiterblättert, behält den Bezug des Tickets, über das er gesprochen hat. Getippter
  Text bekommt (noch) keinen Bezug. Ob ein Diktat an den Board-Chat auf einer neuen Zeile beginnt, entscheidet sich
  dagegen erst beim Ausliefern, mit oder ohne Bezug (`leadForDictation`): Steht dann Text im Feld, kommt ein
  Umbruch davor.
- **„→ Jarvis“** in der Triage legt `WM8-81 „Titel“ <Adresse>` ins Eingabefeld des Board-Chats; abgeschickt
  wird mit Giulianos Return nach einem Klick ins Terminal (den Fokus gibt nur dieser Klick). Bei offener Frage oder Freigabe (Status, Codex-Dialog,
  `DelayedEnterGuard.approvalPending` wie bei `chats send`), beim Hochfahren, am Limit oder bei offener Ansicht von
  Claude (Transkript, `/tasks`, Agent-Liste, `/config`, Verlaufssuche; WM8-123) kommt nichts hinein: Warnton und ein
  Satz unter dem Terminal. Dasselbe gilt für die Triage-Knöpfe und das Dreieck am Controller. Aufträge nennen nur Nummer, Titel und Adresse (`BoardChatText`, Titel ohne
  Steuerzeichen wie beim Kopieren, höchstens 200 Zeichen), nie die Beschreibung.
- **Triage sammeln (Teil d):** Mit sichtbarem Board-Chat steht unter der Leiste der Triage „Triage, gesammelt für
  Jarvis:“ mit Annehmen, Zurückfragen, Zuweisen…, Später, Doppelt, Ablehnen. Ein Klick legt eine Zeile
  „- WM8-81 „Titel“ <Adresse>: annehmen“ ins Eingabefeld des Board-Chats (nie mit Enter) und geht zum nächsten
  Ticket; der erste Klick eines Auftrags setzt „Triage in WM8, bitte ausführen:“ davor. Die Zeile der Liste zeigt
  „→ Annehmen · gesammelt“. Eine geänderte Entscheidung kommt als neue Zeile mit „(statt: …)“. Ein neuer Auftrag
  beginnt, wenn das Feld sichtbar leer ist oder, falls der Bildschirm nichts sagt, die Tasten-Schätzung keinen
  Entwurf mehr sieht (wie die Warteschlange), wenn das Feld seit Beginn des Auftrags abgeschickt oder geleert wurde
  (Zähler `fieldResets` des Trackers, gelesen nach dem eigenen Einfügen, weil das Einfügen einen nach Esc
  zurückgelegten Prompt selbst mit Ctrl+C leert; so beginnt nach Abschicken und neuem Tippen ein neuer Auftrag mit
  Überschrift), oder wenn ein anderer Chat in der Spalte steht; die Marken gehören zum Auftrag und verschwinden
  mit ihm. Verschwindet nur die Spalte (Tickets kurz zu, zugeklappt, Chat in einem anderen Fenster), bleibt der
  Auftrag; erst mit dem Fenster geht er. Ein zweiter Klick innerhalb einer halben Sekunde zählt nicht (er träfe
  das nächste, ungesehene Ticket). Bezug und „→ Jarvis“ beginnen auf einer neuen Zeile, wenn im Feld schon Text
  steht. Bei offener Frage oder Freigabe: Warnton,
  Hinweis, keine Zeile, keine Markierung. Das Board schreibt nichts nach Linear; das tut der Board-Chat nach
  Giulianos Enter (Entscheidung E1).
- **Kosten:** Öffnen der Tickets hängt das Terminal einmal um (`pane.attach`, gemessen rund 70 ms auf ruhigem
  Rechner), Schließen einmal zurück; im Raster hängt das Schließen wie bisher alle Kacheln wieder ein. Je
  Auswertung des Fensters: Nachschlagen weniger Dutzend Chats über den Index des Workspace (WM8-101). Die Triage beobachtet allein der Breiten-Modifier
  (`BoardChatColumnFrame`) hängt nicht mehr an der Triage: J/K und der Wechsel zwischen Board und Triage werten
  weder Fenster noch Terminal neu aus, die Breite des Terminals bleibt gleich (bis WM8-124 zeichnete die TUI beim
  Wechsel einmal neu, weil die Triage die Spalte auf 330 pt deckelte).

### Abruf

- Abgerufen wird beim Zeigen sofort, danach alle 120 Sekunden, dazu der Knopf im Kopf. Je Abruf kommen nach dem
  Board die Tickets der gezeigten Ansicht (eine Anfrage, WM8-125); die Reiter selbst höchstens alle zehn Minuten
  (`TicketBoardStore.catalogLifetime`), mit dem Knopf sofort. Ein anderer Reiter holt seine Tickets nur, wenn der
  Zwischenspeicher älter als ein Takt ist. Scheitert das Holen der Ansichten, bleibt das Board stehen und die Zeile
  unter den Reitern nennt den Grund. Fehler der Reiter und Fehler je Ansicht führt der Store getrennt
  (`catalogError`, `viewErrors`); ein gelungener Abruf des einen löscht den Fehler des anderen nicht. Kommt eine
  Ansicht ohne gespeicherten Stand nicht, steht „Ansicht nicht verfügbar“ statt „Ansicht lädt“. Meldet Linear sie
  als nicht gefunden (in Linear gelöscht), holt der nächste Takt die Reiter neu, und das Board springt von selbst auf
  den Standard. Ist das Fenster verdeckt,
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

Mit den Ansichten (WM8-125, gemessen am 16.11.2026 an der Ansicht „Als Nächstes: Giuliano“, 14 Tickets): die Tickets
einer Ansicht eine Anfrage und rund 3.460 Punkte je Takt (die Beschreibung ist dabei); die Reiter eine Anfrage und
rund 790 Punkte, höchstens alle zehn Minuten. Ein sichtbares Board braucht damit je Stunde rund 96 Anfragen (3,8 %
des Budgets) statt 60, und rund 112.000 Punkte (3,7 %).

Linear zählt je Key und Stunde 2.500 Anfragen und 3.000.000 „Complexity“-Punkte. Derselbe Key trägt die Ansicht
und jeden `tickets`-Befehl aller Chats: Ist das Budget weg, steht beides. Gemessen am 14.11.2026 über die
Kopfzeilen der Antworten (`X-Complexity`, `X-RateLimit-Requests-Remaining`, `X-RateLimit-Complexity-Remaining`):

| Team | offene Tickets | Anfragen je Abruf | Punkte vorher | Punkte jetzt |
|---|---|---|---|---|
| WM8 | 74 | 2 | 230 | 140 |
| ABA | 4 | 2 | 230 | 140 |
| PQR | 108 | 3 | 310 | 175 |

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

### Regel je Team

Welcher Status was bedeutet, ist je Team verschieden: In einem Team heißt ein Status, der nach Code-Prüfung
klingt, „Produktentscheidung offen“, in einem anderen wartet „Merge-bereit“ auf die Abnahme. Deshalb steht im
Code kein Statusname. Die Regel liegt in `tickets.json` unter `rulesByTeam` und hat zwei Teile:

| Teil | Bedeutung | ohne Eintrag |
|---|---|---|
| `statusMeanings` | Name des Status → `wartet` (wartet auf mich), `arbeit` (in Arbeit), `fertig` (gebaut, wartet auf andere) | begonnene Status gelten als „in Arbeit“ |
| `waitingLabels` | Labels, mit denen ein mir zugewiesenes Ticket auf mich wartet | jedes mir zugewiesene offene Ticket |

Ein Ticket wartet auf mich, wenn sein Status „wartet“ bedeutet oder es mir zugewiesen ist und (falls die Regel
Labels nennt) eines davon trägt. Wer „ich“ bin, sagt Linear im selben Abruf wie das Board (`viewer { id }`), ohne
zusätzliche Anfrage.

```bash
whisperm8 tickets setup --team WM8 --status "Merge-bereit=wartet" --status "Wartet aufs Ausliefern=fertig" \
                        --waiting-labels Entscheidung,Handtest
whisperm8 tickets setup --team WM8 --status "Merge-bereit="      # Bedeutung wegnehmen
whisperm8 tickets setup --team WM8 --show-rule                    # zeigen
whisperm8 tickets setup --team WM8 --clear-rule                   # löschen
```

`tickets doctor` meldet Statusnamen der Regel, die das Team nicht als offenen Status kennt (Tippfehler machten den
Status sonst still zu einer gewöhnlichen Spalte). Die Regel ändert nur die Einrichtung, nie Linear. Die Ansicht liest sie beim nächsten Aktivieren des Fensters
neu. Später nutzen „Wartet auf mich“ über alle Teams (WM8-115) und der Controller (WM8-91) dieselbe Regel.

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

- **Board:** eine Spalte je Status des Teams, der offene Tickets hat (seit WM8-112; vorher drei Gruppen nach Art
  des Status, die genau die Engpässe versteckten). Reihenfolge: zuerst Status, die nach der Regel des Teams auf
  mich warten, dann Eingang, Begonnenes (darin „fertig“ hinter „in Arbeit“), als Nächstes, Backlog; sonst der
  weiteste Stand links. Leert ein Filter eine Spalte, klappt sie an ihrem Platz schmal ein (150 pt, nur Statusname
  und 0), und die gefüllten rücken zusammen (Giuliano, 15.11.2026); ohne Filter bleibt eine leere Spalte breit. Die
  Regel steht pur in `TicketBoardLanes.isFolded`. Eine Spalte zeigt die ersten acht Karten, darunter „N weitere · in
  der Liste“ (öffnet die Triage mit der ganzen Spalte). Im Kopf der Spalte steht „Wartet auf dich“ (Status bedeutet das,
  Rahmen in Bernstein) oder „N für dich“. Jede Karte zeigt Nummer, Priorität, Fortschritt der Kästchen, Person,
  Titel, Projekt und Meilenstein, Status und Labels; Labels, mit denen ein Ticket auf mich wartet, in Bernstein.
  Die Chat-Zeile steht nur da, wo ein Chat sitzt oder abgegeben hat („Abgegeben von …“). „Kein Agent“ gibt es
  nicht mehr: In Teams, deren Entwickler ohne WhisperM8-Chats arbeiten, stand es auf fast jeder Karte.
- **Ansichten aus Linear als Reiter (WM8-125, Entscheidungen Giuliano 16.11.2026):** Oben im Board stehen die
  gespeicherten Ansichten aus Linear (`customView`), die der Nutzer im Workspace des Projekts als Favoriten hat, in
  deren Reihenfolge. Standard ist die Ansicht „Als Nächstes: <Vorname>“, auch wenn sie kein Favorit ist; ohne sie
  der erste Favorit (`TicketViewCatalog.make`, pur). Ansichten über Vorhaben (etwa „Laufende Vorhaben“) werden kein
  Reiter. Was nicht in die Zeile passt, steht unter „Mehr“ (`TicketViewTabs.split`, pur); der gezeigte Reiter steht
  immer in der Zeile. Gefiltert wird bei Linear: Die Liste zeigt genau die Tickets der Ansicht, auch aus anderen
  Teams des Workspaces. Unter den Reitern eine Zeile, was die Ansicht tut („Aus Linear · nach Status gruppiert ·
  nach Priorität sortiert · 21 Tickets · In Linear öffnen“). Ohne Ansichten (kein Favorit, Fehler) zeigt das Board
  alle offenen Tickets des Teams nach Status. Nach Linear wird nichts geschrieben.
- **Liste (Standard):** Die Liste ist die Ansicht beim Öffnen, das Board bleibt umschaltbar. Sie gruppiert wie die
  Ansicht in Linear (Status, Vorhaben, Priorität, Person, Label; was WhisperM8 nicht kennt, nach Status mit Hinweis),
  Gruppen nach Status in derselben Reihenfolge wie die Spalten des Boards, innerhalb nach Priorität
  (`TicketListGrouping`, pur). Jeder Gruppenkopf zeigt Zahl und „N mit Chat“ und klappt per Klick auf und zu (je
  Ansicht und Fenster, nicht gespeichert). Unteraufgaben stehen eingerückt unter ihrem Eltern-Ticket und gehören zu
  dessen Gruppe; ist das Eltern-Ticket nicht in der Ansicht, steht die Unteraufgabe für sich mit grauem „↳ WM8-91“.
  Hat die Ansicht Unteraufgaben aus, fehlen sie. Zeile wie in Linear plus Chat: Priorität, Nummer, Status, Titel,
  rechts Labels, Projekt, der Chat am Ticket mit Status-Punkt (feste Spalte), Person, Datum der letzten Änderung.
  Wird es eng, fällt zuerst das Datum weg (unter 900 pt), dann das Projekt (780 pt), dann rücken die Labels auf eines
  plus „+N“ (660 pt), dann gehen Labels und Person (560 pt); Titel und Chat bleiben immer
  (`TicketListRowLayout`, pur).
- **Filter:** Die früheren Filterknöpfe („Wartet auf mich“, Agent, Person, Bereich) gibt es nicht mehr; ihre Fragen
  beantworten Ansichten in Linear (Entscheidung Giuliano, 16.11.2026). Die Linear-Ansicht „Wartet auf mich“ zeigt,
  was ihr Filter sagt; die Regel des Teams (unten) färbt weiter Gruppen und Labels.
- **Triage:** Ein Klick auf eine Karte (oder eine Zeile der Liste) öffnet das Ticket groß, wie die Triage in
  Linear, aber mit der Liste daneben (WM8-125). Links dieselbe Liste schmal: aus der Liste mit den Gruppen der
  Ansicht, Zahl, Aufklappen und Chat-Punkt, das offene Ticket markiert; aus dem Board die Spalte („N weitere · in der
  Liste“ öffnet die ganze Spalte). Die Breite der Liste ist am Griff auf ihrer rechten Kante ziehbar (220 bis 480 pt,
  ab Werk 320; Doppelklick zurück), gilt je Projekt und liegt in `ticket-board-chat.json` (`triageListWidth`). Unter
  270 pt fallen dort Nummer und Chat-Name weg. In der Mitte die Eigenschaften als Zeile über dem Titel, dann
  Beschreibung und Verlauf; rechts steht der Board-Chat. Oben links „‹ Liste“ bzw. „‹ Board“ (immer sichtbar),
  voriges/nächstes, „3 von 5“, „In Linear öffnen“ (bricht nicht um) und Aktualisieren. Die Tasten stehen nicht im Kopf, sondern in der Leiste unten, wenn
  sie die Tastatur zeigt: „J K Ticket · ⌘C Link kopieren · esc Board“ (`KeyboardLegend.ticketItems`, WM8-124). Beim Blättern steht in der Mitte nur der Text des gezeigten Tickets. J/K oder ↑↓ wechseln das
  Ticket, Esc führt zurück zum Board auf dieselbe Karte; das wirkt nur, wenn der Fokus nicht in einem Textfeld oder
  Terminal liegt. Die Eigenschaften stehen als eine Zeile über dem Titel (Entscheidung Giuliano, 16.11.2026; seit
  WM8-125 immer): „In Progress · Hoch · Giuliano · 1/4 · Feature · Tickets · Unteraufgabe von WM8-111 · ● Jon [Zum
  Chat]“, dazu „Abgegeben von …“ oder „Früher: …“. Reicht die Breite nicht, bricht die Zeile um; nichts wird
  abgeschnitten. Behält das Ticket keine 400 pt neben der Liste, fällt die Liste weg (`TicketTriageLayout`, pur und
  getestet). J/K und die Liste der Triage gehen nur durch aufgeklappte Gruppen. Knöpfe, die in Linear etwas ändern, gibt es nicht
  (Entscheidung E1 vom 15.11.2026: Das Board schreibt nicht nach Linear; die Triage-Knöpfe kommen mit dem
  Board-Chat, WM8-113). Die Auswahl-Logik ist pur (`TicketBoardSelection`), damit Controller und Tastatur-Insel
  (WM8-91) dieselben Funktionen nutzen: auf dem Board `columns(lanes)`, `start`, `move(key, .up/.down/.left/.right)`
  (überspringt eingeklappte und leere Spalten), in der Triage `open`, `next`, `previous`, `select`, `close` und
  `reconcile` nach einem neuen Abruf. Das ViewModel wendet sie an (`moveOnBoard`, `openSelected`, `openFromLane`,
  `nextInTriage`, `previousInTriage`, `closeTriage`, `handle(TicketBoardKey)`).
- **Link und Liste kopieren:** „Link kopieren“ in der Triage und ⌘C am gewählten Ticket (Karte auf dem Board oder
  Ticket in der Triage) legen zwei Zeilen in die Zwischenablage: `WM8-104 Titel` und darunter die Adresse.
  Markierter Text geht vor: Ist in der Beschreibung etwas markiert oder liegt der Fokus in einem Textfeld oder
  Terminal, kopiert ⌘C wie gewohnt. ⌘⇧C bleibt der Zwischenablage-Verlauf (Entscheidung Giuliano, 15.11.2026).
  „Liste kopieren“ (Knopf im Kopf, in der Triage über der Liste) kopiert die gezeigten Tickets in ihrer
  Reihenfolge, je Ticket eine Zeile mit Adresse: auf dem Board Spalte für Spalte samt dem, was unter „N weitere“
  steht, in der Liste nach ihren Gruppen (Überschrift: Board und Ansicht), in der Triage ihre Liste. Nur Nummer, Titel und Adresse, nie Ticket-Text.
  Steuer- und Formatzeichen im Titel (ESC, Bidi-Umkehr) werden zu Leerzeichen: Eingefügt wird oft in ein Terminal,
  und `ESC[201~` beendete dort ein Bracketed Paste. Auf dem Board zeigt „Link kopiert“ neben „Liste kopieren“, dass
  ⌘C gegriffen hat. Die
  Schreibvorgänge sind beansprucht (`ClipboardInternalWrites.claim`) und landen nicht im Zwischenablage-Verlauf.
- **Verlauf:** die Kommentare, neueste zuerst. Entscheidungen und Abschlüsse (`tickets decide`, `tickets done`)
  stehen mit einer Kopfzeile in Akzent und ◆. Höchstens die neuesten 40 Kommentare, 200 Zeilen je Kommentar,
  60.000 Zeichen Beschreibung und 100.000 Zeichen insgesamt (ein Riesen-Absatz ließe das Layout auf dem Main Thread
  lang laufen); der Rest steht in Linear, die Überschrift sagt dann „neueste 40 von 60“.
- **Zeile „Chats ohne Ticket“:** zugeklappt eine Zeile mit der Zahl der laufenden Chats ohne offenes Ticket und
  dem Supervisor. Aufgeklappt die Chats mit dem Ticket, an dem sie zuletzt saßen; Supervisor-Chats stehen getrennt
  daneben und zählen nicht als Lücke.
- **Schmales Fenster:** Die Spalten werden nicht schmaler als 260 pt, darunter scrollt das Board waagrecht.
  Was die Liste bei wenig Breite weglässt, steht oben unter „Liste“.
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

Tickets und Kommentare stammen auch von anderen Leuten und von Chats. Ein Link bleibt nur anklickbar, wenn er mit
`http` oder `https` ins Web führt; `file:`, `smb:` und Schemata fremder Apps werden zu Text (beim Zerlegen und noch
einmal beim Klick). Bilder werden nicht geladen, sie stehen als „[Bild in Linear]“ da. HTML bleibt Text. Mehr als
400 Zeilen Beschreibung werden nicht gesetzt, der Rest steht in Linear.

So bleibt die Triage schnell:

- **Kommentare erst beim Öffnen:** eine Anfrage je Ticket (`LinearTicketSource.comments`, bis zu 100 Kommentare),
  erst nach 300 ms Ruhe: Wer mit J/K durch zehn Tickets blättert, löst eine Anfrage aus, nicht zehn. Danach liegen
  sie für die Sitzung im Zwischenspeicher des Workspaces (`TicketBoardStore`), solange sich das Ticket nicht
  geändert hat und höchstens zwei Minuten (Chats schreiben Zwischenstände als Kommentar); Aktualisieren in der
  Triage holt sofort neu. Während der Pause nach „Rate limited“ wird nicht gefragt.
- **Ein Text statt einer Ansicht je Absatz:** Titel, Beschreibung und Verlauf werden abseits des Main Threads zu
  einem `NSAttributedString` gebaut (`TicketTextDocument`, Messpunkt `tickets.document`) und in einem einzigen
  `NSTextView` (TextKit 2) gesetzt, wie der Chat-Verlauf. Ein Wechsel per J/K setzt nur diesen Text neu; die
  Liste links ist ein `LazyVStack`, ihre Zeilen schlagen das Ticket über einen Index nach.
- Gemessen am 15.11.2026 im Debug-Build auf einem stark ausgelasteten Rechner (Last über 40): Text setzen und den
  sichtbaren Teil layouten 30 bis 40 ms, kurz wie lang; ein extrem langes Ticket (Beschreibung mit 200 Zeilen,
  40 lange Kommentare, 64.000 Zeichen) baut im Hintergrund in rund 0,4 s. Im Release-Build auf einem ruhigen
  Rechner nachmessen (`TicketTriageTests.testDocumentCostForALongTicket` druckt beide Werte).

## Grenzen

- **Die Absagen schützen vor Versehen, sie sind keine Sicherheitsgrenze.** Wer die Chat-Kennung aus der
  Umgebung nimmt, gilt als Mensch im Terminal. Supervisor ist, wessen Chat-Titel mit „Jarvis“ beginnt; wer
  seinen Supervisor anders nennt, hat für die Kommandozeile keinen. Der Linear-MCP und die Oberfläche von Linear
  setzen jeden Status ohne Rückfrage, und „verworfen“ prüft die Kommandozeile gar nicht. Die Regeln halten die
  Chats ein; das Werkzeug erinnert sie daran.
- **Die Verknüpfung ist für alle im Workspace sichtbar:** Am Ticket steht ein Anhang „Chat: <Titel des Chats>“
  mit Projektname und Zeit. In einem Workspace mit Kollegen lesen alle den Chat-Titel mit. Entschieden am
  14.11.2026: Der Anhang bleibt in jedem Workspace an, es gibt keinen Schalter dafür.
- **Kommentare:** Das Board holt höchstens 100 je Ticket und zeigt die neuesten 40. Ob Linear beim neuen
  Kommentar die Änderungszeit des Tickets setzt, ist nicht geprüft; ein neuer Kommentar erscheint spätestens nach
  „Aktualisieren“ in der Triage oder beim nächsten App-Start.
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
- **⌘C auf dem Board kopiert den Link nur mit gewählter Karte.** Gewählt ist eine Karte, nachdem ihre Triage
  geschlossen wurde oder (mit WM8-91) per Pfeiltasten; ein Klick öffnet immer die Triage.
- **Kein Tastenkürzel für den Umschalter,** und der Umschalter für Chats mit Ctrl+Tab ist über den Tickets
  nicht zu sehen (er wechselt trotzdem).
- **„Zum Chat“ liest die Workspace-Datei auf dem Main Thread.** Das ist der vorhandene Weg der App
  (`WindowRequestCenter.requestSessionFocus`), nicht neu, aber hier ein weiterer Aufrufer.
- **Mit Board-Chat wird die Triage eng:** Die Liste links fällt weg, wenn neben ihr (mindestens 220 pt) keine
  400 pt für das Ticket bleiben (J/K blättert weiter). Dann den Board-Chat schmaler ziehen oder zuklappen.
- **Ansichten nur aus den Favoriten:** Eine Ansicht, die kein Favorit ist, wird kein Reiter (außer „Als Nächstes:
  <Vorname>“). Wer eine neue Ansicht als Reiter will, setzt in Linear den Stern. Neue Favoriten erscheinen nach
  spätestens zehn Minuten oder mit dem Knopf „Aktualisieren“.
- **Gruppierung nur zum Teil:** Zyklus, Meilenstein, Team und Untergruppen aus Linear zeigt die Liste nach Status;
  Sortierung nach etwas anderem als Priorität oder Änderung nach Priorität. Labels sind ohne Linears Farben.
- **Regel des Teams auch für fremde Teams:** Zeigt eine Ansicht Tickets anderer Teams des Workspaces, gilt für sie
  die Regel des Teams, zu dem das Projekt gehört.
- **Board-Chat erkennt den Jarvis nur am Titel,** wie die Kommandozeile. Wer seinen Supervisor anders nennt, wählt
  ihn von Hand (Teil c).

## Tests

`TicketBoardModelTests`, `LinearTicketSourceTests`, `TicketBoardStoreTests`, `TicketConfigTests`, `TicketToolTests`,
`TicketsCLITests`: pure Typen, Quelle gegen feste Antworten, Speicher mit eingespeister Wartefunktion,
Kommandozeile gegen eine Quelle aus Closures. Kein Test braucht Netz, Schlüsselbund oder die App.

Für die Ansicht: `TicketViewTests` (Reiter aus Linear, Standard, Abruf), `TicketListGroupingTests` (Gruppen,
Unteraufgaben, Aufklappen, Ansicht im Abgleich), `TicketBoardPresentationTests` (Spalten, Zählungen, Detail), `TicketTriageTests`
(Auswahl, Tasten, Triage im ViewModel, Kommentare aus Linear, sicherer Text, Kosten), `TicketCopyTests` (Link und
Liste, ⌘C, Prüfung der Regel), `TicketTeamRuleTests`
(Regel je Team, Spalten nach Status, „Wartet auf mich“, Befehl `setup --status`),
`TicketBoardControllerTests` (Zuordnung, Abruf nur bei sichtbarer Ansicht, Leerzustände, Projektwechsel, überholte
Antworten), `TicketOpenTests` (`tickets open`: Nummer und Adresse, Team → Projekt, nichts offen bei Fehlern,
Fenster, Triage einzeln oder in der Liste, Wunsch bis das Board steht), `AgentWindowStoreTicketsModeTests` (Umschalter je Fenster, Rückkehr zu den Chats, Schnappschuss für
den Controller) und `BoardChatRulesTests` (Jarvis wie die CLI, Wahl, Ort je Fenster, Breite, Speicher je Projekt), `BoardChatInputsTests` (Ziel nur sichtbar und vorn, Schutz bei Frage und Freigabe,
Bezug, Texte) und `RecordingCoordinatorDeliveryTests` (Bezug vor dem Diktat, Umlenken nur vom vorderen Programm). Bilder des Board-Chats: `make snapshots ONLY=board-chat`. Was nur von Hand prüfbar ist, steht als Liste im Plan unter „Tests und Abnahme“.
