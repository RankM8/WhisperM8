---
description: WIP-Dokumentation Multi-Window-Support für Agent Chats mit zentralem AgentWindowStore
description_long: |
  Vollständige Dokumentation der Multi-Window-Implementierung für die Agent-Chats.
  Führt UI-State Schema v3 (Fenstergruppen), den AgentWindowStore als Single
  Source of Truth, Tab-Detach in neue Fenster, Cross-Window-Tab-Moves und die
  zugehörige Scene-/Fenster-Verdrahtung ein. Enthält Architektur, Invarianten,
  Migrations- und Restore-Pfade sowie Test-Abdeckung.
updated: 2026-06-27 14:10
---

# WIP: Multi-Window-Support für Agent Chats

**Typ:** `feat` · **Status:** ✅ Committed als `7bc214c` (feat(agent-chats): Multi-Window-Support mit Store-first-Architektur; finalisiert 2026-07-09)
**Branch:** `main` · **Datum:** 2026-06-27
**Feature-Bereich:** Agent Chats (`docs/features/agent-chats/ui/`)

---

## 1. Was wurde implementiert

Die Agent-Chats unterstützen jetzt **mehrere Fenster** mit jeweils eigener
Tab-Leiste. Ein Tab (Chat-Session) kann per Drag oder Kontextmenü in ein
**neues Fenster abgelöst** und zwischen Fenstern **verschoben** werden. Der
gesamte Fenster-/Tab-Zustand lebt ab jetzt in einem einzigen, beobachtbaren
Store (`AgentWindowStore`) statt verteilt im Pro-View-`@State`.

Kernpunkte:

- **UI-State Schema v3**: Tabs leben in `AgentChatWindowState`-Fenstergruppen
  statt einer einzigen globalen Liste (v2). Verlustfreie Migration v1→v2→v3.
- **`AgentWindowStore`** (neu): `@MainActor @Observable` Single Source of Truth
  über ALLE Fenster. Ersetzt Pro-View-State + `NotificationCenter`-Broadcast +
  Disk-Roundtrip.
- **Strukturelle Invarianten**, erzwungen bei jeder Mutation: jede Session lebt
  in genau einem Fenster; genau ein Primärfenster; keine leeren Sekundärfenster.
- **Scene-Verdrahtung**: Primärfenster als Single-`Window`-Scene, Sekundärfenster
  als `WindowGroup` (`for: UUID.self`). Behebt einen Doppelfenster-Bug.
- **Tab-Detach & Cross-Window-Move** per Drag-Geste, Drop und Kontextmenü.
- **Fenster-Restore** beim Launch ausschliesslich Store-gesteuert (System-
  Restoration deaktiviert).
- **Tests**: neue `AgentWindowStoreTests` (12 Tests) + erweiterte
  `AgentUIStateTests` (Multi-Window-Invarianten, v2→v3-Migration).

---

## 2. Geänderte / neue Dateien

| Datei | Art | Inhalt |
|-------|-----|--------|
| `WhisperM8/Services/AgentWindowStore.swift` | **NEU** | Single Source of Truth für Fenster-/Tab-State (213 Zeilen) |
| `WhisperM8/Models/AgentUIState.swift` | geändert | Schema v3, `AgentChatWindowState`, Invarianten, Migration |
| `WhisperM8/WhisperM8App.swift` | geändert | Primär-`Window` + Sekundär-`WindowGroup` Scenes, Reopen-/Terminate-Logik |
| `WhisperM8/Services/WindowRequestCenter.swift` | geändert | Restore der Sekundärfenster beim Launch, WindowGroup-ID |
| `WhisperM8/Views/AgentChatsView.swift` | geändert | View liest/schreibt über Store-Bridges; Detach/Move/Drop, Window-Drag |
| `WhisperM8/Views/AgentChatsWindowAccessor.swift` | geändert | `isRestorable = false` (System-Restore aus) |
| `WhisperM8/Views/AgentChatChromeViews.swift` | geändert | `WindowDragExclusionView` (Tab-Strip vom Fenster-Drag ausnehmen) |
| `WhisperM8/Views/AgentDragDropTypes.swift` | geändert | `DraggableSession.sourceWindowID` für Cross-Window-Drops |
| `WhisperM8/Services/AgentSessionStore.swift` | geändert | `loadUIState()` liest Workspace 1× statt 3×, persistiert Migration einmalig |
| `Tests/WhisperM8Tests/AgentWindowStoreTests.swift` | **NEU** | 12 Tests für Tab-Lifecycle, Multi-Window, Persistenz |
| `Tests/WhisperM8Tests/AgentUIStateTests.swift` | geändert | Multi-Window-Invarianten, v2→v3-Migration |
| `Tests/WhisperM8Tests/WindowAndOverlayTests.swift` | geändert | Anpassung an neue `AgentChatsView(windowID:)`-Signatur |
| `Makefile` | geändert | Resource-Bundle-Accessor schreibbar machen + `--disable-sandbox` beim 2. Build |

