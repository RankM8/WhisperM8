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

**Präzisierung (Verifikations-Befund 2026-07-12):** „Live-PTY" gibt es nur für Sessions mit
laufendem `AgentTerminalController` — PTYs entstehen ausschließlich über `startController`
(getriggert aus `AgentSessionDetailView.prepareCommand`). Eine Pane hostet deshalb die volle
`AgentSessionDetailView`-Verzweigung: lebender Controller → Live-PTY; sonst → read-only
Transcript bzw. `terminalEndedView`. **Auto-Panes starten nie selbst einen Prozess**
(kein `shouldLaunchOnOpen`-Trigger beim Auto-Befüllen — sonst spawnt ein Preset-Wechsel bis
zu 4 Prozesse); Live wird eine Auto-Pane nur, wenn der Controller schon existiert oder der
User explizit startet. Die Projekt-Ansicht zeigt also typischerweise eine Mischung aus
Live-Terminals und Transcript-Tails — das ist okay und dem BridgeMind-Block-Look sogar näher.

## Zielbild

```
┌────────────────────────────────────────────────────────┐
│ Sidebar │ [Tab][Tab][Tab]  [Projekt|Running] ⊞ 1│2│2×2 │ ← Ansicht- + Preset-Umschalter
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
- **Zwei Ansichten (Grid-Quelle), Umschalter in der Titelzone**:
  - **„Projekt" (Default)** — die Panes befüllen sich automatisch mit den Chats des aktuellen
    Projekts (`selectedProjectID`), Priorität `awaitingInput > working > zuletzt aktiv`. Bei
    mehr Chats als Panes: Top-N nach Priorität + Chip „+N weitere" (Klick öffnet Sidebar).
  - **„Running"** — laufende Sessions (`isLive`) über **alle** Projekte, gleiche Priorität;
    Pane-Header zeigt zusätzlich ein Projekt-Badge, weil cross-project. **Einschränkung
    (verifiziert):** der RuntimeWatcher watcht nur in-App gestartete bzw. hook-gebundene
    Sessions — extern im Terminal gestartete erscheinen hier nicht. Bewusst akzeptiert.
  - Kein dritter „Manuell"-Modus: **Drag eines Tabs/Chats auf eine Pane pinnt sie** (📌 im
    Pane-Header). Gepinnte Panes werden von der Automatik nie ersetzt; Pin lösen gibt den
    Slot an die Automatik zurück.
  - **Stabilitätsregeln** (sonst zappelt das Grid): die Fokus-Pane wird nie automatisch
    ausgetauscht; die Automatik füllt nur leere Panes, ersetzt beendete Sessions und lässt
    `awaitingInput` eine `idle`-Pane verdrängen — kein Reshuffle bei jedem Status-Tick.
- **Panes sind von Tabs entkoppelt**: in den Auto-Ansichten zeigen Panes Sessions unabhängig
  von `openTabIDs` (sonst würde die Automatik ständig Tabs öffnen/schließen). Tab-Klick
  fokussiert die passende Pane bzw. pinnt die Session in die Fokus-Pane; Drag belegt gezielt
  (bestehende `DraggableSession`-Infrastruktur).
- **Genau eine Pane ist fokussiert** (Akzent-Rahmen, dauerhaft sichtbar — kein Hover-only):
  sie empfängt Tastatur (PTY-Fokus), Dictation-Routing („aktiver Agent-Chat") und ist
  `selectedSessionID`. Damit bleiben alle bestehenden Semantiken (Inspector, Auto-Paste in
  aktiven Chat) eindeutig.

## Teil A — Store & Layout-Zustand

- `AgentChatWindowState` um optionale Felder erweitern: `gridPreset: GridPreset` (Default
  `.single`), `paneSource: PaneSource` (`.project` Default | `.running`) und
  `pinnedPaneSessionIDs: [UUID?]` (Slot→gepinnte Session, `nil` = Slot gehört der Automatik).
  Die **automatisch** befüllten Panes werden NICHT persistiert — sie sind eine Ableitung aus
  Workspace + Runtime-Status und werden zur Laufzeit berechnet. Invarianten in
  `normalizedWindows` (`AgentUIState.swift:381`): keine Session in zwei Slots (hart nötig —
  `attach()` reparentet per `removeFromSuperview`, dieselbe Terminal-View kann nur in EINEM
  Container leben), Pins nur auf existierende Sessions, `isCompact` erzwingt
  `gridPreset = .single`. Decoding via manuellem `init(from:)` mit `decodeIfPresent` (siehe
  Kompakt-Plan: synthetisiertes Codable + neues Pflichtfeld = stiller Datenverlust).
- **Fokus braucht ein eigenes Feld** (Verifikations-Befund): `normalizedWindows` setzt
  `selectedSessionID` hart auf `openTabIDs.first` zurück, sobald es nicht in den Tabs liegt —
  eine fokussierte Auto-Pane ohne Tab verlöre still die Selektion. Deshalb neues, der
  Tab-Invariante entzogenes `focusedPaneSessionID: UUID?` (nur bei `gridPreset != .single`
  belegt); Dictation-/AppState-Routing liest im Grid-Modus dieses Feld statt
  `selectedSessionID`.
- Neue pure Logik `PaneAssignmentResolver` (analog `TabSelectionResolver`): Eingabe =
  Preset, Ansicht, Pins, Fokus-Slot, Kandidaten-Sessions mit Status/zuletzt-aktiv; Ausgabe =
  Slot-Belegung. Kapselt Priorität (`awaitingInput > working > zuletzt aktiv`) und die
  Stabilitätsregeln (Fokus-Pane nie tauschen, nur leere/beendete/idle-Slots ersetzen,
  Preset-Wechsel behält vordere Slots). Unit-Tests spiegeln die
  `TabSelectionResolver`-Testdatei.
- `AgentWindowStore`: `gridPreset(in:)`/`setGridPreset`, `paneSource(in:)`/`setPaneSource`,
  `pinnedPanes(in:)`/`pinPane`/`unpinPane`, Persistenz über den vorhandenen
  `scheduleSave()`-Pfad. Tear-off/`removeWindow` räumen Pins mit ab (Tests).

## Teil B — Grid-Container & Pane-Chrome

- Neue Datei `Views/AgentChatsView+Grid.swift`: bei `gridPreset != .single` ersetzt ein
  Grid-Container den einzelnen Content (Muster Archiv-/Kompakt-Modus). Pro Slot eine
  `AgentPaneView`: Header + **volle `AgentSessionDetailView`-Verzweigung** (lebender
  Controller → Live-PTY via `attach()`; sonst read-only Transcript/`terminalEndedView`) —
  mit unterdrücktem Auto-Launch (`shouldLaunchOnOpen` wird beim Auto-Befüllen nie getriggert).
- **Pane-Header** (wiederverwenden statt neu): Status-Dot über `statusPublisher(for:)` +
  `.onReceive`-Muster wie `SessionListButton` (`AgentChatsSidebarViews.swift:774`),
  Provider-Icon, Session-Name, Branch-Chip (Datenquelle wie Sidebar-Gruppenheader), Close (=
  Pane leeren, Tab bleibt offen). Leere Pane = Drop-Ziel „Tab hierher ziehen" + Plus für neuen
  Chat im Fenster-Projekt.
- **Ansicht-Umschalter** (Segmented Control „Projekt | Running") + **Preset-Umschalter** in
  der Titelzone neben dem Tab-Strip (Symbole `rectangle`, `rectangle.split.2x1`,
  `rectangle.split.1x2`, `square.grid.2x2`); Shortcut-Vorschlag ⌘⌥1–⌘⌥4. In der
  Running-Ansicht trägt jeder Pane-Header zusätzlich ein Projekt-Badge. Trennlinien zwischen
  Panes zunächst fix 50 % (verstellbare Splits = V2, Muster `SidebarWidthResolver`).
- **Gepinnte Pane**: 📌-Indikator im Pane-Header (dauerhaft sichtbar), Klick löst den Pin;
  Drag auf eine Pane setzt ihn. Automatik-Panes zeigen keinen Pin.
- Drop-Ziel pro Pane über die bestehende `DraggableSession`-Transferable; Cross-Window-Drop
  funktioniert wie beim Tab-Strip (Quell-Auswahl live aus dem Store).

## Teil C — Fokus, Selektion, Routing

- Klick irgendwo in eine Pane → `selectedSessionID = pane.sessionID` + `makeFirstResponder`
  auf deren Terminal-View; Fokus-Rahmen via Akzent (dauerhaft, nicht nur bei Key-Window).
- Tab-Strip-Verhalten im Grid: Klick auf Tab, dessen Session schon in einer Pane liegt →
  diese Pane fokussieren; sonst → Session in die Fokus-Pane **pinnen** (Automatik darf sie
  nicht mehr verdrängen). ⌘1–⌘9 folgt derselben Semantik.
- Dictation-Routing und „aktiver Agent-Chat" (AppState): im Grid-Modus liest
  `syncActiveAgentChat` das neue `focusedPaneSessionID` statt `selectedSessionID`
  (Regressionstest für den Single-Modus, wo weiterhin `selectedSessionID` gilt).
- `PaneAssignmentResolver` bekommt den Status-**Snapshot** als Eingabe (pure Funktion — sie
  liest `statusStore.statuses` nicht selbst). Recompute-Trigger: Status-Änderungen (debounced
  über den bestehenden per-Item-Publisher-Mechanismus), Workspace-Änderungen, Preset-/
  Ansicht-/Pin-Mutationen.
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
3. ~~**Verstellbare Split-Verhältnisse**~~ — **entschieden 2026-07-12: V1 fix 50 %**,
   Divider-Drag = V2.
4. **Preset-Shortcuts** ⌘⌥1–4 okay? (⌘1–9 = Tabs, ⌘⌥←/→ = Tab-Wechsel sind belegt.)

Bereits entschieden (2026-07-12): **Grid-Ansichten** — Default „Projekt" (alle Chats des
aktuellen Projekts, auto-befüllt), Umschalter auf „Running" (laufende Sessions aller
Projekte); Pin-per-Drag statt drittem Manuell-Modus (Empfehlung, im Plan festgeschrieben).

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
