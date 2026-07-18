---
status: abgeschlossen
updated: 2026-07-18
description: Vollständiges Referenzinventar der sichtbaren Funktionen und Erhaltungsinvarianten des Agent-Chats-Subsystems vor den geplanten Refactor-Wellen.
---

# Feature-Inventar Agent Chats

## Zweck und Leseregel

Dieses Dokument beschreibt den Produktstand der Agent-Chats-Hälfte von WhisperM8. Es ist kein Soll-Konzept und keine Qualitätsbewertung, sondern ein Regressions-Oracle: Eine Roadmap-Maßnahme darf die hier belegten Nutzerfunktionen und Invarianten nicht unbeabsichtigt verändern.

- **Einstiegspunkt** nennt den produktiven Einstieg als `Datei:Zeile`; ergänzende Belege folgen bei Bedarf.
- **Sichtbares Verhalten** beschreibt, was ein Nutzer tatsächlich sieht oder auslösen kann.
- **Erhaltungsinvarianten** enthalten auch bewusst ungewöhnliches Verhalten. Ein Punkt ist nicht deshalb entbehrlich, weil er wie ein Bug oder Workaround wirkt.
- **Roadmap-Bezug** ordnet ausschließlich bestätigte Findings `C01–C16`/`N01–N16` und die Maßnahme/Welle aus `05-roadmap/refactor-roadmap.md` zu. „Kein eigener Finding“ bedeutet nicht „unwichtig“, sondern: nur allgemeines Ship-/Regression-Gate.

## 1. Shell, Persistenz, Sidebar, Projekte und Archiv

### AC-01 · Agent-Chats-App-Shell und Fenster-Restore

- **Funktion:** Stellt ein primäres Agent-Chats-Fenster und wertgebundene Sekundärfenster bereit und komponiert Sidebar, Hauptbereich, Tab-Leiste und Projekt-Inspector.
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:30`, `WhisperM8/WhisperM8App.swift:116`, `WhisperM8/Views/AgentChatsView.swift:439`.
- **Sichtbares Verhalten:** Das Primärfenster ist die Hauptszene; abgelöste Tabs öffnen eigene Fenster und werden nach einem Neustart wiederhergestellt. Ein ungültiges Restore-Fenster schließt sich, statt einen leeren Geisterzustand zu zeigen.
- **Erhaltungsinvarianten:** Genau ein Primärfenster; unbekannte Sekundärfenster-IDs erzeugen keinen neuen Store-Zustand; ein Tab gehört global höchstens einem Fenster; persistierter Restore darf beim programmatischen Schließen nicht als Nutzerlöschung fehlinterpretiert werden (`WhisperM8/Models/AgentUIState.swift:699`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:884`).
- **Roadmap-Bezug:** `C11`, `C14`, `C15`; Welle 1 `P1.7`, Welle 3 `P1.5+P1.8`/`P1.10`, Welle 4 `P2.7`. Das Multi-Window-Verhalten ist explizites Ship-Gate jeder betroffenen Welle.

### AC-02 · Getrennte Domain- und UI-Persistenz

- **Funktion:** Persistiert Projekte/Sessions in `AgentSessions.json` und Fenster/Tabs/Pins/Grid in `agent-ui-state.json` über getrennte Schemata.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentWorkspaceRepository.swift:16`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:29`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:61`.
- **Sichtbares Verhalten:** Chats, Projekte, Fenster, Tabs, Pins, Disclosure-Zustände und Workspaces überleben App-Neustarts; Domainänderungen erscheinen ohne manuelles Reload in allen Fenstern.
- **Erhaltungsinvarianten:** Ein Store-Kern pro standardisiertem Produktionspfad; Domain-Mutationen sind lock-serialisiert und diff-gated; Produktionswrites sind debounced, atomar und spätestens nach zwei Sekunden Dirty-Zeit fällig; `willTerminate` drainiert Domainwrites und flusht den UI-Sidecar; Runtime-Status bleibt absichtlich ephemer (`WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:117`, `WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:207`, `WhisperM8/Models/AgentChat.swift:112`).
- **Roadmap-Bezug:** `C11`, `C14`, `N05`; Welle 1 `R2.3` und `P1.7`, Welle 3 `P1.10`, Welle 4 `P2.3`. Future-Schema muss read-only bleiben; unbekannte Daten dürfen nicht still überschrieben werden.

### AC-03 · Sidebar-Scope, Suche und Layout

- **Funktion:** Zeigt den Chat-Bestand wahlweise als „Aktiv“, „Zuletzt“ (sieben Tage) oder „Alle“ und wahlweise projektgruppiert oder flach.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:7`, `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:45`, `WhisperM8/Views/AgentChatsView.swift:1016`.
- **Sichtbares Verhalten:** Laufende und offene Chats sind im Aktiv-Scope sichtbar; „Zuletzt“ ergänzt kürzlich aktive Chats; Suche überstimmt den Scope und findet Projektname, Pfad, Titel, Provider und Gruppenname. Die flache Liste ist projektübergreifend nach Aktivität sortiert.
- **Erhaltungsinvarianten:** Sidebar bedeutet Bestand, Tab-Leiste bedeutet aktuell geöffnet; nur manuell erstellte, nicht archivierte Sessions erscheinen regulär; gepinnte Sessions erscheinen exklusiv in ihrer eigenen Sektion; laufende Sessions dürfen durch keinen Scope verschwinden (`WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:65`, `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:107`). Die eager `VStack`-Darstellung ist ein bewusster Workaround gegen den früheren `LazyVStack + .draggable`-Freeze (`WhisperM8/Views/AgentChatsSidebarViews.swift:193`).
- **Roadmap-Bezug:** `C15`; Welle 3 `P1.5+P1.8`, Welle 4 `P2.7`. Eine Virtualisierung darf den dokumentierten Drag-Freeze nicht wieder einführen.

### AC-04 · Gepinnte Chats, Unread und Live-Status pro Row

- **Funktion:** Hält eine globale Pin-Reihenfolge, Unread-Markierungen und pro Session abonnierte Runtime-Indikatoren für Sidebar und Tabs.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:303`, `WhisperM8/Views/AgentChatsSidebarViews.swift:651`, `WhisperM8/Views/AgentChatChromeViews.swift:104`.
- **Sichtbares Verhalten:** Gepinnte Chats stehen unabhängig vom Scope oben; Rows/Tabs zeigen `working`, `awaitingInput`, `idle`, Fehler und Subagent-Fortschritt, ohne dass jede fremde Statusänderung die ganze Shell neu rendert.
- **Erhaltungsinvarianten:** Archivierte/unbekannte Pins fallen heraus; Pin-Reihenfolge bleibt stabil; per-Session-Publisher deduplizieren gleiche Werte; Mehrfachauswahl und aktive Auswahl bleiben visuell unterscheidbar.
- **Roadmap-Bezug:** `C14`, `C15`; Welle 1 `P1.7`, Welle 3 `P1.5+P1.8`. Status- und Unread-Sichtbarkeit sind Regression-Gates, keine austauschbare Dekoration.

### AC-05 · Projekt hinzufügen, auswählen und als Startkontext verwenden

- **Funktion:** Fügt per Verzeichnisauswahl ein manuelles Projekt hinzu und macht es zum Ziel für neue Chats und den Inspector.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:9`, `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:29`.
- **Sichtbares Verhalten:** „Projekt hinzufügen“ öffnet einen Ordner-Picker; das Projekt wird selektiert, aufgeklappt und als Standardprojekt gemerkt. Ein Projekt-Header klappt nur seine Chatgruppe auf/zu und verändert weder Tabs noch aktive Session.
- **Erhaltungsinvarianten:** Auto-importierte Pseudo-Projekte werden nicht als manuelle Sidebar-Projekte behandelt; der Projektpfad bleibt die cwd-Quelle für Launch, Resume, Git und Transcript-Lookup.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; betroffen von Welle 3 `P1.5+P1.8` und Welle 4 `P2.2`. Projekt-/Auswahlverhalten muss in der manuellen Multi-Window-QA gleich bleiben.

### AC-06 · Projektmetadaten, Icons, Sortierung und Öffnen

- **Funktion:** Unterstützt Umbenennen, Farbe, manuelles Icon, Repo-Icon-Autoerkennung, Drag-Reorder sowie Öffnen in Finder oder PhpStorm.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:82`, `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:95`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:358`, `WhisperM8/Views/AgentChatsView.swift:2743`.
- **Sichtbares Verhalten:** Projekte besitzen Farbe/Initial oder Bild; Nutzer können ein Bild wählen, Autoerkennung erneut ausführen, die Reihenfolge ziehen und ein Projekt im gewählten Ziel öffnen.
- **Erhaltungsinvarianten:** Benutzer-Icon hat Vorrang vor Auto-Icon; fehlende Bilddatei fällt sauber zurück; Auto-Scan läuft nur für manuelle, noch nicht geprüfte Projekte off-main; Drag schreibt vollständige `sortIndex`-Reihenfolgen. Das PhpStorm-CLI-Binary wird bevorzugt, damit genau das Projektfenster fokussiert wird.
- **Roadmap-Bezug:** `C13`; Welle 1 `P1.6` für asynchronen, stale-sicheren Git-/Inspector-Pfad; Welle 4 `P2.7` für Launcher-Parität.

### AC-07 · Projekt löschen ohne externe Arbeitsdaten zu löschen

