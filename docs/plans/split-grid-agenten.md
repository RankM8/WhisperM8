# Plan: Split-Grid — mehrere Agent-Sessions nebeneinander in einem Fenster

Stand: 2026-07-12 · Status: **Plan-Entwurf, in Beratung** · Vorbild: BridgeMind BridgeSpace
(2×2-Terminal-Grid, siehe Screenshot-Analyse unten). Schwester-Plan:
[`kompakt-chat-fenster.md`](kompakt-chat-fenster.md) (dort: ein Chat klein; hier: viele Chats
gleichzeitig groß).

## Context

BridgeSpace zeigt bis zu 16 Agent-Terminals in Split-Grids: jede Pane hat einen Header
(Provider · Projekt, Branch-Chip, Split-/Close-Controls), eine eigene Prompt-Zeile und
gerenderte Agent-Ausgabe (Diff-Blöcke, Testresultate). WhisperM8 zeigt heute **eine** Session
pro Fenster (Tab-Strip wählt); „mehrere gleichzeitig sehen" geht nur über Tear-off in mehrere
Fenster + manuelles macOS-Tiling.

Warum das bei uns günstig ist:

- **PTYs sind fenster-unabhängig**: `AgentTerminalRegistry` hält Controller sessionID-basiert
  (`Views/AgentTerminalView.swift:264`), `attach(_:to:)` (`:839`) hängt jede Terminal-View in
  jede Hierarchie. N Panes = N Sessions = N vorhandene Controller — kein neuer Prozess-Code.
- **Der Fenster-State ist store-first**: `AgentWindowStore`/`AgentUIState` halten `openTabIDs`
  + `selectedSessionID` pro Fenster (`AgentUIState.swift:13`) — ein Grid ist nur eine andere
  *Präsentation* derselben Tabs.
- **Pure-Logik-Konvention**: Selektion/Reorder sind als testbare pure Typen gebaut
  (`TabSelectionResolver`, `TabReorderGeometry`) — die Grid-Zuteilung bekommt denselben Schnitt.

Unterschied zu BridgeMind, bewusst akzeptiert (V1): unsere Panes zeigen die **rohe TUI**
(Claude/Codex rendern selbst), kein geparster Block-Stream und keine separate Prompt-Zeile pro
Pane — Eingabe geschieht in der TUI der fokussierten Pane. Eine Block-Ansicht existiert als
Zukunftsoption über die Transcript-Reader (Chat-Look Variante E), siehe „Offene Entscheidungen".

## Zielbild

```
┌────────────────────────────────────────────────────────┐
│ Sidebar │ [Tab][Tab][Tab][Tab]          ⊞ 1│2│2×2      │ ← Grid-Preset-Umschalter
│         │──────────────────────────────────────────────│
│ Projekte│ ● claude · api   ⎇main ✕ │ ● codex · api  ✕ │ ← Pane-Header: Status-Dot,
│  + Rows │   (PTY, live)            │   (PTY, live)     │   Provider · Projekt, Branch,
│         │──────────────────────────┼───────────────────│   Close (dauerhaft sichtbar)
│         │ ● codex · db          ✕ │ ● zsh… (leer: Tab │
│         │   (PTY, live)            │   hierher ziehen) │
└────────────────────────────────────────────────────────┘
  Fokus-Pane mit Akzent-Rahmen; Klick in Pane = Terminal-Fokus + selectedSessionID
```

- **Presets statt Freiform-Splits**: 1 (heute), 1×2, 2×1, 2×2. Deckt den realen Bedarf, hält
  Layout-Logik pur und testbar; freies Verschachteln (à la BridgeSpace 16er) ist V2-Option.
- **Grid = Sichtfenster auf die Tabs**: die Panes zeigen eine Teilmenge der `openTabIDs`.
  Tab-Klick füllt die fokussierte Pane; Drag eines Tabs auf eine Pane belegt sie gezielt
  (bestehende `DraggableSession`-Infrastruktur).
