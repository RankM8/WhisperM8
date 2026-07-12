import Foundation

/// Persistenter UI-State des Agent-Chats-Fensters — offene Tabs, gepinnte
/// Chats, Selektion und aufgeklappte Sidebar-Projekte.
///
/// Wird als JSON-Sidecar-Datei `agent-ui-state.json` neben dem Workspace
/// in Application Support gespeichert. Bewusst NICHT in UserDefaults:
/// - Reihenfolge der Tabs (Array statt Set) bleibt erhalten
/// - Future-Proof: bei einem Workspace-Export wandert der UI-State mit
///
/// Schema v3 (Multi-Window Juni 2026): Tabs leben in Fenstergruppen. v2-Dateien
/// mit globaler `openTabIDs`-Liste werden in ein Primaerfenster migriert.
struct AgentChatWindowState: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var openTabIDs: [UUID]
    var selectedSessionID: UUID?
    var selectedProjectID: UUID?
    var isPrimary: Bool
    /// Kompakt-Zustand („Projekt-Cockpit"): Fenster zeigt statt Sidebar+Tabs
    /// eine schmale Projekt-Chat-Liste + den aktiven Chat.
    var isCompact: Bool
    /// Fenster-Frame VOR dem Verkleinern — Ziel der Rueckverwandlung. Muss
    /// persistiert werden, weil die Agent-Fenster `isRestorable = false`
    /// setzen und macOS sich nichts merkt. `nil` ausserhalb des Kompakt-Modus.
    var expandedFrame: AgentWindowFrame?

    init(
        id: UUID = UUID(),
        openTabIDs: [UUID] = [],
        selectedSessionID: UUID? = nil,
        selectedProjectID: UUID? = nil,
        isPrimary: Bool = false,
        isCompact: Bool = false,
        expandedFrame: AgentWindowFrame? = nil
    ) {
        self.id = id
        self.openTabIDs = openTabIDs
        self.selectedSessionID = selectedSessionID
        self.selectedProjectID = selectedProjectID
        self.isPrimary = isPrimary
        self.isCompact = isCompact
        self.expandedFrame = expandedFrame
    }

    enum CodingKeys: String, CodingKey {
        case id, openTabIDs, selectedSessionID, selectedProjectID, isPrimary
        case isCompact, expandedFrame
    }

    /// Manueller Decoder statt Synthese: synthetisiertes Codable nutzt KEINE
    /// Property-Defaults — ein fehlender `isCompact`-Key in Bestandsdateien
    /// wuerde `keyNotFound` werfen, und der `loadUIState`-Fallback verwirft
    /// dann still den kompletten Fenster-/Tab-State des Users.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        openTabIDs = try c.decodeIfPresent([UUID].self, forKey: .openTabIDs) ?? []
        selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        isCompact = try c.decodeIfPresent(Bool.self, forKey: .isCompact) ?? false
        expandedFrame = try c.decodeIfPresent(AgentWindowFrame.self, forKey: .expandedFrame)
    }
}

/// Fenster-Frame in Bildschirm-Koordinaten — eigener Codable-Typ statt
/// `CGRect`, damit das Sidecar-JSON lesbare Keys hat (CGRect encodiert als
/// verschachteltes Array) und das Model plattform-neutral bleibt.
struct AgentWindowFrame: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct AgentUIState: Codable, Equatable {
    var schemaVersion: Int
    /// v2-Altbestand: globale Tab-Liste. Wird fuer die v3-Migration gelesen
    /// und als Kompatibilitaets-Spiegel geschrieben.
    var openTabIDs: [UUID]
    /// In der Sidebar angepinnte Chats (Reihenfolge = Pin-Reihenfolge).
    /// Gepinnte Sessions erscheinen exklusiv in der Gepinnt-Sektion,
    /// nicht mehr in ihrer Projektgruppe.
    var pinnedSessionIDs: [UUID]
    /// Global selektierter Tab.
    var selectedSessionID: UUID?
    /// Kontext-Projekt (Ziel für „Neuer Chat", Inspector). Folgt der
    /// Session-Selektion, bestimmt aber keine Tab-Sichtbarkeit mehr.
    var selectedProjectID: UUID?
    /// Welche Sidebar-Projekte sind aktuell auf-geklappt (Disclosure).
    var expandedProjectIDs: [UUID]
    /// Subagent-Jobs mit ungelesenem Ergebnis (running→done/failed, noch
    /// nicht geöffnet). Global — gelesen ist gelesen, egal in welchem
    /// Fenster. `decodeIfPresent` mit Default `[]`, KEIN schemaVersion-Bump:
    /// ältere Builds ignorieren das Feld einfach.
    var unreadSubagentSessionIDs: [UUID]
    /// Persistierte Agent-Chat-Fenster mit eigener Tab-Reihenfolge.
    var windows: [AgentChatWindowState]
    /// Primaerfenster fuer Dock-/Menubar-Reopen und alte Single-Window-Flows.
    var primaryWindowID: UUID

