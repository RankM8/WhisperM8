import Foundation
import Observation

/// Ergebnis einer Workspace-Aktivierung — Konflikte werden als Werte
/// gemeldet statt als Teilmutationen ausgeführt (Single-Owner-Politik,
/// Plan-Abschnitt 03: kein stilles Stehlen von Terminal-Hierarchien).
enum GridActivationResult: Equatable {
    case activated
    /// Workspace war diesem Fenster schon zugeordnet (idempotent; Grid
    /// wurde sichtbar gemacht, Fokus repariert).
    case alreadyActiveHere
    /// Ein anderes Fenster besitzt den Workspace — UI fokussiert dieses
    /// Fenster, es wurde NICHTS mutiert.
    case alreadyActive(ownerWindowID: UUID)
    /// Slot-Chats sind Tabs anderer Fenster (sessionID → Fenster) — die
    /// Aktivierung würde Terminal-Views stehlen; NICHTS mutiert.
    case blockedByWindowOwnership([UUID: UUID])
    /// Unbekannter Workspace bzw. unbekanntes Fenster.
    case rejected
}

/// Single Source of Truth fuer den Fenster-/Tab-UI-State ueber ALLE
/// Agent-Chats-Fenster.
///
/// Ersetzt den frueheren Pro-View-`@State` (`openTabIDs`, `selectedSessionID` …)
/// plus `NotificationCenter`-Broadcast plus Disk-Roundtrip: jede `AgentChatsView`
/// liest ihren Fenster-Slice reaktiv aus diesem `@Observable`-Store und mutiert
/// ausschliesslich ueber dessen Methoden. Damit existiert der Zustand nur EINMAL
/// im Speicher — keine fensteruebergreifende Synchronisation, keine reentranten
/// Mutationen, keine Read-modify-write-Races. Die strukturellen Invarianten
/// (eine Session lebt in genau einem Fenster; genau ein Primaerfenster; keine
/// leeren Sekundaerfenster) erzwingt `AgentUIState` bei jeder Mutation.
///
/// Persistenz laeuft debounced ueber `AgentSessionStore` — die App-Kopie auf der
/// Platte folgt dem Speicher, nie umgekehrt.
@MainActor
@Observable
final class AgentWindowStore {
    static let shared = AgentWindowStore()

    /// Der gesamte persistente Fenster-/Tab-State. Views beobachten Reads
    /// hierauf reaktiv; geschrieben wird nur ueber die Mutations-Methoden.
    private(set) var state: AgentUIState

    /// Ephemere Multi-Auswahl pro Fenster (NICHT persistiert) — im Store, damit
    /// ein Cross-Window-Drop die Quell-Auswahl LIVE lesen und danach leeren kann.
    private var multiSelectionByWindow: [UUID: Set<UUID>] = [:]

    @ObservationIgnored private let persistence: AgentSessionStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Debounce-Fenster fuer das Persistieren — buendelt schnelle
    /// Tab-Wechsel/Reorders zu einem Schreibvorgang.
    @ObservationIgnored var saveDebounce: Duration = .milliseconds(400)

    /// Offene Tabs ALLER Fenster zum App-Start — Snapshot BEVOR Restore/
    /// User-Interaktion den State verändern. Basis des Summary-Start-Abgleichs
    /// („nur zuvor aktive Tabs prüfen, nie die Historie").
    @ObservationIgnored private(set) var openTabIDsAtLaunch: [UUID] = []

    init(persistence: AgentSessionStore = AgentSessionStore()) {
        self.persistence = persistence
        self.state = persistence.loadUIState()
        var seen = Set<UUID>()
        openTabIDsAtLaunch = state.windows.flatMap(\.openTabIDs).filter { seen.insert($0).inserted }
    }

    // MARK: - Reads

    var primaryWindowID: UUID { state.primaryWindowID }
    var pinnedSessionIDs: [UUID] { state.pinnedSessionIDs }
    var expandedProjectIDs: [UUID] { state.expandedProjectIDs }

    /// Vollstaendiger Slice eines Fensters (Fallback fuer unbekannte IDs liefert
    /// `AgentUIState.windowState(for:)`).
    func window(for id: UUID) -> AgentChatWindowState { state.windowState(for: id) }

    /// `true`, wenn das Fenster wirklich im State existiert (kein Fallback).
    /// Sekundaerfenster, die NICHT hier sind, sind verwaiste Restore-Artefakte
    /// und sollen sich gar nicht erst aufbauen.
    func hasWindow(_ id: UUID) -> Bool {
        id == state.primaryWindowID || state.windows.contains { $0.id == id }
    }

    func openTabIDs(in windowID: UUID) -> [UUID] { window(for: windowID).openTabIDs }
    func selectedSession(in windowID: UUID) -> UUID? { window(for: windowID).selectedSessionID }

