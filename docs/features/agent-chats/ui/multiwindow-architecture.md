---
description: Detail-Architektur des Multi-Window-Systems der Agent Chats
description_long: |
  Tiefen-Architektur des Multi-Window-Features: Datenmodell (Schema v3),
  AgentWindowStore, Scene-Topologie, Restore-/Reopen-/Terminate-Pfade,
  Tab-Gesten und die Normalisierungs-Invarianten samt Edge-Cases.
updated: 2026-06-27 14:10
---

# Architektur: Agent Chats Multi-Window

## 1. Schichten

```
┌────────────────────────────────────────────────────────────┐
│ Scenes (WhisperM8App.swift)                                 │
│  • Window "agent-chats"        → AgentChatsPrimaryWindowRoot │
│  • WindowGroup "agent-chat-window" (for: UUID.self)         │
│                                → AgentChatsSecondaryWindowRoot│
└───────────────┬────────────────────────────────────────────┘
                │ windowID
┌───────────────▼────────────────────────────────────────────┐
│ AgentChatsView(windowID:)                                   │
│  Computed Bridges (nonmutating set) auf den Store           │
└───────────────┬────────────────────────────────────────────┘
                │ Reads/Mutationen
┌───────────────▼────────────────────────────────────────────┐
│ AgentWindowStore.shared  (@MainActor @Observable)          │
│  state: AgentUIState                                        │
└───────────────┬────────────────────────────────────────────┘
                │ debounced save / load
┌───────────────▼────────────────────────────────────────────┐
│ AgentSessionStore → agent-ui-state.json                    │
└────────────────────────────────────────────────────────────┘
```

## 2. Datenmodell (`AgentUIState`, Schema v3)

### 2.1 Felder

- `windows: [AgentChatWindowState]` — Fenstergruppen mit eigener Tab-Reihenfolge.
- `primaryWindowID: UUID` — Reopen-Ziel; das Fenster ist nie entfernbar.
- `openTabIDs`, `selectedSessionID`, `selectedProjectID` — **Spiegel** des
  Primärfensters (Rückwärtskompatibilität v2). Werden via
  `syncLegacyWindowMirror()` nach jeder Mutation aktualisiert.
- `pinnedSessionIDs`, `expandedProjectIDs` — global (fensterunabhängig).
- `schemaVersion`, `legacy*` — Migrations-Input.

### 2.2 `normalizedWindows(_:primaryWindowID:)` – die Invarianten-Maschine

Drei Schritte, in dieser Reihenfolge:

1. **Fenster-Dedup + Primärfenster-Garantie**: doppelte IDs raus; fehlt das
   Primärfenster, wird es vorne eingefügt.
2. **Sortierung**: Primärfenster zuerst, Rest stabil nach `id.uuidString`. Diese
   Reihenfolge bestimmt die Dedup-Priorität in Schritt 3.
3. **isPrimary setzen + Tab-Dedup (lokal & global)**: Tabs innerhalb jedes
   Fensters dedupliziert; danach global so, dass jede Session-ID nur im **ersten**
   beanspruchenden Fenster verbleibt (`claimedTabs`-Set). Verwaiste
   `selectedSessionID` fällt auf den ersten verbliebenen Tab.

Jede strukturelle Mutation (`upsertWindow`, `moveTab`, `prune`, init, decode,
migrate) endet hier → die Invarianten gelten ausnahmslos.

### 2.3 Mutationen am Modell

| Methode | Wirkung |
|---------|---------|
| `upsertWindow(_:)` | Fenster einfügen/ersetzen, dann normalisieren |
| `moveTab(sessionID:from:to:before:)` | Tab überall entfernen, an Zielposition einfügen, selektieren, leeres Quellfenster aufräumen |
| `moveTabToNewWindow(...)` | `moveTab` mit `before: nil` in neue Fenster-ID |
| `removeWindowIfEmpty(_:)` | leeres Sekundärfenster entfernen (Primär nie) |
| `windowState(for:)` | Slice mit Fallback (unbekannte ID → leeres, ggf. primäres Fenster) |

## 3. AgentWindowStore

- `state` ist `private(set)`; Schreiben nur über Methoden. Jede Mutation läuft
  durch `mutate { ... }` → `scheduleSave()`.
- **Debounce**: `saveDebounce = 400 ms`. Schnelle Tab-Wechsel/Reorders bündeln
  sich zu einem Schreibvorgang. `flush()` schreibt sofort (Terminate).
- **`updateWindow(_:_:)`** (intern): holt Fenster-Slice, transformiert, schreibt
  via `upsertWindow` zurück (→ Normalisierung).
- **`hasWindow(_:)`** / **`secondaryWindowIDs`**: für den Restore-Pfad — nur real
  existierende Fenster aufbauen.

### 3.1 Mutations-API (semantisch + Bridge-Setter)

Semantische Tab-Mutationen: `openTab`, `selectTab`, `closeTab`, `reorderTab`,
`moveTab`, `detachToNewWindow`, `removeWindowIfEmpty`, `togglePin`, `prune`.

