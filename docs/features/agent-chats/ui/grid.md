---
description: Raster der Agent Chats — Stufen, Workspaces, Projekt-Ansicht, wie sich das Layout anpasst
description_long: |
  Ist-Zustand des Rasters (Grid): Stufen 1 bis 9, eigene Workspaces und die
  Projekt-Ansicht (⊞), was passiert, wenn Chats wegfallen oder dazukommen
  (⊖, Tab schließen, Archivieren, neue Chats, mehrere Fenster), der Schalter
  „Close gaps…" und die CLI. Pläne mit Vorgeschichte:
  docs/plans/grid-workspace-plan.html, docs/plans/grid-smart-layout.md.
updated: 2026-11-12
status: aktiv
---

# Raster (Grid-Workspaces)

Das Raster zeigt mehrere Chats gleichzeitig als Kacheln (Panes) in einem
Fenster. Es gibt zwei Arten:

- **Eigene Workspaces** — vom User zusammengestellte Gruppen, sichtbar im
  Sidebar-Abschnitt WORKSPACES. Ein Chat kann in mehreren Workspaces liegen
  (wie in Playlists).
- **Projekt-Ansicht** — ⊞ am Projekt-Kopf zeigt alle aktiven Chats eines
  Projekts. Aktiv heißt: läuft oder hat einen offenen Tab, in irgendeinem
  Fenster. Die Ansicht gleicht sich laufend an; sie erscheint in keiner
  Workspace-Liste.

Modell: `AgentGridWorkspace` (Plätze = `slots`, Stufe = `capacity`), pure
Operationen in `WorkspaceSlotOps`, Zustand und Fenster-Kopplung im
`AgentWindowStore`, Darstellung in `AgentChatsView+Grid` und
`AgentGridSplitContainer`.

## Stufen

| Stufe | Anordnung |
|---|---|
| 1 | eine Kachel, volle Fläche |
| 2 | 1×2 |
| 3 | 2 oben, 1 breit unten |
| 4 | 2×2 |
| 5 | 3 oben, 2 unten (spurbündig) |
| 6 | 3×2 |
| 7 / 8 | 3×3, unten 1 bzw. 2 Kacheln über die volle Breite |
| 9 | 3×3 |

Die letzte Zeile verteilt ihre Kacheln immer über die volle Breite, leere
Phantom-Felder gibt es nicht (`AgentGridSplitContainer.blocks`). Ein leeres
Raster zeigt zwei Ablageflächen (`AgentGridWorkspace.emptyCapacity`).

Wachsen: Kommt ein Chat dazu und alles ist belegt, wächst das Raster auf die
nächste Stufe. Bei 3×3 ist Schluss; dann geht nur gezieltes Ersetzen.

## Wenn Chats wegfallen

Mit dem Schalter **„Close gaps when a chat leaves the grid"** (Einstellungen ›
Agent Chats › Grid, Standard an, Schlüssel `gridAutoCompactEnabled`) rücken
die übrigen Chats nach — die Reihenfolge bleibt — und das Raster nimmt die
kleinste passende Stufe. Das gilt für alle Wege:

| Weg | Eigener Workspace | Projekt-Ansicht |
|---|---|---|
| ⊖ an der Kachel | Chat raus, Tab bleibt offen | schließt den Tab (siehe unten) |
| Tab schließen (✕, ⌘W, Sammel-Schließen, `chats close`) | Chat raus aus jedem Workspace, der gerade in einem Fenster offen ist; ⇧⌘T bzw. `chats reopen` setzt Tab und Kachel an die alte Stelle zurück | Chat verlässt die Ansicht, auch wenn er weiterläuft; mit seinem Tab kommt er zurück, ⊞ zeigt wieder alle |
| Archivieren, Löschen | Chat raus | Chat raus |
| Chat beendet sich, Tab war schon zu | — | Chat raus |

Beispiel: Projekt-Ansicht mit 4 Chats (2×2), der zweite wird geschlossen →
2+1. Bleibt nur einer übrig, bekommt er die volle Fläche.

