import Foundation

/// Ermittelt den aktuellen Git-Branch eines Verzeichnisses durch direktes
/// Lesen von `.git/HEAD` — bewusst OHNE `git`-Subprozess: der Lookup läuft
/// u. a. synchron im Chat-Start-Pfad auf dem Main Thread
/// (`AgentSessionStore.upsertProject`), wo ein `Process`-Spawn samt
/// `waitUntilExit()` die UI für 20–150 ms einfriert. Der File-Read kostet
/// Mikrosekunden und ist damit auch nahe dem Store-Lock unbedenklich.
///
/// Semantik wie `git branch --show-current`:
/// - `HEAD` = `ref: refs/heads/<branch>` → Branch-Name (Slashes erlaubt)
/// - detached HEAD (nackter SHA) → `nil`
/// - kein Git-Repo / nicht lesbar → `nil`
enum GitBranchReader {
    static func currentBranch(at projectPath: String) -> String? {
        guard let gitDirectory = resolveGitDirectory(projectPath: projectPath) else { return nil }
        let headURL = gitDirectory.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        return branchName(fromHEADContents: head)
    }

    /// Purer Parser für den `HEAD`-Inhalt — separat testbar.
    static func branchName(fromHEADContents contents: String) -> String? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(refPrefix) else { return nil }
        let branch = String(trimmed.dropFirst(refPrefix.count))
        return branch.isEmpty ? nil : branch
    }

    /// Löst das Git-Dir für einen Projektpfad auf. Wie `git -C <pfad>` wird
    /// dabei in den ELTERN-Verzeichnissen weitergesucht, wenn der Pfad selbst
    /// kein `.git` trägt — Projektpfade sind oft Unterordner eines Monorepos
    /// (`/repo/packages/app` mit nur `/repo/.git`). Bei Worktrees/Submodulen
    /// ist `.git` eine DATEI mit `gitdir: <pfad>` — der Pfad (ggf. relativ
    /// zum jeweiligen Verzeichnis) zeigt auf das echte Git-Dir (z. B.
    /// `<main>/.git/worktrees/<name>`), dessen `HEAD` den Branch trägt.
    private static func resolveGitDirectory(projectPath: String) -> URL? {
        var directory = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        while true {
            if let resolved = gitDirectory(in: directory) {
                return resolved
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    private static func gitDirectory(in directory: URL) -> URL? {
        let gitURL = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return gitURL }

        guard let contents = try? String(contentsOf: gitURL, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitdirPrefix = "gitdir:"
        guard trimmed.hasPrefix(gitdirPrefix) else { return nil }
        let rawPath = String(trimmed.dropFirst(gitdirPrefix.count))
            .trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true)
        }
        return URL(fileURLWithPath: rawPath, relativeTo: directory).standardizedFileURL
    }
}
