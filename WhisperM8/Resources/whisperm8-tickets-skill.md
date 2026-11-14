---
name: tickets
description: Tickets aus Linear und die Chats, die daran arbeiten, über die WhisperM8-CLI (`whisperm8 tickets …`). Nutzen bei "an welchem Ticket arbeite ich", "häng dich ans Ticket", "Ticket auf Merge-bereit", "Ticket ist fertig", "Stand am Ticket eintragen", "welche Tickets haben keinen Agent", "wer arbeitet woran", "Ticket-Board", "was ist mir zugewiesen", "leg ein Ticket an", "Ticket zuweisen", sobald eine Ticket-Nummer wie ABC-12 fällt oder ein Chat eine Arbeit beginnt oder abschließt, die zu einem Ticket gehört. Für den Supervisor: Board lesen, Lücken schließen, Status führen. NICHT für Zyklen, Projekte, Dokumente oder Releases in Linear (dafür der Linear-MCP) und nicht für Jira.
---

# Tickets (`whisperm8:tickets`)

`whisperm8 tickets` verbindet zwei Dinge, die sonst nichts voneinander wissen: die Tickets im
Ticket-Werkzeug (Linear) und die Chats in WhisperM8. Ein Chat hängt sich an sein Ticket; danach
sieht der Nutzer am Board, wer woran sitzt, welche Chats laufen und welche Tickets niemanden haben.

Jeder Befehl kennt `--json`; schreibende Befehle antworten dann mit `{"ok": true, "key": …, "message": …}`.
Hilfe: `whisperm8 tickets --help`.

## Für jeden Chat, der an einem Ticket arbeitet

| Wann | Befehl |
|---|---|
| Arbeit beginnt | `whisperm8 tickets link ABC-12` |
| Etwas wartet auf den Nutzer | `whisperm8 tickets assign ABC-12 me` und das Label, das das Projekt dafür führt: `whisperm8 tickets label ABC-12 --add <Label>` |
| Zwischenstand, der zählt | `whisperm8 tickets note ABC-12 "Branch steht, Review läuft."` |
| Ein Punkt unter „Fertig, wenn“ ist erledigt | `whisperm8 tickets check ABC-12 2` (Nummer oder ein Stück des Textes; ohne Verweis zeigt der Befehl die Kästchen) |
| Der Nutzer hat etwas entschieden | `whisperm8 tickets decide ABC-12 --question "…" --option "A" --option "B" --chosen "A"` |
| Gebaut und geprüft, Branch wartet auf den Merge | `whisperm8 tickets done ABC-12 --built "was gebaut wurde" --commit abc1234 --not "was nicht dazugehört" --test "Schritt für den Handtest" --status "Merge-bereit"` |
| Woran hänge ich | `whisperm8 tickets mine` |
| Falsch verknüpft | `whisperm8 tickets unlink ABC-12` |

- `link` setzt ein Ticket, das noch nicht in Arbeit ist, auf „In Progress“. Mit `--no-status` bleibt der Status.
- `note` ersetzt die erste Zeile des Tickets (`**Stand TT.MM.JJJJ:** …`). Das ist der Ort für den Stand, nicht
  eine Kette von Kommentaren. `comment` ist für Dinge, die als Verlauf stehen bleiben sollen.
- **Abgeben heißt zusammenfassen.** `done` verlangt `--built`: ein, zwei Sätze, was gebaut wurde, so dass es
  jemand ohne den Chat-Verlauf versteht. Dazu nach Bedarf `--commit`, `--not` (was bewusst nicht dazugehört),
  `--test` je Schritt für den Handtest (mehrfach; sie stehen dann als Kästchen am Ticket) und `--image bild.png`.
  Ein hochgeladenes Bild sieht jeder im Workspace: keine Bildschirmfotos mit Schlüsseln, Kundendaten oder
  fremden Chats.
  Der Abschluss steht als Kommentar am Ticket. Arbeit ohne Bau (Analyse, Entscheidung): `--no-summary`.
- **Entscheidungen** hält `decide` fest, in festem Aufbau: Frage, Möglichkeiten (mindestens zwei), Gewählt, wer
  entschieden hat, wer sie festgehalten hat, wann. Festgehalten wird nur, was der Nutzer wirklich entschieden
  hat, mit seinen Möglichkeiten und in seinen Worten; eine eigene Empfehlung ist keine Entscheidung. `--by` ist
  aus einem Chat Pflicht: der Name dessen, der entschieden hat. War es deine eigene Entscheidung (etwa eine
  technische Wahl im Rahmen des Auftrags), steht dort dein Rufname, nicht der des Nutzers. Dein Rufname steht
  ohnehin als „Festgehalten von“ dabei.