Diff-Umfang: **13 Dateien, ~1099 Zeilen hinzugefügt / ~160 entfernt**.

---

## 3. Architektur im Detail

### 3.1 Datenmodell – `AgentUIState` Schema v3

Neuer Typ `AgentChatWindowState` (`Identifiable, Codable, Equatable, Hashable`):

```swift
struct AgentChatWindowState {
    var id: UUID
    var openTabIDs: [UUID]          // Tab-Reihenfolge dieses Fensters
    var selectedSessionID: UUID?
    var selectedProjectID: UUID?
    var isPrimary: Bool
}
```

`AgentUIState` bekommt:
- `windows: [AgentChatWindowState]` — die Fenstergruppen.
- `primaryWindowID: UUID` — für Dock-/Menubar-Reopen.
- `currentSchemaVersion = 3`.

Die alten Top-Level-Felder (`openTabIDs`, `selectedSessionID`,
`selectedProjectID`) bleiben als **Kompatibilitäts-Spiegel** des Primärfensters
erhalten (`syncLegacyWindowMirror()`), damit v2-Leser nicht brechen.

### 3.2 Invarianten – `normalizedWindows(...)`

Jede Mutation läuft am Ende durch `normalizedWindows`, das drei Garantien
herstellt:

1. **Keine doppelten Fenster-IDs**; Primärfenster wird garantiert (notfalls neu
   eingefügt).
2. **Primärfenster zuerst** sortiert → bestimmt die Dedup-Priorität.
3. **Globale Tab-Eindeutigkeit**: jede Session lebt in genau EINEM Fenster (das
   frühere/primäre gewinnt). Verhindert „derselbe Chat in zwei Fenstern".
   Verwaiste Selektionen fallen auf `nil` bzw. den ersten verbliebenen Tab.

Weitere Modell-Operationen:
- `upsertWindow(_:)` — Fenster einfügen/ersetzen + normalisieren.
- `moveTab(sessionID:from:to:before:)` — Tab umhängen (auch fenster-intern als
  Reorder), entfernt ihn überall sonst, fügt ihn an Drop-Position ein, selektiert
  ihn, räumt leeres Quellfenster auf.
- `moveTabToNewWindow(...)` — Spezialfall mit `before: nil`.
- `removeWindowIfEmpty(_:)` — leeres Sekundärfenster entfernen (Primär nie).
- `windowState(for:)` — Slice mit Fallback für unbekannte IDs.

### 3.3 Migration

`migrateToV2IfNeeded(workspace:)` deckt jetzt **beide Stufen** ab:

- **v1 → v2** (unverändert): Pro-Projekt-Maps werden zur globalen `openTabIDs`-
  Liste geflattet.
- **v2 → v3** (neu): globale `openTabIDs`/Selektion wandern in **ein
  Primärfenster**. `initialMigration(from:)` (fehlender Sidecar) erzeugt
  ebenfalls direkt ein Primärfenster.

### 3.4 Store – `AgentWindowStore`

`@MainActor @Observable final class AgentWindowStore` mit `static let shared`.

- Hält `private(set) var state: AgentUIState`. Views beobachten Reads reaktiv,
  schreiben nur über Methoden.
- **Reads**: `openTabIDs(in:)`, `selectedSession(in:)`, `selectedProject(in:)`,
  `primaryWindowID`, `pinnedSessionIDs`, `expandedProjectIDs`,
  `secondaryWindowIDs`, `hasWindow(_:)`.
- **Tab-Mutationen** (pro Fenster): `openTab`, `selectTab`, `setSelectedSession`,
  `setOpenTabIDs`, `closeTab` (Selektion rückt auf vorherigen Tab),
  `reorderTab`, `moveTab`, `detachToNewWindow` (gibt neue Fenster-ID zurück),
  `setSelectedProject`, `removeWindowIfEmpty`.
- **Globale Mutationen**: `setPinnedSessionIDs`, `togglePin`,
  `setExpandedProjectIDs`.
