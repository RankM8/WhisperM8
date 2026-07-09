# Claude-Design-Prompt: Agent-Chat-UX fuer WhisperM8

Kopiere den folgenden Prompt direkt in Claude Design.

```markdown
# Agent-Chat-UX fuer WhisperM8 neu durchdenken und visuell polieren

## 0. Lokale Referenzen fuer Claude

Du hast Zugriff auf den Projektordner. Nutze diese Dateien als konkrete Grundlage:

### Visuelle Referenz

- Screenshot 1 / aktuelle Agent-Chat-UI:
  - `/Users/giulianocosta/repos/whisperm8/Dokumentation/assets/agent-chats-reference.png`

### Relevante SwiftUI-Views

- Agent-Chat-Hauptfenster:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Views/AgentChatsView.swift`
- Terminal-Einbettung:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Views/AgentTerminalView.swift`
- Zentrales Dashboard/Settings-Fenster mit Agent-Chats-Einstieg:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Views/SettingsView.swift`
- Output-Dashboard und Reports:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Views/OutputDashboardView.swift`
- Menubar-Einstieg:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Views/MenuBarView.swift`
- App-Window-Szenen:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/WhisperM8App.swift`

### Relevante Modelle und Services

- Agent-Chat-Datenmodell:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Models/AgentChat.swift`
- Agent-Session-Persistenz:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/AgentSessionStore.swift`
- Codex-/Claude-Session-Indexer:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/AgentSessionIndexer.swift`
- Command Builder fuer Codex/Claude:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/AgentCommandBuilder.swift`
- Chat-Launch aus Voice-/Prompt-Modus:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/AgentChatLaunchService.swift`
- Prompt-/Reply-/Task-Routing:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/PromptPackageBuilder.swift`
- Recording-Flow und Verknuepfung zu Agent Chats:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/RecordingCoordinator.swift`
- Window-Routing:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Services/WindowRequestCenter.swift`
- Output-Modi, inklusive Prompt/Chat/Task:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Models/OutputMode.swift`
- Templates fuer Prompt/Chat/Task:
  - `/Users/giulianocosta/repos/whisperm8/WhisperM8/Models/PostProcessingTemplate.swift`

### Tests als Funktionsuebersicht

- Agent-Chat-Tests:
  - `/Users/giulianocosta/repos/whisperm8/Tests/WhisperM8Tests/AgentChatsTests.swift`
- Output-/Prompt-/Report-Tests:
  - `/Users/giulianocosta/repos/whisperm8/Tests/WhisperM8Tests/OutputDashboardTests.swift`

Nutze diese Referenzen, um die aktuelle Architektur, sichtbare UI, vorhandene Funktionen und den geplanten Kontext-Workflow wirklich zu verstehen. Entwirf danach ein UX-Konzept, das direkt in dieser bestehenden SwiftUI-App umsetzbar ist.

## 1. Ziel

Entwickle ein vollstaendig durchdachtes, modernes und produktionsreifes UX-Konzept fuer die bestehende Agent-Chat-Oberflaeche von WhisperM8.

Die aktuelle UX aus Screenshot 1 ist die verbindliche Ausgangsbasis. Alle sichtbaren Funktionen sollen erhalten bleiben, aber klarer strukturiert, besser priorisiert, visuell hochwertiger gestaltet und fuer taegliche Entwicklerarbeit ergonomischer gemacht werden.

Wichtig: Es soll keine Marketing-Landingpage entstehen. Es geht um ein echtes, dichtes Developer-Workspace-Tool fuer Codex-, Claude- und Projekt-Sessions.

Zentrale Produktidee: WhisperM8 ist gleichzeitig Agent-Chat-Dashboard und Transkriptions-/Prompting-Werkzeug. Wenn der Nutzer eine Aufnahme startet, soll der aktuell offene Agent-Chat als Kontext eingefroren werden. Dieser Chat-Kontext wird zusammen mit dem neu diktierten Auftrag an GPT-5 weitergegeben, damit WhisperM8 perfekte Prompts, Antworten oder Folgeaufgaben erstellen kann, die exakt zum aktuellen Arbeitsstand passen.

## 2. Ausgangslage

Screenshot 1 zeigt ein natives Desktop-App-Fenster mit dunklem Theme und drei Hauptbereichen:

