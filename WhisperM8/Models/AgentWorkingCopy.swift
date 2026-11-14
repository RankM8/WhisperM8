import Foundation

/// Wo ein Chat zuletzt gearbeitet hat: im Hauptordner seines Projekts, in
/// einer eigenen Arbeitskopie (Git-Worktree) oder in einem anderen Ordner —
/// samt Branch. Abgeleitet aus dem Ende des Verlaufs (Claude: `cwd` je Zeile,
/// Codex: `cwd` im `turn_context`), nicht aus dem Startordner: Ein Chat, der
/// im Hauptordner startet und dann in eine Arbeitskopie wechselt, zeigt die
/// Arbeitskopie.
struct AgentWorkingCopy: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case mainFolder
        case worktree
        case otherFolder
    }

    var kind: Kind
    /// Wurzel des Orts (Projektordner, Wurzel der Arbeitskopie bzw. des
    /// Repos), nicht der rohe `cwd`: Ein Sprung in einen Unterordner ändert
    /// den Ort nicht und schreibt deshalb nichts.
    var path: String
    /// Name der Arbeitskopie bzw. des anderen Ordners; `nil` im Hauptordner.
    var name: String?
    /// `nil`, wenn unbekannt (kein Git, losgelöster HEAD).
    var branch: String?
    /// Standard-Branch des Repos (`origin/HEAD`), `nil` wenn unbekannt.
    var defaultBranch: String? = nil

    /// Steht der Ort auf dem Standard-Branch? Ohne bekannten Standard
    /// gelten `main` und `master` als Standard. Ohne Branch: ja (nichts
    /// Auffälliges zu zeigen).
    var isOnDefaultBranch: Bool {
        guard let branch else { return true }
        if let defaultBranch { return branch == defaultBranch }
        return branch == "main" || branch == "master"
    }

    /// Nennt der Name der Arbeitskopie den Branch schon (oder umgekehrt)?
    /// Dann zeigt die Marke beides nur einmal.
    var nameRepeatsBranch: Bool {
        guard let name, let branch else { return false }
        let flat = branch.replacingOccurrences(of: "/", with: "-")
        return name == branch || name == flat || name.contains(flat) || (name.count >= 4 && flat.hasSuffix(name))
    }
}

enum AgentWorkingCopyClassifier {
    /// Ordner, in dem Claude Code seine Arbeitskopien anlegt.
    static let claudeWorktreeMarker = "/.claude/worktrees/"

    /// Pur: ordnet `cwd` dem Projekt zu.
    /// - Parameter git: Repo-Wurzel, Git-Verzeichnis und Branch des `cwd`
    ///   (`GitHeadReader`), `nil` ohne Repo oder bei gelöschtem Ordner.
    /// - Parameter transcriptBranch: Branch laut Verlauf. Nur Rückfall, wenn
    ///   kein Repo lesbar ist: Claude schreibt nach einem Ordnerwechsel noch
    ///   minutenlang den alten Branch (Review WM8-60).
    static func classify(
        cwd: String,
        projectPath: String,
        git: GitLocation?,
        transcriptBranch: String? = nil
    ) -> AgentWorkingCopy {
        let cwd = normalized(cwd)
        let project = normalized(projectPath)
        let rawBranch = git != nil ? git?.branch : transcriptBranch
        let branch = rawBranch.flatMap(displayName).flatMap { $0 == "HEAD" ? nil : $0 }
        let worktreesOfProject = project + claudeWorktreeMarker
        // 1. Arbeitskopie von Claude Code unter <Projekt>/.claude/worktrees/<name>.
        if cwd.hasPrefix(worktreesOfProject),
           let name = cwd.dropFirst(worktreesOfProject.count).split(separator: "/").first.map(String.init),
           !name.isEmpty {
            return AgentWorkingCopy(kind: .worktree, path: worktreesOfProject + name, name: displayName(name),
                                    branch: branch, defaultBranch: git?.defaultBranch.flatMap(displayName))
        }
        // 2. Andere Arbeitskopie desselben Repos (etwa ein Ordner neben dem
        //    Projekt): ihr Git-Verzeichnis liegt unter <Projekt>/.git/worktrees/.
        if let git, normalized(git.gitDir).hasPrefix(project + "/.git/worktrees/") {
            let root = normalized(git.root)
            return AgentWorkingCopy(kind: .worktree, path: root,
                                    name: displayName((root as NSString).lastPathComponent), branch: branch,
                                    defaultBranch: git.defaultBranch.flatMap(displayName))
        }
        // 3. Hauptordner samt Unterordnern — auch erkannt am Git-Verzeichnis
        //    des Projekts, falls ein Pfad trotz Auflösung abweicht.
        let isProjectRepo = git.map { normalized($0.gitDir) == project + "/.git" } ?? false
        if cwd == project || cwd.hasPrefix(project + "/") || isProjectRepo {
            return AgentWorkingCopy(kind: .mainFolder, path: project, name: nil, branch: branch,
                                    defaultBranch: git?.defaultBranch.flatMap(displayName))
        }
        // 4. Alles andere, auch Arbeitskopien fremder Projekte.
        let root = git.map { normalized($0.root) } ?? cwd
        return AgentWorkingCopy(kind: .otherFolder, path: root,
                                name: displayName((root as NSString).lastPathComponent), branch: branch,
                                defaultBranch: git?.defaultBranch.flatMap(displayName))
    }

    /// Branch- und Ordnernamen kommen aus fremden Dateien und landen im
    /// Workspace, im Kachelkopf und per CLI im Terminal: nur druckbare
    /// Zeichen, höchstens 255. Leer → `nil`.
    static func displayName(_ raw: String) -> String? {
        let printable = raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }
        let text = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(255))
    }

    /// Ohne abschließenden Schrägstrich, `/private/tmp` wie `/tmp`.
    static func normalized(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for prefix in ["/private/tmp/", "/private/var/"] where path.hasPrefix(prefix) {
            path.removeFirst("/private".count)
        }
        return path
    }
}