    /// Ephemere Multi-Auswahl (kein Persist). Leere Menge räumt den Eintrag auf.
    func multiSelection(in windowID: UUID) -> Set<UUID> { multiSelectionByWindow[windowID] ?? [] }
    func setMultiSelection(_ ids: Set<UUID>, in windowID: UUID) {
        multiSelectionByWindow[windowID] = ids.isEmpty ? nil : ids
    }
    func selectedProject(in windowID: UUID) -> UUID? { window(for: windowID).selectedProjectID }

    /// IDs aller Sekundaerfenster (alles ausser dem Primaerfenster) — fuer den
    /// Restore-Pfad beim Launch.
    var secondaryWindowIDs: [UUID] {
        state.windows.map(\.id).filter { $0 != state.primaryWindowID }
    }

    /// Fenster, das `sessionID` bereits als Tab offen hat (Primaerfenster
    /// zuerst). `nil`, wenn kein Fenster den Chat zeigt — fuers
    /// Notification-Klick-Routing: vorhandenes Fenster fokussieren statt den
    /// Tab in ein anderes zu ziehen.
    func windowID(containingTab sessionID: UUID) -> UUID? {
        if openTabIDs(in: primaryWindowID).contains(sessionID) {
            return primaryWindowID
        }
        return secondaryWindowIDs.first { openTabIDs(in: $0).contains(sessionID) }
    }

    // MARK: - Tab-Mutationen (pro Fenster)

    /// Oeffnet `sessionID` als Tab im angegebenen Fenster (idempotent) und
    /// selektiert ihn. Die globale Eindeutigkeit (Session nur in EINEM Fenster)
    /// stellt `AgentUIState` ueber `upsertWindow` her.
    func openTab(_ sessionID: UUID, in windowID: UUID, select: Bool = true) {
        updateWindow(windowID) { window in
            if !window.openTabIDs.contains(sessionID) {
                window.openTabIDs.append(sessionID)
            }
            if select { window.selectedSessionID = sessionID }
        }
    }

    func selectTab(_ sessionID: UUID, in windowID: UUID) {
        updateWindow(windowID) { $0.selectedSessionID = sessionID }
    }

    /// Setzt die Selektion und oeffnet dabei den Tab, falls noch nicht offen
    /// (`nil` deselektiert). Bridge fuer die bisherigen `selectedSessionID = …`
    /// Aufrufstellen, die teils auch erst einen Chat oeffnen.
    func setSelectedSession(_ sessionID: UUID?, in windowID: UUID) {
        updateWindow(windowID) { window in
            guard let sessionID else { window.selectedSessionID = nil; return }
            if !window.openTabIDs.contains(sessionID) { window.openTabIDs.append(sessionID) }
            window.selectedSessionID = sessionID
        }
    }

    /// Ersetzt die komplette Tab-Liste eines Fensters. Bridge fuer die
    /// bisherigen `openTabIDs.append/remove/insert`-Aufrufstellen (Swift macht
    /// daraus get→modify→set). Invarianten stellt `upsertWindow` her.
    func setOpenTabIDs(_ ids: [UUID], in windowID: UUID) {
        updateWindow(windowID) { $0.openTabIDs = ids }
    }

    /// Schliesst einen Tab. Selektion rueckt auf den vorherigen Tab (sonst den
    /// neuen letzten), nie ins Leere, solange noch Tabs da sind.
    func closeTab(_ sessionID: UUID, in windowID: UUID) {
        updateWindow(windowID) { window in
            guard let index = window.openTabIDs.firstIndex(of: sessionID) else { return }
            window.openTabIDs.remove(at: index)
            if window.selectedSessionID == sessionID {
                let fallbackIndex = max(0, index - 1)
                window.selectedSessionID = window.openTabIDs.indices.contains(fallbackIndex)
                    ? window.openTabIDs[fallbackIndex]
                    : window.openTabIDs.first
            }
        }
    }

    /// Reorder innerhalb desselben Fensters: `sessionID` landet vor `targetID`
    /// (oder ans Ende, wenn `targetID == nil`). No-op fuer unbekannte Fenster
    /// (siehe `updateWindow` — kein Create-on-mutate).
    func reorderTab(_ sessionID: UUID, before targetID: UUID?, in windowID: UUID) {
        guard hasWindow(windowID) else { return }
        mutate { $0.moveTab(sessionID: sessionID, from: windowID, to: windowID, before: targetID) }
    }