- linke Sidebar fuer Projekte, Sessions und globale Aktionen
- mittlerer Arbeitsbereich fuer aktive Agent-Chats mit Tabs und Terminal-/Chat-Verlauf
- rechtes Detailpanel fuer Projekt-, Git-, Arbeitsumgebungs- und Artefaktinformationen

Die Oberflaeche ist bereits funktional und workfloworientiert. Sie wirkt aber noch wie ein erster technischer Prototyp und braucht eine klarere Informationsarchitektur, bessere visuelle Hierarchie, konsistentere Komponenten und bessere Skalierung fuer viele Projekte und viele Chats.

## 3. Zielgruppe und Nutzungskontext

Die Zielgruppe sind Entwicklerinnen und Entwickler, die parallel mit mehreren Repositories, Branches und Agent-Sessions arbeiten.

Typische Nutzung:

- mehrere Projekte im Blick behalten
- Codex- und Claude-Sessions pro Projekt starten, wiederfinden und fortsetzen
- laufende, geschlossene und archivierte Chats unterscheiden
- Terminal-/Agent-Ausgaben lesen
- Prompts schreiben und weiterarbeiten
- Git-Status und Projektkontext schnell pruefen
- direkt in die IDE wechseln, aktuell PHPStorm
- Screenshots, Artefakte und Quellen einem Chat oder Projekt zuordnen
- den aktuell offenen Agent-Chat beim Start einer WhisperM8-Aufnahme als Kontextquelle verwenden
- Chat-Kontext, Screenshots und gesprochene Anweisung zu einem hochwertigen Prompt oder Task-Paket kombinieren

Die UX muss fuer wiederholte, konzentrierte Arbeit geeignet sein: ruhig, kompakt, schnell scanbar, nicht verspielt, nicht marketingartig.

Ein besonders wichtiger Nutzungskontext ist Voice-Prompting waehrend der Agent-Arbeit: Der Nutzer ist in einem Codex- oder Claude-Chat, startet WhisperM8, spricht eine neue Anweisung, und WhisperM8 nutzt automatisch den gerade aktiven Chatverlauf als Kontext. Dadurch versteht GPT-5, wo die Arbeit gerade steht, welche Fehler, Entscheidungen, Dateien, Aufgaben oder Zwischenstaende bereits im Chat passiert sind, und kann daraus einen deutlich besseren naechsten Prompt oder eine bessere naechste Nachricht bauen.

## 4. Bestehende UI-Bereiche

### Linke Sidebar

Die linke Sidebar enthaelt:

- Fenster-/App-Kontext "Hashboard" mit Untertitel "Agent Chats"
- globale Aktionen:
  - "Neuer Codex Chat"
  - "Sessions scannen"
- Bereich "Projekte"
- Projektkarten oder Projektgruppen mit:
  - Projektname, z. B. `giulianocosta`, `heartbeat`, `whisperm8`, `ListM8`
  - Branch- oder Kontextzeile, z. B. `local`, `main`, `codex/agent-chats-sessio...`, `feature/...`
  - Chat-Anzahl pro Projekt
  - Plus-Aktion pro Projekt zum Erstellen eines neuen Chats
- eingerueckte Chat-/Session-Eintraege pro Projekt mit:
  - Provider-Icon oder Statussymbol
  - Chat-Titel, z. B. `Claude Chat`, `Codex Chat`, `heartbeat`
  - Zeitangaben, z. B. `vor 4 m`, `vor 39 m`, `vor 3 Tagen`
  - laufender Statuspunkt bei aktiven Sessions
- untere Aktion:
  - "Projekt hinzufuegen"
  - Refresh-/Reload-Icon

### Hauptbereich

Der Hauptbereich enthaelt:

- Projektkopf mit:
  - Projektname, z. B. `heartbeat`
  - Repo-/Pfadangabe, z. B. `/Users/giulianocosta/repos/heartbeat`
- obere Chat-/Session-Tab-Leiste:
  - mehrere Sessions innerhalb des Projekts
  - Provider-/Status-Icon
  - Chat-Titel
  - Status wie `Running` oder `Closed`
  - aktiver Tab visuell hervorgehoben
- Chat-Header des aktiven Chats:
  - Provider-Icon
  - Chat-Titel, z. B. `Claude Chat`
  - Projektpfad
  - Modellanzeige, z. B. `gpt-5.5`
  - Aktionen:
    - `Restart`
    - `Close Terminal`
    - `Archive`