- **Wartung**: `prune(workspace:)` (GC toter IDs), `flush()` (sofort
  persistieren, z. B. vor Terminate).
- **Persistenz**: debounced (`saveDebounce = 400 ms`) über `AgentSessionStore`.
  Die Platte folgt dem Speicher, nie umgekehrt.

### 3.5 Scene- & Fenster-Verdrahtung (`WhisperM8App.swift`)

- **Primärfenster**: Single-`Window`-Scene (`id: "agent-chats"`), ERSTE Scene →
  SwiftUI öffnet sie beim Launch automatisch. Eine `Window`-Scene kann sich –
  anders als eine `WindowGroup` – **nie duplizieren** (das war die Ursache des
  Doppelfenster-Bugs). Root: `AgentChatsPrimaryWindowRoot` löst die
  `primaryWindowID` einmalig live aus dem Store auf (bewusst OHNE Binding).
- **Sekundärfenster**: `WindowGroup(id: "agent-chat-window", for: UUID.self)`.
  Als NICHT-erste Scene öffnet SwiftUI hier beim Launch kein Fenster
  automatisch — nur über `openWindow(id:value:)`. Root:
  `AgentChatsSecondaryWindowRoot` schliesst sich selbst (`dismiss()`), wenn die
  ID fehlt oder der Store sie nicht kennt (verwaistes Restore-Artefakt).
- **Reopen** (`applicationShouldHandleReopen`): öffnet das Primärfenster nur,
  wenn KEIN sichtbares Fenster mehr offen ist (`!flag`) — sonst Duplikat.
- **Terminate** (`applicationWillTerminate`): `AgentWindowStore.shared.flush()`.

### 3.6 Restore-Pfad (`WindowRequestCenter.swift`)

`WindowRequestHandler.restoreAgentChatWindowsIfNeeded()` öffnet beim Launch
**nur die Sekundärfenster** aus `AgentWindowStore.shared.secondaryWindowIDs`
(je `openWindow(id: ..., value: windowID)`). Das Primärfenster macht SwiftUI
selbst. Die System-Fenster-Restoration ist via `window.isRestorable = false`
(`AgentChatsWindowAccessor`) ausgeschaltet — `AgentWindowStore` ist die EINZIGE
Restore-Autorität (sonst stapeln sich Duplikate bei jedem Launch).

### 3.7 View-Anbindung (`AgentChatsView.swift`)

- `AgentChatsView` bekommt jetzt einen `let windowID: UUID`.
- Fünf Properties (`selectedProjectID`, `selectedSessionID`,
  `expandedProjectIDs`, `openTabIDs`, `pinnedSessionIDs`) sind **Computed
  Bridges** mit `nonmutating set` auf den geteilten Store. Getter liest den
  Slice DIESES Fensters; Setter schreibt über Store-Mutationen (Invarianten +
  Persistenz inklusive). `@State private var windowStore = AgentWindowStore.shared`
  sichert das Observation-Tracking — auch Mutationen aus ANDEREN Fenstern lösen
  ein Re-Render aus.
- Entfernt: `loadPersistedUIState()`, `schedulePersistUIState()`,
  `currentUIStateSnapshot()`, `isLoadingPersistedUIState`, `uiStatePersistTask`
  — gesamtes Pro-View-Persistenz- und Lade-Gerüst.

**Tab-Interaktionen:**
- `dropTab(_:before:)` / `dropTabAtEnd(_:)` → `windowStore.moveTab(...)` (deckt
  lokalen Reorder UND Cross-Window-Move ab, via `DraggableSession.sourceWindowID`).
- `shouldDetachTab(for:)` — Detach nur bei klar vertikalem Herausziehen
  (`|height| > 60 && |width| < 44`), damit es nicht mit horizontalem Reorder
  kollidiert.
- `moveTabToNewWindow(_:)` → `detachToNewWindow` + `openWindow` (async aus dem
  Gesten-Stack gelöst, sonst Detach-Crash).
- `closeWindowIfEmptyAndSecondary()` — bei letztem entferntem Tab schliesst sich
  ein Sekundärfenster (async, nie im Gesten-Stack).
- Kontextmenü: neuer Eintrag „In neues Fenster verschieben".

**Window-Dragging (browserähnlich):**
- **Hover-gesteuertes `isMovable`-Toggle** (primärer Mechanismus): über dem
  Tab-Strip Window-Drag AUS (`.onChange(of: isHoveringTabStrip)` →
  `hostWindow?.isMovable = !hovering`), auf freien Flächen AN (natives
  Fenster-Verschieben). Schon beim Hover gesetzt, nicht erst beim mouseDown.