    /// Verschiebt einen Tab in ein anderes (bestehendes) Fenster. Das Ziel
    /// muss existieren — sonst wuerde der `windowState(for:)`-Fallback in
    /// `AgentUIState.moveTab` ein Geisterfenster ohne NSWindow erzeugen.
    /// Neue Fenster entstehen ausschliesslich ueber `detachToNewWindow`.
    func moveTab(_ sessionID: UUID, from sourceWindowID: UUID, to targetWindowID: UUID, before targetID: UUID?) {
        guard hasWindow(targetWindowID) else { return }
        mutate { $0.moveTab(sessionID: sessionID, from: sourceWindowID, to: targetWindowID, before: targetID) }
    }

    /// Loest einen Tab in ein NEUES Fenster ab. Gibt die ID des neuen Fensters
    /// zurueck (Aufrufer oeffnet damit die Scene via `openWindow`).
    @discardableResult
    func detachToNewWindow(_ sessionID: UUID, from sourceWindowID: UUID) -> UUID {
        let newWindowID = UUID()
        mutate { $0.moveTabToNewWindow(sessionID: sessionID, sourceWindowID: sourceWindowID, newWindowID: newWindowID) }
        return newWindowID
    }

    func setSelectedProject(_ projectID: UUID?, in windowID: UUID) {
        updateWindow(windowID) { $0.selectedProjectID = projectID }
    }

    // MARK: - Grid-Ansicht (pro Fenster)

    /// `true` = alle offenen Tabs als Panes (Maximize/Minimize-Toggle),
    /// `false` = Einzelansicht des selektierten Tabs (Default).
    func showsGrid(in windowID: UUID) -> Bool {
        window(for: windowID).showsGrid
    }

    func setShowsGrid(_ shows: Bool, in windowID: UUID) {
        updateWindow(windowID) { $0.showsGrid = shows }
    }

    /// ÜBERGANGS-Bridge (bis Paket 2d das Grid auf Workspace-Entities
    /// umstellt): fensterlokale Grid-Mitgliedschaft aus der v3-Ära. Wird
    /// nicht mehr persistiert — die v4-Migration überführt sie in
    /// `gridWorkspaces`.
    func gridSessionIDs(in windowID: UUID) -> [UUID] {
        window(for: windowID).legacyGridSessionIDs
    }

    func setGridSessionIDs(_ ids: [UUID], in windowID: UUID) {
        updateWindow(windowID) { $0.legacyGridSessionIDs = ids }
    }

    // MARK: - Grid-Workspaces: Reads (global, Schema v4)

    var gridWorkspaces: [AgentGridWorkspace] { state.gridWorkspaces }

    func gridWorkspace(id: UUID) -> AgentGridWorkspace? {
        state.gridWorkspaces.first { $0.id == id }
    }

    /// Der Workspace, den das Fenster referenziert (Grid ODER
    /// Rücksprungziel der Einzelansicht).
    func activeGridWorkspace(in windowID: UUID) -> AgentGridWorkspace? {
        guard let id = window(for: windowID).activeWorkspaceID else { return nil }
        return gridWorkspace(id: id)
    }

    /// Besitzerfenster eines Workspace (`nil` = nirgends referenziert).
    func windowID(owningGridWorkspace workspaceID: UUID) -> UUID? {
        state.windows.first { $0.activeWorkspaceID == workspaceID }?.id
    }

    func slotIndex(of sessionID: UUID, inGridWorkspace workspaceID: UUID) -> Int? {
        gridWorkspace(id: workspaceID)?.slotIndex(of: sessionID)
    }

    // MARK: - Grid-Workspaces: Entity-Mutationen

    /// Legt einen Workspace an (ans Array-Ende = unten in der Sidebar) und
    /// aktiviert ihn optional sofort im Fenster. Name/Farbe/Kapazität
    /// normalisiert die Entity selbst (leerer Name → Default).
    @discardableResult
    func createGridWorkspace(
        name: String,
        colorHex: String = AgentGridWorkspace.defaultColorHex,
        capacity: Int = 2,
        slots: [UUID?] = [],
        activateIn windowID: UUID? = nil
    ) -> UUID {
        let entity = AgentGridWorkspace(
            name: name, colorHex: colorHex, slots: slots, capacity: capacity
        )
        mutate { $0.gridWorkspaces.append(entity) }
        if let windowID {
            // Läuft im selben MainActor-Turn wie das Anlegen — der Debounce
            // bündelt beide Mutationen zu einem Save.
            _ = activateGridWorkspace(entity.id, in: windowID)
        }
        return entity.id
    }

    /// Umbenennen (getrimmt; leer/unbekannt = No-op ohne Save-Aktivität).
    @discardableResult
    func renameGridWorkspace(_ workspaceID: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let entity = gridWorkspace(id: workspaceID),
              entity.name != trimmed else { return false }
        mutateGridWorkspace(workspaceID) { $0.name = trimmed }
        return true
    }