- **Kästchen** hakst du ab, sobald ein Punkt wirklich erledigt und geprüft ist, nicht „so gut wie“. Der Befehl
  ändert nur die genannten Kästchen und arbeitet nur auf der Beschreibung: Die Handtest-Kästchen im
  Abschluss-Kommentar erreicht er nicht, die hakt ab, wer testet.
- Text-Argumente nehmen Text, `-` für stdin oder `@datei`. Beginnt der Text selbst mit `-` oder `@`, gehört er
  hinter `--`: `whisperm8 tickets comment ABC-12 -- "@alle bitte prüfen"`. Tickets sind Markdown.
- **Was du schreibst, geht an das Ticket-System und ist für alle dort lesbar.** Keine Schlüssel, Tokens oder
  Passwörter, keine Kundeninhalte, keine rohen Logs oder Chat-Verläufe. Bei `@datei` vorher wissen, was in der
  Datei steht. Mehr als 64 KB nimmt die Kommandozeile nicht an.
- Gibt es zu einer Arbeit kein Ticket: dem Supervisor melden. Chats legen keine Tickets an.

## Wer welchen Status setzt

| Ereignis | Wer | Status |
|---|---|---|
| Chat beginnt | der Chat, über `link` | In Progress (automatisch) |
| Chat ist fertig, Branch steht | der Chat, über `done --built … --status` | Merge-bereit |
| Branch ist in `main` | der Supervisor | Done, oder ein Zwischenstatus, wenn das Projekt einen für „gemergt, noch nicht ausgeliefert“ führt |
| Arbeit ohne Merge erledigt (Analyse, Entscheidung) | der Supervisor | Done |
| Ticket überholt | der Supervisor, nach Ja des Nutzers | Canceled |

„Fertig gebaut“ ist nicht „erledigt“. Ein Chat setzt nie selbst auf einen „erledigt“-Status. Die Kommandozeile
erinnert mit einer Absage daran; eine Sperre ist das nicht, die Regel hältst du ein. `--force` nur, wenn der
Nutzer es ausdrücklich von diesem Chat verlangt. Dasselbe gilt für „verworfen“: nur der Supervisor, nach dem Ja
des Nutzers.

Welches Team, welche Status-Namen und welche Labels gelten, steht in der Doku des Projekts, nicht hier. Die
Namen in dieser Datei („Merge-bereit“, „Done“, `ABC-12`) sind Beispiele; `whisperm8 tickets show <Ticket> --json`
nennt unter `statuses` die echten Status des Teams.

## Für den Supervisor

```
whisperm8 tickets board                       # wer sitzt woran, was hat niemanden
whisperm8 tickets list --no-agent             # in Arbeit oder bereit, aber kein Chat
whisperm8 tickets list --unassigned           # niemandem zugewiesen
whisperm8 tickets list --mine                 # liegt beim Nutzer
whisperm8 tickets list --status "Merge-bereit"
```

- **Board lesen:** Unter „Laufende Chats ohne offenes Ticket“ steht je Chat, woran er zuletzt saß:
  - „zuletzt an ABC-12 (Merge-bereit)“: Er hat abgegeben und wartet auf deinen Merge. Offen lassen, bis gemergt ist.
  - „zuletzt an ABC-29 (Done)“: Die Arbeit ist erledigt. Chat schließen. Dasselbe gilt für einen Status nach dem
    Merge („wartet aufs Ausliefern“): Der Chat hat nichts mehr zu tun.
  - „noch nie verknüpft“: Er arbeitet ohne Ticket. Ticket anlegen und verknüpfen, oder schließen.
  Supervisor-Chats (Titel beginnt mit „Jarvis“) stehen getrennt und brauchen kein Ticket.
- **Abgegebene Tickets:** Ein Ticket, das ein Chat mit `done` abgegeben hat und das noch in Arbeit steht (etwa
  „Merge-bereit“), zeigt „abgegeben von <Chat>“ und zählt nicht zu `--no-agent`. Es wartet auf dich.
- **Für einen anderen Chat handeln:** `--chat <Anfang der Chat-ID>` bei `link`, `done`, `unlink`, `mine`
  (IDs aus `whisperm8 chats list`).
