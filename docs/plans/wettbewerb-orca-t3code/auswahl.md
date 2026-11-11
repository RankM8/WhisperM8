# Auswahl: was für Giuliano zählt und was entschieden ist

**Stand:** 11.11.2026 · **Status:** Auswahl getroffen, Punkte 4 und 8 noch offen, als Erstes kommt `make dev` ohne Chat-Abbruch; kein App-Code geändert
**Gehört zu:** [README.md](README.md) · Grundlage: [kernfeatures.md](kernfeatures.md)

## Blickwinkel

Die Liste in [kernfeatures.md](kernfeatures.md) ist nach dem sortiert, was den Abstand zu Orca und T3 Code verkleinert. Diese Seite sortiert nach dem, was dem tatsächlichen Nutzer hilft: CEO und Entwickler bei DealSupply (ListM8), kein Vollzeit-Entwickler, steuert viele Chats über mehrere Abos, beurteilt Arbeit am Produkt statt am Code und hat ein Team. Beide Konkurrenten bauen für Entwickler, die viele Agents auf ein Repository loslassen. Das ist eine andere Zielgruppe.

Zweites Ziel: WhisperM8 soll als Open-Source-Harness später Leute anziehen, die SaaS bauen und dann DealSupply nutzen.

## Entscheidungen vom 11.11.2026

| Nr. | Feature | Entscheidung |
|---|---|---|
| 1 | Jeder Chat in eigener Umgebung (Arbeitskopie plus Dev-Slot) | **ja** |
| 2 | Leitplanken vor riskanten Schritten (Anhalten vor Merge, Push, Datenbank-Umbau, Deploy) | **nein** |
| 3 | Browser mit Anmerkungen, Playwright zuerst | **ja** |
| 4 | Überblick je Ticket statt je Chat | offen, siehe unten |
| 5 | Chats überleben den Neustart der App | **ja, wenn gut umsetzbar**; Einschätzung unten |
| 6 | Ein Cockpit für alle Abos (Limit erreicht → weiter auf anderem Konto oder mit GPT) | **ja, wenn gut umsetzbar**; Einschätzung unten |
| 7 | PR-Meldungen, die den Chat wecken | **nein** |
| 8 | Änderungen in Klartext | offen, siehe unten |

Aus den früheren Runden bleibt bestehen: Jira mit lokaler Zuweisung und zuschaltbarer Marke ([jira.md](jira.md)), Browser Playwright-first ([browser.md](browser.md)).

## Punkt 4: Überblick je Ticket

Gemeint ist ein Board, dessen Spalten die Status aus Jira sind und dessen Karten Tickets sind. An jeder Karte hängen die Chats, die daran arbeiten, mit ihrem Statuspunkt.

```
 Zu erledigen          In Arbeit                    In Review            Fertig
┌──────────────────┐  ┌──────────────────────────┐ ┌──────────────────┐ ┌──────────────┐
│ LM-412           │  │ LM-398 Export als CSV    │ │ LM-377 Login-Fix │ │ LM-360       │
│ Filter speichern │  │  ● Chat „Export Backend“ │ │  ● Chat fertig   │ │ Preise-Seite │
│  [Chat starten]  │  │  ● Chat „Export UI“      │ │  PR offen        │ │              │
└──────────────────┘  │    wartet auf dich       │ └──────────────────┘ └──────────────┘
                      └──────────────────────────┘
```

- Klick auf einen Chat springt in seinen Tab. „Chat starten“ legt einen Chat mit dem Ticket als Auftrag an.
- Der Unterschied zu Orcas Dashboard: Dort sind die Spalten Zustände von Chats (braucht dich, arbeitet, fertig). Hier sind es Zustände der Arbeit. Die Frage „wie weit ist LM-398“ beantwortet nur diese Sicht.
- Es ist die Ticket-Ansicht aus [jira.md](jira.md), als Board statt als Liste. Kein eigenes Feature daneben.

## Punkt 8: Änderungen in Klartext

Heute endet ein Chat mit „12 Dateien geändert, +340 −80“. Beide Konkurrenten zeigen an der Stelle den Diff, also den geänderten Code Zeile für Zeile. Wer nicht täglich Code liest, hat davon wenig.