    @discardableResult
    func setGridWorkspaceColor(_ workspaceID: UUID, colorHex: String) -> Bool {
        guard let canonical = AgentGridWorkspace.canonicalColorHex(colorHex),
              let entity = gridWorkspace(id: workspaceID),
              entity.colorHex != canonical else { return false }
        mutateGridWorkspace(workspaceID) { $0.colorHex = canonical }
        return true
    }

    /// Löscht die Entity und räumt in EINER Mutation alle Fenster-Referenzen
    /// (`activeWorkspaceID`, `showsGrid`). Tabs, Sessions und Prozesse
    /// bleiben unangetastet. User-Daten → sofortiger Flush statt Debounce.
    @discardableResult
    func deleteGridWorkspace(_ workspaceID: UUID) -> Bool {
        guard gridWorkspace(id: workspaceID) != nil else { return false }
        mutate { state in
            state.gridWorkspaces.removeAll { $0.id == workspaceID }
            for index in state.windows.indices
                where state.windows[index].activeWorkspaceID == workspaceID {
                state.windows[index].activeWorkspaceID = nil
                state.windows[index].showsGrid = false
            }
        }
        flush()
        return true
    }

    /// Sidebar-Reorder: bekannte IDs in übergebener Reihenfolge, ausgelassene
    /// bekannte IDs bleiben (in bisheriger Reihenfolge) hinten — ein stale
    /// Drag kann dadurch NIEMALS Entities löschen.
    func reorderGridWorkspaces(orderedIDs: [UUID]) {
        mutate { state in
            var seen = Set<UUID>()
            let byID = Dictionary(
                uniqueKeysWithValues: state.gridWorkspaces.map { ($0.id, $0) }
            )
            var reordered: [AgentGridWorkspace] = []
            for id in orderedIDs {
                guard let entity = byID[id], seen.insert(id).inserted else { continue }
                reordered.append(entity)
            }
            for entity in state.gridWorkspaces where seen.insert(entity.id).inserted {
                reordered.append(entity)
            }
            state.gridWorkspaces = reordered
        }
    }

    // MARK: - Grid-Workspaces: Slot-Mutationen

    /// Nimmt eine Session in den Workspace auf (Semantik siehe
    /// `WorkspaceSlotOps.add`). Unbekannte/archivierte Sessions werden
    /// abgewiesen; gehört die Session als Tab einem ANDEREN Fenster als dem
    /// Besitzerfenster des Workspace, ebenso (kein Terminal-Stehlen).
    /// Im Besitzerfenster wird der Tab materialisiert und (bei sichtbarem
    /// Grid) fokussiert — alles in EINER Mutation.
    @discardableResult
    func addSession(
        _ sessionID: UUID,
        toGridWorkspace workspaceID: UUID,
        at targetSlot: Int? = nil,
        focusIfActive: Bool = true
    ) -> WorkspaceSlotOps.AddResult {
        guard let entity = gridWorkspace(id: workspaceID) else { return .rejected }
        // Session-Validierung gegen den Domain-Workspace (In-Memory-Read,
        // kein Subprozess).
        let domain = persistence.loadWorkspace()
        guard let session = domain.sessions.first(where: { $0.id == sessionID }),
              session.status != .archived else { return .rejected }
        if let owner = windowID(owningGridWorkspace: workspaceID),
           let host = windowID(containingTab: sessionID),
           host != owner {
            return .rejected
        }

        let (updated, result) = WorkspaceSlotOps.add(sessionID, to: entity, at: targetSlot)
        switch result {
        case .alreadyMember, .full, .rejected:
            return result
        case .added, .replaced, .swapped:
            break
        }
        mutate { state in
            guard let index = state.gridWorkspaces.firstIndex(where: { $0.id == workspaceID })
            else { return }
            state.gridWorkspaces[index] = updated
            guard let ownerID = state.windows.first(where: { $0.activeWorkspaceID == workspaceID })?.id
            else { return }
            var window = state.windowState(for: ownerID)
            if !window.openTabIDs.contains(sessionID) {
                window.openTabIDs.append(sessionID)
            }
            if focusIfActive, window.showsGrid {
                window.selectedSessionID = sessionID
            }
            state.upsertWindow(window)
        }
        return result
    }

    /// Leert den Slot der Session (Tab + Prozess bleiben; nichts rückt
    /// nach). Repariert den Pane-Fokus des Besitzerfensters deterministisch:
    /// nächster belegter Slot, sonst vorheriger, sonst `nil`.
    @discardableResult
    func removeSession(_ sessionID: UUID, fromGridWorkspace workspaceID: UUID) -> Bool {
        guard let entity = gridWorkspace(id: workspaceID),
              let removedIndex = entity.slotIndex(of: sessionID) else { return false }
        let (updated, removed) = WorkspaceSlotOps.remove(sessionID, from: entity)
        guard removed else { return false }
        mutate { state in
            guard let index = state.gridWorkspaces.firstIndex(where: { $0.id == workspaceID })
            else { return }
            state.gridWorkspaces[index] = updated
            guard let ownerID = state.windows.first(where: { $0.activeWorkspaceID == workspaceID })?.id
            else { return }
            var window = state.windowState(for: ownerID)
            if window.showsGrid, window.selectedSessionID == sessionID {
                window.selectedSessionID = Self.gridFocusFallback(
                    in: updated, removedIndex: removedIndex
                )
            }
            state.upsertWindow(window)
        }
        return true
    }

