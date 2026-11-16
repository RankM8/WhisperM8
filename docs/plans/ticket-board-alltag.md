---
status: Beratung abgeschlossen, E1 bis E4 und E6 entschieden (15.11.2026); Bau nicht freigegeben
stand: 2026-11-15
feature: Ticket-Board für den Alltag — Triage wie in Linear, Board-Chat daneben, Jarvis steuert das Board, „Wartet auf mich“ über alle Teams
branch: design/WM8-111-ticket-board-alltag-oeffentlich
---

# Ticket-Board für den Alltag: Beratung

Ticket `WM8-111`. Giuliano am 15.11.2026: Er nutzt das Board in WhisperM8 nicht, „weil es recht stumpf ist und
ich da nichts machen kann“. Seine Ideen: das Ticket groß zeigen (Triage), „Link kopieren“, und rechts neben dem
Board einen Chat, mit dem er direkt am Board arbeitet. Im Lauf der Beratung kamen zwei Wünsche dazu: Der
Jarvis des Projekts soll automatisch dieser Chat sein und das Board selbst steuern können (Tickets öffnen,
Triage-Listen hinlegen), und das große Ticket soll aussehen wie die Triage in Linear (Liste links, Ticket in der
Mitte, Eigenschaften rechts, feste Knöpfe oben).

Klick-Entwurf: [`../design/ticket-board-alltag.html`](../design/ticket-board-alltag.html). Ist-Zustand:
[`../features/tickets.md`](../features/tickets.md), Plan von Stufe 1: [`ticket-board.md`](ticket-board.md).

## Kurz

1. **Das Board liest falsch herum.** Es ist um die Frage „Welcher Chat sitzt woran?“ gebaut. Giulianos Fragen
   lauten „Was wartet auf mich?“ und „Haben die Entwickler genug zu tun?“. Darauf gibt das Board heute keine Antwort.
2. **Empfehlung in einem Satz:** Das große Ticket als Triage wie in Linear, daneben automatisch der Jarvis des
   Projekts als Board-Chat, und alles, was in Linear etwas ändert, läuft als Auftrag über diesen Chat. Jarvis
   kann umgekehrt Tickets auf dem Board öffnen.
3. **Grundsatzentscheidung Schreiben:** Das Board schreibt vorerst nicht selbst nach Linear. Triage-Knöpfe
   sammeln Entscheidungen, ein Enter gibt sie dem Board-Chat. Begründung unten unter „Schreiben nach Linear“.
4. **Bau in vier Paketen**, das erste ändert nur die Ansicht und bringt sofort den größten Teil des Nutzens.

## Teil 1: Befunde

### a) Was das Board heute kann und wo es stumpf ist

Gelesen: Feature-Doku, Plan und Entwurf von Stufe 1, `WhisperM8/Views/Tickets/`, `whisperm8 tickets --help`,
`tickets board` für XYZ, ABC und WM8 am 15.11.2026, die Snapshots unter `docs/design/ticket-board/`.

**Kann:** drei Spalten nach Art des Status (in Arbeit, als Nächstes, Backlog), Liste nach Projekt, Filter nach
Chat und Person, je Karte der verknüpfte Chat mit Live-Status, Detail mit „Zum Chat“ und „In Linear öffnen“,
Leiste „Chats ohne Ticket“. Alle 120 Sekunden ein Abruf, nur bei sichtbarer Ansicht.

**Kann nicht, was Giuliano heute in Linear oder über Jarvis tut:**

| Fehlt | Beleg |
|---|---|
| Ticket groß lesen | Detail fest 340 pt breit (`TicketBoardView.detailWidth`) |
| Kommentare, Entscheidungen, Abschlüsse, Prüfer-Hinweise sehen | Die App liest keine Kommentare (`LinearTicketSource` schreibt nur `commentCreate`) |
| Von Ticket zu Ticket gehen | kein Blättern, keine Liste neben dem Detail |
| Link oder Liste weitergeben | kein Kopieren; heute 34-mal `pbcopy` durch Chats seit 01.11. |
| Ticket an einen Chat geben, Chat starten | nur „Zum Chat“, wenn schon einer verknüpft ist |
| Status, Zuweisung, Priorität, Kästchen, Entscheidung | nur per Chat oder `whisperm8 tickets` |
| Sehen, was auf ihn wartet | kein Filter, keine Teamgrenzen übergreifende Sicht |
| Vorrat je Entwickler, PR und Prüfer | nicht im Board; steht nur im PM-Tagesbericht |
| Mit Jarvis am Board arbeiten | Diktat und Controller treffen hinter den Tickets bewusst keinen Chat |