- **Funktion:** Entfernt nach Bestätigung Projekt und lokale Session-Metadaten und räumt die zugehörigen UI-Referenzen auf.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+ProjectManagement.swift:52`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:482`.
- **Sichtbares Verhalten:** Laufende PTYs des Projekts werden beendet; Tabs, Pins, Disclosure und Auswahl verschwinden. Das Repository und externe Claude-/Codex-Transcripts bleiben auf der Platte.
- **Erhaltungsinvarianten:** `~/.claude/`, `~/.codex/` und das Projektverzeichnis sind read-only aus Sicht dieser Aktion; ein fehlgeschlagener Store-Delete darf UI-Referenzen nicht vorauseilend entfernen.
- **Roadmap-Bezug:** `C11`; Welle 3 `P1.10`, Welle 4 `P2.3`. Externe Daten-Schutzleitplanke der Roadmap gilt zwingend.

### AC-08 · Archiv als Sidebar-Modus mit Wiederherstellung

- **Funktion:** Archiviert Chats mit Zeitstempel und zeigt sie in einer eigenen, durchsuchbaren Sidebar-Ansicht nach Projekten gruppiert.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Tabs.swift:98`, `WhisperM8/Views/AgentChatsView+Archive.swift:75`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:272`.
- **Sichtbares Verhalten:** Nicht laufende Chats verschwinden sofort aus Sidebar und Tab-Leiste; bei laufenden PTYs erscheint vor dem Terminieren eine Bestätigung. „Wiederherstellen“ setzt den Chat auf geschlossen, verlässt den Archivmodus, klappt sein Projekt auf und öffnet ihn.
- **Erhaltungsinvarianten:** Sortierung basiert auf `archivedAt`, nicht auf der vom Indexer weiter veränderbaren `lastActivityAt`; Abbrechen behält die Mehrfachauswahl; Pins werden beim Archivieren entfernt. Reine Terminal-Sessions sind nicht archivierbar: Sie werden beendet und endgültig aus dem lokalen Workspace gelöscht, weil sie weder Transcript noch Resume besitzen (`WhisperM8/Views/AgentChatsView+Tabs.swift:98`).
- **Roadmap-Bezug:** Kein eigener C/N-Finding; Welle 3 `P1.5+P1.8` muss Archiv-/Sortiersemantik bewahren. Hartlöschen externer Transcripts ist ausdrücklich kein Bestandteil.

### AC-09 · Session-Typen und lokale Metadaten

- **Funktion:** Modelliert normale Chats, Claude Agent View, Claude Background Chat, Codex-Subagent-Job und normales Terminal in einem gemeinsamen Workspace.
- **Einstiegspunkt:** `WhisperM8/Models/AgentChat.swift:60`, `WhisperM8/Models/AgentChat.swift:225`.
- **Sichtbares Verhalten:** Jeder Typ erhält passende Detailansicht, Launch-/Resume-Fähigkeit, Kontextmenü und Statusdarstellung; Legacy-Sessions bleiben als normale Chats lesbar.
- **Erhaltungsinvarianten:** Terminal hat keine externe ID, Hooks, Auto-Naming oder Resume; Background-Chat benötigt Short-ID; Subagent-Job verwendet eigenes Job-State-Modell; unbekannte neuere `kind`-Werte dürfen beim Decode nicht die ganze Workspace-Datei zerstören (`WhisperM8/Models/AgentChat.swift:83`).
- **Roadmap-Bezug:** `N05`; Welle 1 `R2.3`. Welle 4 `P2.5+P2.6` darf die Typsemantik beim Target-Schnitt nicht verändern.

### AC-10 · Automatische Titel und Session-Zusammenfassungen

- **Funktion:** Erzeugt nach einem echten Turn-Ende automatisch Titel und bei geschlossenen/geöffneten Sessions Zusammenfassungen; erlaubt einen manuellen Neuversuch.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionAutoNamer.swift:259`, `WhisperM8/Services/AgentChats/AgentSessionSummarizer.swift:212`, `WhisperM8/Views/AgentChatsView.swift:2667`.
- **Sichtbares Verhalten:** Generische „Claude/Codex Chat“-Titel werden inhaltlich benannt; ein Nutzer kann Auto-Naming erneut anstoßen; eine vorhandene Zusammenfassung erscheint im Detail/Inspector.
- **Erhaltungsinvarianten:** Manuell vergebene Titel (`titleIsAutoGenerated == false`) werden niemals überschrieben; Auto-Naming verlangt ein erfasstes Turn-Ende; Headless-Hilfsläufe dürfen ihrerseits keine sichtbaren importierbaren Sessions erzeugen.
- **Roadmap-Bezug:** `C05`, `C06`, `N09`; Welle 1 `P0.4a` und `P1.1`, Welle 3 `P0.4b`. Prävention vor Bestandsmigration; legitime Root-Projekt-Sessions bleiben erhalten.

## 2. Tabs, Mehrfachauswahl, Drag-and-drop und Fenster

### AC-11 · Tab öffnen, schließen und PTY weiterlaufen lassen

- **Funktion:** Trennt Tab-Lifecycle vom Session-/Prozess-Lifecycle.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Tabs.swift:70`, `WhisperM8/Views/AgentChatsView+Tabs.swift:78`, `WhisperM8/Views/AgentTerminalView.swift:322`.
- **Sichtbares Verhalten:** Ein Sidebar-Klick öffnet den Tab; Schließen entfernt nur den Tab. Ein laufender Agent arbeitet weiter und bleibt über den Sidebar-Status sichtbar; erneutes Öffnen zeigt denselben Controller und Scrollback.
- **Erhaltungsinvarianten:** Kein Laufzeit-Cap für offene Tabs; Load-Pruning darf begrenzen/reparieren; Schließen darf weder Session archivieren noch PTY terminieren. Der aktive Nachbar-Fallback ist Teil der vorgesehenen UX, auch wenn View- und Store-Implementierung derzeit auseinanderdriften.
- **Roadmap-Bezug:** `C10`, `C14`, `N01`; Welle 1 `P1.7`, Welle 2 `R2.5` und `P0.7+P1.12`, Welle 4 `P2.1+P2.2`.

### AC-12 · Browser-/Finder-artige Mehrfachauswahl

- **Funktion:** Unterstützt Plain-, Cmd- und Shift-Klicks für Tabs und Sidebar-Rows.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Tabs.swift:9`, `WhisperM8/Views/AgentTabSelection.swift:15`.
- **Sichtbares Verhalten:** Plain-Klick aktiviert einzeln; Cmd toggelt Gruppenmitglieder; Shift wählt einen Bereich. Modifier-Klicks in der Sidebar wählen für Bulk-Aktionen, ohne ungefragt einen Tab zu öffnen.
- **Erhaltungsinvarianten:** Aktiver Tab ist der Bereichsanker; Mehrfachauswahl ist leer oder enthält mindestens zwei IDs; sie ist ephemer, aber pro Fenster im Store gehalten, damit Cross-Window-Drops die Quellauswahl live lesen können.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; Welle 3 `P1.5+P1.8` und Welle 4 `P2.7`. Multi-Select ist manuelles Regression-Gate.

### AC-13 · Bulk-Aktionen

- **Funktion:** Wendet Archivieren, Gruppieren, Pin-/Farb-/Projektaktionen und „Workspace aus Auswahl“ auf die aktive Mehrfachauswahl an.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+BulkActions.swift:4`, `WhisperM8/Views/AgentChatsView+BulkActions.swift:44`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:339`.
- **Sichtbares Verhalten:** Kontextmenüs zeigen count-abhängige „N Chats“-Labels; eine Einzelaktion wirkt auf den angeklickten Chat, wenn er nicht Teil der Auswahl ist.
- **Erhaltungsinvarianten:** Auswahl wird erst nach erfolgreicher/destruktiv bestätigter Aktion geleert; Terminal-Sessions werden beim gemischten Archiv-Bulk getrennt entfernt statt archiviert; Workspace-Erstellung nimmt höchstens die ersten neun Tabs in Tab-Reihenfolge.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; Welle 4 `P2.2` darf die Gruppensemantik beim Herauslösen der View-Logik nicht verändern.

### AC-14 · Tab-Reorder und Cross-Window-Move

- **Funktion:** Verschiebt einzelne oder ausgewählte Tabgruppen lokal und zwischen Fenstern.
- **Einstiegspunkt:** `WhisperM8/Views/AgentTabReorderDrop.swift:14`, `WhisperM8/Views/AgentChatsView+Tabs.swift:180`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:171`.
- **Sichtbares Verhalten:** Eine Einfügelinie zeigt die Drop-Position; ein Sidebar-Chat kann durch Drop direkt an dieser Stelle geöffnet werden; Cross-Window-Drop verschiebt statt kopiert.
- **Erhaltungsinvarianten:** Gruppen behalten ihre relative Reihenfolge; ein Tab ist nach dem Move nur im Zielfenster; Payload- und Drop-Auswertung dürfen einen veralteten Drag ohne Mutation ablehnen; `.leftMouseUp` räumt eine hängengebliebene Einfügelinie.
- **Roadmap-Bezug:** `C14`; Welle 1 `P1.7`, Welle 4 `P2.7`. Cross-Window-DnD ist explizites manuelles QA-Gate.

### AC-15 · Tear-off in ein neues Fenster