    @discardableResult
    func moveSlot(inGridWorkspace workspaceID: UUID, from source: Int, to target: Int) -> Bool {
        guard let entity = gridWorkspace(id: workspaceID) else { return false }
        let (updated, moved) = WorkspaceSlotOps.moveSlot(in: entity, from: source, to: target)
        guard moved else { return false }
        mutateGridWorkspace(workspaceID) { $0 = updated }
        return true
    }

    @discardableResult
    func swapSlots(inGridWorkspace workspaceID: UUID, _ first: Int, _ second: Int) -> Bool {
        guard let entity = gridWorkspace(id: workspaceID) else { return false }
        let (updated, swapped) = WorkspaceSlotOps.swapSlots(in: entity, first, second)
        guard swapped else { return false }
        mutateGridWorkspace(workspaceID) { $0 = updated }
        return true
    }

    /// Welche Sessions würde ein Wechsel auf `capacity` entfernen (geordnet).
    func previewCapacityChange(of workspaceID: UUID, to capacity: Int) -> [UUID] {
        guard let entity = gridWorkspace(id: workspaceID) else { return [] }
        return WorkspaceSlotOps.previewCapacityChange(of: entity, to: capacity)
    }

    /// Kapazität setzen. Shrink verlangt die exakt bestätigte
    /// Eviction-Liste (`.confirmationRequired` sonst) und flusht sofort —
    /// destruktive User-Entscheidung. Fokus wird repariert, falls die
    /// fokussierte Pane den Workspace verlässt.
    func setCapacity(
        ofGridWorkspace workspaceID: UUID,
        to capacity: Int,
        expectedEvictedSessionIDs: [UUID] = []
    ) -> WorkspaceSlotOps.CapacityResult {
        guard let entity = gridWorkspace(id: workspaceID) else { return .rejected }
        let (updated, result) = WorkspaceSlotOps.setCapacity(
            of: entity, to: capacity, expectedEvictedSessionIDs: expectedEvictedSessionIDs
        )
        guard result == .applied else { return result }
        let isShrink = capacity < entity.capacity
        mutate { state in
            guard let index = state.gridWorkspaces.firstIndex(where: { $0.id == workspaceID })
            else { return }
            state.gridWorkspaces[index] = updated
            guard let ownerID = state.windows.first(where: { $0.activeWorkspaceID == workspaceID })?.id
            else { return }
            var window = state.windowState(for: ownerID)
            if window.showsGrid, let selected = window.selectedSessionID,
               updated.slotIndex(of: selected) == nil {
                window.selectedSessionID = updated.occupiedSessionIDs.first
            }
            state.upsertWindow(window)
        }
        if isShrink { flush() }
        return result
    }

    // MARK: - Grid-Workspaces: Fenster-/Fokus-Mutationen

    /// Aktiviert einen Workspace als Grid des Fensters (Single-Owner).
    /// Materialisiert fehlende Slot-Tabs in Slot-Reihenfolge HINTEN, ohne
    /// bestehende Tabs zu schließen oder umzusortieren; startet nie
    /// Prozesse. Konflikte kommen als Ergebnis zurück, nie als Teilmutation.
    @discardableResult
    func activateGridWorkspace(_ workspaceID: UUID, in windowID: UUID) -> GridActivationResult {
        guard let entity = gridWorkspace(id: workspaceID), hasWindow(windowID) else {
            return .rejected
        }
        let current = window(for: windowID)
        if current.activeWorkspaceID == workspaceID {
            updateWindow(windowID) { window in
                window.showsGrid = true
                Self.materializeSlotTabs(&window, entity: entity)
                Self.repairGridFocus(&window, entity: entity)
            }
            return .alreadyActiveHere
        }
        if let owner = self.windowID(owningGridWorkspace: workspaceID), owner != windowID {
            return .alreadyActive(ownerWindowID: owner)
        }
        var conflicts: [UUID: UUID] = [:]
        for sessionID in entity.occupiedSessionIDs {
            if let host = self.windowID(containingTab: sessionID), host != windowID {
                conflicts[sessionID] = host
            }
        }
        guard conflicts.isEmpty else {
            return .blockedByWindowOwnership(conflicts)
        }
        updateWindow(windowID) { window in
            window.activeWorkspaceID = workspaceID
            window.showsGrid = true
            Self.materializeSlotTabs(&window, entity: entity)
            Self.repairGridFocus(&window, entity: entity)
        }
        return .activated
    }