**Wo es an ABC und XYZ vorbeigeht** (Abzug 15.11.2026; die vollständige Fassung mit Zahlen liegt außerhalb des Repos):

- In ABC sammelt „In Arbeit“ Tickets aus mehreren Stationen (in Arbeit, im Review, auf Staging) in einer Spalte.
  Nur ein kleiner Teil davon hat einen Chat; der Rest wartet auf Prüfung oder Test. Der Stau in der Prüfung, den der
  PM-Tagesbericht als größten Engpass nennt, ist im Board nicht zu sehen.
- In XYZ stehen Tickets mit offener Produktentscheidung, die alle bei Giuliano liegen, in „Als Nächstes“ zwischen
  vielen eingeplanten Tickets und fallen nicht auf.
- Die zwei Entwickler arbeiten ohne WhisperM8-Chats. „Kein Agent“ steht deshalb auf fast jeder Karte und sagt dort
  nichts.

### b) Wie in DealSupply und Akquise AI gearbeitet wird

Quellen, nur gelesen: die Linear-Teams ABC und XYZ (Verlauf seit dem Umzug nach Linear am 14.11.), die Spielregeln
„So arbeiten wir mit Linear“ des Teams, die Skills `pm`, `pm-analyse` und `tickets`, der PM-Tagesbericht, die
Verläufe der Supervisor- und Produkt-Chats beider Projekte (nur Giulianos eigene Nachrichten seit 01.11.).

- **Wer legt an, priorisiert, weist zu:** formal fast immer das Konto Giuliano, auch bei Prioritäten und Zyklen.
  Tatsächlich schreiben Jarvis und die Produkt-Chats nach seinem Ja. Ein Entwickler pflegt seine Stationen selbst
  (in Arbeit, gemergt, auf Staging), der andere vereinzelt.
- **Giulianos Handgriffe**, nach Häufigkeit in seinen Nachrichten:
  1. Stand abfragen („Was ist der aktuelle Stand der Tickets?“), fast täglich
  2. Entscheiden über das Fragetool, mit Abstand der häufigste Handgriff
  3. Sich beraten lassen
  4. Vorrat der Entwickler prüfen („Haben beide genug zu tun?“)
  5. Review und PR klären: wer prüft, ist der PR da
  6. Text für einen Entwickler in die Zwischenablage, dann in den Team-Chat
  7. Arbeit an einen Chat geben
  8. Eine Ansicht oder einen Link in Linear finden, oft per Bildschirmfoto in den Chat
- **Nummern nennt er fast nie.** Er spricht in Themen, Jarvis findet die Tickets. Ein Board, auf dem Jarvis ihm die
  Tickets zeigt, über die sie gerade sprechen, passt genau dazu.
- **Wo er springt:** Linear im Browser → Bildschirmfoto → Chat. Chat → Zwischenablage → Team-Chat. Die
  Linear-Ansichten „Wartet auf mich“, „Handtests“, „Entscheidungen“ sind eingerichtet, er benutzt sie nicht.
- **Status mit Sonderbedeutung:** In einem Team heißt ein Status, der nach Code-Prüfung klingt, in Wahrheit
  „Produktentscheidung offen“; im anderen heißt „Backlog“ „noch nicht umsetzbar“. Das Board muss solche Bedeutungen
  je Team kennen, sonst führt es in die Irre.
- **Review-Regel (Spielregeln des Teams, Skill `pm`):** Wer baut, prüft nie selbst; die zwei Entwickler prüfen sich
  gegenseitig. Der PM-Tagesbericht findet regelmäßig Tickets ohne eingetragenen Prüfer.
- **PM-Tagesbericht:** täglich 07:00, liest nur, schreibt ein Linear-Dokument. Er rechnet „umsetzbar“ nach festen
  Regeln (`daten.py`: Kästchen, nicht gesperrt, keine offene Klärung, kein Chat daran). Zeigt das Board Vorrat, muss
  es dieselbe Regel nutzen, sonst zeigen Board und Bericht verschiedene Zahlen.
- **Kollegen lesen mit:** In Linear sind Giuliano und die zwei Entwickler, alle mit vollen Rechten. Fast alles, was
  Chats schreiben, steht dort unter Giulianos Namen. Jede Änderung kann den Entwicklern eine Push-Meldung schicken.

