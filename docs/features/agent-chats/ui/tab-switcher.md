---
description: Ctrl+Tab-Switcher der Agent Chats — Umfang nach Situation, Stand-Kacheln, Performance-Regeln
description_long: |
  Ist-Zustand des Ctrl+Tab-Switchers: kein globaler Modus, sondern drei
  Situationen (Grid sichtbar → Pane-Markierung, maximierter Workspace-Chat →
  Mini-Map, sonst → Projekt-Liste), Reihenfolge in Leserichtung der Slots,
  Kacheln mit Status, Stand-Zeile und Dauer aus dem ohnehin gelesenen
  Transcript-Tail. Plan und Begründung: docs/plans/tab-switcher-workspace.md.
updated: 2026-10-04
---

# Ctrl+Tab-Switcher

⌃Tab wechselt zwischen den Chats, mit denen man gerade arbeitet — nicht
zwischen allen offenen Tabs. Die Übersicht über alles bleibt Sache der
Sidebar und von `whisperm8 chats overview`. Plan mit Befund und
Entscheidungen: [`../../../plans/tab-switcher-workspace.md`](../../../plans/tab-switcher-workspace.md).

## Drei Situationen

Welche gilt, entscheidet die pure Funktion `TabSwitcherScope.resolve`
(Views/). Weniger als zwei Ziele → kein Switcher, und bewusst kein Rückfall
auf eine andere Situation.

| Situation | Umfang | Darstellung | Loslassen von ⌃ |
|---|---|---|---|
| **A** Grid sichtbar | belegte Slots des aktiven Workspace | kein Overlay — die echten Panes werden markiert | Pane bekommt den Fokus (`navigateToSession`) |
| **B** Einzelansicht, Chat liegt im referenzierten Workspace (maximiert) | belegte Slots dieses Workspace | Mini-Map im Layout des Grids | Ziel wird groß, Grid bleibt verborgen, Pane-Fokus zieht mit |
| **C** Einzelansicht ohne Workspace-Bezug | offene Tabs desselben Projekts | Projekt-Liste | Tab wird selektiert |

- **Reihenfolge im Workspace = Slot-Index** — die Slots sind die Leserichtung
  (links → rechts, oben → unten); jeder Chat kommt immer an derselben Stelle
  dran. In C gilt die Tab-Leisten-Reihenfolge.
- Leere Slots, archivierte Chats und Übernahme-Platzhalter (Tab gehört einem
  anderen Fenster) fallen heraus — nichts davon ist fokussierbar.
- B nur, wenn `activeWorkspaceID` des Fensters den selektierten Chat enthält.
  Liegt der Chat in einem anderen Workspace, ist das C.

## Bedienung

Allen Situationen gemeinsam: ⌃Tab / ⌃⇧Tab mit Wrap-around, der erste
Druck macht sofort einen Schritt (schneller Tap = Nachbar-Wechsel),
Loslassen von ⌃ oder Return committet, Esc bricht ab, jede andere Taste
bricht ab und wird geschluckt (ein ⌃C erreicht nie die TUI). Klick auf eine
Kachel bzw. Pane committet sofort; Hover verschiebt nie das Highlight.

| | Pfeiltasten | Fußzeile |
|---|---|---|
| **A** | räumlich über `GridFocusNavigator` (wie ⌃⌘-Pfeile), kein Wrap | keine — es gibt kein Overlay |
| **B** | räumlich über `TabSwitcherMiniMapGeometry.spatialTarget`, kein Wrap | `⌃Tab weiter · ⇧ zurück · Pfeile räumlich · Esc` |
| **C** | jede Pfeiltaste ein Schritt in der Liste, mit Wrap | `⌃Tab weiter · ⇧ zurück · ↑↓ wählen · Esc` |

Die Fußzeilen-Texte stehen zentral in `TabSwitcherHint`.

## Darstellung

- **Kachel** `TabSwitcherTile` — eine für alle drei Situationen: Status
  flächig (Tönung + Rand) und immer auch als Wort und Symbol, Titel,
  Stand-Zeile, Dauer im Zustand („arbeitet · 2 min", „vor 12 min").
  Stufen voll / ohne Stand-Zeile / nur Status + Titel; die Stand-Zeile fällt
  zuerst weg, nie der Status. Modell: `TabSwitcherTileModel` (pur).
- **A** `TabSwitcherGridPaneMarking` je Slot (immer als `.overlay`, damit das
  Terminal nicht remountet): Nicht-Ziele ~35 % abgedunkelt, Ziel mit
  2-pt-Akzent-Rahmen und Status-Chip oben links. Pure Logik in
  `TabSwitcherGridMarking`.
- **B** `AgentTabSwitcherMiniMap`: Geometrie ausschließlich aus
  `TabSwitcherMiniMapGeometry`, das dieselben Bausteine wie der
  Grid-Renderer nutzt (`AgentGridSplitContainer.blocks(inRow:layout:)`,
  `GridSplitResolver.trackSizes`) — keine eigene Tabelle. Die maximierte
  Kachel trägt „Hier".