    /// Einzelansicht öffnen/selektieren — die Workspace-Referenz bleibt
    /// („Zurück zum Workspace"), Slots bleiben unverändert.
    func showSingleSession(_ sessionID: UUID, in windowID: UUID) {
        updateWindow(windowID) { window in
            if !window.openTabIDs.contains(sessionID) {
                window.openTabIDs.append(sessionID)
            }
            window.selectedSessionID = sessionID
            window.showsGrid = false
        }
    }

    /// „Zurück zum Workspace ‹Name›": Grid wieder sichtbar machen. Läuft
    /// über die Aktivierung (inkl. Konflikt-Prüfung, Tab-Materialisierung,
    /// Fokus-Reparatur).
    @discardableResult
    func returnToActiveGrid(in windowID: UUID) -> GridActivationResult {
        guard let workspaceID = window(for: windowID).activeWorkspaceID else {
            return .rejected
        }
        return activateGridWorkspace(workspaceID, in: windowID)
    }

    /// Pane-Fokus im sichtbaren Grid — akzeptiert nur belegte Slots.
    func setGridFocusedSession(_ sessionID: UUID, in windowID: UUID) {
        guard let entity = activeGridWorkspace(in: windowID),
              window(for: windowID).showsGrid,
              entity.slotIndex(of: sessionID) != nil else { return }
        updateWindow(windowID) { $0.selectedSessionID = sessionID }
    }

    // MARK: - Key-Window-Routing (ephemer, fürs Dictation)

    /// Das Agent-Chats-Fenster, das zuletzt Key wurde — Dictation routet
    /// ausschließlich über dieses Fenster (Selektionen in Nicht-Key-Fenstern
    /// ändern das Routing nie). Ephemer, nie persistiert.
    private(set) var keyAgentChatWindowID: UUID?

    func windowDidBecomeKey(_ windowID: UUID) {
        keyAgentChatWindowID = windowID
    }

    /// Löscht das Routing nur, wenn GENAU dieses Fenster noch eingetragen
    /// ist — ein `resignKey` des alten Fensters nach dem `becomeKey` des
    /// neuen darf das neue nicht wegräumen.
    func windowDidResignKey(_ windowID: UUID) {
        if keyAgentChatWindowID == windowID {
            keyAgentChatWindowID = nil
        }
    }

    // MARK: - Grid-Workspaces: Helfer

    /// Ändert genau eine Entity (per ID) in einer Store-Mutation.
    private func mutateGridWorkspace(_ workspaceID: UUID, _ transform: (inout AgentGridWorkspace) -> Void) {
        mutate { state in
            guard let index = state.gridWorkspaces.firstIndex(where: { $0.id == workspaceID })
            else { return }
            var entity = state.gridWorkspaces[index]
            transform(&entity)
            state.gridWorkspaces[index] = entity.normalized()
        }
    }

    /// Fehlende Slot-Tabs in Slot-Reihenfolge hinten anhängen — bestehende
    /// Tabs bleiben unberührt (weder geschlossen noch umsortiert).
    private static func materializeSlotTabs(
        _ window: inout AgentChatWindowState, entity: AgentGridWorkspace
    ) {
        for sessionID in entity.occupiedSessionIDs
            where !window.openTabIDs.contains(sessionID) {
            window.openTabIDs.append(sessionID)
        }
    }

    /// Fokus-Invariante im sichtbaren Grid: Selektion muss ein belegter Slot
    /// sein — sonst erster belegter Slot; leerer Workspace → `nil`.
    private static func repairGridFocus(
        _ window: inout AgentChatWindowState, entity: AgentGridWorkspace
    ) {
        if let selected = window.selectedSessionID,
           entity.slotIndex(of: selected) != nil {
            return
        }
        window.selectedSessionID = entity.occupiedSessionIDs.first
    }

    /// Deterministischer Fokus-Fallback nach Entfernen des fokussierten
    /// Slots: nächster belegter Slot nach dem entfernten Index, sonst der
    /// vorherige, sonst `nil`.
    private static func gridFocusFallback(
        in entity: AgentGridWorkspace, removedIndex: Int
    ) -> UUID? {
        if let next = entity.slots[removedIndex...].compactMap({ $0 }).first {
            return next
        }
        return entity.slots[..<removedIndex].compactMap { $0 }.last
    }