- Terminal-/Agent-Ausgabe:
  - dunkler Terminalbereich
  - fortlaufende Agent-Ausgaben
  - Befehle, Logs, Hook-Ausgaben, Fehlermeldungen und Zusammenfassungen
  - vertikales Scrollen
- Eingabezeile unten:
  - Prompt-Eingabe
  - der aktive Terminal-/Agent-Kontext bleibt sichtbar

### Rechte Sidebar

Die rechte Sidebar enthaelt:

- Bereich "Projekt"
- Karte "Branch-Details" mit:
  - Projekt
  - Branch
  - Pfad
- Karte "Aenderungen" mit:
  - Anzahl geaenderter Dateien
  - Diff-Zaehler, z. B. `+17 -3`
- Karte "Git-Aktionen" mit:
  - `Status pruefen`
  - `Neuer Codex Chat`
  - `Neuer Claude Chat`
- Karte "Arbeitsumgebung" mit:
  - `PHPStorm oeffnen`
  - aktiver Chat
  - Provider
- Karte "Artefakte & Quellen" mit:
  - Chats
  - Screenshots
  - Modell

## 5. Kernfunktionen

Die neue UX muss mindestens diese Funktionen erhalten und besser organisieren:

- Projektverwaltung
- Projekt hinzufuegen
- Projektliste mit vielen Projekten
- Projektwechsel
- Projektgruppen mit Branch-/Kontextinformationen
- Chat-/Session-Liste pro Projekt
- neuer Codex Chat
- neuer Claude Chat
- Sessions scannen
- mehrere Agenten/Provider innerhalb eines Projekts
- Chat-Tabs im Hauptbereich
- Chat-Status wie `Running`, `Closed`, spaeter ggf. `Pending`, `Failed`, `Archived`
- Terminal-/Agent-Ausgabe lesen
- Prompt-Eingabe im aktiven Chat
- Modellanzeige
- Chat-Aktionen:
  - Restart
  - Close Terminal
  - Archive
- Branch-Details
- Git-Status und geaenderte Dateien
- Git-Aktionen
- IDE-/Arbeitsumgebungsaktion:
  - PHPStorm oeffnen
- aktiver Chat und Provider im Detailpanel
- Artefakte, Quellen, Screenshots und Modellinformationen
- Zeit- und Statusinformationen pro Chat
- Dark Theme als visuelle Grundlage
- aktueller Chat als Kontextquelle fuer WhisperM8-Transkriptionen
- eingefrorener Chat-Kontext pro Aufnahme, damit spaetere Navigation den Kontext nicht veraendert
- Weitergabe des Chatverlaufs an GPT-5 fuer Prompt-, Task- und Reply-Verbesserung

## 6. Workflows

### Workflow: Projekt finden und wechseln

Der Nutzer scannt die linke Sidebar, waehlt ein Projekt aus und sieht sofort:

- welche Chats zu diesem Projekt gehoeren
- welcher Branch aktiv ist
- welche Sessions laufen oder geschlossen sind
- welcher Chat zuletzt aktiv war

### Workflow: Neuen Codex-Chat starten

Der Nutzer kann aus mehreren Stellen einen neuen Codex-Chat starten:

- globale Aktion in der linken Sidebar
- Plus-Aktion am Projekt
- Git-Aktionen im rechten Panel
- Chat-Menue im Hauptbereich

Die UX soll klar machen, in welchem Projekt und mit welchem Provider der neue Chat entsteht.

### Workflow: Neuen Claude-Chat starten

Analog zum Codex-Chat, aber sichtbar als Claude-Provider getrennt. Die UX muss deutlich machen, ob eine Session Codex oder Claude ist.

### Workflow: Bestehenden Chat fortsetzen

Der Nutzer waehlt einen Chat aus. Die App soll:

- den zuletzt bekannten Zustand anzeigen
- den Status klar kommunizieren
- nicht versehentlich eine neue Session starten
- bei geschlossenen Chats eine klare Resume-/Start-Option zeigen
- bei laufenden Chats den laufenden Terminal-/Agent-Kontext erhalten

### Workflow: Zwischen Chats wechseln

Der Nutzer kann zwischen Tabs oder Sidebar-Eintraegen wechseln, ohne den mentalen Kontext zu verlieren.