### c) Was es schon gibt und wiederverwendbar ist

| Baustein | Nutzen hier |
|---|---|
| Raster, Kachelkopf, Notiz-Karte am Kachelkopf | Kopf der Board-Chat-Spalte, Notiz zeigt Jarvis' Stand |
| Terminal wandert schon zwischen Einzelansicht und Kachel | dasselbe Umhängen für die Board-Chat-Spalte |
| `chats send --no-submit` | Auftrag ins Eingabefeld legen, ohne abzuschicken |
| Diktat mit Ziel „Agent Chat“ | Diktat geht an den Board-Chat, solange die Tickets offen sind |
| Steuerkanal (`chats focus`, `workspace open`) | Grundlage für `tickets open` durch Jarvis |
| Supervisor-Erkennung am Titel „Jarvis“ (`tickets board`) | Board-Chat automatisch wählen |
| `tickets link/done/decide/check` | Jarvis führt gesammelte Triage aus |
| Ziehen von Chats (`DraggableSession`) | Chat auf die Spalte ziehen; Ticket auf einen Chat ziehen |
| `TicketDescriptionBlocks` | Kommentare genauso leicht setzen wie die Beschreibung |
| Geplante Aufgaben (WM8-110) | die PM-Analyse läuft künftig dort; ihr Ergebnis gehört aufs Board |
| WM8-89 (Ticket am Chat), WM8-91 (Controller) | ergänzen sich mit Paket 1; die Triage-Liste ist für den Controller ideal |

Wettbewerb (`wettbewerb-orca-t3code/jira.md`): Orca startet aus einem Ticket einen Arbeitsbereich mit Agent und
behandelt Ticket-Text ausdrücklich als Daten, nie als Anweisung. Beides übernehmen wir.

## Teil 2: Beratung

### Schreiben nach Linear: Grundsatzentscheidung

Heute schreibt nur `whisperm8 tickets`, die App liest (CLAUDE.md, Invarianten). Ein Knopf, der aus der
Oberfläche nach Linear schreibt, ändert diese Regel. Drei Wege:

| | **A · Aufträge an den Board-Chat** (Empfehlung) | **B · Triage-Knöpfe schreiben direkt** | **C · Volles Bearbeiten im Board** |
|---|---|---|---|
| Was passiert bei „Annehmen“ | wird gesammelt, ein Enter gibt alle an Jarvis | sofort in Linear, mit Rückgängig | jedes Feld direkt änderbar |
| Regeln aus den Spielregeln des Teams (Prüfer, „Fertig, wenn“) | hält Jarvis ein | der Knopf umgeht sie | umgeht sie |
| Wer schreibt | `whisperm8 tickets` durch den Chat, wie heute | die App über denselben Code (`TicketSource`) | die App |
| Tempo | ein Chat-Zug je Sammlung, einige Sekunden | sofort | sofort |
| Kollegen | sehen, was Jarvis nach Regeln schreibt | sehen jeden Klick als „Giuliano“, sofort mit Push | ebenso, mehr Rauschen |
| Regel in CLAUDE.md | bleibt | wird erweitert: App schreibt Triage | wird ersetzt |

**Empfehlung A.** Giuliano entscheidet heute schon fast alles im Gespräch und lässt Jarvis schreiben; das Board
übernimmt das Zeigen und Sammeln, nicht das Schreiben. Das Sammeln nimmt dem Weg die Langsamkeit: Zehn Tickets
durchgehen kostet einen Enter, nicht zehn Chat-Züge. B ist der natürliche nächste Schritt, falls sich A im Alltag
als zu träge erweist; gebaut wird es dann über dieselbe Quelle wie die CLI, nie als zweiter Weg.

Ausnahmen, die keine Grundsatzfrage sind, weil sie nichts in Linear ändern: Link kopieren, In Linear öffnen,
Zum Chat, Filter, Blättern.

### Idee 1: Ticket groß, als Triage wie in Linear

- **Nutzen: hoch.** Lesen ist der häufigste Handgriff. Die Liste links zeigt, was noch vor ihm liegt; das ist
  der Unterschied zwischen „ein Ticket ansehen“ und „Tickets abarbeiten“.
