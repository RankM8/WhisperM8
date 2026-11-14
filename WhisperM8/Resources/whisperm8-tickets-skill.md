---
name: tickets
description: Tickets aus Linear und die Chats, die daran arbeiten, über die WhisperM8-CLI (`whisperm8 tickets …`). Nutzen bei "an welchem Ticket arbeite ich", "häng dich ans Ticket", "Ticket auf Merge-bereit", "Ticket ist fertig", "Stand am Ticket eintragen", "welche Tickets haben keinen Agent", "wer arbeitet woran", "Ticket-Board", "was ist mir zugewiesen", "leg ein Ticket an", "Ticket zuweisen", sobald eine Ticket-Nummer wie WM8-12 fällt oder ein Chat eine Arbeit beginnt oder abschließt, die zu einem Ticket gehört. Für den Supervisor: Board lesen, Lücken schließen, Status führen. NICHT für Zyklen, Projekte, Dokumente oder Releases in Linear (dafür der Linear-MCP) und nicht für Jira.
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
| Arbeit beginnt | `whisperm8 tickets link WM8-12` |
| Etwas wartet auf den Nutzer | `whisperm8 tickets label WM8-12 --add Handtest` (oder `Entscheidung`) und `whisperm8 tickets assign WM8-12 me` |
| Zwischenstand, der zählt | `whisperm8 tickets note WM8-12 "Branch steht, Review läuft."` |
| Gebaut und geprüft, Branch wartet auf den Merge | `whisperm8 tickets done WM8-12 --status "Merge-bereit" --note "Branch feat/x, Commit abc1234, Suite grün."` |
| Woran hänge ich | `whisperm8 tickets mine` |
| Falsch verknüpft | `whisperm8 tickets unlink WM8-12` |

- `link` setzt ein Ticket, das noch nicht in Arbeit ist, auf „In Progress“. Mit `--no-status` bleibt der Status.
- `note` ersetzt die erste Zeile des Tickets (`**Stand TT.MM.JJJJ:** …`). Das ist der Ort für den Stand, nicht
  eine Kette von Kommentaren. `comment` ist für Dinge, die als Verlauf stehen bleiben sollen.
- Text-Argumente nehmen Text, `-` für stdin oder `@datei`. Beginnt der Text selbst mit `-` oder `@`, gehört er
  hinter `--`: `whisperm8 tickets comment WM8-12 -- "@Giuliano bitte prüfen"`. Tickets sind Markdown.
- Gibt es zu einer Arbeit kein Ticket: dem Supervisor melden. Chats legen keine Tickets an.

## Wer welchen Status setzt

| Ereignis | Wer | Status |
|---|---|---|
| Chat beginnt | der Chat, über `link` | In Progress (automatisch) |
| Chat ist fertig, Branch steht | der Chat, über `done --status` | Merge-bereit |
| Branch ist in `main` | der Supervisor | Done |
| Arbeit ohne Merge erledigt (Analyse, Entscheidung) | der Supervisor | Done |
| Ticket überholt | der Supervisor, nach Ja des Nutzers | Canceled |

„Fertig gebaut“ ist nicht „erledigt“. Ein Chat setzt nie selbst auf „Done“.

## Für den Supervisor

```
whisperm8 tickets board                       # wer sitzt woran, was hat niemanden
whisperm8 tickets list --no-agent             # in Arbeit oder bereit, aber kein Chat
whisperm8 tickets list --unassigned           # niemandem zugewiesen
whisperm8 tickets list --mine                 # liegt beim Nutzer
whisperm8 tickets list --status "Merge-bereit"
```

- **Board lesen:** Unter „Laufende Chats ohne offenes Ticket“ steht je Chat, woran er zuletzt saß:
  - „zuletzt an WM8-12 (Merge-bereit)“: Er hat abgegeben und wartet auf deinen Merge. Offen lassen, bis gemergt ist.
  - „zuletzt an WM8-29 (Done)“: Die Arbeit ist erledigt. Chat schließen.
  - „noch nie verknüpft“: Er arbeitet ohne Ticket. Ticket anlegen und verknüpfen, oder schließen.
  Supervisor-Chats (Titel beginnt mit „Jarvis“) stehen getrennt und brauchen kein Ticket.
- **Abgegebene Tickets:** Ein Ticket, das ein Chat mit `done` abgegeben hat und das noch in Arbeit steht (etwa
  „Merge-bereit“), zeigt „abgegeben von <Chat>“ und zählt nicht zu `--no-agent`. Es wartet auf dich.
- **Für einen anderen Chat handeln:** `--chat <Anfang der Chat-ID>` bei `link`, `done`, `unlink`, `mine`
  (IDs aus `whisperm8 chats list`).
- **Nach dem Merge:** `whisperm8 tickets status WM8-12 Done`, dann den Chat schließen.
- **Neue Tickets** nur nach dem Ja des Nutzers:
  `whisperm8 tickets new "Titel" --description @text.md --project "Vorhaben" --priority high --labels Handtest`.
- **Zuweisen:** `whisperm8 tickets assign WM8-12 me` (der Nutzer), `none` oder ein Namensteil.
- Chats nach ihrem Ticket benennen (`WM8-12 Ole · Thema: Aufgabe`), dann stimmt die Zuordnung auch im Kopf.

## Aufbau eines Tickets

```
**Stand 14.11.2026:** ein Satz zum Stand.

## Ziel
Wer will was und warum. Nicht, wie es gebaut wird.

## Fertig, wenn
- prüfbare Punkte

## Hinweise
Branch, Plan-Datei, Abhängigkeiten.
```

Keine Hinweise auf KI-Beteiligung in Tickets oder Kommentaren.

## Grenzen und Fehler

- Der Zustand der Chats (arbeitet, ruht, wartet auf dich) kommt aus der laufenden App. Ohne App gehen alle
  Befehle, das Board zeigt dann „Zustand unbekannt“ und keine Chats ohne Ticket.
- Das Team ergibt sich aus dem Projekt des aktuellen Ordners (auch in Arbeitsordnern darunter), sonst `--team WM8`.
- `whisperm8 tickets doctor` prüft Zugang, Zuordnung und App. Exit-Codes: 0 ok, 1 Aufruf falsch, 3 nicht
  gefunden, 4 mehrdeutig, 5 Linear nicht eingerichtet, nicht erreichbar oder lehnt ab.
- Einrichtung (einmalig, macht der Nutzer oder der Supervisor mit ihm): `pbpaste | whisperm8 tickets setup --key-stdin`
  und `whisperm8 tickets setup --project <Ordner> --team WM8`. Den Key nie ausgeben, nie in eine Datei, nie in den Chat.
- Was die CLI nicht kann (Zyklen, Vorhaben anlegen, Dokumente, Meilensteine, Releases): der Linear-MCP, Server `linear`.
- Die Verknüpfung ist ein Anhang am Ticket (`whisperm8://chat/<ID>`). Nicht von Hand ändern und nicht über den
  MCP anlegen: Board und Ansichten in Linear lesen genau dieses Format.