Dazu **Bridge-Setter**, die die fünf computed Properties der `AgentChatsView`
bedienen (Getter liest Slice, `nonmutating set` ruft diese):

| View-Property | Store-Setter |
|---------------|--------------|
| `openTabIDs` | `setOpenTabIDs(_:in:)` (Batch-Replace; trägt `.append/.remove/.insert` via get→modify→set) |
| `selectedSessionID` | `setSelectedSession(_:in:)` (öffnet Tab falls nötig, `nil` deselektiert) |
| `selectedProjectID` | `setSelectedProject(_:in:)` |
| `pinnedSessionIDs` | `setPinnedSessionIDs(_:)` |
| `expandedProjectIDs` | `setExpandedProjectIDs(_:)` |

Alle Setter laufen durch `mutate { ... }` → Normalisierung + Debounce-Save.

## 4. Scene-Topologie & warum

| Scene | Typ | Warum |
|-------|-----|-------|
| Primärfenster | `Window(id:)` | ERSTE Scene → Auto-Open beim Launch; eine `Window`-Scene kann sich nie duplizieren (im Gegensatz zur `WindowGroup`) |
| Sekundärfenster | `WindowGroup(id:for: UUID.self)` | Nicht-erste Scene → kein Auto-Open; entsteht nur durch `openWindow(id:value:)` |

**Root-Views:**
- `AgentChatsPrimaryWindowRoot`: löst `primaryWindowID` einmalig **live aus dem
  Store** auf (kein Binding — das frühere nil→UUID-Binding-Zurückschreiben einer
  WindowGroup war die Doppelfenster-Ursache).
- `AgentChatsSecondaryWindowRoot`: bekommt die ID als WindowGroup-Wert; kennt der
  Store sie nicht (`hasWindow == false`) oder fehlt sie → `dismiss()` statt ein
  Geister-/Duplikat-Fenster zu rendern.

## 5. Lebenszyklus-Pfade

### 5.1 Launch / Restore

```
SwiftUI öffnet Primär-Window automatisch (erste Scene)
WindowRequestHandler.onAppear
   └─ restoreAgentChatWindowsIfNeeded()
        └─ für jede secondaryWindowIDs: openWindow(id:"agent-chat-window", value: id)
```

System-Fenster-Restoration ist via `window.isRestorable = false`
(`AgentChatsWindowAccessor`) deaktiviert — sonst würde macOS zusätzlich eigene
Fenster wiederherstellen (Duplikate). **`AgentWindowStore` ist die einzige
Restore-Autorität.**

### 5.2 Reopen (Dock-Klick)

`applicationShouldHandleReopen(hasVisibleWindows:)`:
- `flag == false` → `WindowRequestCenter.request(.agentChats)` (Primär neu öffnen).
- `flag == true` → nichts (AppKit bringt App nach vorn; ein `openWindow` würde
  das Primärfenster duplizieren).

### 5.3 Terminate

`applicationWillTerminate` → `AgentWindowStore.shared.flush()` schreibt den
zuletzt debounced Zustand fest.

## 6. Tab-Gesten (AgentChatsView)

| Geste | Erkennung | Aktion |
|-------|-----------|--------|
| Reorder (lokal) | horizontaler `.draggable`-Drop auf Ziel-Tab | `dropTab` → `moveTab(from:windowID,to:windowID)` |
| Drop ans Ende | Drop auf freie Strip-Fläche | `dropTabAtEnd` → `moveTab(before:nil)` |
| Cross-Window-Move | Drop in anderem Fenster (`DraggableSession.sourceWindowID`) | `moveTab(from:source,to:windowID)` |
| Detach (neues Fenster) | `DragGesture`: `|height|>60 && |width|<44` | `moveTabToNewWindow` → `detachToNewWindow` + async `openWindow` |
| Kontextmenü | „In neues Fenster verschieben" | `moveTabToNewWindow` |
| Schliessen | Mittelklick / X | `closeTab` (Selektion rückt nach) |

**Async-Entkopplung**: Fenster öffnen/schliessen passiert via
`DispatchQueue.main.async` — nie im synchronen `DragGesture.onEnded`-Stack
(beobachteter Detach-Crash bzw. View-wird-unterm-Handler-weggezogen).

## 7. Window-Dragging

Die Tabs sitzen browserähnlich in der Titelzone (`hiddenTitleBar` +
`fullSizeContentView`). macOS zieht dort das Fenster, sobald sich die Maus
beim Klick auch nur ein Pixel bewegt — ein Tab-Drag bewegte so das Fenster,
und ein Klick auf einen Knopf kam oft gar nicht an. Deshalb gilt im Titelband
(oberste 34 pt, `TabStripBand.height`):

