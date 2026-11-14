---
status: Plan mit Empfehlung (14.11.2026), Bau nicht freigegeben; Stufe 0 läuft außerhalb der App
stand: 2026-11-14
feature: Ansicht „Tickets“ in Agent Chats — Board und Backlog aus dem Ticket-Werkzeug, je Ticket der zuständige Chat mit Live-Zustand
branch: feat/WM8-37-ticket-board
---

# Tickets in Agent Chats: Plan

Wunsch des Nutzers (14.11.2026): In WhisperM8 soll je Projekt ein Board zu sehen sein, das die Tickets aus
Linear zeigt und dazu, welcher Chat an welchem Ticket sitzt, welche Chats gerade laufen und welche Tickets noch
niemanden haben. Filtern nach Person gehört dazu (mir zugewiesen, niemandem zugewiesen, Kolleginnen und Kollegen).

Entwurf zum Anklicken: [`../design/ticket-board.html`](../design/ticket-board.html) (vom Nutzer am 14.11.2026
abgenommen). Ticket: `WM8-37`, verwandt `WM8-45` (Chats auf anderen Rechnern sehen) und `WM8-23` (Entscheidung,
ob DealSupply und Akquise nach Linear umziehen).

Dieser Plan sagt, was gebaut wird, wo es in der App andockt, in welchen Schritten und was vorher zu entscheiden
ist. Gebaut wird erst nach Freigabe.

## Ausgangslage

- **Linear wird bis 28.11.2026 an WhisperM8 getestet.** Im Team `WM8` liegen die laufenden Vorhaben als Projekte
  und rund 40 Tickets. Ob Linear bleibt, ist offen. Die Ansicht darf deshalb nicht fest an Linear hängen.
- **Stufe 0 läuft schon, ohne App-Code.** Ein Chat hängt sich mit `~/.claude/skills/linear/ticket link WM8-12`
  an sein Ticket. Technisch ist das ein Anhang am Ticket mit der Adresse `whisperm8://chat/<Sitzungs-ID>` und
  den Angaben `source: whisperm8`, `chatId`, `project` in den Metadaten; der Untertitel beginnt mit „arbeitet“
  oder „beendet“. `ticket board` zeigt im Terminal bereits Tickets, Chat und Live-Zustand nebeneinander. Die
  Ansicht in der App liest dieselben Anhänge, damit beides zusammenpasst.
- **Was die App schon weiß:** welche Chats laufen und in welchem Zustand (`AgentSessionActivityStore`,
  Laufzeitstatus je Sitzung), gezeichnet von `AgentStatusIndicator`. Die Sitzungs-ID im Anhang ist dieselbe
  `id`, die `whisperm8 chats list --json` liefert.
- **Was die App nicht weiß:** die Tickets. Dafür braucht sie Zugriff auf Linears Schnittstelle.
- **Belegt am 14.11.2026:** Ein Board (38 Tickets mit Status, Vorhaben, Person, Labels, Anhängen) kommt in einer
  Abfrage in 0,3 Sekunden. Das Limit liegt bei 2.500 Abfragen je Stunde und Person. Änderungen meldet Linear nur
  an öffentliche Web-Adressen, ein Programm auf dem Mac muss also im Takt nachfragen.

## Ziel und Abgrenzung

**Stufe 1 (dieser Plan, nur lesen):**

- Board mit drei Spalten nach Art des Status (in Arbeit, als Nächstes, Backlog) und eine Backlog-Liste, nach
  Vorhaben gruppiert.
- Je Ticket: Nummer, Titel, Vorhaben und Meilenstein, Priorität, die Labels „Handtest“ und „Entscheidung“,
  „blockiert“, zugewiesene Person, und der verknüpfte Chat mit Status-Punkt und Zustand. Ohne Chat steht dort
  sichtbar „Kein Agent“.
- Filter in zwei Gruppen, kombinierbar: Agent (alle, mit, ohne) und Person (alle, nicht zugewiesen, je Person).
  Dazu die Auswahl eines Vorhabens.
- Detail zum Ticket mit Text, Person, Chat, „Zum Chat“ und „In Linear öffnen“.
- Leiste „Laufende Chats ohne Ticket“.

**Stufe 2 (eigener Plan nach Stufe 1):** Chat aus einem Ticket starten, laufenden Chat zuweisen, Verknüpfung
lösen, Status ändern, Person zuweisen. Das sind Schreibzugriffe auf das Ticket-Werkzeug.

