---
description: Runde-2-Audit der Grid-Workspace-, Tab- und Selektionslogik
updated: 2026-07-18
---

# Runde 2: Grid-Workspaces, Tabs und Selektion

Statische Prüfung der genannten Produktionspfade und der zugehörigen Tests. Es wurden keine Tests ausgeführt. Ergebnis: **11 Findings** — **0 kritisch, 1 hoch, 7 mittel, 3 niedrig**.

Die persistenten Grundinvarianten sind ansonsten gut abgesichert: `AgentUIState.prune` räumt gelöschte und archivierte Sessions aus Tabs und Workspace-Slots, `normalizedWindows` repariert nicht offene Selektionen und dedupliziert Tabs fensterübergreifend. Die verbliebenen Probleme liegen überwiegend oberhalb dieser Normalisierung in View-Brücken, ephemerem State und asynchronen Drop-Callbacks.

## F1: Leeres sichtbares Grid routet Diktat in einen unsichtbaren Tab

**Schweregrad:** hoch  
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:384-387`, `WhisperM8/Views/AgentChatsView.swift:894-927`, `WhisperM8/Models/AgentUIState.swift:770-789`

**Szenario:** Der letzte belegte Slot eines sichtbaren Workspace wird entfernt oder archiviert. Die Grid-Normalisierung setzt `selectedSessionID` korrekt auf `nil`; andere offene Tabs des Fensters dürfen aber bestehen bleiben. `selectedSession` interpretiert `nil` unabhängig vom Grid als `headerTabs.first`. `syncActiveAgentChat` übernimmt diesen nicht sichtbaren Tab anschließend als globales Diktat-Ziel.

**Beweis (Code-Zitat):**

```swift
var selectedSession: AgentChatSession? {
    guard let selectedSessionID else { return headerTabs.first }
    return workspace.sessions.first { $0.id == selectedSessionID && $0.status != .archived }
        ?? headerTabs.first
}
```

```swift
guard let project = selectedProject,
      let session = selectedSession,
      session.status != .archived
else { /* activeAgentChat leeren */ }
```

Demgegenüber ist der leere Grid-Zustand ausdrücklich legal:

```swift
normalized[index].selectedSessionID = ownedSlots.first
normalized[index].gridFocusSessionID = ownedSlots.first
```

Bei `ownedSlots.isEmpty` werden beide Werte `nil`, ohne dass offene Nicht-Slot-Tabs geschlossen werden.

**Fix-Vorschlag:** `selectedSession` beziehungsweise einen separaten `ActiveAgentChatResolver` Grid-bewusst machen: Bei `isGridActive && selectedSessionID == nil` darf es keinen Header-Fallback geben. Zusätzlich Projekt und Session gemeinsam aus derselben fokussierten Session ableiten.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/AgentGridWorkspaceStoreTests.swift:411-420` deckt den leeren Workspace ab, prüft aber weder `selectedSession` noch `AppState.activeAgentChat`. Ein View-unabhängiger Resolver-Test fehlt.

## F2: View-Schließpfad umgeht die getestete Nachbarselektion

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentChatsView+Tabs.swift:82-95`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:141-159`, `WhisperM8/Models/AgentUIState.swift:731-735`

**Szenario:** In der Reihenfolge `[A, B, C]` ist `B` aktiv und wird über den Tab-Button oder Mittelklick geschlossen. Die View entfernt zuerst `B` über die `openTabIDs`-Bridge. Beim Store-Roundtrip repariert `normalizedWindows` die nun ungültige Selektion sofort auf `A`. Deshalb ist die anschließende View-Bedingung `selectedSessionID == B` falsch und der kommentierte Fallback auf die gleiche Position (`C`) wird nie ausgeführt.

**Beweis (Code-Zitat):**

```swift
openTabIDs.remove(at: index)
if selectedSessionID == session.id {
    selectedSessionID = openTabIDs.indices.contains(index)
        ? openTabIDs[index]
        : openTabIDs.last
}
```

Der Setter führt vorher bereits diese Reparatur aus:

```swift
if let selected = normalized[index].selectedSessionID,
   !normalized[index].openTabIDs.contains(selected) {
    normalized[index].selectedSessionID = normalized[index].openTabIDs.first
}
```