- **Funktion:** Löst einen Tab oder eine ausgewählte Gruppe aus dem Quellfenster in ein neues Agent-Chats-Fenster.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Tabs.swift:199`, `WhisperM8/Views/AgentChatsView+Tabs.swift:218`.
- **Sichtbares Verhalten:** Drop auf den Content-Bereich beziehungsweise „in neues Fenster“ öffnet genau ein neues Fenster; alle ausgewählten Tabs ziehen gemeinsam um; laufende PTYs bleiben bestehen.
- **Erhaltungsinvarianten:** Gruppenreihenfolge bleibt erhalten; Quell-Multiselection wird geräumt; Auswahl wird live aus dem Quellfenster gelesen statt im Drag-Payload eingefroren; PTY-Identität ist session-ID-basiert und überlebt NSView-Reparenting.
- **Roadmap-Bezug:** `C10`, `N01`; Welle 2 `R2.5`/`P0.7+P1.12`, Welle 4 `P2.1+P2.2`.

### AC-16 · Fenster- und Tab-Shortcuts

- **Funktion:** Bietet Ctrl-Tab-Switcher, Cmd-N, Cmd-W, direkte Tab-Navigation, Grid-Fokus und Trackpad-/Scroll-gestützten Tabwechsel.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Shortcuts.swift:32`, `WhisperM8/Views/AgentChatsView+Shortcuts.swift:85`, `WhisperM8/Views/TabNavShortcut.swift:1`.
- **Sichtbares Verhalten:** Shortcuts gelten nur im konkreten Hostfenster und respektieren Terminal-First-Responder-/Modifier-Konflikte.
- **Erhaltungsinvarianten:** Pro Fenster werden fünf NSEvent-Monitore idempotent installiert und symmetrisch entfernt; Events anderer Fenster werden nicht konsumiert; Command+Option-Pfeile bleiben für Tabwechsel frei.
- **Roadmap-Bezug:** `C10`, `C15`; Welle 2 `P0.7+P1.12`, Welle 3 `P1.10`, Welle 4 `P2.7`.

## 3. Grid-Workspace

### AC-17 · Persistierte Workspace-Entity und positionsstabile Slots

- **Funktion:** Speichert benannte, farbige Gruppen von zwei bis neun Session-Referenzen mit eigenem Split-Layout.
- **Einstiegspunkt:** `WhisperM8/Models/AgentGridWorkspace.swift:3`, `WhisperM8/Models/AgentGridWorkspace.swift:30`, `WhisperM8/Models/AgentUIState.swift:113`.
- **Sichtbares Verhalten:** Workspaces erscheinen in eigener Sidebar-Sektion und behalten Mitglieder, Slotpositionen, Farbe, Name, Reihenfolge und Splitgrößen über Neustarts.
- **Erhaltungsinvarianten:** Array-Reihenfolge ist Sidebar-Reihenfolge; doppelte Namen sind erlaubt; Entfernen/Archivieren setzt einen Slot auf `nil`, nichts kompaktisiert; dieselbe Session darf in mehreren Workspaces, aber nie doppelt im selben Workspace liegen; Decoder-Defaults dürfen niemals wegen eines fehlenden neuen Keys den gesamten UI-State verwerfen.
- **Roadmap-Bezug:** Kein eigener C/N-Finding. Welle 1 `R2.3` schützt Future-Schema; Welle 3 `P1.5+P1.8` nennt Grid/Workspace ausdrücklich als Multi-Window-Regressionsfläche.

### AC-18 · Workspace-Sidebar, Create, Rename, Farbe, Reorder und Delete

- **Funktion:** Verwaltet Workspace-Entities über einen einklappbaren Sidebar-Abschnitt und Kontextmenüs.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Workspaces.swift:14`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:266`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:253`.
- **Sichtbares Verhalten:** Plus erzeugt einen leeren Workspace und öffnet ihn; Header zeigt Belegung/Kapazität; Nutzer können umbenennen, einfärben, ziehen und löschen. Löschen beendet keine Chats und schließt keine Tabs.
- **Erhaltungsinvarianten:** Reorder mit stale Payload darf keine Entity löschen; Delete räumt alle Fensterreferenzen in einer Mutation und flusht sofort; leere Namen/Farben werden normalisiert; ein Workspace darf leer und dennoch sichtbar/öffnbar sein.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; Welle 3 `P1.5+P1.8`, Welle 4 `P2.3`. UI-Sidecar- und Multi-Window-Gates gelten.

### AC-19 · Slot-Aufnahme, Drop, Move und Swap

- **Funktion:** Nimmt Chats per Sidebar-/Tab-/Pane-Drag in Slots auf und unterstützt Verschieben, Ersetzen und Tauschen.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:342`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:353`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:425`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:121`.
- **Sichtbares Verhalten:** Drop auf Gruppe nutzt den ersten freien Slot und wächst bei Bedarf; Drop auf konkrete Pane platziert dort. Pane-Header-Drag hat Move/Swap-Semantik, Sidebar-Row-Drag Add/Place-Semantik.
- **Erhaltungsinvarianten:** Unbekannte/archivierte Sessions werden abgewiesen; Membership-Änderung erfolgt vor einer optionalen Tabübernahme; bei belegter Zielpane und bestehender Mitgliedschaft bleibt der im genehmigten HTML-Prototyp festgelegte Swap erhalten. Grow-Zone erscheint nur, wenn keine Slot-Zone getargetet ist, damit sie die Pane nicht unter dem Cursor verschiebt (bewusst erhalten aus Commit `ddb1727`).
- **Roadmap-Bezug:** Kein eigener C/N-Finding; allgemeines Welle-3-Multi-Window-Gate. DnD-Interaktion bleibt manuelle QA.

### AC-20 · Kapazitäten 2/3/4/6/9 und Split-Griffe

- **Funktion:** Bietet stufenweise Grid-Geometrien und persistierbare Spalten-/Zeilenanteile.
- **Einstiegspunkt:** `WhisperM8/Models/AgentGridWorkspace.swift:32`, `WhisperM8/Models/AgentGridWorkspace.swift:37`, `WhisperM8/Views/AgentGridSplitContainer.swift:16`, `WhisperM8/Views/GridSplitResolver.swift:48`.
- **Sichtbares Verhalten:** Layouts sind 1×2, „2 oben + 1 breit“, 2×2, 3×2 und 3×3; Griffe ändern Größen live und committen beim Drag-Ende. Schrumpfen mit belegten abgeschnittenen Slots verlangt eine genaue Bestätigung.
- **Erhaltungsinvarianten:** Fractions sind positiv, endlich, passend lang und auf Summe 1 normalisiert; Mindestpane-Größe wird über denselben geclamp-ten Vektor für Layout und Drag-Basis eingehalten; `floor` schützt die Restspur. Fokus fällt nach Shrink vom alten Index auf den nächsten, sonst vorherigen belegten eigenen Slot. Die Kapazitäten 6/9 bleiben bewusst ohne automatisches Benchmark-Gate aktiv; Signposts plus manuelle QA sind die beschlossene Absicherung (`ddb1727`, `36f09c2`).
- **Roadmap-Bezug:** Kein eigener C/N-Finding; Welle 3 `P1.5+P1.8` verlangt Messwerte, allgemeines Ship-Gate 4 verlangt Vorher/Nachher-Messung.

### AC-21 · Single-Owner-Aktivierung und fremd gehostete Slots

- **Funktion:** Aktiviert einen Workspace in genau einem Fenster, ohne Tabs/Terminals anderer Fenster still zu stehlen.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:504`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:303`.
- **Sichtbares Verhalten:** Ist der Workspace bereits in einem anderen Fenster aktiv oder als Rücksprungziel gebunden, wird dieses Fenster fokussiert. Fremd gehostete Slot-Chats erscheinen als Übernahme-Platzhalter; der Workspace bleibt trotzdem öffnbar.
- **Erhaltungsinvarianten:** Aktivierung blockiert **nie** allein wegen Tab-Ownership; Fremd-Tabs werden nicht materialisiert; nur expliziter Transfer übernimmt sie. Jeder vorhandene Workspace-Besitzer liefert `.alreadyActive`; versteckter Takeover bleibt entfernt. Diese bewusst nach Re-Verifikation festgelegte Semantik aus `ddb1727` und `36f09c2` darf nicht auf eine frühere Block-/Steal-Variante zurückfallen.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; zwingendes Multi-Window-Regressions-Gate von Welle 3 und Ship-Gate 5.

### AC-22 · Pane-Fokus, Einzelansicht und „Zurück zum Workspace“

- **Funktion:** Hält Workspace-Mitgliedschaft und gemerkten Pane-Fokus getrennt von der aktuell sichtbaren Einzel-/Grid-Ansicht.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:544`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:557`, `WhisperM8/Views/AgentChatsView+Grid.swift:142`.
- **Sichtbares Verhalten:** Klick auf einen sichtbaren Slot fokussiert die Pane; Klick auf einen Nicht-Slot öffnet Einzelansicht; „Zurück“ stellt Workspace und zuletzt betrachtete Pane wieder her. Ein tabloser eigener Slot wird beim Navigieren atomar materialisiert.
- **Erhaltungsinvarianten:** Slots bleiben bei Navigation unverändert; `selected` hat bei Reaktivierung bewusst Vorrang vor einem älteren remembered focus; ein sichtbares leeres Grid darf `selectedSessionID == nil` halten; Fokus-Fallback bevorzugt renderbare eigene Slots. Dictation darf nur die tatsächlich fokussierte/sichtbare Agent-Session erben, nicht einen Header-Fallback aus einem leeren Grid.
- **Roadmap-Bezug:** `N11` berührt das Ziel-Routing; Welle 2 `R2.6`. Außerdem allgemeines Welle-3-Grid-/Multi-Window-Gate.

### AC-23 · Grid-Streaming und Fokus-Performance

- **Funktion:** Drosselt Terminal-Feeds nicht fokussierter Panes und misst Grid-Build/Fokuswechsel über Performance-Signposts.
- **Einstiegspunkt:** `WhisperM8/Views/TerminalFeedBatcher.swift:18`, `WhisperM8/Services/Shared/GridPerformanceTracker.swift:4`, `WhisperM8/Views/AgentChatsView+Grid.swift:887`.
- **Sichtbares Verhalten:** Fokussierte Pane bleibt responsiv; Hintergrundpanes aktualisieren gebündelt, ohne Output zu verlieren; beim Fokuswechsel wird ausstehender Output geflusht.
- **Erhaltungsinvarianten:** FIFO, genau ein geplanter Flush, 256-KiB-High-Water; ersetzte/entfernte Panes und Workspace-Wechsel dürfen nicht gedrosselt zurückbleiben; Teardown, Dismantle und `focusTerminal` fluschen. Fokus-Messcallbacks sind sessiongebunden, stale Callbacks beenden keine neue Messung (`ddb1727`).
- **Roadmap-Bezug:** `C10`, `C15`; Welle 2 `P0.7+P1.12`, Welle 3 `P1.5+P1.8`/`P1.10`.

## 4. Foreground-PTY, Links, Tastatur, Resume und Fork

### AC-24 · Providerabhängiger Foreground-Launch

- **Funktion:** Baut und startet echte Claude-, Codex- oder Login-Shell-Kommandos im SwiftTerm-PTY.
- **Einstiegspunkt:** `WhisperM8/Views/AgentSessionDetailView.swift:382`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:156`, `WhisperM8/Views/AgentTerminalView.swift:345`.
- **Sichtbares Verhalten:** Neue Chat-/Terminal-Tabs starten automatisch; Login-PATH und Binary werden off-main vorgewärmt; Fehler erscheinen im Detail statt als unsichtbarer Prozess.
- **Erhaltungsinvarianten:** Alle Subprozesse nutzen die korrigierte Login-Shell-Umgebung; vor einem verspäteten Warmup-Abschluss wird Session-Existenz/Archivstatus erneut geprüft; Registry dedupliziert Starts pro lokaler Session-ID; Terminals laufen als `SHELL -i -l` im Projektverzeichnis.
- **Roadmap-Bezug:** `C10`, `N01`, `N09`; Welle 1 `P1.1`, Welle 2 `R2.5`/`P0.7+P1.12`, Welle 4 `P2.1+P2.2`.