**Stufe 3 (Idee, `WM8-45`):** Chats sehen, die in WhisperM8 auf anderen Rechnern laufen. Die Anhänge aller
Mitglieder lassen sich in einer Abfrage lesen; für den Live-Zustand müsste jede Installation ihre Verknüpfung
bei Zustandswechseln auffrischen.

**Nicht geplant:** ein vollwertiger Ersatz für Linears Oberfläche (Tickets schreiben, Zyklen planen, Projekte
pflegen). Dafür führt „In Linear öffnen“ dorthin.

## Entscheidungen vor dem Bau

| Nr. | Frage | Empfehlung |
|---|---|---|
| E1 | Wo lebt die Ansicht? | Als umschaltbare Ansicht im Agent-Chats-Fenster, so wie der Entwurf sie zeigt und wie der Archiv-Modus heute umschaltet. Der gesamte Code liegt in neuen Dateien. Ausweichweg, falls die Größen-Grenze von `AgentChatsView.swift` (3.720 Zeilen, nur schrumpfend) den Einstieg nicht zulässt: eigenes Fenster über `WindowRequestCenter`. |
| E2 | Wie meldet sich die App bei Linear an? | Zuerst ein API-Key, den der Nutzer in den Einstellungen einträgt; Ablage im Schlüsselbund über `KeychainManager`, gelesen abseits des Main Threads. Eine Anmeldung per Login kommt, wenn die Funktion für andere Nutzer gedacht ist. |
| E3 | Wie oft wird aktualisiert? | Alle 30 Sekunden, nur solange die Ansicht sichtbar ist, dazu ein Knopf „Jetzt aktualisieren“. Verdecktes Fenster oder andere Ansicht: kein Abruf. |
| E4 | Welches Projekt gehört zu welchem Team? | Eine Zuordnung je Projekt in den Einstellungen (Projektordner → Team-Kürzel, optional ein Vorhaben). Ohne Zuordnung zeigt die Ansicht einen Leerzustand mit dem Weg dorthin. |
| E5 | Spalten: echte Status oder Gruppen? | Drei Gruppen nach Art des Status, der echte Statusname steht auf der Karte. DealSupply hätte sonst sieben Spalten. |
| E6 | Wann bauen? | Kern, Quelle und Speicher (Schritte 1 bis 3) sind vom Werkzeug unabhängig und können sofort entstehen. Die Oberfläche (ab Schritt 4) erst nach E1. Fällt am 28.11. die Entscheidung gegen Linear, bleibt alles bis auf die eine Quelle brauchbar. |

## Aufbau

Neue Dateien, nichts davon in `AgentChatsView.swift`:

```
WhisperM8/Models/Tickets/
  Ticket.swift                    Ticket, TicketStatusKind, TicketPerson, TicketChatLink, TicketBoardSnapshot
WhisperM8/Services/Tickets/
  TicketSource.swift              Protokoll: fetchBoard(for:) async throws -> TicketBoardSnapshot
  LinearTicketSource.swift        GraphQL-Abfrage und Übersetzung in die Modelle
  LinearGraphQLClient.swift       ein POST, Fehler und Limit-Kopfzeilen; Sitzung per Closure austauschbar
  TicketBoardFilter.swift         pur: Agent × Person × Vorhaben, Zählungen für die Filter-Knöpfe
  TicketChatResolver.swift        pur: Anhang → Sitzung der App, „Chats ohne Ticket“
  TicketBoardStore.swift          @Observable: Abzug, Ladezustand, letzter Abruf, Fehler, Takt
  TicketProjectMapping.swift      Projektordner ↔ Team (AppPreferences)
WhisperM8/Views/Tickets/
  TicketBoardView.swift           Kopf, Filter, Umschalter Board/Backlog
  TicketBoardColumnsView.swift    Spalten und Karten
  TicketBacklogListView.swift     Liste nach Vorhaben
  TicketDetailPanel.swift         Detail rechts
  TicketLooseChatsBar.swift       Leiste „Laufende Chats ohne Ticket“
  TicketBoardDependencies.swift   Abhängigkeiten mit `.live`, für Snapshots und Tests ersetzbar
WhisperM8/Views/Settings/Pages/
  TicketsSettingsSection.swift    Schalter, API-Key, Zuordnung je Projekt (in der Labs-Gruppe)
```