- **Beste Form:** nimmt den Platz des Boards ein. Links die Liste, aus der er kommt (eine Spalte, „Wartet auf
  mich“ oder eine Liste von Jarvis), Mitte das Ticket mit Beschreibung und Verlauf, rechts eine schmale Spalte mit
  Eigenschaften (Status, Priorität, Person, Vorhaben, „Fertig, wenn“, PR und Prüfer, Chats). Oben Link, Linear,
  „→ Jarvis“ und die Triage-Knöpfe: Annehmen, Zurückfragen, Zuweisen, Später, Doppelt, Ablehnen. J/K oder ↑↓
  wechselt das Ticket, Esc führt zum Board.
- **Aufwand: mittel.** Ansicht neu, dazu eine Abfrage für Kommentare beim Öffnen eines Tickets (eine Anfrage je
  geöffnetem Ticket; beim heutigen Budget unkritisch).
- **Fallen:** Mit Board-Chat sind es vier Spalten; die Eigenschaften müssen schmal bleiben (rund 200 pt), der
  Board-Chat wird in der Triage schmaler. Bilder in Kommentaren liegen hinter Adressen, die nach Minuten verfallen:
  nur als Verweis „Bild in Linear“ zeigen. Kommentare stammen von Kollegen und Chats: Links wie in der Beschreibung
  nur `http(s)`. Tasten wie J/K wirken nur, wenn der Fokus nicht im Terminal liegt.
- **Alternativen im Entwurf:** „Ticket allein“ (ohne Liste), „Breites Feld rechts“ (600 pt), „Heute“.

### Idee 2: Link kopieren

- **Nutzen: hoch, Aufwand: klein.** Ersetzt die Bitte „gib mir den Link“ und einen Teil der Zwischenablage-Wege.
- **Beste Form:** zwei Zeilen, „WM8-104 Titel“ und darunter die Adresse; lesbar für Menschen in Slack oder im Team-Chat,
  eindeutig für jeden Chat. Dazu „Liste kopieren“: die sichtbaren Tickets in Reihenfolge, für „Was soll ein
  Entwickler als Nächstes machen“. Tastenkürzel ⌘⇧C wie in Linear.
- **Besser als Kopieren**, wenn das Ziel ein Chat ist: „→ Jarvis“ legt die Angaben direkt ins Eingabefeld, und
  ein Ticket lässt sich auf einen Chat in Seitenleiste, Tab oder Kachel ziehen.
- **Falle:** Eigene Schreibvorgänge auf die Zwischenablage müssen beansprucht werden (`ClipboardInternalWrites`),
  sonst landen sie im Zwischenablage-Verlauf. Ob kopierte Links dort auftauchen sollen, ist eine Kleinigkeit für
  den Bau, keine Frage an Giuliano: Empfehlung nicht.

### Idee 3: Chat neben dem Board

- **Nutzen: hoch.** Giuliano arbeitet ohnehin im Gespräch; mit dem Chat am Board sieht er dabei, worüber er spricht.
- **Derselbe Mechanismus wie Workspaces oder ein eigener?** Ein eigener, schmaler: eine Seitenspalte rechts im
  Ticket-Modus, gebaut aus den Bausteinen der Kachel (Kopf, Terminal, Notiz). Die Variante „Board als Kachel im
  Workspace“ ist im Entwurf zu sehen und nicht empfohlen. Das Raster kennt nur Chats als Kacheln; eine
  Board-Kachel zöge durch Speichern, Neustart-Übergabe, Controller und die `workspace`-Befehle. Außerdem bekäme das
  Board nur eine Rasterkachel, und die Triage hätte keinen Platz.
- **Welcher Chat ist es?** Automatisch der Jarvis des Projekts: Chat dieses Projekts, Titel beginnt mit
  „Jarvis“, laufend oder zuletzt aktiv. Gibt es einen Produkt-Chat (Titel mit „Produkt“), steht er
  als zweiter Knopf im Kopf der Spalte. Ein anderer Chat lässt sich hineinziehen; die Wahl gilt je Projekt und
  bleibt gespeichert. Gibt es keinen Jarvis, zeigt die Spalte „Chat hierher ziehen“ und einen Knopf „Jarvis starten“.
  Die Erkennung am Titel ist die vorhandene Regel; sauberer wäre ein Merkmal an der Sitzung (steht schon in
  `ticket-board.md`).
- **Zurück in die Chats:** Die Spalte zeigt kein zweites Terminal, sondern denselben Chat an anderem Ort. Beim
  Umschalten wandert er zurück an seinen Tab und seine Kachel. Eine Sitzung lebt immer in genau einem Fenster:
  Steht der Jarvis gerade in einem anderen Fenster, zeigt die Spalte „läuft in Fenster 2 · hierher holen“.
