import Foundation

// MARK: - Arbeitsordner neben dem Projekt (WM8-102)

/// Ein Arbeitsordner wie `~/repos/akquise-ai-kurse` (angelegt mit
/// `git worktree add` neben `~/repos/akquise-ai`) ist für die App ein eigenes
/// Projekt: Dort startet der Chat, dort liegt sein Verlauf, daran hängt die
/// Bindung. Angezeigt wird er aber unter seinem Haupt-Projekt. Dafür trägt das
/// Projekt des Arbeitsordners `parentProjectID`.
///
/// Bewusst kein Umzug der Chats ins Haupt-Projekt: Start, Fortsetzen, Bindung
/// und Verlaufssuche nutzen an vielen Stellen den Projektpfad als Ordner des
/// Chats, und der Scan hängt Chats ohnehin wieder an den Ordner ihres Verlaufs.
extension AgentSessionStore {
    /// Liest für die Pfade, ob sie Arbeitsordner eines Haupt-Repos sind. Datei-
    /// I/O (gemerkt je Pfad): vor `applyWorktreeProjectLinks` und nie unter
    /// dem Lock des Stores aufrufen.
    static func siblingMainRepos(for paths: some Sequence<String>) -> [String: String] {
        var result: [String: String] = [:]
        for path in Set(paths) {
            if let main = AgentProjectPath.siblingWorktreeMainRepo(of: path) {
                result[path] = main
            }
        }
        return result
    }

    /// Setzt `parentProjectID` nach der vorab gelesenen Zuordnung. Nur Pfade,
    /// die in `mainRepoByPath` vorkommen oder geprüft wurden (`checkedPaths`),
    /// werden geändert; andere Projekte bleiben, wie sie sind.
    func applyWorktreeProjectLinks(mainRepoByPath: [String: String], checkedPaths: Set<String>) throws {
        try mutateWorkspaceIfChanged { workspace in
            Self.applyWorktreeProjectLinks(
                to: &workspace, mainRepoByPath: mainRepoByPath, checkedPaths: checkedPaths)
        }
    }

    /// Pur und testbar. Liefert `true`, wenn sich etwas geändert hat.
    @discardableResult
    static func applyWorktreeProjectLinks(
        to workspace: inout AgentWorkspace,
        mainRepoByPath: [String: String],
        checkedPaths: Set<String>
    ) -> Bool {
        let idByPath = Dictionary(
            workspace.projects.map { ($0.path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = false
        for index in workspace.projects.indices {
            let project = workspace.projects[index]
            guard checkedPaths.contains(project.path) else { continue }
            let parent = mainRepoByPath[project.path].flatMap { idByPath[$0] }
            let link = parent == project.id ? nil : parent
            if project.parentProjectID != link {
                workspace.projects[index].parentProjectID = link
                changed = true
            }
        }
        return changed
    }

    /// Für einen einzelnen, gerade angelegten Projektordner (neuer Chat in
    /// einem Arbeitsordner). Liest höchstens zwei kleine Dateien.
    func linkWorktreeProject(path: String) throws {
        let standardized = Self.canonicalProjectPath(path)
        try applyWorktreeProjectLinks(
            mainRepoByPath: Self.siblingMainRepos(for: [standardized]),
            checkedPaths: [standardized]
        )
    }
}

/// Anzeige-Zuordnung: unter welchem Projekt ein Chat erscheint. Pur.
enum AgentProjectDisplay {
    /// Projekt → Projekt, unter dem es angezeigt wird. Nur gültige Verweise:
    /// Das Haupt-Projekt muss existieren, selbst eigenständig sein und in der
    /// Seitenleiste stehen (manuell angelegt), sonst verschwänden die Chats.
    static func parentByProjectID(projects: [AgentProject]) -> [UUID: UUID] {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: UUID] = [:]
        for project in projects {
            guard let parentID = project.parentProjectID, parentID != project.id,
                  let parent = byID[parentID],
                  parent.parentProjectID == nil,
                  parent.isManuallyAdded else { continue }
            result[project.id] = parentID
        }
        return result
    }

    static func displayProjectID(_ projectID: UUID, parents: [UUID: UUID]) -> UUID {
        parents[projectID] ?? projectID
    }
}