**Fix-Vorschlag:** Alle UI-Schließpfade direkt auf `windowStore.closeTab(_:in:)` routen und die doppelte View-Semantik entfernen. Falls „gleiche Position, sonst letzter“ gewünscht ist, diese eine Semantik im Store implementieren und testen.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/AgentWindowStoreTests.swift:56-74` testet ausschließlich `AgentWindowStore.closeTab`, den die View hier nicht verwendet. Der tatsächliche Bridge-Pfad hat keinen Test.

## F3: Extern entfernte oder archivierte Sessions bleiben in `multiSelection`

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Services/AgentChats/AgentWindowStore.swift:45-47`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:88-92`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:854-860`, `WhisperM8/Views/AgentChatsView.swift:2121-2126`, `WhisperM8/Views/AgentChatsView+BulkActions.swift:13-35`

**Szenario:** Mehrere Sidebar-Sessions sind ausgewählt, darunter eine nicht offene Session. Ein externer Scan entfernt oder archiviert sie, ohne die Header-Tabs zu verändern. `AgentWindowStore.prune` bereinigt nur den persistenten `state`, nicht `multiSelectionByWindow`. Der einzige View-Fixup hängt an einer Änderung von `headerTabs` und schneidet zudem gegen **alle** Workspace-Sessions, sodass archivierte Sessions selbst bei einem Trigger erhalten bleiben. Labels und Bulk-Gruppen zählen danach Geister-IDs; Pin-/Farboperationen laufen über diese IDs, während Archiv-/Close-Aktionen sie erst spät per `compactMap` verlieren.

**Beweis (Code-Zitat):**

```swift
private var multiSelectionByWindow: [UUID: Set<UUID>] = [:]

func prune(workspace: AgentWorkspace) {
    var pruned = state
    pruned.prune(workspace: workspace, capTabs: false)
    // multiSelectionByWindow bleibt unangetastet
}
```

```swift
.onChange(of: headerTabs.map(\.id)) { _, _ in
    multiSelection.formIntersection(Set(workspace.sessions.map(\.id)))
}
```

```swift
multiSelection.contains(id) && multiSelection.count > 1
    ? Array(multiSelection) : [id]
```

**Fix-Vorschlag:** In `AgentWindowStore.prune` jede fensterlokale Mehrfachauswahl gegen die nicht archivierten Live-IDs und die noch existierenden Fenster schneiden und Mengen mit weniger als zwei Elementen auf `[]` normalisieren. Die View-Korrektur kann dann entfallen.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/AgentWindowStoreTests.swift:308-335` prüft nur Isolation, explizites Leeren und Nicht-Persistenz. Prune, Archivierung und das Kollabieren von zwei auf ein Element fehlen.

## F4: Cmd-Abwahl des aktiven Tabs wählt bei Restgruppen zufällig weiter

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentTabSelection.swift:21-32`

**Szenario:** Die Gruppe `{A, B, C}` ist ausgewählt, `C` ist aktiv. Ein Cmd-Klick auf `C` entfernt ihn. Als neuer aktiver Tab wird `set.first` aus `{A, B}` verwendet. Die Iterationsreihenfolge eines `Set` ist nicht die sichtbare Tab-Reihenfolge; der Terminalfokus kann daher ohne deterministische Nachbarregel auf `A` oder `B` springen.

**Beweis (Code-Zitat):**

```swift
if set.contains(id) {
    set.remove(id)
}
let newActive = set.contains(id) ? id : (set.first ?? id)
```

**Fix-Vorschlag:** `commandClick` zusätzlich die sichtbare Reihenfolge übergeben. Beim Entfernen des aktiven Mitglieds deterministisch den nächsten sichtbaren ausgewählten Tab, sonst den vorherigen wählen. Beim Entfernen eines nicht aktiven Mitglieds den bisherigen aktiven Tab beibehalten.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/TabSelectionResolverTests.swift:29-34` deckt nur `{A,B} - B` ab, bei dem genau ein Element übrig bleibt. Der mehrdeutige Fall „drei auf zwei“ fehlt.

## F5: Verspäteter Cross-Window-Drop kann einen Tab aus einem bereits geschlossenen Quellfenster wieder öffnen

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentTabReorderDrop.swift:103-114`, `WhisperM8/Services/AgentChats/AgentWindowStore.swift:171-177`, `WhisperM8/Models/AgentUIState.swift:648-660`

