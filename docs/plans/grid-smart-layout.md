# Smartes Grid — Befund und Plan

Stand 03.08.2026, nach zwei unabhängigen Architekturberatungen. Für einen
Chat **außerhalb der App** (normales Terminal), der `make dev` ausführen darf.

## Das Symptom

Bei 5 Chats zeigt der Workspace 6 Flächen — die sechste ist leer und trägt
„Slot 6 · Chat hier ablegen". Bei 7 Chats zwei solche Phantome, bei 8 eines.

## Die Ursache

`AgentGridSplitContainer.gridBody` (`:94-119`) iteriert **unbedingt**
`rows × columns`. Bei Kapazität 5 sind das 3 × 2 = 6 Felder, obwohl das Modell
nur 5 Slots hat.

Die richtige Aufteilung steht längst im Code: `AgentGridAutoLayout.cell(forSlot:)`
(`AgentGridLayout.swift:87-110`) kennt die Spann-Regeln für 3/5/7/8 — ein Pane
über mehrere Spalten. **Der Renderer liest diese Funktion nie.** Sie wird
ausschließlich vom `GridFocusNavigator` benutzt. Deshalb widersprechen sich
Tastaturfokus und Bild bei 5/7/8 heute schon.

### Zwei Folgen, die über Kosmetik hinausgehen

1. Der Phantom-Slot ist ein **aktives Drop-Ziel**. Ein Drop darauf schlägt
   immer fehl (`WorkspaceSlotOps.add` → `guard slots.indices.contains(5)` →
   `.rejected`). Kein Absturz, aber ein sichtbares Versprechen, das nichts
   annimmt.
2. Er erhöht `gridSlotDropTargetCount` (`AgentChatsView+Grid.swift:643`), und
   dieser Zähler **unterdrückt die Growzone** (`:313`). Über der Geisterfläche
   zu schweben schaltet das Erweitern-Angebot ab.

## Die Entscheidung: kleiner Fix, kein Renderer-Umbau

Geprüft und **verworfen** wurde: flacher `ZStack` mit `.frame`/`.offset`, eine
neue Tabelle je Kapazität, Nutzung von `Services/AgentChats/Layout/`.

Gründe:

- **`cell(forSlot:)` IST bereits die Tabelle.** Eine neue zu schreiben, statt
  die vorhandene zu verdrahten, macht aus neun Quellen zehn.
- **Der ZStack kostet neun funktionierende Dinge** ohne Ersatz im Entwurf:
  `DragState`-Referenztyp + 33-ms-Sampler (`Container:29-35, 217-249`; sein
  Kommentar erklärt, dass ein `@State`-Write pro Maus-Tick den ganzen
  Fenster-Body invalidierte), alle Messpunkte des Resize-Pfads
  (`PerfBudgets.gridDividerTick`, Signposts, Counter — nur dort), Doppelklick =
  Gleichverteilung (`:176-181`), der onChange-Roundtrip gegen Ein-Frame-Rückfall
  (`:66-71`), `onHandleHoverChanged` (`:182`) gegen Fokusklau beim Drag-Start,
  **der 1-px-Gap, der die Trennlinie IST** (`spacing: 1` + durchscheinendes
  `AgentTheme.border`), die zeilenbegrenzten Spalten-Griffe (`:124-135`) und
  `clampedTrackFractions` als Drag-Basis (`:162-166`, bereits einmal falsch
  gebaut, als Re-Verifikations-Finding markiert).
- **Zwei Fraktions-Vektoren für zwei Achsen können keine Zeile beschreiben,
  deren Grenze woanders sitzt als in der Zeile darüber.** Entweder klein
  (spaltenbündiges Raster, Modell passt) oder groß (Zellenbaum, Modell zieht
  mit). Der ZStack bei festgehaltenem Datenmodell ist die Mischung — und die
  wäre der vierte Anlauf in neuer Verpackung.

## Der Fix

**Eine Funktion, `AgentGridSplitContainer.swift:94-119`, ~30 Zeilen.**

Die letzte Zeile bekommt so viele Panes, wie übrig sind, **spaltenbündig**
verteilt entlang `colSizes` nach `cell(forSlot:)`:

- `slotsInRow = min(columns, capacity - row * columns)`
- bei `slotsInRow < columns` die Spuren blockweise zusammenfassen:
  - 5 → unten `colSizes[0] + colSizes[1] + 1` und `colSizes[2]`
  - 7 → unten volle Breite
  - 8 → wie 5
