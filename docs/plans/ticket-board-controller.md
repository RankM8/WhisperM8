---
status: Entwurf zur Abnahme (15.11.2026); Bau nicht freigegeben
stand: 2026-11-15
feature: Ticket-Board mit Controller und Tastatur öffnen und bedienen
ticket: WM8-91
branch: design/WM8-91-board-controller
---

# Ticket-Board mit dem Controller: Belegung

Ticket `WM8-91`. Giuliano am 15.11.2026: „Ich glaube, ich habe noch keine Controller-Einstellungen für das
Board für ein Projekt, oder gibt es da schon irgendwelche Kombinationen mit LT, R1 und R2?“ und danach: „Lege
die Tickets an, um auch das Board mit dem Controller steuern zu können und auch öffnen zu können, das muss
natürlich alles durchgedacht werden.“

Klick-Entwurf: [`../design/ticket-board-controller.html`](../design/ticket-board-controller.html). Grundlagen:
die heutige Belegung in [`../features/controller.md`](../features/controller.md), die Insel per Tastatur in
[`../features/insel-tastatur.md`](../features/insel-tastatur.md) und das abgenommene Board für den Alltag in
[`ticket-board-alltag.md`](ticket-board-alltag.md) (Triage wie in Linear, Spalten nach Status, Board-Chat rechts).
Entworfen ist für dieses Board, nicht für das heutige. Gebaut wird nach Paket 1 des Boards (WM8-112).

## Kurz

1. **Das Board wird ein Ort wie ein Chat oder ein Workspace.** Dann gilt, was Giuliano schon kann: L2 halten
   zeigt „Wohin“, dort gibt es einen dritten Reiter „Tickets“; L2 getippt springt zwischen Board und dem Chat
   davor hin und her. Keine neue Taste, kein neuer Weg.
2. **Im Board gilt die Regel, die es heute schon gibt:** Wo kein Terminal den Fokus hat, bewegen Stick und
   Steuerkreuz die Auswahl. Kreuz geht eine Stufe tiefer (Karte → Ticket groß), Kreis eine zurück.
3. **L1 und R1 blättern durch das, woran du gerade arbeitest:** in den Chats durch Chats, im Board durch
   Tickets. Das bleibt so, auch wenn später der Board-Chat den Fokus hat; so geht die Triage vom Sofa aus, ohne
   den Chat mit Jarvis zu verlassen.
4. **Sicher bleibt es so:** Hinter den Tickets kommt in keinem verdeckten Chat etwas an. Nur der sichtbare
   Board-Chat (WM8-113) bekommt später Diktat und Eingaben. Kein Knopf und keine Taste schreibt nach Linear.
5. **Tastatur mit derselben Logik:** ⌥Tab bekommt denselben Reiter „Tickets“, im Board gehen Pfeile, Return,
   Esc und die Kürzel, die L1/R1 schon heute auf der Tastatur haben (⌘⌥← / ⌘⌥→).

## Heute

- Zeigt ein Fenster die Tickets, meldet es dem Controller keinen gewählten Chat (`withChatsHidden`). Der
  Controller landet damit im Zusammenhang „Liste“: Der Stick bewegt die Markierung in der Seitenleiste, Kreuz
  öffnet einen Chat und verlässt die Tickets, L1/R1 schalten den Filter der Seitenleiste. Im Board selbst
  bewegt sich nichts.
- Es gibt keinen Weg zum Board außer dem Ticket-Knopf in der Titelzone, auch nicht per Tastatur. Zurück geht es
  mit demselben Knopf, ⌘W oder jeder Auswahl eines Chats.
- L2 getippt kennt nur Chats und Workspaces als Orte. Wer aus dem Board in einen Chat springt, kommt mit L2
  nicht ins Board zurück.

## Grundregeln

Fünf Sätze, die Giuliano wissen muss. Alles Weitere folgt daraus.

1. **Das Board ist ein Ort.** Hin über „Wohin“ (L2 halten, Reiter „Tickets“), zurück mit L2 getippt.
2. **Ohne Terminal im Fokus bewegen Stick und Steuerkreuz.** Mit Terminal im Fokus (später der Board-Chat)
   gehen die Pfeile hinein, wie in jedem Chat.
