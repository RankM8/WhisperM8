---
status: aktiv
updated: 2026-07-09
---

# UI — Architektur

Die Agent-Chat-UI trennt View-Orchestrierung, pure Projektionen und
fensterübergreifende Stores. `AgentChatsView` hält die SwiftUI-Komposition und
die AppKit-Brücken, während Sidebar-, Tab- und Timeline-Logik soweit möglich
als pure Builder oder Resolver testbar bleibt.

## Schichten

```
AgentChatsView(windowID)
  ├─ AgentWindowStore.shared        Fenster, Tabs, Pinning, Expansion
  ├─ AgentWorkspaceUIModel.shared   live Workspace-Projektion
  ├─ AgentTerminalRegistry.shared   laufende Vordergrund-PTYs
  ├─ AgentJobRuntimeModel.shared    Subagent-Snapshots und aktive Kinder
  ├─ AgentResourceMonitor           Prozessbaum-Snapshots für CPU und RAM
  └─ AgentSessionStore              Persistenz- und Workspace-Mutationen
```

`AgentChatsView` liest den Workspace aus `AgentWorkspaceUIModel.shared`, aber
mutiert Session-/Projekt-Metadaten über `AgentSessionStore` und die kleine
`AgentChatsViewModel`-Fassade. Fenster- und Tab-Mutationen laufen über
`AgentWindowStore`, damit mehrere Agent-Chat-Fenster denselben Zustand sehen.

## AgentChatsView und Extensions

`AgentChatsView.swift` enthält das Layout, die Store-Bridges, die
Fensterbreiten-Logik, globale View-State-Variablen, Header-Tabs, Sidebar,
Detailfläche, Sheets und Lebenszyklus-Hooks. Die Datei ist bewusst noch der
Orchestrator; thematische Erweiterungen halten die Aktionslogik aus dem Body
heraus.

- `WhisperM8/Views/AgentChatsView+Archive.swift` kapselt Archivmodus, Archivliste und die Verdrahtung der Wiederherstellungsaktion.
- `WhisperM8/Views/AgentChatsView+BackgroundAgents.swift` kapselt Claude-Background-Dispatch, Logs, Lifecycle-Aktionen und Startup-Health-Check.
- `WhisperM8/Views/AgentChatsView+BulkActions.swift` kapselt Multi-Select-Aktionsgruppen für Schließen, Archivieren, Pinning und Farben.
- `WhisperM8/Views/AgentChatsView+DragDrop.swift` kapselt Sidebar-Drops für Sessions und Projekte.
- `WhisperM8/Views/AgentChatsView+ProjectManagement.swift` kapselt Projektselektion, Aufklappen, Erzeugen, Löschen, Umbenennen, Farben und Icons.
- `WhisperM8/Views/AgentChatsView+RuntimeServices.swift` kapselt Workspace-Refresh, Runtime-Service-Setup, Fast-Load und Selection-Reconcile; die dort verbliebene Rebind-Auswahl hat keinen Notification-Producer und ist kein aktiver Recovery-Pfad.
- `WhisperM8/Views/AgentChatsView+SessionLifecycle.swift` kapselt neue Chats, Forks, Statuswechsel, Relaunch, Umbenennen, Gruppen, Farben und Pinning.
- `WhisperM8/Views/AgentChatsView+Shortcuts.swift` kapselt lokale `NSEvent`-Monitore für Cmd-W, neue Chats, Tab-Navigation, Ctrl-Tab, Swipe, Titelzonen-Zoom und Tab-Strip-Scroll.
- `WhisperM8/Views/AgentChatsView+Subagents.swift` kapselt die Übernahme eines Subagent-Jobs in einen interaktiven Codex-Chat.
- `WhisperM8/Views/AgentChatsView+Tabs.swift` kapselt Tab-Klicks, Sidebar-Row-Auswahl, Öffnen, Schließen, Archivieren, Wiederherstellen archivierter Sessions, Drop/Reorder und Tear-off.

