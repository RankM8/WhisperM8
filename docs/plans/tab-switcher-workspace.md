---
status: umgesetzt
stand: 2026-10-04
---

# Ctrl+Tab-Switcher: Workspace statt global, mit Stand-Zeile

> **Status (04.10.2026): umgesetzt, S1–S6.** Ist-Zustand:
> [`../features/agent-chats/ui/tab-switcher.md`](../features/agent-chats/ui/tab-switcher.md).
> Offen bleibt der Slice „⌃⌥Tab — nächster wartender Chat" (siehe
> „Offen / später"); deshalb liegt der Plan noch hier und nicht im Archiv.

## Befund

Der Switcher wird nicht benutzt. Drei Gründe, alle im Code nachvollziehbar:

1. **Zu viel.** Er zeigt `visualHeaderTabs` (`AgentChatsView.swift:580`) —
   alle offenen Tabs über alle Projekte. Man sucht, statt zu wechseln.
2. **Beliebige Anordnung.** Feste Karten 236 × 128 pt, bis zu 4 Spalten
   (`TabSwitcherGridLayout`), Reihenfolge der Tab-Leiste. Mit dem Grid, das
   man sich eingerichtet hat, hat das nichts zu tun — das räumliche
   Gedächtnis („oben rechts") hilft nicht.
3. **Kein Stand.** Titel, Projekt, Branch, persistierte
   `summary?.headline`. Der Status ist ein 6-pt-Punkt. Ob ein Chat arbeitet,
   seit wann er wartet, woran er ist — nicht sichtbar.

Dazu: Im Grid legt sich das Overlay über genau die Panes, die man ohnehin
sieht, und zeigt eine schlechtere Kopie davon.

## Entscheidungen (User, 28.09.2026)

- **Globaler Modus entfällt.** Übersicht über alles bleibt Sache der Sidebar
  und von `whisperm8 chats overview`.
- **Reihenfolge im Workspace = Leserichtung** der Slots (links → rechts,
  oben → unten). Jeder Chat kommt immer an derselben Stelle dran.
- **Mit Stand-Zeile:** pro Chat eine Zeile, woran er gerade ist.

## Das neue Verhalten

Der Switcher kennt drei Situationen. Welche gilt, entscheidet eine pure
Funktion (`TabSwitcherScope`, siehe S1).

| Situation | Umfang | Darstellung | Loslassen von Ctrl |
|---|---|---|---|
| **A** Grid sichtbar | belegte Slots des aktiven Workspace | **kein Overlay** — die echten Panes werden markiert | Pane bekommt den Fokus |
| **B** Einzelansicht, Chat liegt im referenzierten Workspace (maximiert) | belegte Slots dieses Workspace | **Mini-Map** im Layout des Grids | dieser Chat wird groß, Grid bleibt verborgen |
| **C** Einzelansicht ohne Workspace-Bezug | offene Tabs **desselben Projekts** | kompakte Kachel-Liste | Tab wird selektiert |

Weniger als 2 Ziele → kein Switcher (wie heute, `TabSwitcherModel.begin`).

### A — Markierung im Grid

- Ctrl+Tab dunkelt alle Panes leicht ab (Scrim je Pane, ~35 %), das Ziel
  bekommt einen Akzent-Rahmen (2 pt) und oben links einen großen
  Status-Chip mit Stand-Zeile.
- Ctrl+Tab / Ctrl+Shift+Tab: Leserichtung mit Wrap-around. Pfeiltasten bei
  gehaltenem Ctrl: geometrisch über `GridFocusNavigator` (dieselbe Logik
  wie ⌃⌘-Pfeile).
- Loslassen → `windowStore.navigateToSession` (zentraler Pfad, landet bei
  sichtbarem Grid in `setGridFocusedSession`). Esc → Abbruch, Fokus bleibt.
- Klick auf ein Pane während des Durchlaufs = sofortiger Commit.
- Leere Slots und **Übernahme-Platzhalter** (Tab gehört einem anderen
  Fenster) werden übersprungen — beides kann man nicht fokussieren.

Warum kein Overlay: Man schaut auf sein echtes Layout. Das Terminal bleibt
sichtbar, das Umschalten kostet keinen Kontextwechsel.

### B — Mini-Map im maximierten Zustand

Das ist der eigentliche Durchtab-Fall: ein Chat groß, die anderen im Kopf.

```
┌──────────── Workspace „Refactor" ────────────┐
│ ┌──────────────────┐ ┌────────┐ ┌──────────┐ │
│ │● arbeitet · 2 min│ │◐ wartet│ │○ fertig  │ │
│ │Store-Migration   │ │ 4 min  │ │Tests     │ │
│ │› Edit Store.swift│ │Frage:  │ │vor 12 min│ │
│ └──────────────────┘ │Branch? │ └──────────┘ │
│ ┌─────────────────────────────┐ ┌──────────┐ │
│ │● arbeitet · 30 s            │ │○ idle    │ │
│ └─────────────────────────────┘ └──────────┘ │
│  ⌃Tab weiter · ⇧ zurück · Pfeile räumlich · Esc │
└──────────────────────────────────────────────┘
```

- **Gleiche Geometrie wie das Grid**, keine eigene: Zeilen-Blöcke aus
  `AgentGridSplitContainer.blocks(inRow:layout:)`, Spurmaße aus
  `GridSplitResolver.trackSizes` mit `columnFractions`/`rowFractions` der
  Entity, skaliert auf die Overlay-Fläche. Eine zweite Tabelle wäre die
  zehnte Quelle (vgl. `grid-smart-layout.md`).
- Seitenverhältnis der Mini-Map = Seitenverhältnis des Content-Bereichs.
  Größe: höchstens 70 % der Content-Fläche, mindestens so groß, dass eine
  1/9-Kachel 150 × 72 pt hat; darunter wird die Stand-Zeile weggelassen,
  nie der Status.
- Die aktuell maximierte Kachel trägt ein „Hier"-Zeichen; der Durchlauf
  startet bei ihr und macht sofort einen Schritt (schneller Tap =
  Nachbar-Wechsel, wie heute).
- Loslassen → `windowStore.showSingleSession(target)`. `showsGrid` bleibt
  `false`, `activeWorkspaceID` bleibt — „Zurück zum Workspace" funktioniert
  weiter. Entspricht E4 aus `workspace-umbau/02-entscheidungen` (Klick bei
  Zoom wechselt Inhalt, Zoom bleibt).
- `gridFocusSessionID` wird **auf das Ziel mitgezogen**, damit „Zurück zum
  Workspace" beim zuletzt angesehenen Chat landet statt beim ursprünglichen.
  (Ohne das hätte der Rücksprung einen überraschenden Fokus.)

### C — Projekt-Liste

- Offene Tabs mit `projectID == selectedSession.projectID`, in
  Tab-Leisten-Reihenfolge.
- Darstellung: eine Spalte Kacheln (volle Breite, ~56 pt hoch), Status +
  Titel + Stand-Zeile + Dauer. Bei vielen Tabs scrollt die Liste und hält
  das Highlight in Sicht (vorhandene Scroll-Logik übernehmen).
- Chat liegt zwar in einem Workspace, das Fenster referenziert aber einen
  anderen (oder keinen) → C, nicht B. B nur, wenn
  `window.activeWorkspaceID` den selektierten Chat enthält.

## Stand-Zeile — Datenlage

**Geprüft 28.09.2026.** Der `AgentSessionRuntimeWatcher` liest bei jeder
Dateiänderung die letzten 64 KB des Transcripts (`tailReadBytes`) off-main
in `pollSnapshot`, wirft aber alles bis auf den Event-Typ weg:
`AgentTranscriptEvent` trägt nur Zeitstempel und `stopReason`, keinen Inhalt.
Ein Tool-Name, eine Frage oder ein Antwortsatz ist nirgends im Speicher.

`AgentChatTailExtractor` liest ganze Nachrichten, ist aber für das Diktat
gebaut (öffnet das Transcript selbst) — für den Switcher zu teuer.

Der Hook-Pfad kennt `toolName` (`ClaudeHookEvent`) und über
`AgentSessionStateMachine.awaitingKind` die Warte-Art (Frage,
Plan-Freigabe, Berechtigung) — Codex hat keine Hooks.

Es fehlt außerdem ein **Zeitpunkt des letzten Statuswechsels**:
`AgentSessionRuntimeStatusStore` speichert nur den Status.

**Folgerung:** Die Stand-Zeile entsteht im Watcher aus dem Tail, der
ohnehin schon gelesen wird. Keine zusätzliche Datei-I/O, und nur bei
geänderter Datei (der Stat-first-Pfad bleibt unberührt).

### Was die Zeile zeigt

| Status | Zeile | Quelle |
|---|---|---|
| arbeitet | `› Edit Store.swift` / `› Bash swift test` / `› schreibt Antwort` | letzter `tool_use` (Claude) bzw. `function_call` (Codex) im Tail, Name + erstes Argument gekürzt |
| wartet: Frage | `Frage: <erste Zeile der Frage>` | `AskUserQuestion`-tool_use im Tail |
| wartet: Plan | `Plan zur Freigabe` | Warte-Art aus dem Hook |
| wartet: Berechtigung | `Freigabe: Bash git push` | Hook-`toolName` + tool_use im Tail |
| fertig/idle | erster Satz der letzten Antwort | letzte Assistant-Textnachricht im Tail |
| gestoppt/Fehler | `gestoppt` / `Fehler` | Status |

Dazu überall die Dauer im Zustand: „arbeitet · 2 min", „wartet · 4 min",
„vor 12 min".

Längen: Zeile auf 80 Zeichen gekappt, Pfade auf den Dateinamen reduziert,
Zeilenumbrüche entfernt. Nichts davon wird persistiert.

## Performance-Regeln (Abgleich 02.10.2026)

Aus der Messung „Alle"-Klick (30.09.–01.10.2026, `perf/sidebar-cli`):
SwiftUI baut `.contextMenu`-Inhalte bei jedem Body-Rebuild für jede Zeile
mit, die Sidebar-Liste ist ein nicht-lazy `VStack` (jede Zeile bekommt sofort
Layer), und jede Statusänderung zeichnet die Sidebar neu. Daraus für den
Switcher:

- **Kein I/O und kein Scan über alle Sessions im View-Body** von Kachel,
  Overlay, Mini-Map und Pane-Markierung. Lookups über vorab gebaute
  Dictionaries; Profile/Journal nie aus dem Body lesen.
- **Kein `.contextMenu` auf Kacheln.**
- **Die Sidebar beobachtet den `AgentSessionActivityStore` nie**, auch nicht
  indirekt über einen gemeinsamen Elternwert. `statusSince` lebt dort, nicht
  im `AgentSessionRuntimeStatusStore`.
- **Dauer-Anzeigen ticken nur im offenen Switcher** (`TimelineView` innerhalb
  des Overlays), nie in Sidebar-Zeilen oder Tabs.
- **Extractor-Kosten über Zähler** (`PerformanceCounters`), kein zusätzliches
  Signpost-Intervall pro Datei; er läuft im bestehenden
  `PerfBudgets.sidebarStatusPoll`-Intervall. Vorher/nachher mit
  `scripts/perf-load.sh` messen.
- Situation A: Die Pane-Overlays hängen an einem kleinen, eigenen
  Beobachtungswert (hervorgehobene ID), damit ein Schritt nicht das ganze
  Grid samt Terminals neu auswertet.

## Umsetzung in Slices

Jeder Slice ist einzeln baubar, testbar und committbar. Tests nach der
Hauskonvention (pure Logik, Closures statt DI-Framework).

### S1 — Umfang und Reihenfolge (pur)

- Neu: `TabSwitcherScope` (Views/, pur):
  `resolve(showsGrid:activeWorkspace:selectedSessionID:openTabs:hostWindowForTab:) -> Scope?`
  mit `.grid(order)`, `.workspaceMap(entityID, order)`, `.project(order)`.
  Reihenfolge im Workspace = Slot-Index aufsteigend (die Slots SIND die
  Leserichtung), leere Slots und fremd gehaltene Tabs entfernt.
- `handleTabSwitcherKeyDown` (`+Shortcuts:164`) nimmt die Reihenfolge aus
  dem Scope statt aus `visualHeaderTabs`. `TabSwitcherModel` bleibt
  unverändert — es bekommt schon heute die Reihenfolge je Schritt gereicht.
- Das bestehende Overlay zeigt übergangsweise nur die Scope-Sessions. Damit
  ist der globale Modus schon nach S1 weg.
- Tests `TabSwitcherScopeTests`: alle drei Fälle, leere Slots, fremdes
  Fenster, Chat in zwei Workspaces, Projekt mit einem Tab (→ `nil`),
  archivierte Sessions.

### S2 — Stand-Daten (pur + Watcher)

- Neu: `AgentTranscriptActivityExtractor` (Services/AgentChats/, pur):
  `activity(in tail: String, provider:) -> AgentSessionActivity?` —
  rückwärts über die Tail-Zeilen, erste Fundstelle gewinnt. Kürzungsregeln
  aus der Tabelle oben.
- `pollSnapshot` ruft ihn im selben Detached-Task direkt nach
  `AgentTranscriptParser.lastEvent` auf; `AgentSessionRuntimePollSnapshot`
  bekommt ein Feld `activity`. Im Stat-first-Pfad bleibt der gecachte Wert.
- Neu: `AgentSessionActivityStore` (`@MainActor`, `ObservableObject`) mit
  `[UUID: AgentSessionActivity]` und `statusSince: [UUID: Date]`.
  **Eigener Store, nicht in `statuses`** — sonst invalidiert jede neue
  Stand-Zeile jede Sidebar-Row (P4-Regel). Beobachtet wird er nur vom
  Switcher, der nur während des Umschaltens existiert.
- `statusSince` wird im `AgentSessionStatusCoordinator` gesetzt, genau an den
  Stellen, die `statusStore.setStatus` rufen (`:263–269`, `:446`), und nur
  bei echtem Wechsel.
- Warte-Art aus dem Hook-Pfad in die Activity übernehmen (Claude).
- Budget: der Extractor läuft innerhalb von `PerfBudgets.sidebarStatusPoll`;
  Test mit 64-KB-Tail als Laufzeit-Schranke (Muster wie
  `TranscriptTextRendererTests`).
- Tests `AgentTranscriptActivityExtractorTests`: Claude- und Codex-Fixtures
  für jede Tabellenzeile, abgeschnittene erste Zeile, Tail ohne Treffer,
  mehrzeilige Frage, sehr lange Bash-Befehle, Pfade.

### S3 — Stand-Kachel (View)

- Neu: `TabSwitcherTile` — eine Kachel, von allen drei Situationen genutzt.
  Status flächig (Hintergrund-Tönung + Rand), Titel, Stand-Zeile, Dauer.
  Größenstufen: voll / ohne Stand-Zeile / nur Status + Titel.
- Farbe allein trägt keine Bedeutung: Status auch als Wort („arbeitet",
  „wartet") und Symbol.
- Ersetzt `cardCell` in `AgentTabSwitcherOverlay`. Situation C ist damit
  fertig.

### S4 — Mini-Map (Situation B)

- Neu: `TabSwitcherMiniMapGeometry` (pur): Entity + Zielgröße → Rechteck je
  Slot, gebaut aus `AgentGridSplitContainer.blocks(inRow:layout:)` und
  `GridSplitResolver.trackSizes`. Test: für jede Kapazität 2–9 decken sich
  Mini-Map-Rechtecke (skaliert) mit den Grid-Rechtecken; kein Phantom-Slot.
- Overlay-Variante `AgentTabSwitcherMiniMap` mit `TabSwitcherTile`.
- Pfeiltasten im Overlay über `GridFocusNavigator` statt der heutigen
  Spalten-Schrittweite (`tabSwitcherColumns` entfällt hier).
- Commit: `showSingleSession` + `gridFocusSessionID` nachziehen (neue
  Store-Funktion, getestet in den `AgentWindowStore`-Tests).

### S5 — Markierung im Grid (Situation A)

- Kein Overlay mehr über `gridWorkspace`; stattdessen je Pane ein Overlay
  „abgedunkelt / Ziel" und am Ziel der Status-Chip mit `TabSwitcherTile`
  in kleiner Stufe.
- Die Pane-Overlays lesen nur `tabSwitcher?.highlightedID` — kein neuer
  `@State`-Write pro Schritt außer dem, den es schon gibt.
- Commit über `navigateToSession`.
- Manuelle QA (SwiftUI/NSEvent, nicht unit-testbar): Terminal-Eingabe
  während des Durchlaufs geht nicht ins Pane, Mausklick committet,
  Esc stellt den alten Fokus her, Grid-Resize während des Durchlaufs.

### S6 — Aufräumen

- `TabSwitcherGridLayout` + Tests entfernen, sobald S3–S5 stehen.
- Footer-Texte an die drei Situationen anpassen.
- Feature-Doku: Abschnitt in `docs/features/agent-chats/ui/` und
  Stichpunkt in `CLAUDE.md` (Tabs-Abschnitt).
- Eintrag hier auf „umgesetzt", Plan nach `docs/archive/`.

**Erledigt (04.10.2026):** Karten-Grid samt `Presentation.grid`,
`TabSwitcherGridLayout` und der Spalten-Schrittweite
(`tabSwitcherColumns`/`onColumnsChange`) entfernt — kein Pfad erreichte es
mehr (A rendert im Grid-Zweig ohne Overlay, B immer die Mini-Map). ↑/↓ in
der Liste = ein Schritt. Fußzeilen zentral in `TabSwitcherHint`
(C: `⌃Tab weiter · ⇧ zurück · ↑↓ wählen · Esc`, B: `… · Pfeile räumlich · Esc`;
A hat kein Overlay und keinen Hinweis). Feature-Doku
`docs/features/agent-chats/ui/tab-switcher.md`, Stichpunkt in `CLAUDE.md`.
Archivierung zurückgestellt, solange ⌃⌥Tab offen ist.

## Offen / später

- **Sprung zum nächsten wartenden Chat: ⌃⌥Tab** (User, 02.10.2026). ⌃\`
  lag auf deutschen ISO-Tastaturen auf der `<`-Taste; ⌃⌥Tab ist
  layoutunabhängig und gehört sichtbar zur ⌃Tab-Familie. Eigener kleiner
  Slice nach S5, baut auf `statusSince` auf (am längsten wartender zuerst).
- **Codex-Warte-Art.** Ohne Hooks kennt Codex nur den Transcript-Status —
  die Zeile zeigt dort „wartet", ohne Art.
- **Hintergrund-Agents und Agent-Views** haben ein anderes Transcript bzw.
  keins; sie bekommen vorerst nur Status + Dauer.

## Risiken

- **Tail-Parsing im Poll-Pfad.** Läuft pro geänderter Datei, bei vielen
  aktiven Chats im Sekundentakt. Deshalb pur, mit Laufzeit-Test, und
  rückwärts mit frühem Abbruch. Messung vorher/nachher über
  `perf.sidebar` (`scripts/perf-load.sh`).
- **Zwei Geometrie-Quellen im Grid.** Der Renderer nutzt
  `blocks(inRow:)`, der `GridFocusNavigator` `cell(forSlot:)`. S4 bindet
  die Mini-Map an den Renderer und prüft im Test, dass beide dieselben
  Zellen liefern — sonst widersprechen sich Pfeiltasten und Bild.