3. **Kreuz tiefer, Kreis zurück.** Board → Ticket groß → (Chat-Zeile am Ticket) → Chat.
4. **L1/R1 = voriges/nächstes Ticket.** Wie voriger/nächster Chat in den Chats.
5. **R1 rechts und R2 wirken immer auf den Chat, den du siehst.** Im Board ist das der Board-Chat; gibt es
   keinen, tun sie nichts.

## Belegung im Ticket-Modus

Die Spalte „Paket“ sagt, wann es kommt (siehe Paketschnitt). „mit 113“ heißt: kommt mit dem Board-Chat, die
Taste ist reserviert und tut bis dahin nichts. Xbox: A = Kreuz, B = Kreis, X = Viereck, Y = Dreieck, LB/RB =
L1/R1, LT/RT = L2/R2, LS/RS = L3/R3, Menu = Options, View = Create.

### Weg zum Board und zurück

| Nr. | Taste | Wirkung | Paket |
|---|---|---|---|
| 1 | L2 halten | „Wohin“ wie heute, mit drittem Reiter **„Tickets“** rechts von „Workspaces & Projekte“. Start-Reiter wie heute (Einzelansicht „Chats“, Raster „Workspaces & Projekte“); im Ticket-Modus „Tickets“ | 1 |
| 2 | L2 halten, ◀ ▶ | Reiter wechseln, jetzt in Schritten: Chats ↔ Workspaces & Projekte ↔ Tickets, ohne Umlauf. Aus „Chats“ sind es zwei Schritte nach rechts, aus dem Raster einer | 1 |
| 3 | Reiter „Tickets“ | je eingerichtetem Team mit Projekt eine Zeile: Kürzel, Projektname, Zahl „wartet auf dich“. Das Team des aktuellen Projekts trägt „hier“ und ist markiert, das zuletzt gezeigte Board „vorher“. Später (WM8-115) oben „Wartet auf mich · alle Teams“ | 1 |
| 4 | Loslassen, Kreuz | öffnet das markierte Board. Anders als in den anderen Reitern zählt „hier“ als Ziel, solange du nicht im Board bist: L2 halten, ▶ ▶, loslassen genügt | 1 |
| 5 | L2 halten + R2 | im Reiter „Tickets“: hin und diktieren an den Board-Chat; ohne Board-Chat „geht nicht“ | mit 113 |
| 6 | L2 getippt | zurück an den vorigen Ort, auch vom Board in den Chat und vom Chat ins Board. Das Board kommt so wieder, wie du es verlassen hast (Board oder Ticket groß, dieselbe Auswahl). Die Leiste nennt das Ziel („Zurück: Tickets WM8“) | 1 |
| 7 | Options | im Chat: Gruppe „Steuerung“ bekommt „Ticket-Board WM8“ (Board des Projekts dieses Chats). Im Board: „Zu den Chats“ | 1 |

**Welches Board:** das Team, zu dem das Projekt des aktuellen Chats gehört (`tickets.json`); im Raster das
Projekt der fokussierten Kachel. Hat das Projekt kein Team, steht im Reiter „whisperm8 hat kein Team ·
Einstellungen › Tickets“, die Markierung beginnt auf der ersten Zeile, Loslassen ohne Bewegung tut nichts.
**Anderes Team:** im Reiter mit ▲ ▼ wählen. **Start-Auswahl im Board:** die Karte des Tickets, an dem der
Chat hängt, aus dem du kommst; sonst die erste Karte der ersten Spalte, in der etwas auf dich wartet; sonst die
erste Karte.

### Im Board (Spalten)