### AC-25 · PTY-Registry, Scrollback und NSView-Reparenting

- **Funktion:** Hält Controller und Terminal-NSView unabhängig vom SwiftUI-View-Lifecycle am Leben.
- **Einstiegspunkt:** `WhisperM8/Views/AgentTerminalView.swift:322`, `WhisperM8/Views/AgentTerminalView.swift:614`, `WhisperM8/Views/AgentTerminalView.swift:1019`.
- **Sichtbares Verhalten:** Tabwechsel, Grid/Einzelansicht, Tear-off und SwiftUI-Remount erhalten Prozess und Scrollback; maximierte/verschobene Panes adoptieren dieselbe Terminal-NSView.
- **Erhaltungsinvarianten:** Höchstens ein Controller und eine Terminal-NSView pro lokaler Session; `dismantleNSView` beendet den Prozess nicht; Container heilt verlorenes Reparenting; natürlicher Exit behält derzeit den Controller für Scrollback, explizites Stoppen entfernt ihn.
- **Roadmap-Bezug:** `C10`, `N01`; Welle 2 `R2.5`/`P0.7+P1.12`, Welle 4 `P2.1+P2.2`.

### AC-26 · Terminal-Keyboard-Profile

- **Funktion:** Übersetzt macOS-Tastenkombinationen TUI-spezifisch in Control-Sequenzen.
- **Einstiegspunkt:** `WhisperM8/Views/AgentTerminalView.swift:404`, `WhisperM8/Views/AgentTerminalView.swift:448`.
- **Sichtbares Verhalten:** Option-Backspace löscht Wort, Cmd-Backspace Zeile, Cmd-Z macht Readline-Undo, Option-Pfeile springen wortweise. Shift-Enter erzeugt in Claude/Codex `\`+CR, in Agent View CSI-u und bleibt in der normalen Shell ein normales Enter. Option-P schaltet nur in Agent-TUIs das Modell.
- **Erhaltungsinvarianten:** Ctrl-Combos werden nicht durch Cmd-Mappings überschrieben; Cmd+Option-Pfeile bleiben für App-Tabnavigation; Plain Shell erhält keine Agent-spezifischen Mappings; Profilwahl folgt dem tatsächlichen Session-Typ.
- **Roadmap-Bezug:** `C10`; Welle 2 `P0.7+P1.12`. SwiftTerm-Rebase darf diese Byte-Matrix nicht verändern.

### AC-27 · Terminal-Link-Klicks

- **Funktion:** Fängt SwiftTerm-Link-Klicks über einen Delegate-Proxy ab und routet Web, Dateien, Ordner und `path:line[:column]`.
- **Einstiegspunkt:** `WhisperM8/Views/AgentTerminalLinkInterceptor.swift:20`, `WhisperM8/Views/TerminalLinkResolver.swift:49`, `WhisperM8/Views/AgentTerminalView.swift:917`.
- **Sichtbares Verhalten:** Weblinks öffnen im Browser; Code-/Textdateien bevorzugt in PhpStorm; sonstige Dateien in Standard-App; Ordner im Finder; Option-Klick zeigt das Ziel im Finder; fehlende Ziele erzeugen klare Rückmeldung.
- **Erhaltungsinvarianten:** Relative Pfade werden gegen Launch-cwd aufgelöst; `~`, Sonderzeichen und Zeilen-/Spaltensuffixe bleiben unterstützt; der Proxy muss alle übrigen TerminalDelegate-Callbacks an die Basis weiterreichen und wegen SwiftTerms schwachem Delegate stark im Controller gehalten werden.
- **Roadmap-Bezug:** Welle 2 `P0.7+P1.12`, Welle 4 `P2.1+P2.2` und `P2.7`; kein eigener C/N-Finding für den Linkpfad.

### AC-28 · Resume-Verträge für Claude und Codex

- **Funktion:** Setzt geschlossene/gestoppte Chats über ihre reale externe Session-ID fort.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:189`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:353`, `WhisperM8/Views/AgentSessionDetailView.swift:537`.
- **Sichtbares Verhalten:** Codex startet `codex resume`; Claude startet `--resume`; der ursprüngliche Prompt wird nicht erneut gesendet. Fehlt ein Claude-Transcript, versucht WhisperM8 genau einen eindeutigen plausiblen Ersatz zu binden und stoppt sonst sichtbar.
- **Erhaltungsinvarianten:** Codex verlangt bei gesetztem Launch-Marker eine externe ID. Claude startet aktuell ohne gebundene ID frisch; die Roadmap will diesen Verlust künftig als Recovery statt stillen Fresh-Start behandeln. Der reale Claude-Transcript-Root schlägt einen veralteten Account-Stempel; Repair darf nie eine fremde Session kapern.
- **Roadmap-Bezug:** `C04`, `C07`, `C09`; Welle 2 `P0.5+P0.6+P1.3+P1.4` (autoritative Bindung). Recovery darf nie still fresh starten.

### AC-29 · Claude-Fork

- **Funktion:** Erzeugt aus einer bestehenden Claude-Session einen neuen abgezweigten Chat.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:84`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:353`.
- **Sichtbares Verhalten:** Der Fork erbt Projekt, Profil und Quellkontext, startet mit `--resume <quelle> --fork-session` und erhält anschließend eine eigene reale Session-ID.
- **Erhaltungsinvarianten:** Fork-Quelle gewinnt nur solange keine eigene externe ID gebunden ist; danach resumiert die Fork-ID. Original bleibt unangetastet; Profilstempel wird von der Quelle geerbt; Hook-`SessionStart` bindet die neue ID.
- **Roadmap-Bezug:** `C07`, `C09`; Welle 2 „Autoritative Session-Bindung“ mit Start/Fork/Resume-Golden-Matrix.

### AC-30 · Terminal-Endsnapshot und Offline-Fallback

- **Funktion:** Speichert den letzten normalen Terminalbuffer als Plaintext-Sidecar und zeigt ihn ohne JSONL-Parsing an.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/TerminalSnapshotStore.swift:14`, `WhisperM8/Views/AgentTerminalView.swift:799`, `WhisperM8/Views/Transcript/TerminalSnapshotView.swift:8`.
- **Sichtbares Verhalten:** Nach Stop, natürlichem Exit oder App-Quit bleibt der letzte Scrollback sichtbar; Anzeige rendert in 50-Zeilen-Chunks.
- **Erhaltungsinvarianten:** Leere Ränder trimmen, höchstens jüngste 2.000 Zeilen, atomarer Sidecar-Write, Formatversion prüfen; Input wird nicht separat aufgezeichnet. Ein kaputter/neuer Sidecar darf langfristig nicht den JSONL-Fallback blockieren.
- **Roadmap-Bezug:** `C10`; Welle 2 `P0.7+P1.12`, Welle 3 `T1` für output-only Recording. Letzte Exit-Bytes müssen genau einmal enthalten sein; stdin/Secrets dürfen nie in ein neues Recording gelangen.

## 5. Claude-Background-Agents und Codex-Subagent-Jobs

### AC-31 · Claude-Background-Dispatch (`--bg`)

- **Funktion:** Erstellt eine lokale Stub-Session, startet einmalig `claude --bg`, bindet die Short-ID und öffnet danach `claude attach` im normalen PTY.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:35`, `WhisperM8/Services/AgentChats/BackgroundAgentSpawner.swift:78`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:315`.
- **Sichtbares Verhalten:** Nutzer gibt Prompt, optional Agent und Permission-Mode an; nach erfolgreichem Spawn erscheint ein attachbarer Background-Chat. Fehler entfernen den nicht nutzbaren Stub.
- **Erhaltungsinvarianten:** Projektpfad/Binary validieren; 30-s-Timeout; Exit 0 plus 6–16 Hex-Zeichen lange ID erforderlich; Stub und Short-ID werden jeweils sofort geflusht; Attach ist unabhängig vom extern unter Claude Supervisor laufenden Job.
- **Roadmap-Bezug:** `C06`, `C08`; Welle 1 `P1.1`, Welle 2 `P1.2` sowie Welle 4 `P2.1+P2.2`.

### AC-32 · Claude-Background-Lifecycle

