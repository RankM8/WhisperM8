---
description: Multi-Window-Architektur der Agent Chats (Fenster, Tabs, AgentWindowStore)
description_long: |
  Übersicht über das Multi-Window-Feature der Agent Chats: mehrere Fenster mit
  eigener Tab-Leiste, Tab-Detach in neue Fenster, Cross-Window-Moves und der
  AgentWindowStore als Single Source of Truth. Beschreibt Komponenten,
  Datenfluss, Invarianten und Persistenz. Architektur-Tiefe in ARCHITECTURE.md.
updated: 2026-06-27 17:00
---

# Agent Chats – Multi-Window

Die Agent Chats laufen in **mehreren Fenstern**. Jedes Fenster hat seine eigene
Tab-Leiste (Chat-Sessions); Tabs lassen sich per Drag oder Kontextmenü in ein
neues Fenster ablösen und zwischen Fenstern verschieben. Der gesamte Fenster-/
Tab-Zustand lebt in einem einzigen, beobachtbaren Store.

## Komponenten

| Komponente | Datei | Rolle |
|------------|-------|-------|
| `AgentWindowStore` | `WhisperM8/Services/AgentChats/AgentWindowStore.swift` | Single Source of Truth für Fenster-/Tab-State über alle Fenster (`@MainActor @Observable`, `.shared`) |
| `AgentUIState` | `WhisperM8/Models/AgentUIState.swift` | Persistiertes Modell (Schema v3), Invarianten + Migration |
| `AgentChatWindowState` | `WhisperM8/Models/AgentUIState.swift` | Ein Fenster: `openTabIDs`, Selektion, `isPrimary` |
| `AgentChatsView` | `WhisperM8/Views/AgentChatsView.swift` | View pro Fenster; liest/schreibt über Store-Bridges |
| `AgentChatsView+Shortcuts` | `WhisperM8/Views/AgentChatsView+Shortcuts.swift` | NSEvent-Monitore als `extension` (Cmd-W, ⌘⌥-Tab-Nav, Titlebar-Zoom, Tab-Strip-Scroll) — Phase-1-Refactor |
| Scenes | `WhisperM8/WhisperM8App.swift` | Primär-`Window` + Sekundär-`WindowGroup` |
| Restore | `WhisperM8/Services/Shared/WindowRequestCenter.swift` | Öffnet Sekundärfenster beim Launch |
| Drag/Drop | `WhisperM8/Views/AgentDragDropTypes.swift` | `DraggableSession` mit `sourceWindowID` |
| Fenster-Chrome | `WhisperM8/Views/AgentChatsWindowAccessor.swift`, `AgentChatChromeViews.swift` | `isRestorable=false`, `WindowDragExclusionView` |

## Funktionsumfang

- Mehrere Agent-Chats-Fenster gleichzeitig, je mit eigener Tab-Reihenfolge.
- Tab **in neues Fenster ablösen** — vertikales Herausziehen aus der Leiste oder
  Kontextmenü „In neues Fenster verschieben".
- Tab **zwischen Fenstern verschieben** per Drag & Drop.
- **Tab-Reorder** innerhalb eines Fensters per Drag.
- **Persistenz**: Fenster + Tabs überleben App-Neustart (Store-gesteuertes
  Restore).
- **Browserähnliches Window-Dragging**: freie Header-Flächen verschieben das
  Fenster, der Tab-Strip nicht.

## Datenfluss (Kurzform)

```
AgentChatsView (pro Fenster, mit windowID)
   │  liest Slice / mutiert über Bridges
   ▼
AgentWindowStore.shared   ← Single Source of Truth (@Observable)
   │  state: AgentUIState  (Invarianten via normalizedWindows)
   ▼
AgentSessionStore.saveUIState()  (debounced 400ms)
   ▼
~/Library/Application Support/WhisperM8/agent-ui-state.json
```

Alle Fenster lesen denselben Store. Eine Mutation in Fenster A rendert auch
Fenster B neu — keine fensterübergreifende Synchronisation, kein
`NotificationCenter`, kein Disk-Roundtrip zum Aktualisieren der UI.

## Zentrale Invarianten

Erzwungen bei jeder Mutation (`AgentUIState.normalizedWindows`):

1. **Eine Session lebt in genau EINEM Fenster** (Primärfenster hat Vorrang).
2. **Genau ein Primärfenster** (`primaryWindowID`), nie entfernbar.
3. **Keine leeren Sekundärfenster** (werden beim Leerwerden entfernt + Fenster
   geschlossen).

## Persistenz & Migration

- Datei: `~/Library/Application Support/WhisperM8/agent-ui-state.json`.
- Schema **v3** (`AgentChatWindowState`-Fenster). Migration:
  - **v1 → v2**: Pro-Projekt-Tab-Maps → globale Liste.
  - **v2 → v3**: globale Liste → ein Primärfenster.
  - Fehlender Sidecar → `initialMigration` erzeugt direkt ein Primärfenster.
- Top-Level-Felder (`openTabIDs`, `selectedSessionID`) bleiben als
  Kompatibilitäts-Spiegel des Primärfensters erhalten.

## Bekannte Grenzen / Übergang

- Die Top-Level-Felder (`openTabIDs`, `selectedSessionID`, `selectedProjectID`)
  sind nur noch **Kompatibilitäts-Spiegel** des Primärfensters und sollen
  perspektivisch entfallen, sobald keine v2-Leser mehr existieren.
- **Window-Dragging** lebt von einem hover-gesteuerten `isMovable`-Toggle (kein
  natives `WindowDragGesture` — das ist macOS 15+, Projekt-Target ist macOS 14).
- Die Tab-Strip-**Event-Monitore** (Mausrad-Scroll, Cmd-W-Schliessen,
  Doppelklick-Zoom) sind weitgehend **vorbestehend** und nicht Teil des
  Multi-Window-Umbaus; seit dem Phase-1-Refactor liegen sie als `extension`
  in `AgentChatsView+Shortcuts.swift` (aus `AgentChatsView.swift` ausgelagert).

## Verwandte Dokumentation

- **`ARCHITECTURE.md`** (dieses Verzeichnis) — Detail-Architektur, Sequenzen,
  Edge-Cases.
- **`docs/commit-doc/wip-agent-multiwindow/COMMIT.md`** — Einführungs-Commit.
- **`../../../CLAUDE.md`** (Repo-Root) → Abschnitt „Agent Chats subsystem" —
  Gesamtkontext des Subsystems.