| Nr. | Taste | Wirkung | Paket |
|---|---|---|---|
| 8 | Linker Stick, Steuerkreuz | ▲ ▼ Karte, ◀ ▶ Spalte (Höhe bleibt ungefähr gleich), mit Wiederholung beim Halten. Unter der letzten sichtbaren Karte steht „N weitere“ als eigene Zeile. ◀ aus der ersten Spalte: in die Seitenleiste wie heute aus dem Inhalt | 2 |
| 9 | Kreuz | Ticket groß (Triage), Liste = diese Spalte; auf „N weitere“ die ganze Spalte | 2 |
| 10 | Kreis | nichts, mit leiser Rückmeldung; die Leiste nennt „L2 Zurück“. Halten ebenso | 2 |
| 11 | Viereck | Link kopieren: zwei Zeilen, „WM8-112 Titel“ und darunter die Adresse. Kurz bestätigt in der Leiste. Halten tut nichts | 2 |
| 12 | Dreieck | → Jarvis: legt Nummer, Titel und Link ins Eingabefeld des Board-Chats, ohne Absenden | mit 113 |
| 13 | L1 / R1 tippen | voriges / nächstes Ticket in Lesereihenfolge (die Spalte hinunter, dann oben in der nächsten) | 2 |
| 14 | Rechter Stick | blättert die Spalte mit der Auswahl | 2 |
| 15 | L3 | In Linear öffnen (Browser) | 2 |
| 16 | R3 tippen | Aktualisieren, wie ↻ im Kopf. Verfällt, wenn der rechte Stick dabei scrollt | 2 |
| 17 | Options | Menü-Karte an der Karte, siehe unten | 2 |
| 18 | R2 | Diktat an den Board-Chat. Ohne Board-Chat „geht nicht“ (siehe E4) | mit 113 |
| 19 | R1 halten | Rauten wie im Chat: links die App-Raute (Limits, Mitteilungen, Wach bleiben, Zwischenablage) unverändert, rechts die Chat-Raute des Board-Chats; ohne Board-Chat ausgegraut („kein Board-Chat“) | 1 (App), mit 113 (Chat) |
| 20 | L1 halten | Schreiben im Board-Chat; ohne Board-Chat ausgegraut | mit 113 |
| 21 | Create, Touchpad, L1 + R1 | wie überall: Neuer Chat (Projekt des Boards vorgewählt), Zwischenablage-Verlauf, Pause | 1 |
| 22 | Paddles | Sprünge (nächster wartender Chat, Antworten, zurück) wie überall und verlassen das Board; Eingaben in einen Chat (Jetzt senden, Modus, `/tasks`, `/workflows`) nur bei Fokus im Board-Chat, sonst „geht nicht“ | 2 |

### Ticket groß (Triage)

| Nr. | Taste | Wirkung | Paket |
|---|---|---|---|
| 23 | Linker Stick, Steuerkreuz ▲ ▼ | Ticket in der Liste links; rechts steht sofort dieses Ticket (wie in Linear, kein eigenes Öffnen) | 2 |
| 24 | ▶ | in „Chats am Ticket“ (Eigenschaften rechts), nur wenn das Ticket Chats hat; noch mal ▶ in den Board-Chat (mit 113). ◀ zurück, aus der Liste in die Seitenleiste | 2 |
| 25 | Kreuz | in der Liste nichts; auf einer Chat-Zeile **Zum Chat** (siehe E3) | 2 |
| 26 | Kreis | zurück zum Board, Auswahl auf derselben Karte. Auf einer Chat-Zeile zurück in die Liste | 2 |
| 27 | Rechter Stick | blättert Beschreibung und Verlauf (Kommentare, Entscheidungen, Abschluss) | 2 |
| 28 | L1 / R1, Viereck, L3, R3, Dreieck | wie im Board: Ticket, Link, Linear, Aktualisieren, → Jarvis (mit 113) | 2 |
| 29 | Options | Menü-Karte am Ticket. Mit 113 beginnt sie auf der Gruppe „Triage“ | 2 |

### Mit Board-Chat (kommt mit WM8-113, hier reserviert)