## ViewModel und Store-Bridges

`AgentChatsViewModel` ist eine dünne, `@MainActor`-Fassade für getestete,
View-unabhängige Store-Mutationen wie Session-/Projekt-Rename, Gruppe und
Farbe. Sie besitzt bewusst keinen Tab-State; Tabs, Selektion, Pins und
Projekt-Expansion gehören in `AgentWindowStore`.

Die fünf persistenten Bridges in `AgentChatsView` sind:
`selectedProjectID`, `selectedSessionID`, `expandedProjectIDs`,
`openTabIDs` und `pinnedSessionIDs`. Setter rufen Store-Methoden wie
`setSelectedSession`, `setOpenTabIDs` oder `setPinnedSessionIDs` auf; Swift
übersetzt auch `append`/`remove` auf diesen Properties in get-modify-set, sodass
alte Aufrufstellen über denselben Store laufen.

Die sechste Bridge ist `multiSelection`. Sie ist ephemer pro Fenster und liegt
trotzdem in `AgentWindowStore`, damit Cross-Window-Drops die Auswahl des
Quellfensters lesen und danach leeren können.

## AgentWindowStore-Bridging

`AgentWindowStore` hält `AgentUIState` als private observable State und
persistiert über `AgentSessionStore` mit Debounce. Die Store-API trennt Reads
pro Fenster von semantischen Mutationen wie `openTab`, `selectTab`,
`closeTab`, `reorderTab`, `moveTab`, `detachToNewWindow`, `togglePin`,
`prune`, `markSubagentUnread` und `clearSubagentUnread`.

Die Multiwindow-Invarianten liegen im Modell: eine Session lebt in genau einem
Fenster, es gibt genau ein Primärfenster und leere Sekundärfenster werden
entfernt. Details zur Scene-Topologie, Restore-Pfaden und Persistenz stehen in
[`multiwindow-architecture.md`](multiwindow-architecture.md).

## Sidebar-Modell

`AgentSidebarModelBuilder` ist die pure Projektionsschicht der Sidebar. Er
filtert manuelle, nicht archivierte Sessions, entfernt gepinnte Sessions aus
den Hauptlisten, wendet `SidebarScopeFilter` an, gruppiert nach Projekt oder
sortiert flach nach Recency und hält Subagent-Kinder aus der normalen Liste,
wenn sie einem sichtbaren Parent zugeordnet werden können.

`subagentChildren(workspaceSessions:)` matcht `.subagentJob`-Sessions über
`subagentParentSessionID` gegen `externalSessionID` der Parent-Sessions.
Nicht auflösbare Kinder bleiben Orphans und werden als normale Rows im
Projekt-Fallback sichtbar.

`subagentChildSplit` implementiert Variante D: Bei geöffneter erster Stufe sind
fehlgeschlagene und laufende Kinder sowie ein selektiertes Kind direkt
sichtbar; erfolgreich fertige Kinder liegen im Footer, ungelesene vor
gelesenen. Der Fortschrittsbruch ist `terminalCount / totalCount`, wobei ein
Fehler als terminaler Fortschritt zählt und separat über den roten Zustand
angezeigt wird.

`AgentChatsSidebarViews` rendert diese Projektion. `ProjectChatGroup`
berechnet pro Parent genau einen Split. Das Parent-Chip-Chevron schließt die
erste Stufe vollständig, einschließlich laufender und fehlgeschlagener Kinder;
ein selektiertes Kind erzwingt diese Stufe als Reveal. Explizite Expansionen
liegen in `AgentWindowStore.expandedSubagentParentIDs` nur ephemer für den
aktuellen App-Start. Die zweite Footer-Stufe für fertige Kinder ist lokaler
`ProjectChatGroup`-State. Eine ungelesene fertige Row zeigt bei Idle oder
fehlendem Live-Status einen blauen Dot; `selectedSessionID`-Änderungen sowie
`SubagentJobDetailView.onAppear` rufen `clearSubagentUnread` auf.
`SessionListButton` und `PinnedSessionRow` beziehen Live-Status per
`statusPublisher(for:)`, damit Status-Ticks nicht den gesamten
`AgentChatsView`-Body invalidieren.