- **C** `AgentTabSwitcherOverlay`: eine Spalte Kacheln (`TabSwitcherListLayout`,
  56 pt), scrollt erst bei Platzmangel und hält das Highlight in Sicht.

## Stand-Zeile

Entsteht im `AgentSessionRuntimeWatcher` aus dem 64-KB-Tail, den `pollSnapshot`
ohnehin liest — keine zusätzliche Datei-I/O, nur bei geänderter Datei.
`AgentTranscriptActivityExtractor` (pur) geht rückwärts über den Tail: letztes
Tool mit erstem Argument, Frage aus `AskUserQuestion`, erster Satz der letzten
Antwort; 80 Zeichen, Pfade auf den Dateinamen gekürzt, einzeilig. Warte-Art
(Frage, Plan, Berechtigung) kommt bei Claude aus dem Hook-Pfad; Codex hat keine
Hooks und zeigt nur „wartet". Nichts davon wird persistiert.

Ablage im eigenen `AgentSessionActivityStore` (Activity + `statusSince`),
gesetzt im `AgentSessionStatusCoordinator` nur bei echtem Statuswechsel.

## Performance-Regeln

Aus der Messung des „Alle"-Klicks (30.09.–01.10.2026): SwiftUI baut
`.contextMenu`-Inhalte bei jedem Body-Rebuild für jede Zeile mit, und jede
Statusänderung zeichnete die Sidebar neu. Daraus:

- Kein I/O und kein Scan über alle Sessions im Body von Kachel, Overlay,
  Mini-Map und Pane-Markierung. Den Umfang löst `refreshTabSwitcherScope` im
  Key-Event-Pfad auf und legt einen Snapshot ab.
- Kein `.contextMenu` auf Kacheln.
- **Die Sidebar beobachtet den `AgentSessionActivityStore` nie** — sonst
  invalidiert jede neue Stand-Zeile jede Row. Beobachtet wird er nur von
  Overlay, Mini-Map und Ziel-Chip, die nur während des Umschaltens leben.
- Dauer-Anzeigen ticken per `TimelineView` nur im offenen Switcher.
- Extractor-Kosten über `PerformanceCounters` (`activity.extracted`), kein
  eigenes Signpost-Intervall; er läuft im bestehenden
  `PerfBudgets.sidebarStatusPoll`.
- Situation A: Die Pane-Overlays lesen nur den kleinen
  `TabSwitcherGridMarkingState` (hervorgehobene ID). Ein Schritt invalidiert
  die Overlays, nicht das Grid samt Terminals; der Grid-Zweig des
  `AgentChatsView`-Body liest `tabSwitcher` nicht.

## Offen

- **⌃⌥Tab — Sprung zum am längsten wartenden Chat** (baut auf `statusSince`).
- Hintergrund-Agents und Agent-Views zeigen nur Status + Dauer.

## Manuelle QA (nicht unit-testbar)

Terminal-Eingabe während des Durchlaufs erreicht das Pane nicht, Mausklick
committet, Esc stellt den alten Fokus her, Grid-Resize während des
Durchlaufs, Mini-Map bei 2–9 Slots, Liste mit vielen Tabs scrollt mit.

## Schlüsseldateien

- `WhisperM8/Views/TabSwitcherScope.swift` — Umfang und Reihenfolge (A/B/C).
- `WhisperM8/Views/TabSwitcherModel.swift` — Durchlauf-Maschine, Listen-Metrik, Fußzeilen-Texte.
- `WhisperM8/Views/TabSwitcherShortcut.swift` — Tastenerkennung.
- `WhisperM8/Views/TabSwitcherTile.swift`, `TabSwitcherTileModel.swift` — Kachel.
- `WhisperM8/Views/TabSwitcherGridMarking.swift`, `TabSwitcherGridPaneMarking.swift` — Situation A.
- `WhisperM8/Views/TabSwitcherMiniMapGeometry.swift`, `AgentTabSwitcherMiniMap.swift` — Situation B.
- `WhisperM8/Views/AgentTabSwitcherOverlay.swift` — Situation C.
- `WhisperM8/Views/AgentChatsView+Shortcuts.swift` — Monitore, Scope-Snapshot, Commit.
- `WhisperM8/Services/AgentChats/AgentTranscriptActivityExtractor.swift`, `AgentSessionActivityStore.swift` — Stand-Daten.
- Tests: `TabSwitcherScopeTests`, `TabSwitcherModelTests`, `TabSwitcherShortcutTests`, `TabSwitcherTileModelTests`, `TabSwitcherMiniMapGeometryTests`, `TabSwitcherGridMarkingTests`, `AgentTranscriptActivityExtractorTests`.

## Keywords

Ctrl+Tab, ⌃Tab, Tab-Switcher, Umschalter, Workspace, Grid-Markierung,
Mini-Map, Projekt-Liste, Leserichtung, Stand-Zeile, Stand-Kachel,
`statusSince`, `TabSwitcherScope`, `TabSwitcherModel`, `TabSwitcherTile`,
`AgentTabSwitcherOverlay`, `AgentTabSwitcherMiniMap`,
`TabSwitcherGridPaneMarking`, `AgentSessionActivityStore`,
`AgentTranscriptActivityExtractor`.