    /// Entfernt ein leeres Sekundaerfenster aus dem State. Gibt `true` zurueck,
    /// wenn tatsaechlich entfernt wurde (Aufrufer kann dann das NSWindow zu).
    @discardableResult
    func removeWindowIfEmpty(_ windowID: UUID) -> Bool {
        guard windowID != state.primaryWindowID,
              window(for: windowID).openTabIDs.isEmpty,
              state.windows.contains(where: { $0.id == windowID }) else { return false }
        mutate { $0.removeWindowIfEmpty(windowID) }
        return true
    }

    // MARK: - Fenster-Lifecycle (Close-Tracking)

    /// `true`, solange Fenster-Closes NICHT als User-Aktion gewertet werden
    /// sollen (App-Quit, Profilwechsel). Ephemer, nie persistiert.
    @ObservationIgnored private(set) var isCloseTrackingSuspended = false

    /// Programmatisches Fenster-Schliessen beginnt (App-Quit, Profilwechsel):
    /// `handleWindowWillClose` entfernt ab jetzt KEINE Fenster mehr aus dem
    /// State — genau dadurch ueberleben offene Fenster den Neustart bzw. den
    /// Rueckwechsel des Profils.
    func suspendCloseTracking() { isCloseTrackingSuspended = true }

    /// User-Close-Tracking wieder aktivieren (nach dem Profilwechsel-Close;
    /// beim App-Quit bleibt es bis zum Prozess-Ende suspendiert).
    func resumeCloseTracking() { isCloseTrackingSuspended = false }

    /// Entfernt ein Sekundaerfenster MITSAMT seiner Tabs aus dem State —
    /// Chrome-Semantik fuer „User schliesst das Fenster" (rotes X, ⌘W ohne
    /// Tabs, Fenstermenue). Die Sessions bleiben im Workspace/der Sidebar
    /// erhalten; laufende PTYs laufen weiter (Registry ist sessionID-basiert).
    /// No-op fuer das Primaerfenster und unbekannte IDs.
    @discardableResult
    func removeWindow(_ windowID: UUID) -> Bool {
        guard windowID != state.primaryWindowID,
              state.windows.contains(where: { $0.id == windowID }) else { return false }
        mutate { $0.removeWindow(windowID) }
        multiSelectionByWindow[windowID] = nil
        return true
    }

    /// Einstiegspunkt fuer `NSWindow.willCloseNotification` (via
    /// `AgentChatsWindowAccessor.onWillClose`): Nur ein USER-Close raeumt das
    /// Fenster aus dem State — waehrend Quit/Profilwechsel (suspended) bleibt
    /// der State unangetastet, damit der Launch-Restore die Fenster
    /// wiederherstellen kann.
    func handleWindowWillClose(_ windowID: UUID) {
        guard !isCloseTrackingSuspended else { return }
        removeWindow(windowID)
    }

    // MARK: - Globale Mutationen

    func setPinnedSessionIDs(_ ids: [UUID]) {
        mutate { $0.pinnedSessionIDs = ids }
    }

    func togglePin(_ sessionID: UUID) {
        mutate { state in
            if let index = state.pinnedSessionIDs.firstIndex(of: sessionID) {
                state.pinnedSessionIDs.remove(at: index)
            } else {
                state.pinnedSessionIDs.append(sessionID)
            }
        }
    }

    func setExpandedProjectIDs(_ ids: [UUID]) {
        mutate { $0.expandedProjectIDs = ids }
    }

    /// Klappt genau ein Projekt auf (idempotent, kein Save-Churn) — für den
    /// Sidebar-Reveal beim Notification-Fokus: die Selektion allein macht die
    /// Row nicht sichtbar, wenn ihre Projekt-Gruppe eingeklappt ist.
    func expandProject(_ projectID: UUID) {
        guard !state.expandedProjectIDs.contains(projectID) else { return }
        mutate { $0.expandedProjectIDs.append(projectID) }
    }

    // MARK: - Subagent-Unread (global, gelesen ist gelesen)

    /// Ungelesene Subagent-Ergebnisse als Set — Row-Input der Sidebar.
    var unreadSubagentSessionIDs: Set<UUID> {
        Set(state.unreadSubagentSessionIDs)
    }

    func isSubagentUnread(_ sessionID: UUID) -> Bool {
        state.unreadSubagentSessionIDs.contains(sessionID)
    }

    /// Vom `AgentJobWorkspaceSync` beim Übergang running→done/failed gesetzt.
    /// Diff-gated: erneutes Markieren derselben Session ist ein No-op (kein
    /// Save-Churn).
    func markSubagentUnread(_ sessionID: UUID) {
        guard !state.unreadSubagentSessionIDs.contains(sessionID) else { return }
        mutate { $0.unreadSubagentSessionIDs.append(sessionID) }
    }