Gemeint ist stattdessen eine kurze Karte am Chat, die der Agent am Ende seines Arbeitsschritts selbst schreibt:

> **Neu:** Export-Knopf auf der Kampagnenseite, lädt die Leads als CSV.
> **Geändert:** Die Lead-Tabelle hat eine neue Spalte. Dafür läuft beim nächsten Deploy eine Datenbank-Migration.
> **Vorsicht:** Berührt die Rechteprüfung beim Download. Bitte einmal mit einem Nutzer ohne Admin-Rechte testen.
> **So prüfst du es:** Kampagne öffnen, oben rechts „Export“.

Darunter aufklappbar die Liste der Dateien für alle, die sie sehen wollen. Kosten: ein paar hundert Token je Arbeitsschritt.

## Punkt 5: Chats überleben den Neustart. Ist das gut umsetzbar?

**Ja, in Stufen, aber es ist kein kleines Stück.** Drei Wege wurden geprüft:

| Weg | Wie | Urteil |
|---|---|---|
| A: Claudes eigener Hintergrund-Dienst | Chat läuft als `claude --bg`, der Tab hängt sich per `claude attach` an. Gibt es bei uns schon unter „Advanced“. | **Reicht nicht.** Laufen nur im Hauptkonto (`main`), nicht in den Zusatzkonten; hängen am vollen Hook-Satz; gelten nicht für Codex und Terminals. |
| B: kleiner Halter je Chat | Die App startet statt `claude` ein schlankes Relais. Das echte Terminal hält ein eigener kleiner Prozess, der die App überlebt. Beim nächsten Start hängt sich das Relais wieder an und lässt Claude neu zeichnen. So arbeiten `dtach` und `tmux` seit Jahrzehnten. | **Empfohlen.** Die Terminal-Ansicht der App bleibt, wie sie ist. Mittel bis groß. |
| C: vollwertiger Dienst mit eigenem Protokoll | Wie Orca: ein Dienst für alle Terminals, mit mitlaufendem Terminal-Emulator | **Zu groß als Einstieg.** Orca nennt dort 23 Fehler in sieben Review-Runden. |

Was bei Weg B Arbeit macht (jedes davon betrifft bestehende Funktionen, deshalb vor dem Bau eine Impact-Analyse mit Tests):

- **Status und Ressourcen** hängen heute an der Prozessnummer des Kindprozesses der App. Mit Relais ist das Kind das Relais, nicht Claude. Der Halter muss die echte Nummer melden.
- **Verlauf im Fenster:** Nach dem Wiederanhängen ist nur der aktuelle Bildschirm da. Der Halter braucht einen begrenzten Puffer der letzten Ausgabe zum Nachspielen.
- **Stoppen, Fortsetzen, Kontowechsel, Wiederaufnahme nach Absturz:** Alle gehen heute davon aus, dass ein beendetes Terminal ein beendeter Chat ist.
- **Beenden der App:** Es braucht zwei Wege, „App schließen, Chats laufen weiter“ und „alles beenden“.
- **Update:** Nach einem Update läuft der Halter noch in der alten Version. Das Protokoll zwischen beiden braucht eine Versionsnummer.

Vorgehen: hinter einem Labs-Schalter, ab Werk aus, der alte Weg bleibt als Rückfall. Der Beweis, dass es trägt, ist erst mit einem Build in der App und einem Feldtest erbracht.

## Punkt 6: Ein Cockpit für alle Abos. Ist das gut umsetzbar?

**Ja. Die meisten Teile gibt es schon.**

| Baustein | Stand |
|---|---|
| Verbrauch je Konto (5 Stunden, Woche, je Modell) mit Reset-Zeit | vorhanden (`ClaudeAccountUsageFetcher`) |
| Chat auf ein anderes Konto umziehen, auch laufend, nach dem Turn | vorhanden (`AccountSwitchPlanner`, `AccountSwitchCoordinator`) |
| Prüfung, ob das Zielkonto den Ordner freigegeben hat und welche MCP-Server fehlen | vorhanden (`ClaudeAccountPreflight`) |
| Rückgängig für einen Umzug | vorhanden (Journal) |
| GPT im selben Claude Code | vorhanden (GPT-Backend) |
| **Auslöser:** erkennen, dass das Konto eines Chats am Limit ist oder gleich sein wird | fehlt |
| **Zielwahl:** das Konto mit dem meisten Spielraum vorschlagen | fehlt |
| **Der Hinweis am Chat** mit einem Klick „weiter auf Konto X“ | fehlt |