## Sidebar-Drag-and-Drop

`AgentDragDropPlanner` trennt die Drop-Entscheidung von Persistenz und UI. Für
Session-Drops innerhalb desselben Projekts entfernt er zunächst die gezogene
ID und korrigiert den Einfügeindex richtungsabhängig: nach unten wird hinter,
nach oben vor der getroffenen Row einsortiert. Bei einem Projektwechsel liefert
er stattdessen einen `.move`-Plan mit Zielprojekt und Zielindex. Für
Projekt-Drops berechnet `projectDropPlan` analog eine vollständige neue
ID-Reihenfolge; Selbst-Drops und unveränderte Reihenfolgen ergeben `.none`.

`AgentChatsView+DragDrop` führt diese puren Pläne anschließend über
`reorderSessions`, `moveSessionToProject` oder `reorderProjects` aus. Dadurch
bleiben Geometrie-/Richtungsfälle ohne SwiftUI und ohne echten Store testbar.

## Overlay-Scroller

Die Sidebar hängt `overlayScrollers()` an den Inhalt innerhalb ihrer
`ScrollView`. Nur dort kann der 0×0-`OverlayScrollersApplier` über
`enclosingScrollView` die AppKit-ScrollView erreichen. Bei angeschlossener Maus
würde die Systemeinstellung sonst einen 15 Punkte breiten Legacy-Scroller mit
Track aktivieren. Weil AppKit den Stil nach Änderungen der bevorzugten
Scroller-Darstellung zurücksetzt, beobachtet der Applier
`preferredScrollerStyleDidChangeNotification` und setzt `.overlay` plus
`autohidesScrollers` erneut.

## Status-Anzeige

`AgentStatusIndicator` ist die gemeinsame visuelle Sprache für Sidebar-Rows
und den Ctrl-Tab-Switcher. `working` pulsiert grün, `awaitingInput` pulsiert
amber, `idle` ist ein ruhiger grauer Punkt, `errored` ist ein roter Ring und
`stopped` beziehungsweise `nil` bleibt leer.

`ChatTabButton` rendert im Tab selbst eine eigene kompakte Statusvariante.
Sie nutzt denselben Runtime-Status als Quelle, aber eigene 5px-Punkte und eine
gedimmt grüne Idle-Darstellung; sie ist deshalb nicht identisch mit
`AgentStatusIndicator`.

Die Statusdaten kommen aus `AgentSessionStatusCoordinator.shared.statusStore`.
Rows und Tab-Switcher abonnieren einzelne IDs über `statusPublisher(for:)` oder
lesen im kurzlebigen Overlay direkt aus dem Store; der Haupt-Body liest die
Status-Map nicht.

## Ressourcenmonitor

`AgentChatsView.runningResourceDescriptors` liefert nur Sessions mit
Workspace-Status `.running` und nimmt ihre Root-PID aus dem zugehörigen
`AgentTerminalController`. `AgentResourceMonitor` ruft `/bin/ps -axo
pid=,ppid=,%cpu=,rss=,comm=` auf, baut aus PID/PPID den vollständigen
Nachfahrenbaum jeder Root-PID und summiert CPU sowie RSS erst pro Session, dann
pro Projekt und insgesamt. `hw.memsize` kommt einmalig gecacht aus `sysctl`;
daraus entsteht der sichtbare RAM-Anteil.

`AgentResourceSummaryButton` führt die Erfassung off-main aus und verhindert
parallele Refreshes. Das kompakte Badge pollt alle 10 Sekunden, das geöffnete
Popover alle 2 Sekunden. `controlActiveState == .inactive` beendet die
Polling-Schleife; der inaktive Zweig führt beim Zustandswechsel allerdings noch
einen einmaligen `refresh()` aus, bevor keine weiteren `ps`-Kinder mehr
entstehen.