**Datenfluss:** `TicketBoardStore` fragt die `TicketSource` im Takt, abseits des Main Threads. Das Ergebnis ist
ein unveränderlicher Abzug. `TicketChatResolver` ordnet die Anhänge den Sitzungen des Workspace zu.
`TicketBoardFilter` rechnet daraus, was sichtbar ist. Die Ansichten zeichnen nur.

**Live-Zustand:** Die Karte zeigt den Zustand über `AgentStatusIndicator`, also dieselbe Logik wie Sidebar, Tab
und Kopf. Grün heißt auch hier nur „arbeitet“. Der Zustand kommt aus der App, nie aus Linear.

**Verknüpfung:** Quelle der Wahrheit ist der Anhang am Ticket. Die App legt in Stufe 1 keine eigene Zuordnung
an. So bleiben Skript und App deckungsgleich, und eine zweite Installation sieht dasselbe.

**Werkzeug austauschbar:** Die Oberfläche kennt nur `TicketSource` und die Modelle. Für Jira bräuchte es eine
zweite Quelle, die Verknüpfung läge dort in einem Remote-Link statt in einem Anhang.

## Schritte

Jeder Schritt ist ein Commit mit grüner Suite. Die Schritte 1 bis 3 ändern nichts Sichtbares.

1. **Modelle und pure Logik.** `Ticket`-Typen, `TicketBoardFilter`, `TicketChatResolver`. Tests: Filter in allen
   Kombinationen, Zählungen, Zuordnung von Anhängen (richtiger Chat, fremder Anhang, beendete Verknüpfung, Chat
   nicht mehr vorhanden), „Chats ohne Ticket“.
2. **Quelle für Linear.** `LinearGraphQLClient` und `LinearTicketSource` mit einer festen Antwort als Fixture
   (Abzug vom 14.11.). Tests: Übersetzung aller Felder, Status-Arten, „blockiert“ aus den Beziehungen, Fehlerfälle
   (401, Limit erreicht, Netz weg, unerwartete Antwort). Der Key wird nie geloggt.
3. **Speicher und Takt.** `TicketBoardStore` mit eingespeister Uhr und Quelle. Tests: Abruf nur bei Sichtbarkeit,
   kein doppelter Abruf, Fehler lässt den letzten Abzug stehen und zeigt sein Alter, Wiederanlauf nach Fehler.
4. **Einstellungen.** Schalter `ticketBoardEnabled` (ab Werk aus) in der Labs-Gruppe, Feld für den API-Key,
   Zuordnung je Projekt. Eintrag in `PreferenceBedienweg.swift`, Texte englisch mit deutscher Übersetzung im
   Katalog, Seite in `SettingsNavigation`.
5. **Board.** `TicketBoardView` mit Spalten, Karten und Filtern. Fixture in `UISnapshotGallery` (hell und dunkel,
   mit festem Abzug), rendern und ansehen.
6. **Backlog, Detail, Leiste.** Liste nach Vorhaben, Detail rechts, „Laufende Chats ohne Ticket“. „Zum Chat“ nutzt
   den vorhandenen Weg zum Öffnen einer Sitzung, „In Linear öffnen“ die Adresse des Tickets.
7. **Einstieg im Fenster.** Umschalter Chats/Tickets nach E1, Tastenkürzel, Zustand je Fenster im
   `AgentWindowStore`. Leerzustände: Schalter aus, kein Key, keine Zuordnung, Linear nicht erreichbar.
8. **Doku und Abnahme.** `docs/features/tickets.md`, Verweis in `CLAUDE.md` unter Architektur, Kill-Switch in
   der Liste, Abschnitt im `USER_GUIDE.md` samt Datenschutz (neue Verbindung zu `api.linear.app`).

## Regeln der App, die hier greifen

- **Kein I/O in Ansichten.** Abruf und Entschlüsseln laufen im Speicher, abseits des Main Threads. Karten
  bekommen fertige Werte.
- **Status-Wechsel dürfen das Board nicht neu aufbauen.** Die Karte beobachtet nur den Zustand ihres Chats. Die
  Sidebar beobachtet den `AgentSessionActivityStore` weiterhin nie.
- **Kein Hover-only.** „Kein Agent“, die Person und alle Knöpfe sind ohne Mauszeiger sichtbar. Kein
  `.contextMenu` in Flächen, die bei Statusänderungen neu ausgewertet werden.