Zwei Grenzen, die bleiben:

- **Der Wechsel auf GPT bleibt ein ausdrückliches Angebot, kein Automatismus.** Die Regel der App lautet, dass Claude Code entscheidet, welches Modell ein Claude-Chat nutzt. Ein anderes Modell mitten im Chat ändert auch das Verhalten, das soll niemand unbemerkt bekommen.
- **Hat das Zielkonto den Ordner nie freigegeben, wird nicht automatisch gewechselt.** Sonst landet der Neustart in Claudes Freigabe-Dialog.

Offene Frage: Soll der Kontowechsel bei erreichtem Limit **nachfragen** (ein Klick am Chat) oder **von selbst** passieren? Empfehlung: zuerst nachfragen, „immer automatisch“ als Schalter danach.

Aufwand: mittel. Entwurf des Hinweises zuerst im HTML-Zwilling.

### Nachtrag vom 11.11.2026: `make dev` zuerst

Giuliano will Punkt 5 zuerst, und zwar für den Fall, der am häufigsten stört: `make dev` beendet alle laufenden Chats. Die Prüfung im Code ergab einen kleineren Weg als den Halter je Chat: Die App gibt ihre Terminal-Leitungen vor dem Beenden an einen Aufbewahrer ab und holt sie nach dem Start zurück. Der Normalbetrieb bleibt unverändert, jeder Fehler fällt auf den heutigen Stand zurück, und die Teile lassen sich später für Weg B wiederverwenden. Plan mit Ablauf, betroffenen Stellen und den drei offenen Belegen: [`../neustart-ohne-chatverlust.md`](../neustart-ohne-chatverlust.md).

## Reihenfolge nach dieser Auswahl

| Schritt | Inhalt | Warum hier |
|---|---|---|
| 1 | Punkt 5 als Übergabe bei `make dev`, beginnend mit dem Vorversuch | Wunsch vom 11.11.2026; stört täglich |
| 2 | Punkt 6, Cockpit für alle Abos | schnell spürbar, baut auf Vorhandenem auf |
| 3 | Punkt 1, eigene Umgebung je Chat, mit dem Start-Dialog | Voraussetzung für sicheres paralleles Arbeiten und für „Chat aus Ticket“ |
| 4 | Vorversuch zu Punkt 3, dann Browser | der Vorversuch entscheidet den Weg |
| 5 | Jira, je nach Antwort zu Punkt 4 als Board | braucht den Start-Dialog aus Schritt 3 |
| später | Punkt 5, Weg B (auch Abstürze abdecken) | baut auf der Übergabe auf |

## Zum Open-Source-Trichter

- **Nische:** „Die Harness für Gründer, die ihr SaaS mit Claude Code bauen und keine Vollzeit-Entwickler sind.“ Gegen Orca als allgemeines Entwickler-Werkzeug anzutreten ist aussichtslos; diese Nische besetzt keiner.
- **Brücke zu DealSupply:** Wer mit der Harness ein Produkt baut, braucht danach Kunden. Die Outreach-Plugins, mit denen sich Leads und Kampagnen aus dem Chat steuern lassen, sind der Weg von der Harness zum Produkt. Ohne eingebaute Brücke bleibt die Harness ein Gratis-Werkzeug ohne Weg zu DealSupply.
- **Einstieg vor Features:** in fünf Minuten installiert, englische Startseite, kurzes Video.
- **Zwei Schwächen:** Der Name WhisperM8 klingt nach Diktat, nicht nach Harness. Und nur macOS halbiert das Publikum, was für Gründer eher verkraftbar ist als für Entwickler-Teams.
- **Leitplanken (Punkt 2) wurden abgelehnt.** Für die Nische „keine Vollzeit-Entwickler“ wären sie ein Argument gewesen. Das lässt sich später neu bewerten, wenn fremde Nutzer dazukommen.