Beim Subprozess-Drain liest `runProcess` zuerst stdout vollständig, leert dann
stderr und ruft erst danach `waitUntilExit()` auf. Das vermeidet den häufigsten
Deadlock (Warten auf Exit bei vollem Puffer), ist aber keine Garantie: Füllt ein
Child zuerst stderr, kann es blockieren, während der Parent stdout noch bis EOF
liest.

## Tab-Logik

Die Tab-Leiste nutzt mehrere pure Bausteine:

- `WhisperM8/Views/AgentTabSelection.swift` enthält `TabSelectionResolver` für normalen Klick, Cmd-Klick, Shift-Klick und Gruppen-Pin-Normalisierung.
- `WhisperM8/Views/AgentTabReorderDrop.swift` enthält `TabReorderGeometry` für Einfügeindex/-position, `TabGroupReorder` für Multi-Tab-Reorder und `TabReorderDropDelegate` für Move-Drops.
- `WhisperM8/Views/TabSwitcherModel.swift` enthält `TabSwitcherModel`, `adjacentTabID`-basierte Navigation und `TabSwitcherGridLayout`.

`AgentChatsView+Tabs` bindet diese Logik an Workspace und Store. Lokaler
Reorder einer Multi-Auswahl schreibt eine neue Reihenfolge in
`AgentWindowStore`; Einzel-Moves und Cross-Window-Moves nutzen die semantische
Store-API. Tear-off erzeugt über den Store eine neue Fenster-ID und öffnet die
SwiftUI-Scene asynchron.

## Transcript-Rendering

`Views/Transcript/` ist die Timeline-Schicht. `AgentTranscriptContainerView`
entscheidet aus Transcript, Session und Live-Zustand den Darstellungsmodus und
baut die Timeline asynchron über `TranscriptTimelineBuilder`. Sie rendert
Header-Strip, Summary-Card, History-Pills, Ladezustände und `AgentTimelineView`.

`AgentTimelineView` begrenzt die sichtbaren Rounds, zeigt frühere History als
nachladbaren Abschnitt und ergänzt bei laufenden Sessions einen Live-Hinweis.
`TimelineRoundView` rendert Prompt, Activity, Reports,
Teammate-Nachrichten und unvollständige Runden. `TimelineActivityRow`,
`TimelineReportView`, `TranscriptMarkdownView`, `SessionSummaryCard` und
`TranscriptHistoryState` liefern die spezialisierten Zeilen und Karten.

`AgentChatTranscriptView` bleibt die Message-orientierte Bubble-Ansicht. Sie
zeigt rohe `AgentChatMessage`-Blöcke, Tool-Use, Tool-Result, Images,
Thinking-Blöcke und Spezialbanner für orphaned Background-Chats.

Die Detail-View lädt Transcripts nur, wenn kein Live-Controller läuft, die
Session keine `.agentView` ist, kein `.backgroundChat` ist und eine
`externalSessionID` bekannt ist. Terminal-Tabs ohne laufenden Controller haben
keine Transcript-Fläche, sondern den eigenen Ended-State mit Restart-Aktion.

## Detailflächen

`mainWorkspace` wählt anhand der selektierten Session. Für
`session.isSubagentJob`, solange `AgentJobRuntimeModel.isTakenOver` false ist,
wird `SubagentJobDetailView` gerendert; sonst `AgentSessionDetailView`.

`AgentSessionDetailView` verwaltet interaktive PTY-Sessions. Es lädt
Transcripts, kann frühere History nachladen, bereitet Launch-Kommandos vor,
repariert Sessions vor dem Start, startet oder restartert das Terminal, bindet
externe Session-IDs und meldet Launch/Termination an die Parent-View.

`SubagentJobDetailView` liest den Runtime-Snapshot, rendert Job-Header, Status,
Auftrag, Report, Live-Eventstrip, Metriken, Composer, Stop, Reload,
History-Load und Report-Routing zum Parent-Chat. Die Übernahme ruft
`takeOverSubagentJob` auf und führt danach in den normalen Codex-PTY-Pfad.