- **Funktion:** Bietet Logs, Stop, Respawn und Remove über kurzlebige Claude-CLI-Aufrufe sowie Startup-Healthcheck.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/BackgroundAgentLifecycle.swift:79`, `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:128`.
- **Sichtbares Verhalten:** Aktionen erscheinen im Session-Kontext; lokales Archiv/Tab-Close erfolgt erst nach erfolgreichem `claude rm`; unbekannte alte IDs werden beim Startup archiviert, allgemeine Fehler bleiben sichtbar.
- **Erhaltungsinvarianten:** WhisperM8 besitzt keine Agent-PID und darf Attach-Exit nicht als Job-Ende behandeln; nur eindeutig „unknown“ ist Zombie-Nachweis; Lifecycle muss denselben Account-Kontext wie der Spawn verwenden.
- **Roadmap-Bezug:** `C06`, `C08`; Welle 1 `P1.1`, Welle 2 `P1.2` (`claude agents --json --all` primär, `state.json` nur capability-gegateter Fallback).

### AC-33 · Claude Agent View und aktive Background-Anzeige

- **Funktion:** Öffnet das eigenständige `claude agents`-Dashboard und markiert dessen zuletzt aktiven Supervisor-Job.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:298`, `WhisperM8/Services/AgentChats/ActiveBackgroundSessionTracker.swift:52`, `WhisperM8/Services/AgentChats/SupervisorJobReader.swift:98`.
- **Sichtbares Verhalten:** Agent View ist ein eigener TUI-Tab; alle fünf Sekunden wird der innerhalb von 60 Sekunden jüngste Job anhand Transcript-mtime/`updatedAt` als aktiv projiziert.
- **Erhaltungsinvarianten:** Agent View ist Dashboard, kein Chat: keine Resume-ID, keine Hook-Bridge; Attach/Job-Ownership bleibt getrennt. Future-Timestamps und fehlerhafte externe `state.json` müssen kontrolliert degradieren.
- **Roadmap-Bezug:** `C08`; Welle 2 `P1.2`. Offizielle profilbezogene Claude-Schnittstellen sollen Fremdformat-Lesen ablösen, ohne das Dashboard zu entfernen.

### AC-34 · Persistenter Codex-Subagent-Job

- **Funktion:** Implementiert einen eigenen detachten Ein-Turn-Supervisor für `codex exec --json` und `resume`.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentJobState.swift:13`, `WhisperM8/Services/AgentChats/AgentJobSupervisor.swift:59`, `WhisperM8/Services/AgentChats/CodexExecRunner.swift:180`.
- **Sichtbares Verhalten:** Jobs durchlaufen `spawning`, `running`, `done|failed|stopped` oder terminal `takenOver`; Events, letzte Nachricht, Report und State bleiben unter `agent-jobs/<short-id>/` verfügbar.
- **Erhaltungsinvarianten:** Jeder Supervisor bearbeitet genau einen Turn; State-Write ist atomar; erlaubte Übergänge sind zentral; erste Codex-Thread-ID wird früh persistiert; stdout/stderr werden bis EOF plus Prozessende gedraint; Idle-Watchdog begrenzt einen stillen Turn.
- **Roadmap-Bezug:** `N07`, `N08`, `N12`, `N13`, `N14`; Welle 1 `R2.4`, Welle 2 `R2.7`. Supervisor/Turn-Vertrag und State-CAS sind P0-Regressionsflächen.

### AC-35 · `whisperm8 agent`-CLI

- **Funktion:** Steuert Codex-Jobs headless mit `run`, `send`, `list`, `status`, `wait`, `logs`, `stop` und `rm`.
- **Einstiegspunkt:** `WhisperM8/CLI/AgentCLICommand.swift:46`, `WhisperM8/CLI/AgentCLICommand.swift:160`, `WhisperM8/CLI/AgentCLICommand.swift:273`, `WhisperM8/CLI/AgentCLICommand.swift:729`.
- **Sichtbares Verhalten:** `run` gibt Short-ID/JSON aus und kann mit `--wait` Events verfolgen; `send` startet einen Folgeturn auf demselben Thread; `status/wait` liefern skriptbare Exitcodes; `logs` zeigt Events; `stop/rm` verwalten Lifecycle.
- **Erhaltungsinvarianten:** `--wait` ändert Ownership nicht, sondern pollt den detachten Supervisor; `send` verlangt ruhenden Job plus Thread-ID und claimt per Lock; Prompt-Write-Fehler rollen auf den vorherigen Ruhe-State zurück; `done` mit semantischem Report-Fehler liefert Exit 2; `takenOver` ist nicht mehr per CLI fortsetzbar.
- **Roadmap-Bezug:** `N07`, `N08`, `N12`, `N14`; Welle 1 `R2.4`, Welle 2 `R2.7`. Prozessgruppen-, Stop- und vollständige Turn-Erfolgskriterien müssen erhalten/gehärtet werden.

### AC-36 · Job-Sync, Subagent-Rows und Detailansicht

- **Funktion:** Spiegelt Job-State per FSEvents in den Agent-Workspace und zeigt Parent-Kinder, Fortschritt, Report, Transcript und Composer.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentJobDirectoryMonitor.swift:30`, `WhisperM8/Services/AgentChats/AgentJobWorkspaceSync.swift:82`, `WhisperM8/Views/SubagentJobDetailView.swift:37`, `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift:137`.
- **Sichtbares Verhalten:** Aktive/fehlgeschlagene Kinder bleiben unter dem Parent sichtbar; erfolgreich Fertige wandern in einen aufklappbaren Fuß, ungelesene zuerst. Detail bietet Stop, Folgeturn und Takeover.
- **Erhaltungsinvarianten:** Orphan-Kinder bleiben als normale Projekt-Rows erreichbar; selektiertes fertiges Kind bleibt sichtbar; Fortschrittsbruch zählt terminale inklusive Fehler; rote/grüne/unread Indikatoren bleiben getrennt. Sync-Anforderungen coalescen und Disk-Read läuft off-main.
- **Roadmap-Bezug:** `N12`, `N13`; Welle 2 `R2.7`. Monotone Revision/CAS darf keinen neueren Jobzustand zurücksetzen.

### AC-37 · Takeover eines Codex-Jobs in einen interaktiven PTY

- **Funktion:** Überführt einen ruhenden Job in den normalen Codex-Resume-Pfad der App.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+Subagents.swift:19`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:189`.
- **Sichtbares Verhalten:** „Übernehmen“ öffnet den Job als interaktiven Codex-Chat im Job-cwd; der Disk-State wird `takenOver` und bleibt terminal.
- **Erhaltungsinvarianten:** Benötigt reale Codex-Thread-ID und gültiges cwd; nach Takeover darf kein paralleles `agent send` starten; Workspace-Reparatur und State-Wechsel müssen transaktional werden. Der derzeitige bugähnliche fehlende Vorcheck ist **kein** zu erhaltendes Verhalten, sondern bestätigte Roadmap-Lücke.
- **Roadmap-Bezug:** `N12`, `N13`; Welle 2 `R2.7` sowie Welle 4 `P2.2` für gemeinsame Operations-Schicht.

### AC-38 · Agent-Ressourcenanzeige

- **Funktion:** Aggregiert CPU/RAM aus Prozessbäumen aktiver Root-PIDs und zeigt Session-/Gesamtlast.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentResourceMonitor.swift:75`, `WhisperM8/Views/AgentChatsView.swift:415`.
- **Sichtbares Verhalten:** Laufende PTY-Chats tragen Ressourcenwerte; aggregierte Last kann im Agent-Chats-Fenster dargestellt werden.
- **Erhaltungsinvarianten:** Nur verifizierbare Root-PIDs werden verfolgt; Prozessbaumaggregation darf keine fremden Prozesse zuordnen. Detachte Codex-Supervisoren fehlen derzeit in dieser Anzeige und sollen laut Audit ergänzt, nicht als gewünschte Auslassung konserviert werden.
- **Roadmap-Bezug:** `N07`, `N14` mittelbar; Welle 1 `R2.4`. Kein eigener C/N-Finding für die Anzeige.

## 6. Hooks, Session-Bindung und Runtime-Status

### AC-39 · Launch-spezifische Claude-Hook-Konfiguration

- **Funktion:** Erzeugt pro lokaler Session eine 0600-Settings-Datei und Event-JSONL und injiziert `--settings` in normale Claude-Starts beziehungsweise `--bg`.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeHookSettingsBuilder.swift:25`, `WhisperM8/Views/AgentSessionDetailView.swift:475`, `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift:68`.
- **Sichtbares Verhalten:** Status, Eingabebedarf und reale Claude-ID werden ohne Polling aus Claude-Lifecycle-Events aktualisiert.
- **Erhaltungsinvarianten:** Registriert sind `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Stop`; `Notification` bleibt bewusst aus, damit `idle_prompt` nicht als Eingabebedarf erscheint. Agent View, Terminal und Background-Attach bekommen keine zweite Bridge.
- **Roadmap-Bezug:** `C07`, `C08`, `C09`; Welle 2 „Autoritative Session-Bindung“ und `P1.2` Hook-Matrix/Reconciliation.

### AC-40 · Event-Datei-Bridge mit initialem Drain