**Szenario:** Ein Tab wird aus einem Sekundärfenster auf ein anderes Fenster gezogen. Während `loadDataRepresentation` den Payload asynchron lädt, wird das Quellfenster geschlossen; sein State und seine Tabs werden entfernt. Der spätere Callback ruft dennoch `moveTab` auf. Diese Methode validiert nur das Ziel. `AgentUIState.moveTab` verlangt weder ein existentes Quellfenster noch, dass die Session dort noch offen ist, und fügt sie deshalb im Ziel wieder ein.

**Beweis (Code-Zitat):**

```swift
provider.loadDataRepresentation(...) { data, _ in
    // ...
    DispatchQueue.main.async {
        move(dropped, beforeID)
    }
}
```

```swift
func moveTab(_ sessionID: UUID, from sourceWindowID: UUID,
             to targetWindowID: UUID, before targetID: UUID?) {
    guard hasWindow(targetWindowID) else { return }
    mutate { $0.moveTab(sessionID: sessionID, from: sourceWindowID,
                        to: targetWindowID, before: targetID) }
}
```

```swift
var target = windowState(for: targetWindowID)
target.openTabIDs.insert(sessionID, at: insertAt)
```

**Fix-Vorschlag:** Für Payloads mit expliziter `sourceWindowID` vor dem Move atomar prüfen, dass Quelle noch existiert und die Session dort noch Tab ist. Sidebar-Open als getrennte API ohne Quellenanforderung modellieren.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/AgentWindowStoreTests.swift:256-263` testet nur ein unbekanntes **Ziel**. Ein nach Quellfenster-Close verspäteter Move fehlt.

## F6: Ein leeres Primärfenster besitzt kein Tab-Drop-Ziel

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentChatsView.swift:2075-2149`, `WhisperM8/Views/AgentChatsView.swift:2007-2010`

**Szenario:** Das Primärfenster ist leer, ein Sekundärfenster enthält Tabs. Der User möchte einen Tab in die leere primäre Tab-Leiste ziehen. Der einzige `TabReorderDropDelegate` liegt innerhalb von `if !headerTabs.isEmpty`; bei null Tabs wird der gesamte Scroll-/Drop-Teilbaum nicht erzeugt. Auch der leere Content-Fallback besitzt kein Drop-Ziel. Der Store unterstützt den Move in ein leeres Fenster, die UI bietet ihn aber nicht an.

**Beweis (Code-Zitat):**

```swift
if !headerTabs.isEmpty {
    ScrollView(.horizontal, showsIndicators: false) {
        // ...
    }
    .onDrop(of: [.agentChatSession], delegate: TabReorderDropDelegate(...))
}
```

Der Leerzustand ist nur:

```swift
ContentUnavailableView("Kein Agent Chat", systemImage: "terminal")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

**Fix-Vorschlag:** Eine dauerhaft vorhandene Drop-Fläche für die Tab-Leiste vorsehen und bei leerer Reihenfolge `beforeID == nil` liefern; alternativ den leeren Content explizit als „hierher verschieben“-Ziel verdrahten.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/TabReorderGeometryTests.swift:52-55` prüft nur, dass `insertionX` bei leerer Liste `nil` liefert. Die bedingte Existenz der Drop-Zone ist ungetestete SwiftUI-Integration.