- **Was sich dabei ändert:** Solange die Tickets offen sind, ist der Board-Chat Ziel für Diktat und Controller
  (heute ruht beides hinter den Tickets). Was am Board offen ist, steht als „Bezug: WM8-104“ vor seiner nächsten
  Nachricht; der Bezug ist sichtbar und mit einem Klick weg.
- **Aufwand: groß.** Umhängen des Terminals, Diktat-Ziel, Eingabe ohne Abschicken, Speichern der Wahl, Ziehen.

### Zusatz vom 15.11.: Jarvis steuert das Board

Giuliano: Jarvis soll sich selbst als Board-Chat eintragen können, ihm das Board öffnen und neue Tickets direkt
in der Triage zeigen, damit er als Mensch denselben Kontext hat.

- **Nutzen: hoch.** Es passt zu seiner Art zu arbeiten: Er nennt Themen, Jarvis kennt die Nummern. Mit dem Befehl
  zeigt Jarvis sie ihm.
- **Form:** neue Befehle im Steuerkanal, etwa `whisperm8 tickets open WM8-112 [--triage WM8-112,WM8-113,…]`
  (Board des Teams, Ticket groß, Liste links) und `whisperm8 tickets view --json` (was gerade offen ist, damit
  Jarvis weiß, bei welchem Ticket Giuliano ist). Der Skill `tickets` bekommt dafür einen Abschnitt.
- **Rückweg:** Ein Knopf „Zurück, wo ich war“ stellt die vorige Ansicht wieder her.
- **Falle:** Schaltet Jarvis um, während Giuliano anderswo tippt oder diktiert, reißt ihn das heraus. Siehe
  Entscheidung E4.

### Eigene Vorschläge

1. **„Wartet auf mich“ über alle Teams.** Eine Liste für den Morgen über XYZ, ABC und WM8, getrennt nach Grund:
   Prüfung ohne Prüfer, Produktentscheidung offen, Abnahme (In Review bei ihm), Staging-Test, Handtest. Mit
   denselben Regeln wie der PM-Tagesbericht. „Durchgehen“ öffnet die Triage mit genau dieser Liste. Nutzen hoch,
   Aufwand mittel (drei Teams im Takt statt eines, dazu je Team eine Regel, welcher Status was bedeutet).
2. **Vorrat und Prüfung sichtbar.** Eine Leiste über dem Board: umsetzbar je Entwickler und Team, Zahl
   „Prüfung ohne Prüfer“, Verweis auf den PM-Tagesbericht. Auf Karten in Review PR-Nummer und Prüfer, in Bernstein,
   wenn keiner eingetragen ist. Damit die Zahlen zum Bericht passen, wandert die Regel „umsetzbar“ aus `daten.py`
   in `whisperm8 tickets` (zum Beispiel `tickets list --ready`), und Bericht wie Board nutzen sie.
3. **Spalten nach echtem Status statt drei Gruppen.** Das nimmt die Entscheidung E5 von Stufe 1 zurück, mit Beleg:
   Die Gruppen verstecken genau die Engpässe. Lange Spalten zeigen die ersten Karten und „N weitere · in der
   Liste“; Spalten, in denen etwas auf Giuliano wartet, sind markiert.
4. **Unbequem, was weg kann oder leiser werden muss:**
   - „Kein Agent“ auf jeder Karte: weg. Die Chat-Zeile steht nur da, wo es einen Chat gibt; der Filter bleibt.
   - Leiste „Chats ohne Ticket“: in eine Zeile mit Zahl, aufklappbar. Sie dient Jarvis, nicht Giuliano.
   - Das Board hängt am gewählten Projektordner. Für WM8 ist das richtig, für Giuliano als Chef zweier Teams nicht;
     „Wartet auf mich“ löst das, ohne die Projektbindung aufzugeben.
5. **Nebenbefund, nicht Teil des Baus:** Die Skills `pm` und `linear` verlangen „keine Hinweise auf Chats in
   Tickets“, die Verknüpfung schreibt aber Anhänge „Chat: <Titel des Chats>“ (am 14.11. so entschieden). Das sollte
   Jarvis einmal glattziehen, bevor der Board-Chat noch mehr Spuren in ABC und XYZ hinterlässt.

### Reihenfolge nach Nutzen und Paketschnitt

