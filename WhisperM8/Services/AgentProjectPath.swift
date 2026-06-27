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
}