- `WindowDragExclusionView` (NSView mit `mouseDownCanMoveWindow = false`) hinter
  dem Tab-Strip als Zusatz-Sicherung gegen Tab-Klick-zieht-Fenster.
- Der Event-Monitor macht nur noch **Doppelklick-Zoom** im freien Band.
- VERWORFEN (nicht im Code): dauerhaftes `isMovable = false` +
  `WindowDragHandle`/`performDrag` (performDrag war bei `isMovable = false`
  unzuverlässig) sowie ein isMovable-Toggle erst im leftMouseDown-Monitor
  (Timing-anfällig).

### 3.8 `loadUIState()`-Optimierung (`AgentSessionStore.swift`)

- Workspace wird nur noch **einmal** gelesen (vorher 3× für decode/migrate/prune).
- Eine nicht migrierte Datei / ein fehlender Sidecar erzeugt bei jedem Decode
  eine frische `primaryWindowID`. Damit Fenster-Identitäten nicht divergieren,
  wird die Migration **einmalig sofort persistiert** (`needsPersist`).

---

## 4. Behobene Probleme (warum)

- **Doppelfenster beim Launch/Reopen**: WindowGroup mit nil→UUID-Binding
  duplizierte das Primärfenster. Fix: Primär = Single-`Window`-Scene; Reopen nur
  bei `!hasVisibleWindows`; System-Restoration aus.
- **„Chat doppelt in zwei Fenstern"**: durch `normalizedWindows`-Invariante
  ausgeschlossen (globale Tab-Eindeutigkeit).
- **Read-modify-write-Races / fensterübergreifende Sync**: entfällt, da der
  Zustand nur EINMAL im Store existiert.
- **Tab-Drag zog das Fenster**: hover-gesteuertes `isMovable` +
  `WindowDragExclusionView` statt unzuverlässigem Event-Monitor-Toggle.
- **Detach-Crash**: Fenster-Erzeugung async aus dem `DragGesture.onEnded`-Stack
  gelöst.
- **Divergierende `primaryWindowID`**: Migration wird einmalig festgeschrieben.

---

## 5. Test-Abdeckung

**`AgentWindowStoreTests` (neu, 12 Tests, isolierte Temp-Dateien):**
- Tab-Lifecycle: `openTab` (add+select), Idempotenz, `closeTab`
  (Selektion rückt auf vorherigen/Nachbar-Tab), `reorderTab`.
- Multi-Window: `detachToNewWindow`, `moveTab` zwischen Fenstern, Kerninvariante
  „Session nie in zwei Fenstern", `removeWindowIfEmpty`, Primärfenster nie
  entfernbar.
- Globaler State: `togglePin`.
- Persistenz: Mutation → `flush()` → Reload überlebt Roundtrip.

**`AgentUIStateTests` (erweitert):**
- `moveTabToNewWindow` entfernt aus Quelle / erzeugt Ziel.
- Letzter Tab aus Sekundärfenster → Sekundärfenster verschwindet.
- `testSameSessionLivesInOnlyOneWindow` (Normalisierungs-Invariante).
- `testV2StateMigratesIntoSinglePrimaryWindow` (v2→v3-Migration).
- prune/cap-Tests prüfen zusätzlich `windows.first`.

**Test ausführen:**
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --filter AgentWindowStoreTests
swift test --filter AgentUIStateTests
```

---

## 6. Offene Punkte / Hinweise

- **Build-Verifikation ausstehend**: `swift test` wurde im Rahmen dieser
  Dokumentation nicht ausgeführt — vor dem Commit lokal laufen lassen.
- **Makefile**: `--disable-sandbox` beim zweiten Release-Build und das
  `chmod u+w` auf `resource_bundle_accessor.swift` sind Workarounds für das
  Patchen der Resource-Accessoren (vgl. Commit 78bf08f). Bei künftigen
  SwiftPM-Updates prüfen, ob noch nötig.
- **Schema-Spiegel**: Die Top-Level-`openTabIDs`/`selectedSessionID` in
  `AgentUIState` werden weiter als Spiegel des Primärfensters geschrieben. Wenn
  irgendwann kein v2-Leser mehr existiert, kann der Spiegel entfallen.

---

## 7. Nächster Schritt

```bash
# Tests grün?
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
# dann committen
git add WhisperM8 Tests Makefile docs
git commit
```