| Paket | Inhalt | Nutzen | Aufwand | hängt ab von |
|---|---|---|---|---|
| **P1 Triage und Lesen** | Triage-Ansicht (Liste, Ticket, Eigenschaften), Kommentare lesen, Link und Liste kopieren, Spalten nach Status, Filter „Wartet auf mich“ im Team, „Kein Agent“ weg | hoch | mittel | – |
| **P2 Board-Chat** | Seitenspalte, automatisch Jarvis, Produkt-Chat als zweiter Knopf, Hineinziehen, Wahl je Projekt, Terminal umhängen, Diktat und Controller an den Board-Chat, Bezug, „→ Jarvis“, Aufträge ins Eingabefeld, Triage-Knöpfe sammeln | hoch | groß | P1 |
| **P3 Jarvis steuert** | `tickets open … --triage`, `tickets view --json`, „Zurück, wo ich war“, Regel aus E4, Skill-Abschnitt | hoch | mittel | P1, besser nach P2 |
| **P4 Alle Teams und Vorrat** | „Wartet auf mich“ über alle Teams, Vorrats-Leiste, PR und Prüfer auf Karten, Regel „umsetzbar“ in `whisperm8 tickets` | hoch | mittel | P1; parallel zu P2 möglich |
| (P5, nur nach Entscheidung) | Triage-Knöpfe schreiben direkt (Weg B) | mittel | mittel | P2 |

Verwandt: WM8-91 (Controller) passt direkt hinter P1, weil die Triage-Liste mit Steuerkreuz und Tasten gut zu
bedienen ist. WM8-89 (Ticket am Chat) bleibt eigenständig. WM8-83 (Chat-Verlauf am Ticket) ist unberührt.

Alles bleibt hinter `ticketBoardEnabled` (Labs). Neue Einstellungen (etwa die Wahl des Board-Chats) sind
Bedienwege im Board selbst und brauchen keinen eigenen Schalter.

## Entscheidungen

Giuliano hat am 15.11.2026 E1, E3, E4 und E6 jeweils wie empfohlen entschieden, festgehalten am Ticket
(`tickets decide`). E2 (Triage wie in Linear) war sein eigener Wunsch. E5 folgt aus dem Entwurf, den er so
abgenommen hat; beim Bau von P1 noch einmal zeigen.

| Nr. | Frage | Empfehlung · Stand |
|---|---|---|
| E1 | Schreibt das Board selbst nach Linear? | A: nein, Triage-Knöpfe sammeln, Jarvis führt aus · **entschieden** |
| E2 | Form des großen Tickets | Triage wie in Linear (Liste, Ticket, Eigenschaften) · **Giulianos Wunsch** |
| E3 | Board-Chat | eigene Seitenspalte, automatisch Jarvis, Produkt-Chat als zweiter Knopf · **entschieden** |
| E4 | Wann darf Jarvis das Board öffnen? | nur, wenn Giuliano gerade mit ihm spricht oder das Board schon offen ist; sonst ein Hinweis „Jarvis möchte dir 4 Tickets zeigen · Öffnen“ · **entschieden** |
| E5 | Spalten | echter Status je Team statt drei Gruppen |
| E6 | Reihenfolge | P1, dann P2 und P4, dann P3 · **entschieden** |

## Risiken

| Risiko | Folge | Gegenmittel |
|---|---|---|
| Linear-Budget bei drei Teams im Takt | 2.500 Anfragen je Stunde teilen sich Board und alle `tickets`-Befehle | „Wartet auf mich“ fragt je Team eine schlanke Abfrage; Kommentare nur beim Öffnen; gemessen wird wie in `tickets.md` |
| Status-Bedeutungen je Team | falsche Gruppen in „Wartet auf mich“ | Regel je Team in `tickets.json` neben der Zuordnung, gepflegt mit `tickets setup` |
| Board-Chat in anderem Fenster | Spalte leer oder Chat springt | Hinweis mit „hierher holen“, nie still verschieben |
| Jarvis schaltet im falschen Moment um | Giuliano verliert seinen Platz | E4 und „Zurück, wo ich war“ |
| Ticket-Text als Anweisung an Jarvis | fremder Text steuert den Chat | Aufträge nennen Nummer, Titel und Link, nie die Beschreibung; der Skill behandelt Ticket-Text als Daten |
| `AgentChatsView.swift` an der Größengrenze | Einstieg der Spalte passt nicht | alles in eigenen Dateien, Einstieg über die vorhandene Ticket-Erweiterung |