- **Funktion:** Tailt Hook-JSONL inkrementell per vnode-DispatchSource und liefert Events an den Statuskoordinator.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeHookBridge.swift:104`, `WhisperM8/Services/AgentChats/ClaudeHookEventStore.swift:49`.
- **Sichtbares Verhalten:** Events zwischen Settings-Erzeugung und Watch-Anlage gehen durch initialen Drain nicht verloren; Tool-Bursts überlasten die UI nicht.
- **Erhaltungsinvarianten:** Eine Bridge-Entry pro lokaler UUID; Reads beginnen am Byte-Cursor und konsumieren nur newline-terminierte Records; AskUserQuestion/ExitPlanMode und seltene Lifecycle-/Permission-/Stop-Events dürfen nicht wegdrosseln; Cancel schließt FD. Delete/Rename-Rearm und geordnete Drains sind Roadmap-Härtung, nicht entbehrliche Semantik.
- **Roadmap-Bezug:** `C08`; Welle 2 `P1.2`. Hook-SSoT bleibt bestehen; Fallback darf keine stärkere Quelle überschreiben.

### AC-41 · Reale Session-ID-Bindung

- **Funktion:** Bindet Claudes `SessionStart.session_id` an die lokale UUID und aktualisiert Controller/Transcript-Watch.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:345`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:598`.
- **Sichtbares Verhalten:** Nach erstem Start kann derselbe lokale Chat später zuverlässig resumiert, geforkt, benannt und im Transcript gefunden werden.
- **Erhaltungsinvarianten:** Binding wird sofort geflusht, bevor abhängige Watches umgehängt werden; bereits belegte externe IDs dürfen nicht parallel an zwei lokale Rows gebunden werden; mehrdeutige Reparatur startet nicht still eine fremde/fresh Session; `/cd`, Profilroot und ID-Rotation müssen berücksichtigt werden.
- **Roadmap-Bezug:** `C04`, `C07`, `C09`; Welle 2 `P0.5+P0.6+P1.3+P1.4`.

### AC-42 · Runtime-State-Machine und Hook-Primat

- **Funktion:** Reduziert Prozess-, Hook-, Transcript- und Subagent-Signale auf `working`, `awaitingInput`, `idle`, `stopped`, `errored`.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionStateMachine.swift:134`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:200`, `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:4`.
- **Sichtbares Verhalten:** Grün/aktiv während Arbeit, deutlicher Handlungsbedarf bei Permission/Ask/ExitPlanMode, ruhig nach Turn-Ende, Fehler nach Nonzero-Exit. Benachrichtigungen/Sound werden auf echte Übergänge dedupliziert.
- **Erhaltungsinvarianten:** Nach erstem lebendigen Hook schlägt Hook-Evidenz Transcript-Evidenz; Transcript erzeugt niemals verlässlich `awaitingInput`; `Stop` beendet Turn, nicht zwingend Prozess; `SessionEnd(clear|resume|compact)` ist In-Place-Wechsel; ein späteres starkes Lebenszeichen darf einen irrtümlich beendeten Lauf wiederbeleben.
- **Roadmap-Bezug:** `C08`; Welle 2 `P1.2`. Lease-/Reconciliation-Härtung darf den Hook-SSoT-Vertrag nicht durch Poll-Heuristik ersetzen.

### AC-43 · Eventbasierter Transcript-Watcher mit Poll-Fallback

- **Funktion:** Beobachtet aktive Claude-/Codex-Transcripts per vnode und 1,5-s-Timer und leitet Status/Turn-Ende aus einem begrenzten Tail ab.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionRuntimeWatcher.swift:77`, `WhisperM8/Services/Shared/FileEventSource.swift:31`, `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:175`.
- **Sichtbares Verhalten:** Status reagiert typischerweise kurz nach JSONL-Writes; verpasste Events, verschobene Dateien oder deaktivierter Kill-Switch degradieren auf Polling.
- **Erhaltungsinvarianten:** `.write/.extend` 180-ms-debounced; laufender Poll pro Session exklusiv mit genau einer trailing Repoll; `.delete/.rename` rearmt über Timer; unveränderte `(mtime,size)` vermeiden Tail-Read, zeitbasierte Schwellen werden dennoch neu bewertet; Writeback nur bei gleicher Generation. Kill-Switch: `agentEventDrivenWatchEnabled`.
- **Roadmap-Bezug:** `C08`, `C16`; Welle 1 `P1.9`, Welle 2 `P1.2`, Welle 3 `P1.10`.

### AC-44 · Turn-Ende, Auto-Naming und lokale Notifications

- **Funktion:** Persistiert `lastTurnAt`, startet Auto-Naming und informiert bei Fertig-/Eingabebedarf.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:251`, `WhisperM8/Services/AgentChats/AgentSessionStatusCoordinator.swift:369`, `WhisperM8/Services/Shared/WindowRequestCenter.swift:125`.
- **Sichtbares Verhalten:** Fertig- und Awaiting-Benachrichtigungen führen beim Klick zum richtigen Fenster/Tab; Stop-Sound/Benachrichtigung erscheinen nicht mehrfach für denselben Übergang.
- **Erhaltungsinvarianten:** Hook-live Transcript-Ende darf Bookkeeping auslösen, aber nicht den stärkeren Hook-Status überschreiben; Notification-Fokus validiert, dass Session noch existiert und nicht archiviert ist, bevor UI-State mutiert; fremde Fenster werden per ID fokussiert.
- **Roadmap-Bezug:** `C08`, `C11`; Welle 2 `P1.2`, Welle 3 `P1.10`.

## 7. Profile und Account-Wechsel

### AC-45 · Claude-Account-Profile und sessionstabiler Account

- **Funktion:** Entdeckt `main` plus Zusatzprofile unter `~/.claude-profiles`, speichert `.active` und stempelt neue Claude-Sessions mit dem aktuellen Profil.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:39`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:103`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:47`.
- **Sichtbares Verhalten:** Nutzer wählt in Settings ein Konto; Wechsel gilt nur für neue Chats. Forks erben das Profil ihrer Quelle; bestehende Sessions resumen weiter unter ihrem eigenen Konto.
- **Erhaltungsinvarianten:** Fehlende/leere/ungültige `.active` fällt auf `main`; Basisumgebung entfernt jedes geerbte `CLAUDE_CONFIG_DIR`; nur expliziter Command-Override setzt es; realer Transcript-Root darf einen veralteten Stempel überstimmen.
- **Roadmap-Bezug:** `C06`, `N09`; Welle 1 `P1.1`, Welle 2 „Autoritative Session-Bindung“.

### AC-46 · Profilanlage, Login, Rename und Remove

- **Funktion:** Legt isolierte Claude-Config-Roots an, teilt ausgewählte Commands/Agents/Skills/Plugins und verwaltet Login/Keychain-Metadaten.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:225`, `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:278`, `WhisperM8/Views/Settings/Pages/AgentChatsClaudeAccountsTab.swift:372`.
- **Sichtbares Verhalten:** Zusatzaccount kann angelegt, in Terminal.app eingeloggt, umbenannt und entfernt werden; Usage/Plan werden profilbezogen angezeigt.
- **Erhaltungsinvarianten:** Credentials, `projects/` und `history.jsonl` bleiben getrennt; gemeinsam sind nur die vorgesehenen Konfigurationsobjekte. Fremde/laufende Profile dürfen künftig nicht halbmutiert werden. OAuth-Secrets dürfen nicht als argv-Klartext weitergereicht werden.
- **Roadmap-Bezug:** `N10`, `C06`, `N09`; Welle 1 `P1.1`. Rename/Remove brauchen sicheren Secret- und Transaktionspfad.

### AC-47 · Session in einen anderen Claude-Account verschieben

- **Funktion:** Verschiebt Transcript plus Subagent-Ordner und setzt danach den Session-Profilstempel um.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeAccountProfiles.swift:412`, `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:177`.
- **Sichtbares Verhalten:** Kontextmenü „Zu Account verschieben“ macht einen bestehenden Chat unter dem Zielkonto resumierbar.
- **Erhaltungsinvarianten:** Externe Daten-Ausnahme nur als Copy/Move mit Verify vor Quellenlöschung; Fehler müssen vor Stempelwechsel abbrechen/rollbacken; Quelle ist über echten Locator statt nur nachgebautem CWD-Encoding zu bestimmen; Unicode/Langpfade bleiben erreichbar.
- **Roadmap-Bezug:** `C04`, `C06`; Welle 2 „Autoritative Session-Bindung“ und Roadmap-Leitplanke Copy+Verify vor Löschen.

### AC-48 · App-Profil-Gate und Dictation-Zielfenster

- **Funktion:** Aktiviert Agent-Chats-Fenster nur im passenden App-Profil und merkt das zuletzt key gewordene Agent-Fenster als Dictation-Ziel.
- **Einstiegspunkt:** `WhisperM8/WhisperM8App.swift:116`, `WhisperM8/Services/Shared/AppProfileActivator.swift:19`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:615`.
- **Sichtbares Verhalten:** Profilwechsel schließt/öffnet die passende Fensteroberfläche; globales Diktat kann nach App-Wechsel weiter in den zuletzt fokussierten Agent-Chat zielen.
- **Erhaltungsinvarianten:** `dictationWindowID` überlebt `resignKey`, wird aber durch anderes Agent-Fenster oder endgültiges Close ersetzt; Settings/Onboarding dürfen das Agent-Ziel nicht injizieren; leeres Grid hat kein unsichtbares Header-Fallback-Ziel.
- **Roadmap-Bezug:** `N11`; Welle 2 `R2.6`. Außerdem Multi-Window-Ship-Gate.

## 8. Externe Indexierung und Transcript-Ansichten

### AC-49 · Discovery externer Claude-/Codex-Sessions

- **Funktion:** Importiert externe Sessions aus allen Claude-Profilroots und rekursiv aus `~/.codex/sessions`.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:38`, `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift:29`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:74`.
- **Sichtbares Verhalten:** Extern gestartete Chats erscheinen nach Launch, Foreground, FSEvent oder manuellem Refresh; Import-Sessions sind geschlossen und können geöffnet/resumiert werden.
- **Erhaltungsinvarianten:** `~/.claude`/`~/.codex` bleiben read-only; Claude-`subagents/` und Claude-Worktree-CWDs werden als normale Sessions übersprungen; Codex-Jobthreads werden nicht doppelt als normale Sessions importiert; standardmäßig höchstens 1.000 Resultate je Provider, sortiert nach Aktivität.
- **Roadmap-Bezug:** `C04`, `C05`, `C07`, `C12`; Welle 1 `P0.4a`, Welle 2 „Autoritative Session-Bindung“, Welle 3 `P0.4b`/`P1.5+P1.8`, Welle 4 `P2.4`.

### AC-50 · Scan-Koordination und Directory-FSEvents

- **Funktion:** Coalesced Scan-Auslöser, debounced Verzeichnisänderungen und schützt die UI mit Cooldowns.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentDirectoryEventMonitor.swift:23`, `WhisperM8/Services/AgentChats/AgentScanCoordinator.swift:38`, `WhisperM8/WhisperM8App.swift:281`.
- **Sichtbares Verhalten:** Scan-Badge/Refresh reagiert ohne parallele Vollscans; manuelles Refresh umgeht Cooldown.
- **Erhaltungsinvarianten:** Höchstens ein Scan aktiv; Pending-Grund geht nicht verloren; Launch/Foreground 30 s, FSEvent 10 s, Verzeichnisevent 5 s debounce; live vnode-gewatchte Transcripts werden aus globalen FSEvents ausgeschlossen.
- **Roadmap-Bezug:** `C12`; Welle 3 `P1.10`, Welle 4 `P2.4`.

