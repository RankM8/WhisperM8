# Jira in der App: Tickets spiegeln, Chats daraus starten

**Stand:** 10.11.2026 · **Status:** Wunsch mit gefallenen Grundentscheidungen, kein App-Code geändert
**Gehört zu:** [README.md](README.md) · **Vorbild:** Orcas Ansicht „Aufgaben“ ([orca-video.md](orca-video.md), Abschnitt Aufgaben)

## Worum es geht

Jira einmal per API-Token in der App einrichten und danach in WhisperM8 sehen, was ansteht. Aus einem Ticket einen Chat starten, oder ein laufender Chat nimmt sich ein Ticket. Wer was bearbeitet, hält zunächst nur die App fest, nicht Jira. Das soll auch die Zusammenarbeit mit den anderen WhisperM8-Nutzern erleichtern.

## Entscheidungen (Giuliano, 10.11.2026)

1. **Zuweisung an einen Chat ist standardmäßig lokal.** Jira bleibt unberührt, der zuständige Mensch im Ticket wird nie geändert.
2. **Eine sichtbare Marke in Jira ist zuschaltbar.** Wer im Team arbeitet, kann einschalten, dass die App das Ticket in Jira kennzeichnet, damit Kollegen sehen, dass es vergeben ist.
3. **Mehrere Projekte und Boards.** Die Ansicht ist nicht auf ein Jira-Projekt festgelegt.

## Warum die Marke nötig ist

Die lokale Zuweisung reicht für einen einzelnen Nutzer. Sobald zwei Leute mit WhisperM8 am selben Jira-Projekt arbeiten, sieht keiner, was der andere Chat gerade bearbeitet, und zwei Agents können dasselbe Ticket nehmen. WhisperM8 hat keinen gemeinsamen Server, über den sich die Apps abstimmen könnten. Der einzige Ort, den alle sehen, ist Jira. Die Marke ist deshalb kein Komfort, sondern die Voraussetzung dafür, dass das Feature im Team funktioniert.

Zwei Formen kommen in Frage, die Wahl ist noch offen:

| Form | Was in Jira passiert | Für | Gegen |
|---|---|---|---|
| **Label** (etwa `whisperm8-giuliano`) | Ticket bekommt ein Label, beim Freigeben verschwindet es | filterbar, leise, kein Benachrichtigungs-Rauschen | Labels sind in vielen Projekten schon anders belegt; jeder kann sie entfernen |
| **Kommentar** („in Arbeit bei Giuliano, WhisperM8“) | ein Kommentar beim Übernehmen, einer beim Abschluss | für alle lesbar, mit Zeitpunkt, kann PR-Link tragen | löst Benachrichtigungen an Beobachter aus; nicht filterbar |

Empfehlung: Label als Marke, Kommentar nur beim Abschluss und nur, wenn der Nutzer es so einstellt.

## Was Orca an der Stelle hat

Im Code nachgesehen (`src/main/jira/`, Skills `orca-jira` und `jira-tickets`):

- Einrichtung mit Seitenadresse, E-Mail und API-Token, geprüft gegen `/rest/api/3/myself`. Selbst gehostetes Jira geht über `/rest/api/2`.
- Mehrere Jira-Seiten nebeneinander, eine davon aktiv (`jira-sites.json`), Token verschlüsselt je Seite.
- Lesen und schreiben: Suche mit JQL, gespeicherte Filter, Projekte, Tickets anlegen, kommentieren, Status weiterschieben, Anhänge.
- Zwei Zugänge: die Ansicht „Aufgaben“ für den Menschen und `orca`-Befehle samt Skill für die Agents. Aus einem Ticket startet ein Arbeitsbereich mit Agent.
- Der Skill behandelt Ticket-Text, Kommentare und Labels ausdrücklich als nicht vertrauenswürdige Daten, nie als Anweisungen. Das übernehmen wir so.
- Orca schreibt nach Jira zurück: Der Skill sieht einen Abschlusskommentar mit PR-Link und das Weiterschieben des Status vor.

## Was wir schon haben

- Chat aus der App starten, in einem bestimmten Projekt, mit vorgegebenem ersten Auftrag (`whisperm8 chats`).
- Nachricht an einen wählbaren Chat senden, mit Schutz gegen Senden in einen arbeitenden Chat.
- Jarvis-Board mit Ampeln für betreute Chats.
- Schlüsselablage im Keychain.
- Die Agents erreichen Jira heute schon über den Atlassian-Connector. Das native Feature ersetzt das nicht, es gibt dem Menschen die Übersicht und verbindet Ticket und Chat.

## Was neu wäre

1. **Einrichtung:** Seite, E-Mail, Token in den Einstellungen, Token im Keychain, Prüfung beim Speichern. Mehrere Seiten möglich.
2. **Ticket-Ansicht:** eigene Fläche in der App, je Jira-Projekt oder Board, mit Filter („mir zugewiesen“, „offen“, gespeicherte Jira-Filter). Die Zuordnung Jira-Projekt ↔ WhisperM8-Projekt (Ordner) legt der Nutzer einmal fest.
3. **Verknüpfung Ticket ↔ Chat:** Ticket-Nummer am Chat (Sidebar, Tab, Kopf), Chat am Ticket. Ein Ticket kann mehrere Chats haben, ein Chat ein Ticket.
4. **Chat aus Ticket starten:** Titel und Beschreibung werden zum ersten Auftrag, Branch-Name mit Ticket-Nummer.
5. **Chat nimmt sich ein Ticket:** per Befehl aus dem Chat (`whisperm8 chats …`) oder per Klick. Standard lokal, Marke in Jira nur bei eingeschaltetem Schalter.
6. **Anzeige im Jarvis-Board:** Board-Zeilen tragen die Ticket-Nummer. Das Board bleibt die Liste betreuter Chats; die Ticket-Ansicht ist eine eigene Fläche daneben.

## Abgrenzung

- Kein zweites Jira: keine Bearbeitung von Feldern, Sprints oder Workflows in der App. Lesen, verknüpfen, starten, optional markieren.
- Kein Schreiben nach Jira ohne eingeschalteten Schalter.
- Linear und GitHub-Issues wären dieselbe Fläche mit anderer Quelle. Die Ansicht sollte so gebaut sein, dass eine zweite Quelle später dazukommen kann, ohne dass sie jetzt mitgebaut wird.

## Offene Fragen

1. Label oder Kommentar als Marke (siehe Tabelle)?
2. Wo sitzt die Ticket-Ansicht: als Modus der Sidebar (wie das Archiv), als eigener Tab oder rechts im Inspector?
3. Soll ein Chat sein Ticket am Ende selbst weiterschieben dürfen („In Review“), wenn die Marke eingeschaltet ist?

## Aufwand

Mittel. Der Jira-Teil (Anmeldung, Suche, Lesen) ist überschaubar, weil die Schnittstelle stabil und gut dokumentiert ist. Die Arbeit steckt in der neuen Ansicht und in der Verknüpfung, die an drei Stellen sichtbar wird (Sidebar, Tab, Board). Entwurf zuerst im HTML-Zwilling.