    /// v1-Altbestand — wird nur noch dekodiert (Input für die Migration),
    /// nie mehr encodiert. Nach `migrateToV2IfNeeded` immer leer.
    var legacyOpenTabIDsByProject: [UUID: [UUID]]
    var legacySelectedSessionIDByProject: [UUID: UUID]

    /// Persistenz-Cap der globalen Tab-Liste. Greift nur in `prune` /
    /// bei der Migration — zur Laufzeit darf die Bar mehr Tabs zeigen
    /// (sie scrollt), beim nächsten Load wird gekappt.
    static let maxOpenTabs = 12
    static let currentSchemaVersion = 3

    static let empty = AgentUIState()

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case openTabIDs
        case pinnedSessionIDs
        case selectedSessionID
        case selectedProjectID
        case expandedProjectIDs
        case unreadSubagentSessionIDs
        case windows
        case primaryWindowID
        // v1-Keys, nur fürs Decoding
        case openTabIDsByProject
        case selectedSessionIDByProject
    }

    init(
        schemaVersion: Int = AgentUIState.currentSchemaVersion,
        openTabIDs: [UUID] = [],
        pinnedSessionIDs: [UUID] = [],
        selectedSessionID: UUID? = nil,
        selectedProjectID: UUID? = nil,
        expandedProjectIDs: [UUID] = [],
        unreadSubagentSessionIDs: [UUID] = [],
        windows: [AgentChatWindowState] = [],
        primaryWindowID: UUID? = nil,
        legacyOpenTabIDsByProject: [UUID: [UUID]] = [:],
        legacySelectedSessionIDByProject: [UUID: UUID] = [:]
    ) {
        let resolvedPrimaryWindowID = primaryWindowID ?? windows.first(where: \.isPrimary)?.id ?? UUID()
        self.schemaVersion = schemaVersion
        self.openTabIDs = openTabIDs
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedSessionID = selectedSessionID
        self.selectedProjectID = selectedProjectID
        self.expandedProjectIDs = expandedProjectIDs
        self.unreadSubagentSessionIDs = unreadSubagentSessionIDs
        self.primaryWindowID = resolvedPrimaryWindowID
        if windows.isEmpty {
            self.windows = [
                AgentChatWindowState(
                    id: resolvedPrimaryWindowID,
                    openTabIDs: openTabIDs,
                    selectedSessionID: selectedSessionID,
                    selectedProjectID: selectedProjectID,
                    isPrimary: true
                )
            ]
        } else {
            self.windows = Self.normalizedWindows(windows, primaryWindowID: resolvedPrimaryWindowID)
        }
        self.legacyOpenTabIDsByProject = legacyOpenTabIDsByProject
        self.legacySelectedSessionIDByProject = legacySelectedSessionIDByProject
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        openTabIDs = try c.decodeIfPresent([UUID].self, forKey: .openTabIDs) ?? []
        pinnedSessionIDs = try c.decodeIfPresent([UUID].self, forKey: .pinnedSessionIDs) ?? []
        selectedSessionID = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        expandedProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .expandedProjectIDs) ?? []
        unreadSubagentSessionIDs = try c.decodeIfPresent([UUID].self, forKey: .unreadSubagentSessionIDs) ?? []
        windows = try c.decodeIfPresent([AgentChatWindowState].self, forKey: .windows) ?? []
        primaryWindowID = try c.decodeIfPresent(UUID.self, forKey: .primaryWindowID)
            ?? windows.first(where: \.isPrimary)?.id
            ?? UUID()
        legacyOpenTabIDsByProject = try c.decodeIfPresent([UUID: [UUID]].self, forKey: .openTabIDsByProject) ?? [:]
        legacySelectedSessionIDByProject = try c.decodeIfPresent([UUID: UUID].self, forKey: .selectedSessionIDByProject) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(openTabIDs, forKey: .openTabIDs)
        try c.encode(pinnedSessionIDs, forKey: .pinnedSessionIDs)
        try c.encodeIfPresent(selectedSessionID, forKey: .selectedSessionID)
        try c.encodeIfPresent(selectedProjectID, forKey: .selectedProjectID)
        try c.encode(expandedProjectIDs, forKey: .expandedProjectIDs)
        try c.encode(unreadSubagentSessionIDs, forKey: .unreadSubagentSessionIDs)
        try c.encode(windows, forKey: .windows)
        try c.encode(primaryWindowID, forKey: .primaryWindowID)
        // v1-Felder werden bewusst nicht mehr geschrieben.
    }

    /// v1 → v2: flacht die Pro-Projekt-Tab-Maps in die globale, geordnete
    /// Tab-Liste. Projekt-Reihenfolge = Sidebar-Reihenfolge
    /// (`AgentSessionStore.sortedProjects`), innerhalb eines Projekts
    /// bleibt die v1-Tab-Reihenfolge erhalten. Die Session-Selektion wird
    /// aus der Pro-Projekt-Erinnerung des selektierten Projekts übernommen.
    mutating func migrateToV2IfNeeded(workspace: AgentWorkspace) {
        guard schemaVersion < Self.currentSchemaVersion else {
            windows = Self.normalizedWindows(windows, primaryWindowID: primaryWindowID)
            syncLegacyWindowMirror()
            legacyOpenTabIDsByProject = [:]
            legacySelectedSessionIDByProject = [:]
            return
        }

        if schemaVersion < 2 {
            var flattened: [UUID] = []
            let knownProjectIDs = Set(workspace.projects.map(\.id))
            for project in AgentSessionStore.sortedProjects(workspace.projects) {
                flattened.append(contentsOf: legacyOpenTabIDsByProject[project.id] ?? [])
            }
            // Tabs von Projekten, die der Workspace nicht (mehr) kennt,
            // deterministisch hinten anhängen — prune() räumt tote IDs weg.
            for (projectID, ids) in legacyOpenTabIDsByProject
                .sorted(by: { $0.key.uuidString < $1.key.uuidString })
                where !knownProjectIDs.contains(projectID) {
                flattened.append(contentsOf: ids)
            }
            openTabIDs = Self.deduplicated(flattened)

            if selectedSessionID == nil {
                if let pid = selectedProjectID, let sid = legacySelectedSessionIDByProject[pid] {
                    selectedSessionID = sid
                } else {
                    selectedSessionID = openTabIDs.first
                }
            }
        }

        if schemaVersion < 3 || windows.isEmpty {
            primaryWindowID = windows.first(where: \.isPrimary)?.id ?? primaryWindowID
            windows = [
                AgentChatWindowState(
                    id: primaryWindowID,
                    openTabIDs: openTabIDs,
                    selectedSessionID: selectedSessionID,
                    selectedProjectID: selectedProjectID,
                    isPrimary: true
                )
            ]
        }
        windows = Self.normalizedWindows(windows, primaryWindowID: primaryWindowID)
        syncLegacyWindowMirror()
        schemaVersion = Self.currentSchemaVersion
        legacyOpenTabIDsByProject = [:]
        legacySelectedSessionIDByProject = [:]
    }

    /// Garbage-Collection: entfernt Eintraege fuer Projekte / Sessions, die
    /// nicht mehr im uebergebenen Workspace existieren. Wichtig damit
    /// stale UUIDs (z. B. nach manuellem Workspace-Delete) keine Geister-
    /// Tabs in der UI hinterlassen. Kappt außerdem die globale Tab-Liste
    /// auf `maxOpenTabs` (selektierter Tab überlebt die Kappung).
    /// `capTabs: false` fuer den Laufzeit-Aufruf (AgentWindowStore.prune) —
    /// zur Laufzeit darf die Bar mehr Tabs zeigen (sie scrollt), gekappt
    /// wird nur beim Load.
    mutating func prune(workspace: AgentWorkspace, capTabs: Bool = true) {
        let liveProjectIDs = Set(workspace.projects.map(\.id))
        let liveSessionIDs = Set(workspace.sessions.map(\.id))

        let cleanedGlobal = Self.deduplicated(openTabIDs.filter { liveSessionIDs.contains($0) })
        openTabIDs = capTabs
            ? Self.cappedOpenTabIDs(cleanedGlobal, selectedID: selectedSessionID)
            : cleanedGlobal
        windows = Self.normalizedWindows(windows, primaryWindowID: primaryWindowID).map { window in
            var copy = window
            let cleaned = Self.deduplicated(copy.openTabIDs.filter { liveSessionIDs.contains($0) })
            copy.openTabIDs = capTabs
                ? Self.cappedOpenTabIDs(cleaned, selectedID: copy.selectedSessionID)
                : cleaned
            if let sid = copy.selectedSessionID, !liveSessionIDs.contains(sid) {
                copy.selectedSessionID = copy.openTabIDs.first
            }
            if let pid = copy.selectedProjectID, !liveProjectIDs.contains(pid) {
                copy.selectedProjectID = nil
            }
            return copy
        }.filter { $0.isPrimary || !$0.openTabIDs.isEmpty }
        if windows.first(where: { $0.id == primaryWindowID }) == nil {
            windows.insert(
                AgentChatWindowState(
                    id: primaryWindowID,
                    openTabIDs: openTabIDs,
                    selectedSessionID: selectedSessionID,
                    selectedProjectID: selectedProjectID,
                    isPrimary: true
                ),
                at: 0
            )
        }
        windows = Self.normalizedWindows(windows, primaryWindowID: primaryWindowID)
        pinnedSessionIDs = Self.deduplicated(
            pinnedSessionIDs.filter { liveSessionIDs.contains($0) }
        )
        unreadSubagentSessionIDs = Self.deduplicated(
            unreadSubagentSessionIDs.filter { liveSessionIDs.contains($0) }
        )

        if let sid = selectedSessionID, !liveSessionIDs.contains(sid) {
            selectedSessionID = nil
        }
        if let pid = selectedProjectID, !liveProjectIDs.contains(pid) {
            selectedProjectID = nil
        }
        expandedProjectIDs = expandedProjectIDs.filter { liveProjectIDs.contains($0) }
        syncLegacyWindowMirror()
    }

    /// First-Load-Migration: wenn der Sidecar fehlt und wir aus einem
    /// existierenden Workspace kommen, mit den neuesten manuell-erstellten
    /// nicht-archivierten Sessions pre-populieren (bis zu 3 pro Projekt,
    /// global gekappt) — damit die Tab-Bar nach Deployment des Features
    /// nicht ploetzlich leer ist.
    static func initialMigration(from workspace: AgentWorkspace) -> AgentUIState {
        var state = AgentUIState.empty
        for project in AgentSessionStore.sortedProjects(workspace.projects) {
            let sessions = workspace.sessions
                .filter { $0.projectID == project.id
                    && $0.isManuallyCreated
                    && $0.status != .archived
                }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            state.openTabIDs.append(contentsOf: sessions.prefix(3).map(\.id))
        }
        state.openTabIDs = Array(state.openTabIDs.prefix(maxOpenTabs))
        state.windows = [
            AgentChatWindowState(
                id: state.primaryWindowID,
                openTabIDs: state.openTabIDs,
                selectedSessionID: state.openTabIDs.first,
                selectedProjectID: nil,
                isPrimary: true
            )
        ]
        state.selectedSessionID = state.openTabIDs.first
        return state
    }

    func windowState(for id: UUID) -> AgentChatWindowState {
        windows.first { $0.id == id }
            ?? AgentChatWindowState(id: id, isPrimary: id == primaryWindowID)
    }

    mutating func upsertWindow(_ window: AgentChatWindowState) {
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            windows[index] = window
        } else {
            windows.append(window)
        }
        windows = Self.normalizedWindows(windows, primaryWindowID: primaryWindowID)
        syncLegacyWindowMirror()
    }

    mutating func removeWindowIfEmpty(_ id: UUID) {
        guard id != primaryWindowID,
              let window = windows.first(where: { $0.id == id }),
              window.openTabIDs.isEmpty else { return }
        windows.removeAll { $0.id == id }
    }

    /// Entfernt ein Sekundaerfenster MITSAMT seiner Tabs — Chrome-Semantik
    /// fuer „User schliesst das Fenster". Die Sessions bleiben im Workspace
    /// (Sidebar) erhalten. Das Primaerfenster ist geschuetzt: dessen Tabs
    /// muessen den Dock-Reopen ueberleben.
    mutating func removeWindow(_ id: UUID) {
        guard id != primaryWindowID else { return }
        windows.removeAll { $0.id == id }
    }

    mutating func moveTabToNewWindow(sessionID: UUID, sourceWindowID: UUID, newWindowID: UUID) {
        moveTab(sessionID: sessionID, from: sourceWindowID, to: newWindowID, before: nil)
    }

    mutating func moveTab(sessionID: UUID, from sourceWindowID: UUID, to targetWindowID: UUID, before targetID: UUID?) {
        for index in windows.indices {
            windows[index].openTabIDs.removeAll { $0 == sessionID }
            if windows[index].selectedSessionID == sessionID {
                windows[index].selectedSessionID = windows[index].openTabIDs.first
            }
        }
        var target = windowState(for: targetWindowID)
        target.openTabIDs.removeAll { $0 == sessionID }
        let insertAt = targetID.flatMap { target.openTabIDs.firstIndex(of: $0) } ?? target.openTabIDs.endIndex
        target.openTabIDs.insert(sessionID, at: insertAt)
        target.selectedSessionID = sessionID
        upsertWindow(target)
        removeWindowIfEmpty(sourceWindowID)
        syncLegacyWindowMirror()
    }

    /// Reihenfolge-erhaltendes Dedupe — doppelte Tab-IDs würden die
    /// SwiftUI-ForEach-Identity brechen.
    private static func deduplicated(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func cappedOpenTabIDs(_ ids: [UUID], selectedID: UUID?) -> [UUID] {
        guard ids.count > maxOpenTabs else { return ids }
        var capped = Array(ids.prefix(maxOpenTabs))
        if let selectedID, ids.contains(selectedID), !capped.contains(selectedID) {
            capped[maxOpenTabs - 1] = selectedID
        }
        return capped
    }

    private mutating func syncLegacyWindowMirror() {
        let primary = windowState(for: primaryWindowID)
        openTabIDs = primary.openTabIDs
        selectedSessionID = primary.selectedSessionID
        selectedProjectID = primary.selectedProjectID
    }

    private static func normalizedWindows(
        _ windows: [AgentChatWindowState],
        primaryWindowID: UUID
    ) -> [AgentChatWindowState] {
        // 1. Doppelte Fenster-IDs entfernen, Primaerfenster garantieren.
        var seenWindowIDs = Set<UUID>()
        var normalized = windows.filter { seenWindowIDs.insert($0.id).inserted }
        if normalized.first(where: { $0.id == primaryWindowID }) == nil {
            normalized.insert(AgentChatWindowState(id: primaryWindowID, isPrimary: true), at: 0)
        }
        // 2. Primaerfenster zuerst — diese Reihenfolge bestimmt die
        //    Dedup-Prioritaet in Schritt 3.
        normalized.sort { lhs, rhs in
            if lhs.id == primaryWindowID { return true }
            if rhs.id == primaryWindowID { return false }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // 3. isPrimary setzen, Tabs INNERHALB jedes Fensters deduplizieren und
        //    dann GLOBAL: jede Session lebt in genau EINEM Fenster (das in der
        //    Reihenfolge fruehere gewinnt → Primaer hat Vorrang). Verhindert,
        //    dass derselbe Chat gleichzeitig in zwei Fenstern auftaucht.
        var claimedTabs = Set<UUID>()
        for index in normalized.indices {
            normalized[index].isPrimary = normalized[index].id == primaryWindowID
            normalized[index].openTabIDs = deduplicated(normalized[index].openTabIDs)
                .filter { claimedTabs.insert($0).inserted }
            if let selected = normalized[index].selectedSessionID,
               !normalized[index].openTabIDs.contains(selected) {
                normalized[index].selectedSessionID = normalized[index].openTabIDs.first
            }
        }
        return normalized
    }
}