| Nr. | Taste | Wirkung |
|---|---|---|
| 30 | Fokus im Board-Chat | alles wie in einem Chat: Kreuz Enter (mit allen Schutzregeln), Kreis Escape, Steuerkreuz Pfeile ins Terminal, Viereck Rücktaste, R3 halten leert, R1 und L1 halten wie im Chat |
| 31 | dort L1 / R1 | voriges / nächstes Ticket der Triage — **nicht** Chatwechsel. So blätterst du, während du mit Jarvis sprichst |
| 32 | dort Stick ◀ oder ▲ ▼ | zurück ins Board bzw. in die Triage-Liste, mit einem Schritt (wie heute aus der Einzelansicht in die Liste) |
| 33 | R2 überall im Board | Diktat in den Board-Chat; „Bezug: WM8-112“ steht davor, wie im Board-Entwurf |
| 34 | Triage-Entscheidungen | Options in der Triage öffnet auf „Triage“: Annehmen, Zurückfragen, Zuweisen…, Später, Doppelt, Ablehnen. Kreuz sammelt die Entscheidung im Eingabefeld des Board-Chats und springt zum nächsten Ticket. Abgeschickt wird erst mit Kreuz im Board-Chat |

### Menü-Karte (Options) im Board

Dieselbe Karte wie am Chat, an der ausgewählten Karte bzw. am Kopf des großen Tickets. Gruppen in fester
Reihenfolge, ein Eintrag nur, wenn er passt:

| Gruppe | Einträge |
|---|---|
| Triage (mit 113, nur in der Triage) | Annehmen, Zurückfragen, Zuweisen…, Später, Doppelt, Ablehnen |
| Ticket „WM8-112“ | Zum Chat › (je Chat am Ticket eine Zeile), Link kopieren, In Linear öffnen, → Jarvis (mit 113) |
| Board | Nur „Wartet auf mich“ an/aus, Filter Person ›, Filter Chat ›, Liste kopieren, Aktualisieren |
| Steuerung | Zu den Chats, Zwischenablage-Verlauf, Belegung anzeigen, Controller pausieren |

### Tastatur (dieselbe Logik)

| Controller | Tastatur | Wo |
|---|---|---|
| L2 halten, Reiter „Tickets“ | ⌥Tab halten, → bis „Tickets“, ⌥ loslassen oder Return | überall |
| L2 getippt | ⌥Tab kurz | überall |
| Stick, Steuerkreuz | ↑ ↓ ← → | Board und Triage, nur ohne Terminal im Fokus |
| L1 / R1 | ⌘⌥← / ⌘⌥→ (ebenso ⌘⇧← / ⌘⇧→), in der Liste auch J / K | im ganzen Ticket-Modus, auch im Board-Chat |
| Kreuz | Return | Board, Chat-Zeile |
| Kreis | Esc | Triage, Chat-Zeile |
| Viereck | ⌘⇧C | Link kopieren |
| L3 | ⌘O | In Linear öffnen |
| R3 | ⌘R | Aktualisieren (im Ticket-Modus statt „Sitzungen neu lesen“) |
| Options | ⌘K | Menü-Karte, bedient wie per Tastatur aus der Insel (↑ ↓, Return, Esc) |
| Dreieck (mit 113) | ⌘J | → Jarvis |
| R2 (mit 113) | ⌥Leertaste (Diktat-Hotkey) | Ziel ist der Board-Chat |

„Geht nicht“ ist auf der Tastatur der macOS-Warnton (wie in der Insel, Entscheidung vom 15.11.2026), am
Controller die kurze Vibration.

## Die Leiste unten im Ticket-Modus

Wie heute zeigt sie nur Tasten, die gerade etwas tun, und folgt dem zuletzt benutzten Gerät
(`KeyboardLegend.mode`). Links steht statt des Chats der Ort: „Tickets · WM8“.