### AC-51 · Bounded Index-Parsing und persistenter Index-Cache

- **Funktion:** Extrahiert Metadaten mit festen Byte-/Zeilenbudgets und cached Resultate nach Provider, Pfad, mtime und Größe.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionIndexer.swift:19`, `WhisperM8/Services/AgentChats/ClaudeSessionIndexer.swift:102`, `WhisperM8/Services/AgentChats/CodexSessionIndexer.swift:80`.
- **Sichtbares Verhalten:** Wiederholte Scans sind deutlich schneller; korrupte Einzeldateien verhindern keinen Gesamtimport.
- **Erhaltungsinvarianten:** Claude höchstens 200 Kopfzeilen/1 MiB; Codex erste `session_meta`-Zeile höchstens 256 KiB; negative Parse-Misses werden gecacht; Cache-Save ist atomar; Decode-/Writefehler degradieren auf leeren Cache/fortgesetzten Scan.
- **Roadmap-Bezug:** `C12`; Welle 3 `P1.10`, Welle 4 `P2.4`. Provider-spezifische Zeit-/Schema-Semantik darf bei Scanner-Konsolidierung nicht vereinheitlicht werden.

### AC-52 · Merge, Adoption und Deduplizierung

- **Funktion:** Führt indexierte Sessions mit lokalen Projekten/Sessions zusammen und adoptiert zeitnah gestartete ungebundene Tabs.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionStore.swift:736`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:786`.
- **Sichtbares Verhalten:** Externe Session und lokal gestarteter Tab werden zu einer Row statt Duplikaten; Metadaten/letzte Aktivität aktualisieren sich.
- **Erhaltungsinvarianten:** Dedupe-Key `provider|externalSessionID`; bei Claude passt Profilkandidat vor reiner Recency; Adoption nur im echten ±5-s-Fenster und bei eindeutiger Zuordnung; laufende Jobthreads bleiben aus normalem Import heraus.
- **Roadmap-Bezug:** `C07`, `C12`; Welle 2 „Autoritative Session-Bindung“, Welle 3 `P1.5+P1.8`, Welle 4 `P2.3`.

### AC-53 · Transcript-Locator und providerübergreifender Tail-Cache

- **Funktion:** Findet reale Claude-/Codex-JSONL-Dateien, liest zunächst 512 KiB Tail und cached maximal 24 Transcripts mit zwei parallelen Reads.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/AgentSessionTranscript.swift:297`, `WhisperM8/Services/AgentChats/AgentTranscriptCache.swift:14`, `WhisperM8/Views/AgentSessionDetailView.swift:267`.
- **Sichtbares Verhalten:** Offline-Verlauf erscheint schnell; „mehr laden“ vergrößert das Fenster ×4 bis 32 MiB; verschobene Profile/Codex-Dateien können per Fallback gefunden werden.
- **Erhaltungsinvarianten:** Cache-Key umfasst Session/Tail/Dateiidentität; gleiche In-flight-Reads werden nur innerhalb derselben Generation geteilt; Invalidierung darf alte Reads nicht wiederbeleben; LRU-Grenze 24, Read-Limit zwei. Tail-Anfang verwirft angeschnittene erste Zeile und signalisiert Truncation.
- **Roadmap-Bezug:** `C04`, `C16`; Welle 1 `P1.9`, Welle 2 „Autoritative Session-Bindung“.

### AC-54 · Claude-/Codex-Transcript-Parser

- **Funktion:** Übersetzt provider-spezifische JSONL-Events in stabile `AgentChatMessage`-/Blockmodelle.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeTranscriptReader.swift:78`, `WhisperM8/Services/AgentChats/CodexTranscriptReader.swift:65`, `WhisperM8/Models/AgentChatTranscript.swift:42`.
- **Sichtbares Verhalten:** User-/Assistant-Texte, Tool-Calls, Tool-Results und Bildplatzhalter werden in einer einheitlichen Ansicht dargestellt; defekte Zeilen werden übersprungen.
- **Erhaltungsinvarianten:** Stabile inhaltsbasierte IDs verhindern SwiftUI-Flackern; Voll-Reader streamen zeilenweise; Bilder werden im Endmodell nur als Platzhalter geführt. Unbekannte syntaktisch gültige Events sollen künftig sichtbar degradieren statt still verschwinden.
- **Roadmap-Bezug:** `N16`; Welle 3 `P1.11`. Aktuelle Claude-/Codex-Schema-Fixtures und unbekannte Events sind Regression-Gate.

### AC-55 · Timeline-, Roh- und Snapshot-Ansicht

- **Funktion:** Bietet Chat-Timeline, rohe Nachrichtenansicht und TerminalSnapshotStore-Fallback im selben Detailpfad.
- **Einstiegspunkt:** `WhisperM8/Views/Transcript/AgentTranscriptContainerView.swift:28`, `WhisperM8/Views/Transcript/AgentTimelineView.swift:23`, `WhisperM8/Views/AgentChatTranscriptView.swift:22`, `WhisperM8/Views/Transcript/TerminalSnapshotView.swift:8`.
- **Sichtbares Verhalten:** Timeline gruppiert Runden, Zwischentexte, Tools und finale Antworten; Rohansicht zeigt die Message-Reihenfolge; große Verläufe rendern harte Fenster (160 Runden/600 Messages), nicht die komplette Historie auf einmal.
- **Erhaltungsinvarianten:** Timeline-Aufbau ist pure/off-main und verlustfrei bezüglich erzeugter Blocks; Antwort/Notiz bleiben getrennt; stabile IDs; ältere asynchrone Builds dürfen künftig keinen neueren View-State überschreiben. Terminal-Snapshot ist schneller Fallback, kein Ersatz des providerseitigen Transcripts.
- **Roadmap-Bezug:** `N15`, `N16`; Welle 3 `P1.11` und `T1`.

### AC-56 · Tool-Korrelation in der Timeline

- **Funktion:** Ordnet Tool-Results den offenen Tool-Schritten einer Runde zu.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:98`, `WhisperM8/Services/AgentChats/TranscriptTimelineBuilder.swift:228`.
- **Sichtbares Verhalten:** Tool-Call und Ergebnis erscheinen als zusammengehöriger Schritt, inklusive Aktivitätsstatistik und Tool-Klassifikation.
- **Erhaltungsinvarianten:** Heute erfolgt Pairing FIFO; bei parallelen Tools kann das falsch sein. Zu erhalten ist die korrekte sichtbare Zuordnung, **nicht** FIFO als Implementation. Provider-IDs (`tool_use.id`, `tool_use_id`, `call_id`) müssen künftig erhalten werden.
- **Roadmap-Bezug:** `N15`; Welle 3 `P1.11`.

## 9. GPT-Backend über `ClaudeCodeProxyManager` und `MixRouter`

### AC-57 · GPT-Backend-Settings und Device-Code-Login

- **Funktion:** Konfiguriert lokalen Proxy-Port, Standard-/Subagent-Modell, Backend-Aktivierung und ChatGPT-Device-Login.
- **Einstiegspunkt:** `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:4`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:302`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:326`.
- **Sichtbares Verhalten:** Settings zeigen Binary-, Prozess- und Authstatus; Proxy kann gestartet/gestoppt werden; URL und Gerätecode werden angezeigt/kopiert; freie Modellstrings mit Vorschlägen sind editierbar.
- **Erhaltungsinvarianten:** Deaktiviert bedeutet direkter Anthropic-Betrieb und GPT-Stempel ignorieren; „Proxy stoppen“ beendet nur von WhisperM8 selbst gestartete Instanz; Device-Login ersetzt einen alten laufenden Login und endet beim App-Quit; Default leer bedeutet Claude, nicht automatisch GPT.
- **Roadmap-Bezug:** Noch kein C/N-Finding der Audit-Roadmap; als jüngst implementierter Produktpfad vollständiges Feature-Erhaltungs-Gate für alle Agent-Chats-Wellen.

### AC-58 · Proxy-Lifecycle und Health-Signatur

