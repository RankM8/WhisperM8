import Foundation

/// Persistenter UI-State des Agent-Chats-Fensters — offene Tabs, gepinnte
/// Chats, Selektion und aufgeklappte Sidebar-Projekte.
///
/// Wird als JSON-Sidecar-Datei `agent-ui-state.json` neben dem Workspace
/// in Application Support gespeichert. Bewusst NICHT in UserDefaults:
/// - Reihenfolge der Tabs (Array statt Set) bleibt erhalten
/// - Future-Proof: bei einem Workspace-Export wandert der UI-State mit
///
/// Schema v2 (Layout-Redesign Juni 2026): Tabs sind GLOBAL über alle
/// Projekte — ein geordnetes Array statt der v1-Pro-Projekt-Maps. Dazu
/// `pinnedSessionIDs` für die „Gepinnt"-Sektion der Sidebar. v1-Dateien
/// werden in `migrateToV2IfNeeded(workspace:)` verlustfrei geflattet.
struct AgentUIState: Codable, Equatable {
    var schemaVersion: Int
    /// Offene Tabs in Anzeige-Reihenfolge der globalen Tab-Bar —
    /// projektübergreifend, die View entscheidet nichts mehr um.
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

    /// v1-Altbestand — wird nur noch dekodiert (Input für die Migration),
    /// nie mehr encodiert. Nach `migrateToV2IfNeeded` immer leer.
    var legacyOpenTabIDsByProject: [UUID: [UUID]]
    var legacySelectedSessionIDByProject: [UUID: UUID]

    /// Persistenz-Cap der globalen Tab-Liste. Greift nur in `prune` /
    /// bei der Migration — zur Laufzeit darf die Bar mehr Tabs zeigen
    /// (sie scrollt), beim nächsten Load wird gekappt.
    static let maxOpenTabs = 12
    static let currentSchemaVersion = 2

    static let empty = AgentUIState()

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case openTabIDs
        case pinnedSessionIDs
        case selectedSessionID
        case selectedProjectID
        case expandedProjectIDs
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
        legacyOpenTabIDsByProject: [UUID: [UUID]] = [:],
        legacySelectedSessionIDByProject: [UUID: UUID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.openTabIDs = openTabIDs
        self.pinnedSessionIDs = pinnedSessionIDs
        self.selectedSessionID = selectedSessionID
        self.selectedProjectID = selectedProjectID
        self.expandedProjectIDs = expandedProjectIDs
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
        // v1-Felder werden bewusst nicht mehr geschrieben.
    }

    /// v1 → v2: flacht die Pro-Projekt-Tab-Maps in die globale, geordnete
    /// Tab-Liste. Projekt-Reihenfolge = Sidebar-Reihenfolge
    /// (`AgentSessionStore.sortedProjects`), innerhalb eines Projekts
    /// bleibt die v1-Tab-Reihenfolge erhalten. Die Session-Selektion wird
    /// aus der Pro-Projekt-Erinnerung des selektierten Projekts übernommen.
    mutating func migrateToV2IfNeeded(workspace: AgentWorkspace) {
        guard schemaVersion < Self.currentSchemaVersion else {
            legacyOpenTabIDsByProject = [:]
            legacySelectedSessionIDByProject = [:]
            return
        }

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

        schemaVersion = Self.currentSchemaVersion
        legacyOpenTabIDsByProject = [:]
        legacySelectedSessionIDByProject = [:]
    }

    /// Garbage-Collection: entfernt Eintraege fuer Projekte / Sessions, die
    /// nicht mehr im uebergebenen Workspace existieren. Wichtig damit
    /// stale UUIDs (z. B. nach manuellem Workspace-Delete) keine Geister-
    /// Tabs in der UI hinterlassen. Kappt außerdem die globale Tab-Liste
    /// auf `maxOpenTabs` (selektierter Tab überlebt die Kappung).
    mutating func prune(workspace: AgentWorkspace) {
        let liveProjectIDs = Set(workspace.projects.map(\.id))
        let liveSessionIDs = Set(workspace.sessions.map(\.id))

        openTabIDs = Self.cappedOpenTabIDs(
            Self.deduplicated(openTabIDs.filter { liveSessionIDs.contains($0) }),
            selectedID: selectedSessionID
        )
        pinnedSessionIDs = Self.deduplicated(
            pinnedSessionIDs.filter { liveSessionIDs.contains($0) }
        )

        if let sid = selectedSessionID, !liveSessionIDs.contains(sid) {
            selectedSessionID = nil
        }
        if let pid = selectedProjectID, !liveProjectIDs.contains(pid) {
            selectedProjectID = nil
        }
        expandedProjectIDs = expandedProjectIDs.filter { liveProjectIDs.contains($0) }
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
        return state
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
}