- **Keine Dauerbewegung.** Der Puls des Status-Punkts bleibt bei `SoftPulseRing`.
- **Schrift ab 11 pt** für alles, was Information trägt (`ChatsFontSizeGuardTests`).
- **Schlüsselbund abseits des Main Threads** (Vorfall vom 13.11.: ein Schlüsselbund-Dialog fror die App ein).
- **Größen-Grenze:** keine Datei über 1.500 Zeilen, `AgentChatsView.swift` wächst nicht.
- **Lokalisierung:** englische Basis, deutsche Übersetzung, keine Ternär-Literale in `Text`.

## Leistung

- Ein Abruf je 30 Sekunden sind 120 je Stunde bei einem offenen Board, weit unter dem Limit von 2.500.
- Signposts `tickets.fetch` und `tickets.build` in der Stufe `.detail`, Budgets in `PerfBudgets` nach der ersten
  Messung mit `make dev-release`.
- Spalten als `LazyVStack`. Erwartete Größe: 40 bis 300 offene Tickets je Team. Erledigte Tickets werden nicht
  geladen.
- Kostenpunkt, der gemeldet gehört: Der Abzug wird je Abruf neu gebaut. Bei über 300 Tickets wäre der nächste
  Schritt ein Abruf nur der Änderungen (`updatedAt` seit dem letzten Abruf).

## Risiken

| Risiko | Folge | Gegenmittel |
|---|---|---|
| Linear wird nicht das Werkzeug | Quelle für Linear ist umsonst gebaut | `TicketSource` als Grenze; nur eine Datei hängt an Linear |
| Dev-Builds gelten für den Schlüsselbund nach jedem Build als fremde App | Abfrage nach jedem `make dev` oder kein Zugriff auf den Key | derselbe Weg wie bei den Diktat-Keys; Verhalten vor Schritt 4 an einem Dev-Build prüfen. Der Key des Skripts aus Stufe 0 ist ein anderer Eintrag und bleibt davon unberührt |
| Großes Vorhaben „Neustart ohne Chatverlust“ läuft parallel | Konflikte in `AgentChatsView` und im Fenster-Zustand | Schritte 1 bis 6 berühren keine bestehende Datei außer Einstellungen und Katalog; Schritt 7 erst nach Absprache mit dem Sammel-Branch |
| Anhänge werden von Hand geändert oder vom Skript anders geschrieben | Karte zeigt falschen oder keinen Chat | Format in `docs/features/tickets.md` festhalten, Test mit dem Abzug des Skripts |
| Zustand in Linear und Zustand des Chats widersprechen sich (Ticket „Done“, Chat arbeitet) | verwirrende Karte | erledigte Tickets erscheinen nicht; ein Chat an einem erledigten Ticket landet in „Chats ohne Ticket“ mit Hinweis |

## Tests und Abnahme

- **Suite:** pure Typen und Speicher wie oben, Quelle gegen Fixtures, kein Netz in Tests. Abhängigkeiten über
  Closures und kleine Protokolle, Helfer in `AgentTestSupport.swift`.
- **Snapshots:** `make snapshots ONLY=tickets` für Board, Backlog, Detail und die vier Leerzustände, hell und dunkel.
- **Handtest nach `make dev`:**
  1. Schalter an, Key eintragen, Projekt `whisperm8` dem Team `WM8` zuordnen: Board erscheint.
  2. `ticket link` in einem Chat: Karte zeigt den Chat spätestens nach 30 Sekunden, der Punkt folgt dem Zustand
     sofort.
  3. Filter „Ohne Agent“ und „Nicht zugewiesen“ einzeln und kombiniert, Zählungen stimmen mit Linear.
  4. „Zum Chat“ öffnet den richtigen Tab, „In Linear öffnen“ das richtige Ticket.
  5. Netz aus: der letzte Stand bleibt stehen, das Alter ist sichtbar; Netz an: Abruf läuft wieder.
  6. Ansicht verdeckt: im Log kein `tickets.fetch` mehr.
  7. Schalter aus: kein Einstieg sichtbar, keine Verbindung zu Linear.

## Offen

- E1 bis E6 oben.
- Ob der Nutzer die Pflege der Verknüpfungen durch den Supervisor-Chat will (sonst bleibt das Board lückenhaft).
- Für Stufe 2: Ein Chat lässt sich heute per `whisperm8 chats new --project … --title …` anlegen. Wie der Text
  des Tickets als erster Auftrag in den Chat kommt, ist zu klären.
