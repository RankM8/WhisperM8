import Foundation

/// Persistenter UI-State des Agent-Chats-Fensters — welche Tabs sind offen
/// pro Projekt, welche Tab/Projekt ist aktuell selektiert, welche Sidebar-
/// Projekte sind ausgeklappt.
///
/// Wird als JSON-Sidecar-Datei `agent-ui-state.json` neben dem Workspace
/// in Application Support gespeichert. Bewusst NICHT in UserDefaults:
/// - Reihenfolge der Tabs (Array statt Set) bleibt erhalten
/// - Pro-Projekt-Sub-Selection als eine Datei statt vier UserDefaults-Keys
/// - Future-Proof: bei einem Workspace-Export wandert der UI-State mit
///
/// `schemaVersion` ist `1`. Bei spaeteren Aenderungen koennen wir per
/// `decodeIfPresent` + version-check sauber migrieren.
struct AgentUIState: Codable, Equatable {
    var schemaVersion: Int
    /// Tabs die in der Sidebar pro Projekt sichtbar sein sollen, in der
    /// Reihenfolge in der sie zuletzt sortiert wurden. Wir behalten das
    /// Insertion-Order — die Sidebar-View entscheidet ueber die finale
    /// Display-Sortierung (sortIndex, lastActivityAt, …).
    var openTabIDsByProject: [UUID: [UUID]]
    /// Pro Projekt: zuletzt selektierter Tab. Beim Projekt-Switch springt
    /// die UI auf diesen statt auf "den ersten verfuegbaren".
    var selectedSessionIDByProject: [UUID: UUID]
    /// Globaler Project-Selected-State.
    var selectedProjectID: UUID?
    /// Welche Sidebar-Projekte sind aktuell auf-geklappt (Disclosure).
    var expandedProjectIDs: [UUID]
    static let maxOpenTabsPerProject = 6

    static let empty = AgentUIState(
        schemaVersion: 1,
        openTabIDsByProject: [:],
        selectedSessionIDByProject: [:],
        selectedProjectID: nil,
        expandedProjectIDs: []
    )

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case openTabIDsByProject
        case selectedSessionIDByProject
        case selectedProjectID
        case expandedProjectIDs
    }

    init(
        schemaVersion: Int = 1,
        openTabIDsByProject: [UUID: [UUID]] = [:],
        selectedSessionIDByProject: [UUID: UUID] = [:],
        selectedProjectID: UUID? = nil,
        expandedProjectIDs: [UUID] = []
    ) {
        self.schemaVersion = schemaVersion
        self.openTabIDsByProject = openTabIDsByProject
        self.selectedSessionIDByProject = selectedSessionIDByProject
        self.selectedProjectID = selectedProjectID
        self.expandedProjectIDs = expandedProjectIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        openTabIDsByProject = try c.decodeIfPresent([UUID: [UUID]].self, forKey: .openTabIDsByProject) ?? [:]
        selectedSessionIDByProject = try c.decodeIfPresent([UUID: UUID].self, forKey: .selectedSessionIDByProject) ?? [:]
        selectedProjectID = try c.decodeIfPresent(UUID.self, forKey: .selectedProjectID)
        expandedProjectIDs = try c.decodeIfPresent([UUID].self, forKey: .expandedProjectIDs) ?? []
    }

    /// Garbage-Collection: entfernt Eintraege fuer Projekte / Sessions, die
    /// nicht mehr im uebergebenen Workspace existieren. Wichtig damit
    /// stale UUIDs (z. B. nach manuellem Workspace-Delete) keine Geister-
    /// Tabs in der UI hinterlassen.
    mutating func prune(workspace: AgentWorkspace) {
        let liveProjectIDs = Set(workspace.projects.map(\.id))
        let liveSessionIDs = Set(workspace.sessions.map(\.id))

        // Projekt-Map einschraenken
        openTabIDsByProject = openTabIDsByProject.filter { liveProjectIDs.contains($0.key) }
        selectedSessionIDByProject = selectedSessionIDByProject.filter { liveProjectIDs.contains($0.key) }

        // Pro Projekt: nur lebende Session-IDs behalten, Reihenfolge erhalten
        for (projectID, ids) in openTabIDsByProject {
            let liveIDs = ids.filter { liveSessionIDs.contains($0) }
            openTabIDsByProject[projectID] = Self.cappedOpenTabIDs(
                liveIDs,
                selectedID: selectedSessionIDByProject[projectID]
            )
        }

        // Selected Session: nur wenn sie noch existiert
        for (projectID, sessionID) in selectedSessionIDByProject {
            if !liveSessionIDs.contains(sessionID) {
                selectedSessionIDByProject.removeValue(forKey: projectID)
            }
        }

        // Project-Level Selection
        if let pid = selectedProjectID, !liveProjectIDs.contains(pid) {
            selectedProjectID = nil
        }

        // Expanded-Set einschraenken
        expandedProjectIDs = expandedProjectIDs.filter { liveProjectIDs.contains($0) }
    }

    /// First-Load-Migration: wenn der Sidecar fehlt und wir aus einem
    /// existierenden Workspace kommen, mit allen manuell-erstellten
    /// nicht-archivierten Sessions pre-populieren — damit die Sidebar
    /// nach Deployment des Features nicht ploetzlich leer ist.
    static func initialMigration(from workspace: AgentWorkspace) -> AgentUIState {
        var state = AgentUIState.empty
        for project in workspace.projects {
            let sessions = workspace.sessions
                .filter { $0.projectID == project.id
                    && $0.isManuallyCreated
                    && $0.status != .archived
                }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            guard !sessions.isEmpty else { continue }
            state.openTabIDsByProject[project.id] = Array(sessions.prefix(Self.maxOpenTabsPerProject).map(\.id))
        }
        return state
    }

    private static func cappedOpenTabIDs(_ ids: [UUID], selectedID: UUID?) -> [UUID] {
        guard ids.count > maxOpenTabsPerProject else { return ids }
        var capped = Array(ids.prefix(maxOpenTabsPerProject))
        if let selectedID, ids.contains(selectedID), !capped.contains(selectedID) {
            capped[maxOpenTabsPerProject - 1] = selectedID
        }
        return capped
    }
}