| Zustand | Controller (PS) | Tastatur |
|---|---|---|
| Board | Tickets · WM8 · Stick Auswahl · ✕ Öffnen · □ Link · L1 R1 Ticket · L3 Linear · R3 Aktualisieren · Options Menü · L2 Zurück: Chat Jarvis | ↑↓←→ Auswahl · ↩ Öffnen · ⌘⇧C Link · ⌘⌥←→ Ticket · ⌘O Linear · ⌘R Aktualisieren · ⌘K Menü · ⌥⇥ Zurück |
| Triage | Tickets · WM8 · Stick Ticket · ○ Board · □ Link · L1 R1 Ticket · R-Stick Lesen · ▶ Chats am Ticket · L2 Zurück | ↑↓ Ticket · Esc Board · ⌘⇧C Link · ⌘⌥←→ Ticket · → Chats am Ticket · ⌥⇥ Zurück |
| Chat-Zeile am Ticket | ✕ Zum Chat Vic · ○ Liste | ↩ Zum Chat Vic · Esc Liste |
| Board-Chat im Fokus (mit 113) | Board-Chat Jarvis · ✕ Senden · ○ Escape · R2 Diktat · Steuerkreuz Pfeile · L1 R1 Ticket · ◀ Board | wie im Chat, dazu ⌘⌥←→ Ticket |
| Board, R2 ohne Board-Chat | „Diktat erst mit dem Board-Chat“ einmal nach dem Druck | – |

L2 + Touchpad, Create und die Ebenen nennt die Leiste wie heute in einem Eintrag („L1 R1 L2 Halten: Ebenen“).

## Schutz, der bleibt

- **Nichts an einen verdeckten Chat.** Der neue Zusammenhang `tickets` gilt, solange die Tickets offen sind und
  der Fokus nicht im Board-Chat liegt. `withChatsHidden` bleibt. Kein Enter, kein Escape, kein Diktat, keine
  Eingabe aus R1 oder L1 erreicht den Chat dahinter.
- **Kreuz springt nie von selbst in einen Chat.** „Zum Chat“ verlangt, dass die Auswahl auf der Chat-Zeile steht.
  Dreimal schnell Kreuz führt so nie vom Board in einen Chat und dort zu einem Enter in eine offene Freigabe.
- **Kreis im Board tut nichts.** Zweimal Kreis aus der Triage wirft dich nicht aus dem Board.
- **Das Board schreibt nichts.** Keine Taste ändert etwas in Linear. Triage-Entscheidungen landen im
  Eingabefeld des Board-Chats; abgeschickt wird nur mit Kreuz bzw. Return im Board-Chat, mit allen Regeln eines
  Chats (Feld sichtbar, keine Freigabe offen).
- **Ticket-Text ist Daten.** „→ Jarvis“ gibt Nummer, Titel und Link weiter, nie die Beschreibung.
- **R2 nur an einen sichtbaren Chat.** Bis WM8-113 tut R2 im Board nichts (siehe E4).

## Was unbequem ist und wie es gelöst ist

| Reibung | Varianten | Empfehlung |
|---|---|---|
| **L1/R1:** heute Chatwechsel, im Board würde Giuliano damit herausfallen | **A Ticket blättern** ★: eine Regel („blättert durch das, woran du arbeitest“), ermöglicht die Triage im Gespräch mit Jarvis. Wider: im Board doppelt zum Stick. **B Chatwechsel wie bisher:** nichts Neues. Wider: ein Druck verlässt das Board, im Board-Chat genauso. **C Filter** wie in Seitenleiste und Verlauf. Wider: in der Triage sinnlos, Filter braucht man selten | A |
| **Steuerkreuz:** heute Pfeile ins Terminal, im Board gibt es kein Terminal | **A wie der Stick** ★: genau die heutige Regel „ohne lebendes Terminal wie der Stick“; präzise Schritte durch Spalten. **B nur Stick:** Steuerkreuz ruht. Wider: das genauere Werkzeug liegt brach. **C Pfeile an den Board-Chat**, auch wenn die Auswahl im Board steht. Wider: Pfeile träfen einen Chat, auf den du nicht schaust | A |
| **Weg zum Board:** R1 hat keinen freien Platz (App-Raute voll, Chat-Raute gehört dem Chat) | **A Reiter „Tickets“ in Wohin + L2 getippt + Options** ★: Orte wählt man schon heute dort; anderes Team gleich mit. **B Schnellbefehl R1 + ▼:** ein Druck. Wider: verdrängt die Zwischenablage (auch am Touchpad), R1 heißt „handeln“, nicht „hingehen“. **C nur Options:** Wider: drei Drücke und versteckt | A |
| **Zum Chat:** Kreuz heißt „tiefer“, im Chat aber Enter | **A über die Chat-Zeile** ★: ▶ auf „Chats am Ticket“, dann Kreuz. Sicher gegen schnelles Mehrfach-Kreuz. **B Kreuz in der Triage direkt:** schneller. Wider: Board → Ticket → Chat → Enter mit dreimal Kreuz | A |
| **Kreis im Board** | **A nichts** ★: schützt vor Kreis-Kreis aus der Triage. **B zurück zu den Chats** wie L2 getippt. Wider: doppelt zu L2 und ein Fehlgriff verlässt das Board | A |
| **R2 vor dem Board-Chat** | **A geht nicht** ★: kein Diktat ohne sichtbares Ziel. **B in die Zwischenablage:** Wider: Text landet unbemerkt im Verlauf | A |