Wichtig:

- aktive Sessions sollen nicht verschwinden
- Status und Verlauf sollen nachvollziehbar bleiben
- der aktive Chat muss klar markiert sein

### Workflow: Git-Status pruefen

Der Nutzer sieht im rechten Panel:

- Branch
- geaenderte Dateien
- Diff-Zaehler
- Status pruefen als Aktion

Die UX soll zeigen, wann diese Informationen frisch oder eventuell veraltet sind.

### Workflow: In der IDE weiterarbeiten

Der Nutzer klickt `PHPStorm oeffnen`, um das aktive Projekt direkt in der IDE zu oeffnen.

Die Aktion soll klar sichtbar, aber nicht dominanter als der aktive Chat sein.

### Workflow: Viele Projekte und viele Chats verwalten

Die UX muss bei vielen Projekten und vielen Sessions funktionieren:

- gute Scroll- und Gruppierungslogik
- kompakte, aber lesbare Eintraege
- klare aktive Auswahl
- gute Unterscheidung zwischen Projekt, Gruppe und Chat
- Moeglichkeit, relevante laufende Sessions schnell zu finden

### Workflow: Voice-Prompting mit aktuellem Agent-Chat als Kontext

Dieser Workflow ist ein Kernziel der UX und soll besonders gut ausgearbeitet werden.

Ausgangssituation:

- Der Nutzer befindet sich in einem konkreten Agent-Chat, z. B. einem Codex- oder Claude-Chat in einem Projekt.
- In diesem Chat gibt es bereits Verlauf: Prompts, Antworten, Fehler, Terminal-Ausgaben, Entscheidungen, offene Aufgaben oder Zwischenstaende.
- Der Nutzer startet WhisperM8, um eine neue Anweisung zu diktieren.

Erwartetes Verhalten:

- Beim Aktivieren der Transkription wird der gerade offene Agent-Chat als Kontextquelle festgelegt.
- Dieser Kontext wird fuer genau diese Aufnahme eingefroren.
- Wenn der Nutzer waehrend der Aufnahme in einen anderen Chat oder ein anderes Projekt klickt, bleibt trotzdem der urspruenglich beim Start aktive Chat der Kontext dieser Aufnahme.
- Der eingefrorene Chat-Kontext wird gespeichert und im Report/Verlauf nachvollziehbar angezeigt.
- GPT-5 bekommt nicht nur die neue gesprochene Anweisung, sondern auch den relevanten Chatverlauf, damit es weiss, an welcher Stelle der Arbeit der Nutzer gerade ist.

Design-Ziel:

- Die UI soll klar zeigen, welcher Chat gerade als Kontext fuer die laufende Aufnahme verwendet wird.
- Es soll sichtbar sein, ob Chat-Kontext aktiv, eingefroren, fehlt oder nicht verfuegbar ist.
- Der Nutzer soll verstehen: "Meine neue Diktat-Anweisung bezieht sich auf diesen Chat."
- Der Kontext darf nicht versehentlich wechseln, nur weil der Nutzer waehrend der Aufnahme navigiert.

Beispiele fuer moegliche UI-Elemente:

- ein Kontext-Badge im aktiven Chat, z. B. `Context for recording`
- ein Recording-Hinweis, z. B. `Using Claude Chat · heartbeat as context`
- ein kleines Kontextpanel im Report: `Frozen chat context: Claude Chat / heartbeat`
- ein Status im Chat-Header, wenn eine Aufnahme diesen Chat gerade als Kontext verwendet

Dieser Workflow ist der Game Changer: WhisperM8 wird dadurch nicht nur zu einer Transkriptionssoftware, sondern zu einem kontextbewussten Prompting-System fuer Codex und Claude Code.

## 7. UX-Probleme und Verbesserungsziele

Verbessere gezielt:

