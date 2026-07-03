import Foundation
import Observation

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

    init(persistence: AgentSessionStore = AgentSessionStore()) {
        self.persistence = persistence
        self.state = persistence.loadUIState()
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

    /// Erzwingt sofortiges Persistieren (z. B. vor App-Terminierung).
    func flush() {
        saveTask?.cancel()
        try? persistence.saveUIState(state)
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
        let snapshot = state
        let persistence = persistence
        let debounce = saveDebounce
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            try? persistence.saveUIState(snapshot)
        }
    }
}
