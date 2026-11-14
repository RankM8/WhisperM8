import Foundation

/// Wo ein Chat zuletzt gearbeitet hat: im Hauptordner seines Projekts, in
/// einer eigenen Arbeitskopie (Git-Worktree unter `.claude/worktrees/<name>`)
/// oder in einem anderen Ordner — samt Branch. Abgeleitet aus dem Ende des
/// Verlaufs (Claude: `cwd` und `gitBranch` je Zeile, Codex: `cwd` im
/// `turn_context`), nicht aus dem Startordner: Ein Chat, der im Hauptordner
/// startet und dann in eine Arbeitskopie wechselt, zeigt die Arbeitskopie.
struct AgentWorkingCopy: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case mainFolder
        case worktree
        case otherFolder
    }

    var kind: Kind
    /// Der zuletzt genutzte Ordner (`cwd`).
    var path: String
    /// Name der Arbeitskopie bzw. des anderen Ordners; `nil` im Hauptordner.
    var name: String?
    /// `nil`, wenn der Verlauf keinen Branch nennt (kein Git, Codex ohne
    /// lesbares HEAD).
    var branch: String?
}

enum AgentWorkingCopyClassifier {
    /// Ordner, in dem Claude Code seine Arbeitskopien anlegt.
    static let claudeWorktreeMarker = "/.claude/worktrees/"

    /// Pur: ordnet `cwd` dem Projekt zu. Unterordner des Projekts zählen zum
    /// Hauptordner, Unterordner einer Arbeitskopie zur Arbeitskopie.
    static func classify(cwd: String, projectPath: String, branch: String?) -> AgentWorkingCopy {
        let cwd = normalized(cwd)
        let project = normalized(projectPath)
        let branch = branch.flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
        if let range = cwd.range(of: claudeWorktreeMarker) {
            let rest = cwd[range.upperBound...]
            let name = rest.split(separator: "/", maxSplits: 1).first.map(String.init)
            if let name, !name.isEmpty {
                return AgentWorkingCopy(kind: .worktree, path: cwd, name: name, branch: branch)
            }
        }
        if cwd == project || cwd.hasPrefix(project + "/") {
            return AgentWorkingCopy(kind: .mainFolder, path: cwd, name: nil, branch: branch)
        }
        return AgentWorkingCopy(kind: .otherFolder, path: cwd,
                                name: (cwd as NSString).lastPathComponent, branch: branch)
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