    /// Geleert bei Tab-Selektion bzw. beim Öffnen der Job-Detail-View.
    func clearSubagentUnread(_ sessionID: UUID) {
        guard state.unreadSubagentSessionIDs.contains(sessionID) else { return }
        mutate { $0.unreadSubagentSessionIDs.removeAll { $0 == sessionID } }
    }

    // MARK: - Subagent-Kinder: Auf-/Einklappen (ephemer)

    /// Parents, deren Subagent-Kinder in der Sidebar AUSGEKLAPPT sind.
    /// Bewusst NICHT persistiert (kein `state`-Feld): Default ist bei jedem
    /// App-Start eingeklappt — die Kinder sind Detail, der Parent-Chip zeigt,
    /// dass es sie gibt.
    var expandedSubagentParentIDs: Set<UUID> = []

    func isSubagentChildrenExpanded(_ parentID: UUID) -> Bool {
        expandedSubagentParentIDs.contains(parentID)
    }

    func toggleSubagentChildren(_ parentID: UUID) {
        if expandedSubagentParentIDs.contains(parentID) {
            expandedSubagentParentIDs.remove(parentID)
        } else {
            expandedSubagentParentIDs.insert(parentID)
        }
    }

    /// Klappt die Subagent-Gruppe eines Parents explizit AUF (Notification-
    /// Fokus): die implizite Offenhaltung über die Selektion greift nur,
    /// solange das Kind selektiert bleibt — nach einem Tab-Wechsel wäre die
    /// Gruppe sonst wieder zu und die Row weg.
    func expandSubagentChildren(_ parentID: UUID) {
        expandedSubagentParentIDs.insert(parentID)
    }

    // MARK: - Wartung

    /// Garbage-Collection gegen den aktuellen Workspace (tote Session-/Projekt-
    /// IDs raus, leere Sekundaerfenster weg). Vom UI nach Workspace-Aenderungen
    /// aufgerufen (`onChange(of: workspace)` in AgentChatsView). Diff-gated:
    /// ohne effektive Aenderung kein State-Write — sonst wuerde jeder
    /// Workspace-Tick alle Fenster re-rendern und leere Saves schedulen.
    /// Bewusst OHNE Tab-Cap (`capTabs: false`): zur Laufzeit darf die Bar
    /// mehr als `maxOpenTabs` zeigen, gekappt wird nur beim Load.
    func prune(workspace: AgentWorkspace) {
        var pruned = state
        pruned.prune(workspace: workspace, capTabs: false)
        guard pruned != state else { return }
        state = pruned
        scheduleSave()
    }

    /// Erzwingt sofortiges Persistieren (z. B. vor App-Terminierung,
    /// Workspace-Delete, bestätigtem Capacity-Shrink). Fehler werden
    /// geloggt, nicht verschluckt — der Zustand bleibt dirty und der
    /// nächste Debounce/Flush versucht es erneut.
    func flush() {
        saveTask?.cancel()
        do {
            try persistence.saveUIState(state)
        } catch {
            Logger.debug("AgentUIState flush failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Intern

    /// Modifiziert genau ein Fenster und schreibt es zurueck (`upsertWindow`
    /// normalisiert danach alle Invarianten).
    ///
    /// Kein Create-on-mutate: Mutationen auf Fenster, die der Store nicht
    /// (mehr) kennt, sind No-ops. Nachzuegler einer View, deren Fenster gerade
    /// geschlossen/entfernt wurde (onChange/reconcileSelection feuern beim
    /// Teardown noch), wuerden das Fenster sonst als Geist wiederbeleben —
    /// beim naechsten Launch stuende es wieder da. Neue Fenster entstehen
    /// ausschliesslich ueber `detachToNewWindow` (und die Primaerfenster-
    /// Garantie in `normalizedWindows`).
    private func updateWindow(_ id: UUID, _ transform: (inout AgentChatWindowState) -> Void) {
        guard hasWindow(id) else { return }
        var window = state.windowState(for: id)
        transform(&window)
        mutate { $0.upsertWindow(window) }
    }

    private func mutate(_ block: (inout AgentUIState) -> Void) {
        block(&state)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let persistence = persistence
        let debounce = saveDebounce
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            do {
                // Bewusst der AKTUELLE State statt eines Alt-Snapshots:
                // eine Mutation während des Debounce-Fensters kann so nie
                // von einem älteren Write überholt werden (Robustheits-Spez
                // 14d92786, stateRevision-Garantie auf dem MainActor).
                try persistence.saveUIState(self.state)
            } catch {
                // Nicht verschlucken: loggen, dirty lassen, mit Abstand
                // erneut versuchen (Dauerfehler wie „Disk voll" sollen
                // nicht im 400-ms-Takt spammen).
                Logger.debug("AgentUIState save failed: \(error.localizedDescription) — retry in 5s")
                self.saveTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.scheduleSave()
                }
            }
        }
    }
}