## F7: Fehlende Tab-Frames verschieben den semantischen Drop-Index

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentTabReorderDrop.swift:15-20`, `WhisperM8/Views/AgentTabReorderDrop.swift:103-108`

**Szenario:** Für die Reihenfolge `[A, B, C]` fehlt während eines Preference-/Layout-Übergangs der Frame von `B`. Der Cursor liegt rechts von `C`. `insertionIndex` zählt zwei gemessene Mittelpunkte und liefert `2`; `performDrop` interpretiert diese Zahl anschließend als Index in der vollständigen Liste und setzt `beforeID = C`. Ein Drop optisch hinter allen Tabs wird so vor `C` ausgeführt statt am Ende. Derselbe Indexraum-Fehler betrifft fehlende Frames am Anfang oder in der Mitte, etwa während Overflow-/Resize-Übergängen.

**Beweis (Code-Zitat):**

```swift
orderedIDs.reduce(into: 0) { count, id in
    if let mid = frames[id]?.midX, mid < x { count += 1 }
}
```

```swift
let beforeID: UUID? = index < orderedIDs.count ? orderedIDs[index] : nil
```

Die erste Funktion liefert einen **Frame-Count**, die zweite liest ihn als **Index der vollständigen ID-Liste**.

**Fix-Vorschlag:** Direkt eine semantische Einfügegrenze beziehungsweise `beforeID` berechnen: erstes gemessenes Element rechts des Cursors in `orderedIDs`, sonst `nil`. Fehlende Frames dürfen die Indizes nachfolgender IDs nicht nach links verschieben.

**Konfidenz:** hoch

**Testabdeckung: Lücke trotz vorhandenem Randtest.** `Tests/WhisperM8Tests/TabReorderGeometryTests.swift:34-37` erwartet den isolierten Count `2`, prüft aber nicht dessen anschließende Abbildung auf `beforeID`; gerade die Komposition beider Funktionen ist fehlerhaft.

## F8: Tab-Reorder ist fest auf Links-nach-rechts-Geometrie verdrahtet

**Schweregrad:** niedrig  
**Fundort:** `WhisperM8/Views/AgentTabReorderDrop.swift:14-37`

**Szenario:** Unter einer Right-to-left-Layout-Umgebung liegt der semantisch erste Tab rechts. `insertionIndex` zählt weiterhin Mittelpunkte links vom Cursor, und `insertionX` behandelt Index `0` als linke Kante des ersten Frames. Drop-Linie und resultierende Reihenfolge sind damit gespiegelt beziehungsweise springen an die falsche Blockgrenze.

**Beweis (Code-Zitat):**

```swift
if let mid = frames[id]?.midX, mid < x { count += 1 }
```

```swift
if clamped == 0 {
    return first.minX - spacing / 2
}
```

Die API erhält keine `LayoutDirection`; beide Entscheidungen kodieren LTR.

**Fix-Vorschlag:** `layoutDirection` an Geometrie und Delegate übergeben und Vergleiche sowie Außenkanten für RTL spiegeln. Die semantische ID-Reihenfolge sollte dabei unverändert die Quelle des Reorders bleiben.

**Konfidenz:** hoch für den Kontrollfluss, mittel für die praktische Häufigkeit

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/TabReorderGeometryTests.swift` enthält ausschließlich monoton nach rechts laufende Frames; RTL und absteigende `midX` fehlen.

## F9: Workspace-Erstellung aus nicht offenen Sidebar-Sessions hat zufällige Slot-Reihenfolge

**Schweregrad:** mittel  
**Fundort:** `WhisperM8/Views/AgentChatsView+BulkActions.swift:13-16`, `WhisperM8/Views/AgentChatsView+Workspaces.swift:339-356`

**Szenario:** Mehrere nicht offene Sessions werden per Cmd in der Sidebar ausgewählt und „Neuer Workspace aus Auswahl“ gewählt. `actionGroup` materialisiert das ungeordnete `Set` als Array. `createWorkspaceFromSelection` sortiert nur anhand von `openTabIDs`; für alle nicht offenen IDs ist der Schlüssel `Int.max`. Damit bleibt deren Reihenfolge von der beliebigen Set-Iteration abhängig, obwohl Workspace-Slots positionsstabil und sichtbar nummeriert sind.

**Beweis (Code-Zitat):**

```swift
multiSelection.contains(id) && multiSelection.count > 1
    ? Array(multiSelection) : [id]
```

```swift
let ordered = sessionIDs.sorted {
    (tabOrder.firstIndex(of: $0) ?? Int.max)
        < (tabOrder.firstIndex(of: $1) ?? Int.max)
}
```

Für zwei Sidebar-only-IDs vergleicht der Comparator in beide Richtungen `Int.max < Int.max` und kann die bereits ungeordnete Eingabe nicht kanonisieren.

