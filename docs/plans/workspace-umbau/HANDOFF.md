# Handoff — Workspace-Umbau ab S4b

Stand 02.08.2026. Dieser Text ist für einen Chat gedacht, der **außerhalb der
WhisperM8-App** läuft (normales Terminal) und deshalb `make dev` selbst
ausführen darf.

## Warum außerhalb der App

Die nächsten Schritte bauen `AgentChatsView+Grid.swift` um — die Ansicht, in
der Agent-Chats *innerhalb* der App laufen. Ein `make dev` würde eine Session
in der App mitsamt allen anderen offenen Chats beenden. Von außen ist der volle
Zyklus möglich: bauen, App neu starten, hinsehen, messen.

## Wo der Stand ist

Alles committet auf `main`, Arbeitsbaum sauber, **2290 Tests grün**.

Die gesamte Logik des Umbaus ist gebaut und geprüft — ohne eine Zeile SwiftUI:

| Datei | Zweck | Tests |
|---|---|---|
| `Models/WorkspaceLayout.swift` | Zellen mit Stapeln statt Plätzen mit Löchern | — |
| `Services/AgentChats/Layout/LayoutNormalizer.swift` | Sechs Invarianten an einer Stelle | 17 |
| `Services/AgentChats/Layout/LayoutEngine.swift` | add · remove · purge · swap · drop · insert · resetToAutomatic · activate | 25 |
| `Services/AgentChats/Layout/LayoutGeometry.swift` | Baum und Zellenzahl → Rechtecke | 13 |
| `Services/AgentChats/Layout/WorkspaceLayoutMigration.swift` | Schema v4 → v5 | 19 |
| `Services/AgentChats/Layout/LayoutDropResolver.swift` | Welche Zone bedeutet was | 19 |
| `Services/AgentChats/Layout/LayoutDragState.swift` | Klick vs. Zug, Zielverfolgung | 12 |
| `Services/AgentChats/Layout/LayoutDividerDrag.swift` | Dehn-Technik beim Trenner | 12 |
| `Views/Workspace/WorkspaceLayoutView.swift` | Zeichnet die Flächen — **noch nicht eingehängt** | — |

## Was zu tun ist

### 1. Verdrahtung (Rest von S4b)

`WorkspaceLayoutView` muss die Bausteine benutzen:

- Mausereignisse über `NSEvent`/Zeigegerät an `LayoutDragState` weiterreichen.
  **Nicht `.draggable`** — das hat die App im Mai 2026 schon einmal eingefroren
  (`LazyVStack` + `.draggable`, Fix 60ca683, Kommentar in
  `AgentChatsSidebarViews.swift:199`).
- Zielvorschau zeichnen: `LayoutDragState.target` → Overlay auf der Zielfläche.
  Ohne sichtbare Zone ist die Zwei-Zonen-Regel ein Ratespiel.
- Trenner: Während des Ziehens nur `LayoutDividerDrag.offset` verwenden und die
  Darstellung strecken. `LayoutDividerDrag.resolvedFractions` erst beim
  Loslassen.

### 2. Zoom (S5)

Zoom ist **keine** Layoutänderung, sondern reine Sichtbarkeit — verdeckte
Terminals behalten ihre Größe und werden nicht neu gezeichnet.

Verhalten steht in `02-entscheidungen/01-offene-fragen.html`:
E4 (Klick bei Zoom wechselt Inhalt, Zoom bleibt) · E1 (Klick auf Chat außerhalb
verlässt den Workspace) · E2 (Rückweg über die Seitenleiste) · E6 (Zoom
überlebt das Verlassen nicht).

Anknüpfungspunkt: `AgentChatWindowState.showsGrid`.

### 3. Das alte Modell entfernen (S6)

**82 Stellen** mit `.slots`/`.capacity` — aber rund zwei Drittel sind Löschung:

| Datei | Stellen | Schicksal |
|---|---|---|
| `WorkspaceSlotOps.swift` (273 Z) | 26 | entfällt — `LayoutEngine` ist der Ersatz |
| `AgentChatsView+Grid.swift` | 19 | ersetzt durch `WorkspaceLayoutView` |
| `GridDropZoneResolver.swift` (50 Z) | 5 | entfällt — `LayoutDropResolver` steht |
| `GridShrinkSelectionViews.swift` (245 Z) | 1 | entfällt ersatzlos, es gibt keine Kapazität mehr |
| Rest | ~30 | echte Anpassung |

**In einem Schritt, nicht schrittweise.** Zwei aktive Layoutsysteme sind der
teuerste Weg — der Drift-Fund vom 02.08. (Commit `5e764e2`) ist genau das
Muster, das dabei entsteht.

Mit S6 entfällt die Ableitungs-Krücke in `AgentUIState.migrateIfNeeded`:
`layouts` wird führend, `gridWorkspaces` verschwindet. Zwei Tests in
`WorkspaceLayoutMigrationTests` kehren sich dann um — der Hinweis steht dort im
Kommentar.

## Fallstricke, die Zeit kosten würden

**Terminals dürfen beim Umsortieren nie neu aufgebaut werden.** Ein neuer PTY
heißt: Scrollback weg, laufender Befehl weg. Die Identität ist die Session-ID
(`.id(sessionID)`), nicht die Position. Der Zähler `pane.mounted` deckt jeden
Verstoß auf — er läuft nur bei
`defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES`.

**Zell-IDs müssen deterministisch bleiben.** Die Migration setzt Zell-ID =
Session-ID. Am 02.08. erzeugte sie bei jedem Lauf neue UUIDs — bei einer
Ableitung pro Laden hätte das ständig wechselnde Identitäten bedeutet, also
genau den Terminal-Neuaufbau, den der Umbau verhindern soll.

**Die Dehn-Technik lässt sich nicht nachrüsten.** Gemessen: neun Flächen kosten
11,24 ms Größenänderung plus etwa dieselbe Menge Neuzeichnung durch die
laufenden Programme — rund 24 ms gegen ein 60-Hz-Budget von 16,7 ms. Die
gesamte Geometrie-Kette hängt daran, ob eine Größe vorläufig oder endgültig ist.

## Wie zu prüfen ist

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build && swift test          # muss grün bleiben, 2290 Tests
make dev                           # nur von außerhalb der App!
scripts/perf-report.sh 15m         # Budgets und Stillstände
```

**Abnahme je Schritt:**

- In ein Terminal tippen, Layout ändern, Text ist noch da — und
  `pane.mounted` ist nicht gestiegen. Das ist der wichtigste Test des Umbaus.
- `grid.dividerTick` unter 16 ms bei neun Flächen
- Kein `main_thread_freeze` bei einer Minute Dauerziehen
- Ein Klick bleibt ein Klick (unter 4 Punkten Bewegung passiert nichts)
- Nach S6: `grep -rn "\.slots\b\|\.capacity\b" WhisperM8 --include="*.swift"`
  liefert nichts mehr

## Was schon gemessen wurde

Nicht neu erheben, steht in `index.html` und `04-sofort/`:

- Größenänderung: 1,31 ms je Fläche, exakt linear bis neun
- Ein Bildschirm Terminal-Ausgabe: 1,40 ms
- JSON-Encoder bei 1971 Sessions: 17,5 ms — `prettyPrinted`/`sortedKeys`
  abzuschalten bringt 2,3 ms, lohnt also nicht
- os_signpost: 686 ns je Intervall, auch ohne Instruments. Deshalb nie pro
  Byte, Zeichen oder Zeile messen — dafür gibt es `PerformanceCounters`.

## Regeln aus dem Projekt

- Kommentare auf Deutsch, im Stil der umgebenden Dateien
- Keine Selbsterwähnung in Commits (kein `Co-Authored-By`, kein „Generated
  with")
- Vor dem Commit: selektiv stagen. Im Arbeitsbaum können Änderungen anderer
  Chats liegen.