- **Verschiebbar ist nur, was als Grifffläche ausgewiesen ist**
  (`.windowDragArea(depth:)`): die freie Fläche im Sidebar-Kopf samt Ampel, der
  freie Rest der Tab-Zeile, der Ampel-Platz bei ausgeblendeter Sidebar und die
  freie Kopffläche des Projektkontext-Panels. Über Tabs, Knöpfen und den
  Resize-Rändern ist `isMovable` aus. Ein neuer Knopf im Titelband ist damit von
  selbst geschützt; eine neue freie Fläche braucht den Modifier.
- **`TitleBandPointerTracker`** (AppKit-Tracking-Area nur über dem Band) ruft bei
  jeder Mausbewegung `refreshWindowMovability(atWindowPoint:)`. Entscheidend:
  `isMovable` steht **vor** dem Klick — erst beim `mouseDown` umzuschalten ist zu
  spät. Die Entscheidung ist zustandslos (`WindowMovability.isMovable`, pur und
  getestet); verlässt der Zeiger das Band, ist das Fenster wieder verschiebbar.
- Gegencheck im `leftMouseDown`-Monitor und Rücksetzen beim Verlust des
  Key-Status: sollte der Tracker einmal nichts geliefert haben, stimmt der
  Zustand spätestens beim nächsten Klick.
- Ohne gemessene Griffflächen (vor dem ersten Layout) gilt das frühere
  Verhalten: alles außer Tab-Strip und Rändern ist verschiebbar. Ein Messfehler
  kann das Fenster so nie unverschiebbar machen.
- `WindowDragExclusionView` (`NSView.mouseDownCanMoveWindow = false`) hinter dem
  Strip als Zusatz-Sicherung gegen Fenster-Drag direkt auf Tabs.
- `isMovableByWindowBackground = false` (`AgentChatsWindowAccessor`) verhindert
  Drag über den Content-Hintergrund.
- Event-Monitor (`titleBarZoomMonitor`) macht **Doppelklick-Zoom** nur auf einer
  Grifffläche (`clickCount == 2`, x ≥ 80, nicht über Tabs) — ein schneller
  Doppelklick auf einen Knopf zoomt nicht mehr.

> **Verworfene Zwischenstände** (NICHT im Code, nicht wieder einführen): ein
> dauerhaftes `isMovable = false` + `WindowDragHandle`/`performDrag`-Flächen
> (performDrag war bei `isMovable = false` unzuverlässig → Fenster gar nicht mehr
> verschiebbar), ein `isMovable`-Toggle erst im `leftMouseDown`-Monitor
> (Timing-anfällig) und SwiftUI-`onHover`-Flags als einzige Quelle (bis
> 10.11.2026: `onHover(false)` geht verloren, geschützt war nur der Tab-Strip,
> und jedes Hover wertete den ganzen Fenster-Body neu aus).

## 8. Edge-Cases

- **Letzter Tab eines Sekundärfensters entfernt/verschoben** →
  `closeWindowIfEmptyAndSecondary()` entfernt State-Eintrag + schliesst NSWindow
  (async). Primärfenster bleibt immer bestehen, auch leer.
- **Session in zwei Fenstern** (durch Race/Restore) → `normalizedWindows`
  räumt das Duplikat auf (Primär gewinnt).
- **Verwaiste Sekundärfenster-ID beim Launch** → Secondary-Root `dismiss()`.
- **Tote Session-/Projekt-IDs** → `prune(workspace:)` entfernt sie aus allen
  Fenstern; leere Sekundärfenster fallen weg; fehlendes Primärfenster wird
  rekonstruiert.
- **Migration ohne persistierte `primaryWindowID`** → einmaliges sofortiges
  Persistieren in `loadUIState()` verhindert divergierende Fenster-IDs.

## 9. Tests

Ausführen (Xcode-Toolchain nötig, sonst schlagen die SwiftUI-Makros fehl):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --filter AgentWindowStoreTests
swift test --filter AgentUIStateTests
```

- **`AgentWindowStoreTests`** (12) — Store-Verhalten:
  `testOpenTabAddsAndSelects`, `testOpenTabIsIdempotent`,
  `testCloseTabMovesSelectionToPreviousTab`,
  `testCloseLastSelectedTabFallsBackToNeighbor`, `testReorderTabBeforeTarget`,
  `testDetachToNewWindowMovesTabOut`, `testMoveTabBetweenWindows`,
  `testSameSessionNeverLivesInTwoWindows`, `testRemoveWindowIfEmpty`,
  `testPrimaryWindowIsNeverRemoved`, `testTogglePin`,
  `testMutationsPersistAndReload`.
- **`AgentUIStateTests`** — Modell-Invarianten + Migration: u. a.
  `testSameSessionLivesInOnlyOneWindow`,
  `testV2StateMigratesIntoSinglePrimaryWindow`,
  `testPruneRemovesEmptyAndDeadSecondaryWindowsKeepsPrimary`,
  `testExactlyOnePrimaryWindowMatchesPrimaryID`.
- **`WindowAndOverlayTests`** — Window-Request-Routing, angepasst an
  `AgentChatsView(windowID:)`.