- Das ist die Verallgemeinerung des `twoPlusOne`-Zweigs, der eine Zeile darüber
  steht und seit Monaten trägt.

**Spaltenbündig statt gleichmäßig ist der Punkt:** Nur so bleiben die
Trennlinien durchgehend gerade und die vorhandenen `columnHandles` gültig. Bei
50/50 säße die untere Grenze auf keiner Spur, und die Griffe wären als Balken
nicht mehr haltbar. (Genau das hätte `LayoutGeometry.automaticArrangement`
falsch gemacht — es verteilt die letzte Zeile gleichmäßig.)

Unangetastet bleiben: Datenmodell, Drop-Ziele, Kontextmenüs, Header,
Shrink-Auswahl, Sampler, Perf-Instrumente.

### Zweiter, unabhängiger Fix

`capacityLabel` (`AgentChatsView+Grid.swift:499-508`) hat keine Fälle für
5/7/8. Die Picker-Leiste zeigt deshalb wörtlich `1×2 · 2+1 · 2×2 · 5 · 3×2 ·
7 · 8 · 3×3`.

## Abnahme

- 5 Chats → fünf Flächen, keine „Slot 6"-Zone; unten zwei Panes, die Grenze
  sitzt auf der Spaltenspur
- 7 und 8 Chats ebenso ohne Phantome
- Trenner ziehen funktioniert weiter, Griffe sitzen auf den sichtbaren Linien
- ⌃⌘-Pfeile bewegen den Fokus dorthin, wo die Pane wirklich liegt (stimmt
  heute bei 5/7/8 nicht)
- Growzone erscheint wieder, wenn der Zeiger nicht über einer echten Pane ist
- `swift test` grün (Ausgangswert 2312)

## Fallstricke für den nächsten Durchgang

1. **Trenner-Griffe sind keine Panes.** Bei 5/7/8 existiert eine Spaltengrenze
   nur in manchen Zeilen. Wer nur Pane-Rechtecke korrigiert, hat die Griffe
   nicht — strukturell derselbe Fehler wie am 02.08.
2. **Zweitwirkungen des Phantom-Slots** prüfen: `GridSlotSelectionOverlay`,
   `gridSlotDropTargetCount`, `firstFreeSlotIndex == nil`. Alle nehmen
   stillschweigend an, sichtbare Slots == `capacity`.
3. **`Services/AgentChats/Layout/` NICHT einfach löschen.** `AgentUIState`
   leitet `layouts` bei jedem Laden aus `gridWorkspaces` ab (`:299`) und
   **persistiert es** (`:270`); `WorkspaceLayoutMigration` hängt am
   Schema-v5-Pfad (`:372-384`). Naives Löschen bricht das Decoding bestehender
   `agent-ui-state.json` — dasselbe Muster wie der Datenverlust am 02.08. Das
   ist ein eigener, sorgfältiger Schritt (Feld mit-entfernen,
   Schema-Version-Behandlung).
4. **`8b33b1d` zurücknehmen** (Stufen 5/7/8 in `allowedCapacities`) — ODER
   behalten, wenn der Fix zusammen damit kommt. Allein ist der Commit
   schädlich: Er erzeugt die Phantom-Slots erst.

## Die neun Layout-Quellen (Warum es dreimal schiefging)

`AgentGridWorkspace.columns/rows(forCapacity:)` (`:41-51`) ·
`allowedCapacities`/`smallestCapacity`/`nextCapacity` (`:35, :55-64`) ·
`AgentGridAutoLayout.columns/.rows` (Duplikat, `:69-83`) · `cell(forSlot:)`
(`:87-110`) · `gridBody` (`Container:94-119`) · `columnHandles`/`rowHandles`
(`:121-145`) · `capacityStageFits` (`+Grid:408-414`) · `capacityLabel`
(`+Grid:499-508`) · `WorkspaceLayoutMigration:96-97`. Als zehnte,
widersprechende Regel: `LayoutGeometry.automaticArrangement` (`:50-80`).

**Nicht auf der Liste:** die „3×3"-Strings (`+Grid:40, 543, 544`). Sie feuern
nur bei `.full`, und das gibt es nur bei Kapazität 9 — die tatsächlich 3×3 ist.

## Was am 02.08. schon umgesetzt wurde und bleibt

- `fbcda65` — Grid verdichtet sich beim Entfernen (Kill-Switch
  `gridAutoCompactEnabled`)
- `b1b748d` — Ziehbild für Grid-Panes und Sidebar-Rows