**Fix-Vorschlag:** Die aktuell sichtbare Sidebar-Reihenfolge als geordneten Input übergeben. Als defensiven Tie-Breaker mindestens UUID-String oder Session-Sortierung verwenden; besser ist die Reihenfolge, in der der User die Rows sieht.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** Es gibt Tests für Slot-Stabilität und `WorkspaceSlotOps`, aber keinen Test für `createWorkspaceFromSelection` mit mehreren nicht offenen IDs.

## F10: Fremd gehostete Workspace-Slots erzeugen falsche Grid-Performance-Verletzungen

**Schweregrad:** niedrig  
**Fundort:** `WhisperM8/Views/AgentChatsView+Grid.swift:187-195`, `WhisperM8/Views/AgentChatsView+Grid.swift:595-605`

**Szenario:** Dieselbe Session liegt in mehreren Workspaces. Ihr Tab und Terminal-Controller gehören Fenster B; Fenster A aktiviert einen anderen Workspace mit derselben Session als fremd gehostetem Slot. Die Pane rendert in A korrekt nur einen Platzhalter. `beginGridBuildMeasurement` nimmt die Session wegen des existierenden globalen Controllers trotzdem in `expectedPaneIDs` auf. Da in A niemals ein Terminal für diese ID attached, endet die Messung im Timeout und meldet eine falsche Budgetverletzung.

**Beweis (Code-Zitat):**

```swift
let expected = target?.occupiedSessionIDs
    .filter { terminalRegistry.controller(for: $0) != nil } ?? []
```

Der Renderpfad ist strenger:

```swift
if windowStore.windowID(containingTab: sessionID) == windowID {
    gridPane(for: session, workspaceID: entity.id, slotIndex: index)
} else {
    gridOrphanSlot(session, entity: entity, slotIndex: index)
}
```

**Fix-Vorschlag:** Die erwarteten Attach-IDs mit demselben Render-Ownership-Prädikat filtern wie `gridSlot`.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/AgentGridWorkspaceStoreTests.swift:212-233` deckt Fremd-Tab-Platzhalter semantisch ab; `Tests/WhisperM8Tests/GridPerformanceTrackerTests.swift` deckt Tracker-Timeouts ab. Ein Integrationstest der Erwartungsmenge mit fremdem Host fehlt.

## F11: Ein während des Drags archivierter Chat kann noch das Projekt wechseln

**Schweregrad:** niedrig  
**Fundort:** `WhisperM8/Services/AgentChats/AgentDragDropPlanner.swift:20-23`, `WhisperM8/Services/AgentChats/AgentDragDropPlanner.swift:47-60`, `WhisperM8/Services/AgentChats/AgentSessionStore.swift:395-415`

**Szenario:** Eine Session wird aus Projekt A gezogen und vor Abschluss des Drops durch einen externen Scan oder ein anderes Fenster archiviert. Archivierte Sessions bleiben im Domain-Workspace vorhanden. Der Planner prüft nur Existenz, nicht den Archivstatus. Im Cross-Project-Zweig erzeugt er deshalb weiter einen Move-Plan; `moveSessionToProject` akzeptiert die archivierte Session und ändert ihr `projectID`, obwohl sie aus allen normalen Listen verschwunden ist.

**Beweis (Code-Zitat):**

```swift
guard workspace.projects.contains(where: { $0.id == targetProjectID }),
      workspace.sessions.contains(where: { $0.id == dropped.sessionID }) else {
    return .none
}
```

Nur die **Ziel**liste wird gefiltert:

```swift
workspace.sessions.filter {
    $0.projectID == targetProjectID && $0.status != .archived
}
```

Der Store mutiert anschließend ohne Status-Guard:

```swift
workspace.sessions[sessionIdx].projectID = newProjectID
```

**Fix-Vorschlag:** Im Planner und defensiv im Store archivierte Quellen ablehnen. Ein Drop-Payload sollte nur eine aktuell sichtbare, nicht archivierte Session bewegen dürfen.

**Konfidenz:** hoch

**Testabdeckung: Lücke.** `Tests/WhisperM8Tests/AgentDragDropPlannerTests.swift:65-77` prüft unbekannte IDs, aber keine zwischen Drag-Start und Drop archivierte Cross-Project-Session.