## Nachbar-Feature-Boundary

`AgentChatsView` spiegelt die aktuelle Auswahl als `AgentChatContextRef` nach
`AppState.shared.activeAgentChat`. Die Agent-Chat-UI schreibt damit nur den
aktuellen Kontextanker; die Diktat-/Recording-Pipeline und das
Context-Bundle-Feature lesen diesen Wert als Nachbar-Feature, um einen
Recording-Start dem aktiven Agent-Chat zuzuordnen.

## Invarianten und Grenzen

- Store-Mutationen in `AgentWorkspaceStore` dürfen keine Subprozesse oder blockierendes I/O ausführen; UI-Code berechnet solche Daten vor der Mutation.
- `AgentWindowStore` ist die einzige Autorität für Fenster-/Tab-State; lokale View-State-Felder sind nur ephemer oder UI-spezifisch.
- Subagent-Kinder mit sichtbarem Parent erscheinen nicht zusätzlich in der Hauptliste; Orphans bleiben sichtbar.
- Das Parent-Chevron darf alle Subagent-Kinder einklappen; nur ein selektiertes Kind erzwingt die erste Expansion.
- Status-Ticks dürfen nicht den gesamten `AgentChatsView`-Body treiben; Status wird pro Row oder im kurzlebigen Overlay gelesen.
- Transcript-Timeline liest aus bereits geladenen Transcript-Modellen; History-Nachladen ist explizit und nicht an Tab-Highlight-Wechsel gekoppelt.
- Konkrete Reaktionen externer TUIs auf gesendete Terminal-Sequenzen sind im Repo nicht beweisbar; die UI-Doku beschreibt nur die Integrationspunkte und kennzeichnet Tool-Verhalten als extern oder empirisch.

## Schlüsseldateien

- `WhisperM8/Views/AgentChatsView.swift` ist der zentrale SwiftUI-Orchestrator für Fensterlayout, Store-Bridges, Sidebar, Header-Tabs, Detailfläche, Sheets und Lebenszyklus.
- `WhisperM8/Views/AgentChatsViewModel.swift` ist die dünne ViewModel-Fassade für testbare Session- und Projektmutationen im Store.
- `WhisperM8/Services/AgentChats/AgentSidebarModelBuilder.swift` ist der pure Builder für Sidebar-Scope, Gruppierung, flache Liste, Subagent-Zuordnung und Variante-D-Split.
- `WhisperM8/Services/AgentChats/AgentDragDropPlanner.swift` ist die pure Planungslogik für Session-Reorder, Cross-Project-Moves und Projekt-Reorder.
- `WhisperM8/Views/AgentChatsSidebarViews.swift` ist die Sidebar-View-Schicht für Projektgruppen, Session-Rows, Pins, Subagent-Kinder, Footer und Drag-Drop.
- `WhisperM8/Services/AgentChats/AgentWindowStore.swift` ist die observable Single Source of Truth für Fenster, Tabs, Pins, Expansion, Unread-Subagents und Multi-Selection.
- `WhisperM8/Services/AgentChats/AgentResourceMonitor.swift` liest Prozessdaten und aggregiert CPU/RAM über Session-Prozessbäume und Projekte.
- `WhisperM8/Views/AgentResourceSummaryButton.swift` enthält Badge, Popover und aktivitätsabhängiges 10-s-/2-s-Polling.
- `WhisperM8/Views/OverlayScrollers.swift` erzwingt AppKits Overlay-Scroller und setzt den Stil nach Systemänderungen erneut.
- `WhisperM8/Views/AgentStatusIndicator.swift` ist die gemeinsame Statusanzeige für row-lokale Live-Zustände.
- `WhisperM8/Views/AgentTabSelection.swift` ist die pure Multi-Select-Entscheidungslogik der Tab-Leiste.
- `WhisperM8/Views/AgentTabReorderDrop.swift` ist die pure Reorder-Geometrie plus Drop-Delegate für die Tab-Leiste.
- `WhisperM8/Views/TabSwitcherModel.swift` ist die pure State-Machine und Layout-Metrik des Ctrl-Tab-Switchers.
- `WhisperM8/Views/Transcript/` ist die View-Schicht für Timeline, Activity, Report, Markdown, Summary und History.
- `WhisperM8/Views/AgentSessionDetailView.swift` ist die Detailfläche für interaktive PTY-Sessions.
- `WhisperM8/Views/SubagentJobDetailView.swift` ist die Detailfläche für headless Codex-Subagent-Jobs vor der Übernahme.