## Offene Entscheidungen

| Nr. | Frage | Empfehlung |
|---|---|---|
| E1 | Wie kommst du zum Board? | Reiter „Tickets“ in Wohin (L2 halten), zurück mit L2 getippt, dazu ein Eintrag im Options-Menü |
| E2 | Was tun L1/R1 im Board? | voriges/nächstes Ticket, auch später im Board-Chat |
| E3 | Wie kommst du vom Ticket zu seinem Chat? | über die Chat-Zeile am Ticket (▶, dann Kreuz) |
| E4 | Was tut R2 im Board, solange es den Board-Chat noch nicht gibt? | nichts, mit kurzer Rückmeldung |

Ohne eigene Frage, weil sie aus der heutigen Belegung folgen: Steuerkreuz wie Stick, Kreis im Board ohne
Wirkung, R1-Rauten unverändert, Tastatur wie in der Tabelle.

## Wo die Logik liegt

- **Auswahl, pur:** `WhisperM8/Views/Tickets/TicketBoardSelection.swift`, nur Foundation, neben der Tab-Logik
  (`Views/AgentTabSelection.swift`). Eingabe: Spalten mit sichtbaren Ticket-Nummern und „N weitere“, Triage-Liste,
  Chats am Ticket, ob es einen Board-Chat gibt. Ausgabe: neue Auswahl und Fokus (`board(column, row)`,
  `triage(index)`, `ticketChat(index)`, `boardChat`, `sidebar`). Bewegung mit ungleich langen Spalten,
  Lesereihenfolge für L1/R1, Start-Auswahl, Erhalt der Auswahl nach einem Abruf (über die Ticket-Nummer, fällt
  sie weg: Nachbar in derselben Spalte). Tests: `TicketBoardSelectionTests`. Maus, Tastatur und Controller
  benutzen dieselben Funktionen.
- **Tasten, pur:** `Services/Controller/Core/ControllerBindingResolver+Tickets.swift` mit neuem Zusammenhang
  `ControllerContext.tickets(ControllerTicketState)` (Vorrang nach Menü und Dialog, vor Liste und Chat). Der
  Schnappschuss bekommt den Ticket-Zustand nur, wenn das Fenster Tickets zeigt. Legende über dieselben Proben
  wie heute (`ControllerLegend`), damit sie keine Taste ohne Wirkung zeigt.
- **Ort:** `ChatPlace` bekommt `.tickets(team:)`, `ChatPlaceHistory` und `AgentWindowStore+PlaceHistory` führen
  ihn wie Chat und Workspace. Den Stand des Boards (Ansicht, Auswahl) hält schon `TicketBoardController` je Fenster.
- **Wohin:** `ControllerIsland` bekommt den dritten Reiter, Zeilen aus der Einrichtung (`TicketConfig`),
  gelesen beim Öffnen der Insel abseits des Main Threads gecacht, nie im Ereignis-Pfad von Disk.
- **Tastatur:** `Views/Tickets/TicketBoardKeys.swift` (pur, keyCode und Modifier → Aktion wie
  `TabNavShortcut`), `KeyboardIslandKeys` für den Reiter.