- **Funktion:** Erkennt externen `claude-code-proxy`, startet ihn bei Bedarf loopback-only und serialisiert Startversuche.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:116`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:218`, `WhisperM8/Services/AgentChats/ClaudeCodeProxyManager.swift:469`.
- **Sichtbares Verhalten:** Ein Claude-Chat startet den Backend-Proxy automatisch; fehlendes Binary/Start/Reachability/Router-Fehler werden unterscheidbar gemeldet. Externer Proxy bleibt beim App-Quit/Stop unangetastet.
- **Erhaltungsinvarianten:** `ensureLock` verhindert Doppelstart; Health gilt nur bei `GET /healthz`, HTTP 200, `application/json`, `{ "ok": true }`, ohne Redirect; Bind-Defense `127.0.0.1`; startet Router nach selbst gestartetem Proxy nicht, wird dieser Versuch beendet; nur eigener Handle wird terminiert.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; tangiert `N09` (Child-Environment) und Welle 1 `P1.1`, ohne die lokale OAuth-/Proxy-Semantik zu verändern.

### AC-59 · In-Process-MixRouter

- **Funktion:** Routet HTTP-Requests einer Claude-PTY-Session anhand des JSON-`model` entweder zum lokalen Codex-Proxy oder zu Anthropic.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:24`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:268`, `WhisperM8/Services/AgentChats/ClaudeGPTMixRouter.swift:403`.
- **Sichtbares Verhalten:** In derselben Claude-Code-Session können Claude- und `gpt-*`-Modelle beziehungsweise GPT-Subagents genutzt werden; SSE/Antwortdaten streamen sofort als HTTP-Chunks.
- **Erhaltungsinvarianten:** Listener ausschließlich `127.0.0.1`; Modellpräfix `gpt-` geht zum Codex-Proxy, alles andere zu Anthropic; Anthropic-Credentials (`Authorization`, `x-api-key`, `anthropic-*`) werden vor lokalem Codex-Upstream entfernt, zum Anthropic-Upstream aber erhalten; Hop-by-Hop-/Compression-Header werden korrekt gefiltert; maximal 64 KiB Header/64 MiB Body; kein Transfer-Encoding-Request; eine Clientverbindung verarbeitet genau einen Request; später Upstream-Fehler bricht die Verbindung statt eine falsche 502 nach bereits gesendetem Status zu schreiben.
- **Roadmap-Bezug:** Kein eigener C/N-Finding. `N09`/Welle 1 `P1.1` ist als Secret-Grenze relevant; MixRouter-Headerfilter ist zusätzliches Security-Regressions-Gate.

### AC-60 · GPT-Modellstempel, Router-Environment und Fallback

- **Funktion:** Stempelt neue Claude-Chats optional mit dem konfigurierten GPT-Standardmodell und setzt pro Launch Router-/Model-Environment.
- **Einstiegspunkt:** `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift:47`, `WhisperM8/Views/AgentSessionDetailView.swift:399`, `WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:259`.
- **Sichtbares Verhalten:** Mit GPT-Default startet ein neuer Chat per `--model`; ohne Stempel bleibt Claude Standard, GPT steht aber per `/model` und Agent-Typ zur Verfügung. Ist Backend beim Launch nicht verfügbar, startet ein gestempelter/forcierter GPT-Pfad mit sichtbarer Warnung im direkten Claude-Fallback.
- **Erhaltungsinvarianten:** Lifecycle-Entscheidung wird pro Launch eingefroren; User-`--model` aus Extra-Args bleibt last-flag-wins; Router gilt für alle Claude-PTY-Sessions, damit späterer `/model`-Wechsel funktioniert; `ANTHROPIC_CUSTOM_MODEL_OPTION` fällt auf `gpt-5.6-sol`; GPT-Tuning (Haiku-Ersatz/Tool-Concurrency) nur für GPT-gestempelte Hauptsession; leeres globales Subagent-Override bleibt empfohlen.
- **Roadmap-Bezug:** Kein eigener C/N-Finding; `N09`/Welle 1 `P1.1` für kontrolliertes Child-Environment und Welle-2-Resume-Gate für Erhalt des Sessionstempels.

### AC-61 · Verwalteter nativer Agent-Typ `gpt`

- **Funktion:** Synchronisiert eine Claude-Code-Agent-Definition `agents/gpt.md` in main und allen Zusatzprofilen.
- **Einstiegspunkt:** `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:3`, `WhisperM8/Services/AgentChats/ClaudeGPTAgentDefinition.swift:50`, `WhisperM8/Views/Settings/Pages/GPTBackendSettingsPage.swift:66`.
- **Sichtbares Verhalten:** Claude kann pro Aufgabe einen nativen `gpt`-Subagenten wählen; Aktivieren/Modellwechsel aktualisiert die Definition, Deaktivieren entfernt sie.
- **Erhaltungsinvarianten:** Nur Dateien mit `managed-by: whisperm8-gpt-backend` werden überschrieben/entfernt; fremde `gpt.md` bleibt unangetastet; jede Profil-Config erhält eigene Definition; leeres Modell fällt kanonisch auf `gpt-5.6-sol`; globales `CLAUDE_CODE_SUBAGENT_MODEL` ist ein optionaler Zwangs-Override, nicht Voraussetzung für den Agent-Typ.
- **Roadmap-Bezug:** `C06` mittelbar; Welle 1 `P1.1` muss alle Profilroots erhalten. Kein eigener bestätigter Finding.

## 10. Querschnittsinvarianten und Abgrenzungen

1. **WhisperM8 bleibt CLI-Host.** Claude Code, Codex und Shell laufen als echte Prozesse in PTYs beziehungsweise als echte CLI-Supervisoren. Eine Refactor-Welle darf sie nicht still durch eine Eigen-UI- oder SDK-Runtime ersetzen (`WhisperM8/Services/AgentChats/AgentCommandBuilder.swift:156`, `WhisperM8/Views/AgentTerminalView.swift:749`).
2. **Externe Daten bleiben read-only.** Session-Indexer, Reader und Statuspfade lesen `~/.claude/`/`~/.codex/`. Expliziter Account-Umzug ist die einzige hier beschriebene Mutationsausnahme und braucht Copy+Verify vor Quellenlöschung.
3. **Domain-Store-Mutationsclosures starten keine Subprozesse.** Sie laufen unter dem prozessweiten Lock; Git-, Config-, Index- und Dateiarbeit ist vorher/off-main zu erledigen (`WhisperM8/Services/AgentChats/AgentWorkspaceStore.swift:117`).
4. **Hooks bleiben Claude-Status-SSoT.** Transcript ist Fallback und Turn-Ende-Oracle, nicht gleichrangiger Überschreiber eines lebendigen Hook-Zustands.
5. **Session-, Tab-, Fenster- und Workspace-Identität sind verschieden.** Lokale Session-UUID, externe Provider-ID, Tab-Owner, Workspace-Membership und Prozess/PTY dürfen nicht vermischt werden.
6. **„Schließen“ ist kontextabhängig.** Tab schließen lässt Prozess/Session leben; Chat archivieren beendet ggf. PTY und behält Session; Terminal schließen löscht lokale Session; Projekt löschen entfernt lokale Metadaten, nicht Repo/Provider-Transcripts; Background `rm` verlangt externen Erfolg.
7. **Keine stillen Recovery-Neustarts.** Wo Bindung/Resume nicht eindeutig ist, fordert die Roadmap sichtbares `recoveryRequired`; ein frischer Chat darf nicht als erfolgreicher Resume erscheinen.
8. **Bewusste Grid-Entscheidungen aus `ddb1727`/`36f09c2` sind Oracle:** kein Hidden-Takeover; Aktivierung blockiert nie wegen Fremd-Tab-Membership; Fremdslot = Platzhalter bis expliziter Transfer; Swap-Semantik auf belegter Pane bleibt; ausgewählter Fokus gewinnt beim Reaktivieren; 6/9 bleiben mit Signposts/manueller QA aktiv.
9. **Performance-Optimierung darf keine Semantik verstecken.** Lazy-/Cache-/Projection-Umbauten müssen Auswahl, Reihenfolge, Archiv, Unread, Status, Grid-Slots, Terminalscrollback und Dictation-Ziel identisch halten.
10. **Terminal-Output ist verlustsensitiv, Input ist privat.** Teardown/Recording muss letzte Outputbytes genau einmal erhalten; stdin, Prompts, Tokens und Secrets dürfen nicht neu aufgezeichnet oder geloggt werden.

## 11. Roadmap-Deckungsmatrix

| Roadmap-Finding/-Maßnahme | Primär geschützte Inventarbereiche |
|---|---|
| `C04`, `C07`, `C09` · Welle 2 autoritative Bindung | AC-28, AC-29, AC-39–AC-41, AC-47, AC-49, AC-52–AC-53 |
| `C05` · Welle 1/3 Headless-Prävention/-Migration | AC-10, AC-49 |
| `C06`, `N09`, `N10` · Welle 1 Child-Environment/Profile | AC-24, AC-31–AC-32, AC-45–AC-47, AC-58–AC-61 |
| `C08` · Welle 2 Background-/Hook-Reconciliation | AC-31–AC-33, AC-39–AC-44 |
| `C10`, `N01` · Welle 2 Terminal-Identität/Teardown | AC-11, AC-15–AC-16, AC-23–AC-27, AC-30 |
| `C11`, `C14`, `C15`, `C12` · Welle 1/3/4 Store/UI/Performance | AC-01–AC-07, AC-11, AC-14, AC-17–AC-23, AC-49–AC-52 |
| `N05` · Welle 1 Future-Schema | AC-02, AC-09, AC-17 |
| `N07`, `N08`, `N12`, `N13`, `N14` · Welle 1/2 Codex-Supervisor/State | AC-34–AC-38 |
| `N11` · Welle 2 zielgebundenes Auto-Paste | AC-22, AC-48 |
| `N15`, `N16` · Welle 3 Transcript-Korrelation/Drift | AC-54–AC-56 |
| `T1` · Welle 3 output-only Recording | AC-25, AC-30, AC-55 |
| Welle 4 `P2.1–P2.7` Architektur/Module | Alle Bereiche; besonders AC-01–AC-07, AC-11–AC-16, AC-24–AC-27, AC-31–AC-36, AC-49–AC-56 |