- die visuelle Hierarchie zwischen Projekt, Chat, Status und Aktionen
- die Scanbarkeit der linken Sidebar
- die Unterscheidung von Projekten und Chats
- die Statuskommunikation fuer laufende, geschlossene, archivierte und fehlerhafte Sessions
- die Lesbarkeit der Chat-Tabs bei vielen Sessions
- die Priorisierung im rechten Detailpanel
- die Auffindbarkeit wichtiger Aktionen
- die Konsistenz von Buttons, Icons, Status-Badges und Panels
- die Balance zwischen dichter Information und ruhiger Oberflaeche
- die Skalierung bei vielen Projekten/Sessions
- die Erkennbarkeit des aktiven Providers
- die Trennung zwischen Navigation, Chat-Arbeitsbereich und Kontextdetails
- die Sichtbarkeit, welcher Chat gerade als Kontext fuer WhisperM8-Aufnahmen verwendet wird
- die Sicherheit, dass der Kontext beim Recording-Start eingefroren und nicht durch Navigation versehentlich geaendert wird
- die Nachvollziehbarkeit, welcher Chatverlauf an GPT-5 fuer Prompt-Verbesserung weitergegeben wurde

## 8. Design-Anforderungen

Erstelle ein hochwertiges Dark-Theme, das auf der bestehenden dunklen UI basiert.

Anforderungen:

- ruhig, professionell, produktiv
- keine Marketing-Aesthetik
- keine Hero-Sektion
- keine dekorativen Gradients, Orbs oder grossen Illustrationen
- kompakte Panels
- klare Trennlinien und Flaechen
- gute Kontraste ohne grelle Ueberladung
- klare aktive Auswahlzustaende
- Provider-Farben nur als Akzent, nicht als komplette Flaechen
- konsistente Icons
- konsistente Button-Hierarchie:
  - primaere Aktion
  - sekundaere Aktion
  - destruktive Aktion
  - neutrale Toolbar-Aktion
- klare Status-Badges fuer Sessions
- hochwertige Terminal-Einbettung mit guter Lesbarkeit

## 9. Interaktionsanforderungen

Definiere Interaktionen fuer:

- Projekt auswaehlen
- Projekt hinzufuegen
- Projektliste aktualisieren
- Session scannen
- Chat aus Sidebar auswaehlen
- Chat aus Tab-Leiste auswaehlen
- neuen Codex-Chat starten
- neuen Claude-Chat starten
- Chat neu starten
- Terminal schliessen
- Chat archivieren
- Git-Status pruefen
- PHPStorm oeffnen
- viele Chat-Tabs horizontal verwalten
- laufende Chats hervorheben
- geschlossene Chats wiederaufnehmen
- Fehlerzustaende anzeigen
- leere Zustaende anzeigen, z. B. kein Projekt oder kein Chat
- aktuellen Chat als Transkriptionskontext aktivieren
- eingefrorenen Recording-Kontext anzeigen
- Kontextquelle nach Aufnahme im Report anzeigen
- klaeren, was passiert, wenn kein Agent-Chat offen ist

## 10. Informationsarchitektur

Schlage eine klare Informationsarchitektur vor:

- globale Ebene:
  - Agent Chats
  - neue Chats
  - Sessions scannen
  - Projekt hinzufuegen
- Projektebene:
  - Projektname
  - Branch
  - Pfad
  - Chat-Anzahl
  - Projektaktionen
- Chat-/Session-Ebene:
  - Provider
  - Titel
  - Status
  - Zeitangabe
  - Modell
  - Aktionen
  - Kontextrolle fuer aktuelle oder letzte WhisperM8-Aufnahme
- Arbeitsbereich:
  - aktiver Chat
  - Chat-/Terminal-Verlauf
  - Prompt-Eingabe
  - sichtbarer Hinweis, wenn dieser Chat als Recording-Kontext eingefroren wurde
- Kontextpanel:
  - Branch-Details
  - Aenderungen
  - Git-Aktionen
  - Arbeitsumgebung
  - Artefakte & Quellen

## 11. Zustaende und Statusanzeigen

Definiere visuelle Zustaende fuer:

- Projekt aktiv
- Projekt inaktiv
- Chat aktiv
- Chat inaktiv
- Chat running
- Chat closed
- Chat pending
- Chat failed
- Chat archived
- Terminal verbunden
- Terminal geschlossen
- Session wird gescannt
- Git-Status wird geladen
- keine Sessions vorhanden
- viele Sessions vorhanden
- Fehler beim Resume
- Fehler beim Starten eines Providers
- Chat-Kontext aktiv fuer laufende Aufnahme
- Chat-Kontext eingefroren fuer Aufnahme
- Chat-Kontext nicht verfuegbar
- Chat-Kontext wurde gespeichert
- Chat-Kontext wurde an GPT-5 weitergegeben