- **Nach dem Merge:** `whisperm8 tickets status ABC-12 Done`, dann den Chat schließen.
- **Neue Tickets** nur nach dem Ja des Nutzers:
  `whisperm8 tickets new "Titel" --description @text.md --project "Vorhaben" --priority high --labels <Label>`.
- **Zuweisen:** `whisperm8 tickets assign ABC-12 me` (der Nutzer), `none` oder ein Namensteil.
- Chats nach ihrem Ticket benennen (`ABC-12 Ole · Thema: Aufgabe`); das Board zeigt daraus den Rufnamen „Ole“.

## Aufbau eines Tickets

```
**Stand 14.11.2026:** ein Satz zum Stand.

## Ziel
Wer will was und warum. Nicht, wie es gebaut wird.

## Fertig, wenn
- [ ] ein prüfbarer Punkt je Kästchen
- [ ] so geschrieben, dass man „ja“ oder „nein“ sagen kann

## Hinweise
Branch, Plan-Datei, Abhängigkeiten.
```

Keine Hinweise auf KI-Beteiligung in Tickets oder Kommentaren.

## Grenzen und Fehler

- Der Zustand der Chats (arbeitet, ruht, wartet auf dich) kommt aus der laufenden App. Ohne App gehen alle
  Befehle, das Board zeigt dann „Zustand unbekannt“ und keine Chats ohne Ticket.
- Das Team ergibt sich aus dem Projekt des aktuellen Ordners (auch in Arbeitsordnern darunter), sonst `--team ABC`.
- **Mehrere Workspaces** (mehrere Firmen): Das Team steckt in der Ticket-Nummer, der Workspace folgt aus dem Team.
  Du schreibst nur in den Workspace deines Projekts, egal in welchem Ordner du gerade stehst; Tickets eines
  anderen Workspaces kannst du lesen (`show`, `list --team`), aber nicht ändern und dich nicht daran hängen. Die
  Kommandozeile sagt dann ab (Exit 4). `--other-workspace` nur, wenn der Nutzer das Schreiben nach drüben
  ausdrücklich verlangt. Gehört eine Arbeit ins andere Projekt: dem Supervisor melden, nicht selbst umhängen.
  Die Absage fängt Versehen ab; dieselbe Regel gilt auch dort, wo kein Werkzeug sie prüft (MCP, Browser).
- Die Verknüpfung steht am Ticket als Anhang mit dem Titel deines Chats. Jeder im Workspace sieht ihn. Ein
  Chat-Titel enthält deshalb nichts, was dort nicht stehen soll.
- `whisperm8 tickets doctor` prüft Zugang, Zuordnung und App, und nennt als Hinweise („ACHTE“), was Ordnung
  braucht: Tickets ohne Projekt, eingeplant ohne „Fertig, wenn“, in Arbeit ohne Chat, seit Wochen unberührt, und
  Abweichungen zwischen der Tabelle der Bereiche in der Doku des Projekts und dem Ticket-Werkzeug. Exit-Codes: 0 ok, 1 Aufruf falsch, 3 nicht
  gefunden, 4 mehrdeutig, 5 Linear nicht eingerichtet, nicht erreichbar oder lehnt ab.
- Einrichtung (einmalig, macht der Nutzer oder der Supervisor mit ihm): `pbpaste | whisperm8 tickets setup --key-stdin`
  (je Workspace ein Key, der Workspace ergibt sich aus dem Key) und `whisperm8 tickets setup --team ABC --project <Ordner>`.
  Den Key nie ausgeben, nie in eine Datei, nie in den Chat.
- Meldet `doctor` ein Team, das es in Linear nicht mehr gibt (gelöscht oder umbenannt), nennt die Zeile den Befehl
  dazu: `whisperm8 tickets setup --remove-team ABC` nimmt es aus der Einrichtung. Hängt noch ein Ordner daran,
  bricht der Befehl ab und nennt ihn; das entscheidet der Nutzer, nicht du (`--with-projects` löst den Ordner mit).
- Was die CLI nicht kann (Zyklen, Vorhaben anlegen, Dokumente, Meilensteine, Releases): der Linear-MCP. Bei mehreren
  Workspaces hat jeder seinen eigenen Server; vor dem Schreiben prüfen, welcher zum Projekt gehört.
- Die Verknüpfung ist ein Anhang am Ticket (`whisperm8://chat/<ID>`). Nicht von Hand ändern und nicht über den
  MCP anlegen: Board und Ansichten in Linear lesen genau dieses Format.