## Test-Cluster

- `Tests/WhisperM8Tests/AgentChatsViewModelTests.swift` deckt die ViewModel-Fassade für Session-/Projektmutationen ab.
- `Tests/WhisperM8Tests/AgentSidebarTests.swift` deckt Sidebar-Gruppierung, Scope, Subagent-Kindgruppierung, Footer-Split und sichtbare Rows ab.
- `Tests/WhisperM8Tests/AgentDragDropPlannerTests.swift` deckt beide Reorder-Richtungen, No-ops, Cross-Project-Moves, Projekt-Reorder und Store-Ausführung ab.
- `Tests/WhisperM8Tests/AgentResourceMonitorTests.swift` deckt Prozessbaum-Aggregation, fehlenden Gesamtspeicher und nicht laufende Root-Prozesse ab.
- `Tests/WhisperM8Tests/AgentWindowStoreTests.swift` und `Tests/WhisperM8Tests/AgentUIStateTests.swift` decken Fenster-/Tab-Store, Persistenz, Invarianten und Migration ab.
- `Tests/WhisperM8Tests/TabSelectionResolverTests.swift`, `TabReorderGeometryTests.swift`, `TabGroupReorderTests.swift`, `TabNavigationTests.swift`, `TabNavShortcutTests.swift`, `TabSwitcherModelTests.swift`, `TabSwitcherShortcutTests.swift` und `TabScrollSwipeRecognizerTests.swift` decken Tab-Auswahl, Reorder, Navigation, Switcher und Swipe ab.
- `Tests/WhisperM8Tests/TerminalKeyboardShortcutTests.swift`, `TerminalLinkResolverTests.swift` und `AgentTerminalSessionTests.swift` decken die terminalnahen UI-Resolver und Session-Integration ab.
- `Tests/WhisperM8Tests/TranscriptTimelineBuilderTests.swift`, `MarkdownBlockParserTests.swift` und `TeammateMessageParserTests.swift` decken die UI-nahe Timeline-, Markdown- und Teammate-Projektion ab; Indexer, Runtime-Status, Transcript-Reader und Context-Bundle gehören zum Sessions-/Diktat-Datenkern und werden dort dokumentiert.

## Keywords

Agent-Chat-UI-Architektur, `AgentSidebarModelBuilder`, Variante D,
Subagent-Expansion, ephemeres Aufklappen, selektiertes Kind, Unread zuerst,
blauer Unread-Dot, `clearSubagentUnread`, Sidebar-Drag-and-Drop,
`AgentDragDropPlanner`, `AgentSessionDropPlan`, `AgentProjectDropPlan`,
richtungsabhängiger Session-Reorder, Cross-Project-Move, Projekt-Reorder,
Overlay-Scroller, 15-Punkt-Legacy-Scroller, `overlayScrollers()`,
`OverlayScrollersApplier`, `preferredScrollerStyleDidChangeNotification`,
Ressourcenmonitor, CPU, RSS, RAM Share, Prozessbaum, `/bin/ps`, `sysctl`,
`AgentResourceMonitor`, `AgentResourceSummaryButton`, 10-Sekunden-Polling,
2-Sekunden-Polling, inaktives Fenster, Pipe-Drain, Child-Deadlock,
`AgentResourceMonitorTests`, `AgentDragDropPlannerTests`.