Statusanzeigen sollen klar, kompakt und eindeutig sein. Bitte nicht nur Farbe verwenden, sondern auch Text/Icon-Kombinationen.

## 12. Responsive und skalierbare Layout-Erwartungen

Das Layout soll auf unterschiedlichen Fensterbreiten funktionieren:

- linke Sidebar darf kompakter werden, aber nicht unlesbar
- rechte Sidebar soll bei wenig Breite einklappbar oder priorisierbar sein
- Chat-Tabs muessen bei vielen Sessions scrollbar oder sinnvoll gruppierbar sein
- Terminal-/Chat-Bereich muss die meiste Flaeche erhalten
- keine Ueberlappungen
- keine abgeschnittenen wichtigen Aktionen
- lange Pfade muessen sinnvoll gekuerzt werden
- lange Chat-Titel muessen sinnvoll gekuerzt werden
- Kontext-Badges fuer laufende Aufnahmen duerfen Tabs, Sidebar und Chat-Header nicht ueberladen

## 13. Nicht-Ziele

Bitte nicht:

- keine Marketing-Landingpage entwerfen
- keine Funktionen entfernen
- keine reine optische Skinsammlung liefern
- keine stark dekorative UI
- keine grossen Illustrationen
- keine erfundenen externen Integrationen hinzufuegen
- keine neuen Produktnamen erfinden
- keine unrealistischen Backend-Funktionen voraussetzen
- keine Automatisierungen annehmen, die im Screenshot nicht sichtbar sind

Falls eine Funktion fuer ein gutes Design sinnvoll waere, aber im Screenshot nicht eindeutig belegt ist, markiere sie als Annahme oder optionalen Vorschlag.

Ausnahme: Die Funktion "aktueller Agent-Chat wird beim Start einer WhisperM8-Aufnahme als Kontext eingefroren und an GPT-5 fuer Prompt-Verbesserung weitergegeben" ist eine explizite neue Produktanforderung und soll im Design vollstaendig mitgedacht werden.

## 14. Akzeptanzkriterien fuer das Design-Ergebnis

Das Design-Ergebnis ist gut, wenn:

- alle sichtbaren Funktionen aus Screenshot 1 erhalten bleiben
- die App eindeutig als Developer-/Agenten-Workspace wirkt
- Projekte, Chats und Provider klar unterscheidbar sind
- laufende und geschlossene Sessions sofort erkennbar sind
- die Navigation bei vielen Projekten und Chats skaliert
- der aktive Chat im Hauptbereich eindeutig ist
- Terminal-/Agent-Ausgaben gut lesbar bleiben
- Git- und Projektinformationen rechts klar priorisiert sind
- wichtige Aktionen schnell erreichbar sind
- die UI hochwertig, ruhig und professionell wirkt
- Buttons, Tabs, Badges, Icons und Panels konsistent definiert sind
- der Nutzer jederzeit versteht, welcher Chat als Kontext fuer eine laufende oder gerade abgeschlossene Aufnahme verwendet wird
- der eingefrorene Chat-Kontext als Teil des Prompting-Workflows klar sichtbar und nachvollziehbar ist
- das Design erklaert, wie Chatverlauf, Screenshots und gesprochene Anweisung zusammen zu einem besseren GPT-5-Prompt werden
- das Ergebnis als Grundlage fuer eine spaetere SwiftUI-Implementierung dienen kann

## 15. Gewuenschtes Ergebnis von Claude Design

Bitte liefere:

- eine neu strukturierte UX-Beschreibung
- ein klares Layout-Konzept
- eine Komponentenliste
- ein Design-System fuer Farben, Typografie, Abstaende, Panels, Buttons, Badges und Tabs
- Zustaende fuer Sessions und Provider
- konkrete Verbesserungen fuer Sidebar, Hauptbereich und rechtes Detailpanel
- konkrete Vorschlaege fuer leere Zustaende, Fehlerzustaende und Ladezustaende
- Hinweise, wie die UI bei vielen Projekten und Chats skalieren soll
- einen klaren UX-Flow fuer "aktueller Agent-Chat als eingefrorener Recording-Kontext"
- UI-Vorschlaege fuer Kontext-Badges, Recording-Kontext-Anzeige und Report-Nachvollziehbarkeit
- keine Code-Implementierung, sondern ein vollstaendiges Design- und UX-Konzept
```