Leistung: Die Auswahl rechnet nur auf dem schon geladenen Board-Modell, ohne Abruf; der Takt bleibt bei 120 s.
R3 und ⌘R lösen je Druck höchstens einen Abruf aus, gebremst wie der Knopf (`rateLimitPause`).

## Paketschnitt für den Bau

Alles hinter `ticketBoardEnabled` und `controllerFeatureEnabled` (Tastatur: `keyboardIslandEnabled`).
Reihenfolge: nach WM8-112, das die Triage-Ansicht baut.

| Paket | Inhalt | Fertig, wenn |
|---|---|---|
| **1 Öffnen und Umschalten** | Board als Ort (`.tickets(team:)`), L2 getippt hin und zurück, Reiter „Tickets“ in Wohin samt Teams und „hier/vorher“, Options „Ticket-Board WM8“ und „Zu den Chats“, Start-Auswahl, Kopf der Insel und Leiste nennen „Tickets · WM8“ | mit dem Controller allein vom Chat ins Board und zurück, auch in das Board eines anderen Teams |
| **2 Bedienen** | `TicketBoardSelection` pur und getestet, Zusammenhang `tickets`, Belegung Nr. 8–29, Menü-Karte am Ticket, Leiste für Board, Triage und Chat-Zeile, Snapshots hell und dunkel | jede Taste tut, was die Liste sagt, auch „nichts, mit Rückmeldung“ |
| **3 Tastatur über die Insel** | Reiter „Tickets“ in ⌥Tab, Kürzel aus der Tabelle (Pfeile, Return, Esc, J/K, ⌘⌥←→, ⌘⇧C, ⌘O, ⌘R, ⌘K), Leiste in der Tastatur-Fassung | derselbe Weg geht ohne Controller |
| mit WM8-113 | R2, Dreieck/⌘J, R1-Chat-Raute und L1 am Board-Chat, Fokus im Board-Chat (Nr. 30–34), Gruppe „Triage“ | steht im Ticket WM8-113 |

Paket 1 und 3 lassen sich parallel bauen, wenn der Ort `.tickets` zuerst kommt.

## Nicht dabei

- Freies Umbelegen der Tasten (WM8-19).
- Ziehen von Tickets per Controller (Ticket auf einen Chat ziehen): bleibt Maus; „→ Jarvis“ deckt den Fall ab.
- Ein eigener Schnellbefehl unter R1 für das Board und ein eigenes globales Kürzel: Wohin und L2 reichen.
- Triage-Entscheidungen mit Wirkung und Schreiben nach Linear (Entscheidung E1 vom 15.11.2026: das Board
  schreibt nicht selbst).
- Controller außerhalb der App im Board (Hintergrund-Empfang weckt die App wie heute, mehr nicht).
- Die Seitenleiste im Archiv-Modus: Wer aus dem Board mit ◀ in die Seitenleiste geht, sieht sie, wie sie steht.

## Hinweise für den Bau

- WM8-112 nennt ⌘⇧C bei „Liste kopieren“. Dieser Entwurf legt ⌘⇧C auf „Link kopieren“ (die Auswahl ist im neuen
  Board immer da) und „Liste kopieren“ in die Menü-Karte. Beim Bau von WM8-112 abstimmen.
- ⌘R heißt im Ticket-Modus „Aktualisieren“; in den Chats bleibt es „Sitzungen neu lesen“.
- Jarvis öffnet das Board künftig selbst (WM8-114). „Zurück, wo ich war“ ist dann dasselbe wie L2 getippt.
- Prüfen: `swift test --filter TicketBoardSelection`, `--filter ControllerBindingResolverTickets`,
  `--filter ChatPlace`, `--filter KeyboardIsland`; `make snapshots ONLY=tickets-controller` (Board mit Auswahl
  und Leiste, Triage, Chat-Zeile, Wohin mit Reiter „Tickets“, Menü-Karte am Ticket, Tastatur-Leiste, hell und
  dunkel).
