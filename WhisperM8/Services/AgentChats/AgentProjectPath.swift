import Foundation

/// Pfad-Utilities fuer Agent-Projektpfade: Worktree-Stripping und -Erkennung.
///
/// Pure und zustandslos — aus `AgentSessionStore` ausgelagert. `AgentSessionStore`
/// behaelt duenne static-Forwarder, damit bestehende Aufrufstellen unveraendert
/// bleiben.
enum AgentProjectPath {
    static func canonicalProjectPath(_ path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let marker = "/.claude/worktrees/"
        guard let range = standardizedPath.range(of: marker) else {
            return standardizedPath
        }
        return String(standardizedPath[..<range.lowerBound])
    }

    static func isClaudeWorktreePath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.contains("/.claude/worktrees/")
    }

    // MARK: - Arbeitsordner neben dem Projekt (WM8-102)

    /// Haupt-Repo eines Arbeitsordners, der neben dem Projekt liegt
    /// (`git worktree add ../akquise-ai-kurse`). Pur: `git` ist das Ergebnis
    /// von `GitHeadReader.location(at: path)`.
    ///
    /// Regel (Giuliano, 15.11.2026): Ein solcher Ordner gehört nur dann zum
    /// Haupt-Repo, wenn sein Name mit dem Namen des Haupt-Repos beginnt
    /// (akquise-ai-kurse → akquise-ai, ListM8-ds190 → ListM8). Arbeitsordner
    /// mit eigenem Namen (kunden-webseiten/podomedica aus sindy-deluxe) sind
    /// eigene Projekte. Nur die Wurzel des Arbeitsordners zählt, nicht ein
    /// Unterordner darin.
    static func siblingWorktreeMainRepo(
        path: String,
        git: GitLocation?,
        directoryExists: (String) -> Bool
    ) -> String? {
        guard let git else { return nil }
        let marker = "/.git/worktrees/"
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = URL(fileURLWithPath: git.root).standardizedFileURL.path
        guard root == standardizedPath,
              let range = git.gitDir.range(of: marker) else { return nil }
        let mainRepo = URL(fileURLWithPath: String(git.gitDir[..<range.lowerBound])).standardizedFileURL.path
        guard mainRepo != root, directoryExists(mainRepo) else { return nil }
        let folderName = (root as NSString).lastPathComponent.lowercased()
        let repoName = (mainRepo as NSString).lastPathComponent.lowercased()
        guard !repoName.isEmpty, folderName.count > repoName.count, folderName.hasPrefix(repoName) else {
            return nil
        }
        return mainRepo
    }

    private static let mainRepoCache = NSCache<NSString, NSString>()
    private static let noMainRepo: NSString = ""

    /// Wie `siblingWorktreeMainRepo`, liest aber selbst (ein, zwei kleine
    /// Dateien) und merkt sich das Ergebnis je Pfad. Nie in einem View-Body
    /// oder unter dem Lock des Workspace-Stores aufrufen.
    static func siblingWorktreeMainRepo(of path: String) -> String? {
        let key = path as NSString
        if let cached = mainRepoCache.object(forKey: key) {
            return cached == noMainRepo ? nil : cached as String
        }
        let result = siblingWorktreeMainRepo(
            path: path,
            git: GitHeadReader.location(at: path),
            directoryExists: { candidate in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        )
        mainRepoCache.setObject((result ?? "") as NSString, forKey: key)
        return result
    }

    /// Projektordner, zu dem ein Verzeichnis für die Anzeige gehört: Claudes
    /// Arbeitsordner unter `.claude/worktrees/` wie bisher, dazu Arbeitsordner
    /// neben dem Projekt nach der Namensregel. Liest Dateien (gemerkt).
    static func owningProjectPath(_ path: String) -> String {
        let canonical = canonicalProjectPath(path)
        return siblingWorktreeMainRepo(of: canonical) ?? canonical
    }
}