- **Genau eine Pane ist fokussiert** (Akzent-Rahmen, dauerhaft sichtbar — kein Hover-only):
  sie empfängt Tastatur (PTY-Fokus), Dictation-Routing („aktiver Agent-Chat") und ist
  `selectedSessionID`. Damit bleiben alle bestehenden Semantiken (Inspector, Auto-Paste in
  aktiven Chat) eindeutig.

## Teil A — Store & Layout-Zustand

- `AgentChatWindowState` um optionale Felder erweitern: `gridPreset: GridPreset` (Default
  `.single`) und `paneSessionIDs: [UUID?]` (Slot→Session, `nil` = leere Pane). Invarianten in
  `normalizedWindows` (`AgentUIState.swift:381`) ergänzen: Pane-Sessions ⊆ `openTabIDs`,
  keine Session in zwei Panes, `selectedSessionID` ∈ Panes (bei `gridPreset != .single`).
  `decodeIfPresent` mit Defaults → kein Schema-Bump.
- Neue pure Logik `PaneAssignmentResolver` (analog `TabSelectionResolver`): Tab-Klick →
  Ziel-Slot (fokussierte Pane), Tab-Close → Slot-Nachrücken aus unbelegten Tabs, Preset-Wechsel
  → Slot-Erhalt (2×2→1×2 behält die ersten beiden, Rest bleibt als Tab offen). Unit-Tests
  spiegeln die `TabSelectionResolver`-Testdatei.
- `AgentWindowStore`: `gridPreset(in:)`/`setGridPreset`, `paneAssignment(in:)`/`assignPane`,
  Persistenz über den vorhandenen `scheduleSave()`-Pfad. Tear-off/`removeWindow` räumen
  Pane-Slots mit ab (Tests).

## Teil B — Grid-Container & Pane-Chrome

- Neue Datei `Views/AgentChatsView+Grid.swift`: bei `gridPreset != .single` ersetzt ein
  Grid-Container den einzelnen Content (Muster Archiv-/Kompakt-Modus). Pro Slot eine
  `AgentPaneView`: Header + `AgentTerminalView(sessionID:)` — `attach()` erledigt das Hosting,
  SwiftTerm meldet die neue Spaltenzahl je Pane an die PTY.
- **Pane-Header** (wiederverwenden statt neu): Status-Dot über `statusPublisher(for:)` +
  `.onReceive`-Muster wie `SessionListButton` (`AgentChatsSidebarViews.swift:774`),
  Provider-Icon, Session-Name, Branch-Chip (Datenquelle wie Sidebar-Gruppenheader), Close (=
  Pane leeren, Tab bleibt offen). Leere Pane = Drop-Ziel „Tab hierher ziehen" + Plus für neuen
  Chat im Fenster-Projekt.
- **Preset-Umschalter** in der Titelzone neben dem Tab-Strip (Symbole `rectangle`,
  `rectangle.split.2x1`, `rectangle.split.1x2`, `square.grid.2x2`); Shortcut-Vorschlag
  ⌘⌥1–⌘⌥4. Trennlinien zwischen Panes zunächst fix 50 % (verstellbare Splits = V2, Muster
  `SidebarWidthResolver`).
- Drop-Ziel pro Pane über die bestehende `DraggableSession`-Transferable; Cross-Window-Drop
  funktioniert wie beim Tab-Strip (Quell-Auswahl live aus dem Store).

## Teil C — Fokus, Selektion, Routing

- Klick irgendwo in eine Pane → `selectedSessionID = pane.sessionID` + `makeFirstResponder`
  auf deren Terminal-View; Fokus-Rahmen via Akzent (dauerhaft, nicht nur bei Key-Window).
- Tab-Strip-Verhalten im Grid: Klick auf Tab, der schon in einer Pane liegt → diese Pane
  fokussieren; sonst → fokussierte Pane ersetzt ihren Inhalt. ⌘1–⌘9 folgt derselben Semantik.
- Dictation-Routing und „aktiver Agent-Chat" (AppState) hängen an `selectedSessionID` — durch
  die Ein-Fokus-Pane-Regel ändert sich hier nichts (Regressionstest).
- `AgentSessionRuntimeWatcher`: mehrere gleichzeitig sichtbare Live-Sessions sind bereits sein
  Normalfall (Sidebar) — keine Änderung; nur die vnode-Quellen der Pane-Sessions bleiben wie
  gehabt aktiv.

## Teil D — Performance & Feinschliff

- **Perf-Risiko ernst nehmen**: 4 parallel streamende SwiftTerm-Views sind der Hot-Path, an dem
  BridgeSpace nachweislich litt (deren 3.1.11-Changelog: Multi-Terminal-Freezes durch
  Fokus-Feedback-Loop) und wir Scroll-Jank-Vorgeschichte haben
  (`docs/…/terminal-ux-root-causes`-Memory). Maßnahmen: Signpost-Kategorie `perf.grid`
  (Frame-Budget beim parallelen Streamen), Redraw-Drosselung nicht-fokussierter Panes prüfen
  (SwiftTerm-Refresh-Rate), QA-Szenario „4 × working gleichzeitig".
- Grid-Zustand überlebt Relaunch (Teil A); Fenster-Restore baut Panes direkt auf.
- Kompakt-Modus (`kompakt-chat-fenster.md`) und Grid schließen sich pro Fenster aus:
  `isCompact` erzwingt `gridPreset = .single` (Normalisierung).
- Bulk-Kontextmenü/Multi-Select bleiben unberührt (Panes sind keine Selektion).

## Offene Entscheidungen (vor Umsetzung klären)

1. **Max. Panes V1 = 4?** (BridgeSpace kann 16 — bei roher TUI unter 2×2 unbrauchbar eng.)
   Empfehlung: 4, mit purer Logik, die später mehr Slots trägt.
2. **Block-Ansicht statt roher TUI** für nicht-fokussierte Panes (read-only Transcript-Tail im
   Chat-Look, Variante E) — spart Rendering und liest sich bei kleinen Panes besser, kostet
   aber einen zweiten Darstellungspfad. Empfehlung: V2, erst Perf-Daten aus V1 abwarten.
3. **Verstellbare Split-Verhältnisse** (V1 fix 50 % vs. Divider-Drag)?
4. **Preset-Shortcuts** ⌘⌥1–4 okay? (⌘1–9 = Tabs, ⌘⌥←/→ = Tab-Wechsel sind belegt.)

## Verifikation

- 2×2 mit 4 aktiven Sessions: alle Status-Dots live, Tastatur geht ausschließlich an die
  Fokus-Pane, Dictation landet im fokussierten Chat.
- Preset-Wechsel 2×2→1×2→1: kein PTY-Neustart (PIDs stabil), überzählige Sessions bleiben als
  Tabs, Scrollback lückenlos.
- Tab-Drag auf Pane (gleiches + fremdes Fenster): Slot-Belegung korrekt, Invarianten
  (`normalizedWindows`) halten, keine Session doppelt sichtbar.
- Perf: 4 × working, 60 s streamen → `perf.grid`-Budget eingehalten, UI bleibt responsiv
  (kein Beachball, Scroll in fokussierter Pane flüssig).
- Alte `agent-ui-state.json` lädt fehlerfrei; Relaunch stellt Grid samt Belegung wieder her.
- `swift test` für `PaneAssignmentResolver`/`AgentUIState`-Erweiterungen grün; Grid-Interaktion
  (Drag, Fokus-Rahmen) manuelle QA.
