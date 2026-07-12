# Plan: Kompakt-Chat-Fenster („Make window small" mit Projekt-Chat-Übersicht)

Stand: 2026-07-12 · Status: **VERWORFEN** (User-Feedback 2026-07-12: Feature beruhte auf einem
Missverständnis der ursprünglichen Anfrage — gewollt war nur die Grid-View. Umsetzung war
komplett gebaut und wurde revertiert, siehe Commits `58a5635`/Revert-Paar; Wiederaufnahme nur
auf expliziten Wunsch) · Vorbild: BridgeMind BridgeSpace
(<https://www.bridgemind.ai/products/bridgespace>) — deren Desktop-App bietet einen kompakten
Chat-Workspace mit Session-Liste, aus dem heraus man zwischen allen Chats wechselt, ohne das
große Arbeitsfenster zu brauchen.

## Context

Wunsch: Ein Agent-Chat soll sich per „Make window small"-Aktion in ein **kleines Fenster**
verwandeln, das neben dem aktiven Chat eine **Übersicht aller Chats des aktuellen Projekts**
zeigt — ein „Projekt-Cockpit" im Palettenformat, das man neben Editor/Browser stellt, während
die Agents arbeiten.

Was WhisperM8 heute hat (Anker aus der Architektur-Analyse):

- **Fenster-State ist store-first**: `AgentWindowStore` (SSoT, `Services/AgentChats/AgentWindowStore.swift:20`)
  hält per Fenster `openTabIDs`, `selectedSessionID`, `selectedProjectID`, `isPrimary`
  (`AgentUIState.swift:13`), persistiert debounced nach `agent-ui-state.json`. Es gibt also
  bereits ein **„aktuelles Projekt" pro Fenster** (`selectedProjectID`) — genau die Datenbasis
  für die Übersicht.
- **Chat-Rows sind wiederverwendbar**: `SessionListButton` (`AgentChatsSidebarViews.swift:631`)
  mit per-Item-Status via `statusStore.statusPublisher(for:)` + `.equatable()` — skaliert ohne
  Re-Render-Sturm.
- **Sidebar-Modus-Wechsel ist vorexerziert**: Der Archiv-Modus (`AgentChatsView+Archive.swift:75`)
  ersetzt den kompletten Sidebar-Inhalt bei stehendem Footer — dasselbe Muster trägt ein
  Kompakt-Layout.
- **Terminal überlebt Re-Layout**: PTYs leben sessionID-basiert in `AgentTerminalRegistry`
  (`Views/AgentTerminalView.swift:264`); `attach(_:to:)` (`:839`) reparentet dieselbe
  SwiftTerm-View in jede neue Hierarchie — Scrollback und Prozess bleiben erhalten.
- **Kein Kompakt-Modus existiert** für Agent-Chats-Fenster (nur das Recording-Overlay kennt
  `OverlayStyle.mini`, `Windows/RecordingPanel.swift:4`). Fenstergröße nur `.defaultSize(1100×720)`.

## Zielbild (Variante A — empfohlen): Kompakt als Fenster-Zustand

Kein neues Fenster, keine neue Scene, kein NSPanel: **jedes Agent-Chats-Fenster kann in einen
Kompakt-Zustand umschalten** (und zurück). Das passt zur Store-first-Multi-Window-Architektur
und bekommt Tear-off gratis dazu: Tab in neues Fenster ziehen → dort „klein machen" = genau der
BridgeMind-Flow.

```
┌──────────────────────────┐
│ ⤢  WhisperM8 · [Avatar]  │  ← Titelzone: Expand-Button, Projektname, ● 2 working
│──────────────────────────│
│ ● Auth-Refactor    ▌▌▌   │  ← Chat-Liste des aktuellen Projekts
│ ◐ DB-Migration   braucht │     (SessionListButton wiederverwendet,
│ ○ Docs-Update    12m     │      Status DAUERHAFT sichtbar, kein Hover-only)
│ + Neuer Chat             │
│──────────────────────────│
│                          │
│   aktiver Chat (PTY,     │  ← dieselbe Terminal-View, per attach()
│   live, ~44 Spalten)     │     reparentet; TUIs reflowen beim Resize
│                          │
└──────────────────────────┘
   Default ~380×580, min 340×480
```

Verworfene Alternativen:

- **B — eigenes Floating-NSPanel** (wie `RecordingPanel`): zweite Fenster-Klasse neben den
  Scene-Fenstern, eigener Lifecycle, Terminal müsste zwischen Panel und Fenster wandern, und der
  Store kennt das Panel nicht → verletzt die SSoT-Invarianten („eine Session in genau einem
  Fenster"). Always-on-top holen wir uns billiger: `window.level = .floating` auf dem normalen
  Fenster (Teil D).
- **C — nur Tear-off-Größen-Preset**: löst die Übersicht nicht — ein losgerissener Tab ohne
  Projekt-Liste ist nur ein kleines Terminal.

Abgrenzung: Das Kompakt-Fenster ist ein **Ein-Projekt-Cockpit**. Das globale Board über alle
Sessions bleibt der [Jarvis-Supervisor-Plan](jarvis-supervisor/) — kein Overlap, die Features
ergänzen sich (Jarvis = Missionskontrolle, Kompakt = Nahaufnahme eines Projekts).

## Teil A — Store & Persistenz

- `AgentUIState.AgentChatWindowState` (`AgentUIState.swift:13`) um zwei Felder erweitern:
  `isCompact: Bool` (Default `false`) und `expandedFrame` (Frame vor dem Verkleinern, für die
  Rückverwandlung — auch über App-Neustarts, da `isRestorable = false` gesetzt ist und macOS
  nichts für uns merkt). **Achtung (Verifikations-Befund 2026-07-12):** der Struct hat
  synthetisiertes Codable — ein neues nicht-optionales Feld wirft bei alten Dateien
  `keyNotFound`, und der `loadUIState`-Fallback (`AgentSessionStore.swift:55`) verwirft dann
  still den kompletten Fenster-/Tab-State. Deshalb **manueller `init(from:)` + CodingKeys mit
  `decodeIfPresent(...) ?? false`** für `AgentChatWindowState`. Kein Schema-Bump nötig;
  `normalizedWindows` (`AgentUIState.swift:381`) kopiert/mutiert in place und verliert neue
  Felder nicht (verifiziert).
- `AgentWindowStore`: `isCompact(in:)` / `setCompact(_:in:expandedFrame:)` analog zu den
  bestehenden per-Fenster-Reads/Writes; Persistenz läuft über den vorhandenen
  `scheduleSave()`-Pfad.
- Tests (`AgentWindowStoreTests`/`AgentUIStateTests`): Roundtrip mit/ohne neue Felder
  (Abwärtskompatibilität alter `agent-ui-state.json`), Detach eines Tabs aus einem kompakten
  Fenster, `removeWindow` räumt den Zustand mit ab.

## Teil B — Fenster-Metamorphose

- **Toggle-Button in der Titelzone** (rechts, neben den bestehenden Chrome-Controls in
  `AgentChatChromeViews.swift`): Symbol `arrow.down.right.and.arrow.up.left` /
  `arrow.up.left.and.arrow.down.right`, dauerhaft sichtbar. Shortcut-Vorschlag **⌘⇧M**
  (in `AgentChatsView+Shortcuts.swift` registrieren), plus Menüeintrag im Fenster-Kontext.
- **Frame-Wechsel** über den bestehenden `AgentChatsWindowAccessor` (liefert das `NSWindow`):
  beim Verkleinern aktuellen Frame als `expandedFrame` sichern, dann
  `window.setFrame(compactFrame, display: true, animate: true)`; Kompakt-Frame verankert an der
  aktuellen Fensterposition (obere rechte Ecke stabil). Beim Vergrößern `expandedFrame`
  wiederherstellen (Fallback `.defaultSize`).
- **Größen-Constraints nur im Kompakt-Zustand** setzen (`window.minSize` 340×480, `maxSize`
  z. B. 520×900), beim Expand zurücksetzen — so bleibt das große Fenster frei skalierbar.
- Doppelklick-Titelzone im Kompakt-Zustand auf „Expand" umdeuten statt Zoom — sonst springt
  das Fenster auf Bildschirmgröße. Verzweigung gehört in den Aufrufer `handleTitleBarMouse`
  (`AgentChatsView+Shortcuts.swift:294`), nicht in die pure `TitleBarZoom`-Enum. Fallstrick:
  im Kompakt-Zustand gibt es keinen Tab-Strip → das gesamte obere Band zählt als
  Doppelklick-Zone; der Expand-/Pin-Button muss davon ausgenommen werden.

## Teil C — Kompakt-Layout

- `AgentChatsView`: bei `isCompact` ersetzt ein `compactContent` den gesamten
  Sidebar+Tabs+Content-Aufbau (Muster: Archiv-Modus, `AgentChatsView+Archive.swift:75`).
  Neue Datei `AgentChatsView+Compact.swift` (Konvention der `extension`-Dekomposition).
- **Header**: Expand-Button, `ProjectAvatar` + Projektname (aus `selectedProjectID`),
  Working-Count-Chip (Anzahl `.working`-Sessions des Projekts — dauerhaft sichtbar).
  Projektwechsel per Menü am Projektnamen (alle Projekte, wie Sidebar-Reihenfolge).
  **Empty-State** (Verifikations-Befund): `selectedProjectID` kann bei leerem Workspace nil
  sein — dann „Kein Projekt"-Hinweis statt Liste, „+ Neuer Chat" disabled (die bestehenden
  Create-Pfade sind ohnehin auf `selectedProject != nil` gegated).
- **Chat-Liste**: flache Liste aller Sessions des aktuellen Projekts —
  **`SessionListButton` unverändert wiederverwenden** (inkl. Status-Publisher, Subagent-Chip,
  Relativzeiten). Keine Ordner-Hierarchie, keine Sonder-Row. Sortierung wie Sidebar.
  Klick = `selectSession` mit denselben Semantiken wie der Sidebar-Klick (Tab wird geöffnet
  bzw. fokussiert; `openTabIDs` bleibt die eine Wahrheit — der Tab-Strip ist nur ausgeblendet,
  nicht entkoppelt). „+ Neuer Chat"-Row am Listenende (ruft den bestehenden Neuer-Chat-Pfad
  mit dem Fenster-Projekt auf).
- **Aktiver Chat**: dieselbe `AgentTerminalView` — `attach()` reparentet die Terminal-View
  verlustfrei, SwiftTerm meldet die neue Spaltenzahl an die PTY, Claude/Codex-TUIs reflowen.
  Liste und Terminal teilen sich die Höhe (Liste max. ~40 %, scrollbar).
- Inspector, Scope-Bar, Befehlszeilen, Tab-Strip: im Kompakt-Zustand ausgeblendet; ihr State
  bleibt unangetastet (Rückverwandlung stellt alles wieder her, da nur Layout wechselt).

## Teil D — Feinschliff

- **Always-on-top-Pin** (explizierter Toggle im Kompakt-Header, nicht Default):
  `window.level = .floating` + `hidesOnDeactivate = false`; beim Expand oder Fenster-Close
  zurück auf `.normal`. Ephemer (nicht persistieren).
- **MenuBarExtra-Quick-Action**: „Projekt-Cockpit öffnen" → fokussiert/öffnet ein Fenster via
  `WindowRequestCenter` und schaltet es kompakt.
- Kompakt-Zustand überlebt Relaunch (Teil A) → beim Launch-Restore (`restoreAgentChatWindowsIfNeeded`,
  `WindowRequestCenter.swift:198`) Frame + Constraints direkt kompakt setzen, kein Aufblitzen groß.

## Offene Entscheidungen (vor Umsetzung klären)

1. **PTY oder Transcript im Kleinen?** Empfehlung: live PTY (V1, null Zusatzaufwand durch
   `attach()`). Alternative für V2: read-only Transcript-Tail (Chat-Look Variante E) + kleines
   Eingabefeld — hübscher bei <400 px, aber neuer Send-Pfad nötig.
2. **Listen-Klick-Semantik**: öffnet wie Sidebar einen Tab (empfohlen, eine Wahrheit) — oder
   soll die Kompakt-Liste nur `selectedSessionID` wechseln, ohne `openTabIDs` zu erweitern?
3. **Shortcut**: ⌘⇧M okay? (⌘1–9, ⌘⌥←/→ sind belegt.)
4. **Mehrere kompakte Fenster gleichzeitig** zulassen (ergibt sich aus Variante A gratis) —
   bewusst so lassen? Empfehlung: ja, ein Cockpit pro Projekt ist der eigentliche Gewinn.

## Verifikation

- Toggle klein→groß→klein: Frame, Sidebar-Breite, Inspector, Tab-Strip und Selektion exakt
  wiederhergestellt; Terminal-Scrollback lückenlos, Prozess ununterbrochen (PID stabil).
- Status-Updates in der Kompakt-Liste live (working→awaitingInput→idle) ohne Re-Render der
  Nachbar-Rows (Signpost `perf.sidebar` unter Budget).
- Alte `agent-ui-state.json` (ohne neue Felder) lädt fehlerfrei; kompaktes Fenster übersteht
  Relaunch als kompaktes Fenster an gleicher Position.
- Tear-off aus kompaktem Fenster + Fenster-Close im Kompakt-Zustand: Invarianten
  (`normalizedWindows`) halten, keine verwaisten Einträge.
- `swift test` (Store-/UIState-Tests) grün; manuelle QA für Frame-Animation, Pin und
  Doppelklick-Verhalten (NSWindow nicht unit-testbar).