Ist der Wiederherstellungs-Workspace inzwischen voll (3×3) oder gelöscht,
geht beim Wiederöffnen nur der Tab auf; der Grund steht im Log
(`reopen_not_back_in_workspace`, Kategorie `agent.store`).

Ist der Schalter aus, gilt das alte Verhalten: Bei ⊖, Archivieren und
Löschen bleibt der Platz leer stehen und die Stufe bleibt; in der
Projekt-Ansicht fallen nur leere Kacheln am Ende weg. Tab schließen nimmt
den Chat dann aus keinem Workspace — die Kachel zeigt „Tab was closed ·
Reopen", in der Projekt-Ansicht bleibt ein weiterlaufender Chat so stehen.
`chats workspace remove --keep-slot` erzwingt stabile Plätze für einen
einzelnen Aufruf.

Fokus: Hatte die weggefallene Kachel den Fokus, geht er an die nächste
Kachel dahinter, sonst an die davor. Das Raster bleibt sichtbar, auch wenn
keine Kachel mehr übrig ist.

**Bleibt bewusst unverändert:**

- Ein Tab, der nur **in ein anderes Fenster wandert**, bleibt Mitglied; die
  Kachel zeigt „Running as a tab in another window · Move here".
- Workspaces, die in **keinem Fenster offen** sind, behalten ihre Mitglieder,
  wenn deren Tab zugeht. Beim Öffnen kommen die Tabs wieder.
- Ein weggeschlossener laufender Chat einer Projekt-Ansicht wird nur im
  Speicher gemerkt (`dismissedProjectViewSessionIDs`); nach einem Neustart
  zeigt ⊞ wieder alle aktiven Chats.

Code: `WorkspaceSlotOps.compacted`/`projectViewLayout`,
`AgentWindowStore+GridTabClose` (Tab schließen), `AgentUIState.prune`
(Archivieren/Löschen, Parameter `compactingGridWorkspaces`).

## Wenn Chats dazukommen

- **Eigener Workspace:** Drop auf eine Kachel ersetzt oder tauscht, Drop auf
  den Workspace oder „Add to workspace" nimmt den ersten freien Platz bzw.
  wächst. Die Wachstumszone unter dem Raster erscheint beim Ziehen, wenn alles
  belegt ist.
- **Projekt-Ansicht:** Ein neuer aktiver Chat wird hinten angehängt (nach
  Sidebar-Reihenfolge), höchstens 9 — der Kopf zeigt dann „9/N".

## Live-Abgleich der Projekt-Ansicht

Der Abgleich läuft, sobald sich die Aktiv-Mengen, die Belegung einer offenen
Projekt-Ansicht oder die Liste der weggeschlossenen Chats ändern. Mit
sichtbarer Sidebar liefert ihr Snapshot die Aktiv-Menge; ist sie
ausgeblendet oder im Archiv-Modus, übernimmt `ProjectViewLiveSync`
(`AgentChatsView+Workspaces`) mit derselben Funktion
`AgentSidebarModelBuilder.activeSessionIDsByProject`. Diese kleine View
hängt nur im Fenster, solange irgendwo eine Projekt-Ansicht offen ist, und
beobachtet Terminal-Registry und Job-Modell selbst, damit deren Ticks nicht
den Fensterbody neu auswerten.

## Mehrere Fenster

Ein Workspace gehört höchstens einem Fenster. ⊞ oder ein Klick auf den
Workspace in einem anderen Fenster holt das Besitzerfenster nach vorn, statt
Terminals zu stehlen. Details: [`multiwindow.md`](multiwindow.md).

## Tests und Ansicht

- `GridLayoutAdaptationTests` — die Fälle dieser Seite aus Nutzersicht.
- `WorkspaceSlotOpsTests`, `AgentGridWorkspaceStoreTests`,
  `AgentGridWorkspaceTests`, `GridRowBlockTests`, `GridFocusNavigatorTests`.
- Snapshots: `make snapshots ONLY=raster-` rendert alle Stufen, die
  Projekt-Ansicht nach einem weggefallenen Chat, einen einzelnen Chat und
  einen leeren Workspace (hell und dunkel).
