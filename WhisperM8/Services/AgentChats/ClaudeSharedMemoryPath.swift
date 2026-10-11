import Foundation

/// Gemeinsames Auto-Memory über alle Claude-Konten: berechnet den Ordner, den
/// Claude Code unter `main` (`~/.claude`) für ein Arbeitsverzeichnis als
/// Auto-Memory nimmt. WhisperM8 gibt ihn Chats von Zusatzprofilen per
/// `autoMemoryDirectory` (offizielle Einstellung, über `--settings`) mit —
/// so kennt ein Chat unter `ai2` dasselbe Projektwissen wie einer unter `main`.
///
/// Die Regel ist aus Claude Code 2.1.296 nachgebaut und im Prototyp gemessen
/// (Plan `docs/plans/claude-account-switch-ohne-stopp.md`, P2):
/// - Ausgangspunkt ist der **realpath** des Arbeitsverzeichnisses
///   (`/tmp` → `/private/tmp`). `URL.resolvingSymlinksInPath()` taugt dafür
///   nicht — es macht aus `/private/tmp` wieder `/tmp`.
/// - Im Git-Repo zählt der Repo-Root; Unterordner teilen ihn, ein Worktree den
///   des Haupt-Repos (`.git`-Datei → `gitdir` → `commondir`). Ohne Git zählt
///   das Arbeitsverzeichnis selbst.
/// - Kodierung: jede UTF-16-Einheit außer `[A-Za-z0-9]` wird `-`; länger als
///   200 Zeichen → die ersten 200 plus `-` plus Hash (Java-String-Hash, Basis 36).
///
/// Pur bis auf lesende Dateizugriffe; kein `git`-Aufruf, damit der Launch-Pfad
/// keinen Subprozess startet.
enum ClaudeSharedMemoryPath {
    static let maxEncodedLength = 200

    /// Settings-Fragment `{"autoMemoryDirectory": …}` für einen Claude-Launch —
    /// oder `nil`, wenn der Chat ohnehin das Memory von `main` nutzt:
    /// - nur Claude-Chats (Codex hat kein Auto-Memory dieser Art),
    /// - nicht für `main` selbst: dort ist der Ordner Claudes eigener Standard,
    ///   ohne Fragment bleibt `main` exakt wie bisher, auch falls diese
    ///   Berechnung einmal von Claude abweicht,
    /// - nicht für ein Profil ohne Ordner: der Launch fällt dann auf `main`
    ///   zurück (`environmentOverrides(forProfile:)`).
    static func settingsFragment(
        provider: AgentProvider,
        profileName: String?,
        workingDirectory: String,
        profiles: ClaudeAccountProfiles,
        isEnabled: Bool
    ) -> [String: Any]? {
        guard isEnabled, provider == .claude,
              let profileName, profileName != ClaudeAccountProfiles.mainProfileName,
              profiles.fileManager.fileExists(atPath: profiles.configDir(forProfile: profileName).path)
        else { return nil }
        let directory = memoryDirectory(
            forWorkingDirectory: workingDirectory,
            mainConfigDirectory: profiles.configDir(forProfile: ClaudeAccountProfiles.mainProfileName),
            fileManager: profiles.fileManager
        )
        return ["autoMemoryDirectory": directory.path]
    }

    /// `<main-config>/projects/<kodiert>/memory` für ein Arbeitsverzeichnis.
    static func memoryDirectory(
        forWorkingDirectory workingDirectory: String,
        mainConfigDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let root = projectRoot(forWorkingDirectory: workingDirectory, fileManager: fileManager)
        return mainConfigDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedProjectName(root), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// realpath + Git-Root (Worktree → Haupt-Repo), sonst das Verzeichnis selbst.
    static func projectRoot(
        forWorkingDirectory workingDirectory: String,
        fileManager: FileManager = .default
    ) -> String {
        let resolved = realPath(workingDirectory)
        guard let gitRoot = gitRoot(startingAt: resolved, fileManager: fileManager) else {
            return resolved
        }
        return mainWorktreeRoot(forRoot: gitRoot)
    }

    /// `realpath(3)`; existiert der Pfad nicht, wird er nur textuell normalisiert.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            return absolutePath(path, relativeTo: FileManager.default.currentDirectoryPath)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Nächster Ordner aufwärts, der ein `.git` (Ordner oder Datei) enthält.
    static func gitRoot(startingAt path: String, fileManager: FileManager = .default) -> String? {
        var current = path
        while true {
            if fileManager.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// Ist `<root>/.git` eine Datei mit `gitdir:` auf `<haupt>/.git/worktrees/<name>`,
    /// liefert das den Haupt-Repo-Root. Sonst (normales Repo, Submodul, kaputte
    /// Verweise) bleibt es beim übergebenen Root — wie in Claude Code, das bei
    /// jeder Unstimmigkeit ebenfalls auf den Root selbst zurückfällt.
    static func mainWorktreeRoot(forRoot root: String) -> String {
        let gitFile = (root as NSString).appendingPathComponent(".git")
        guard let content = try? String(contentsOfFile: gitFile, encoding: .utf8) else {
            return root  // `.git` ist ein Ordner → normales Repo
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return root }
        let gitDir = absolutePath(
            String(trimmed.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces),
            relativeTo: root
        )
        let commonDirFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let commonRaw = try? String(contentsOfFile: commonDirFile, encoding: .utf8) else {
            return root  // kein Worktree (z. B. Submodul)
        }
        let commonDir = absolutePath(
            commonRaw.trimmingCharacters(in: .whitespacesAndNewlines),
            relativeTo: gitDir
        )
        // Plausibilität wie in Claude Code: der Worktree-Gitdir liegt unter
        // `<common>/worktrees/`, und der gemeinsame Ordner heißt `.git`.
        guard (gitDir as NSString).deletingLastPathComponent
                == (commonDir as NSString).appendingPathComponent("worktrees"),
              (commonDir as NSString).lastPathComponent == ".git" else {
            return root
        }
        return (commonDir as NSString).deletingLastPathComponent
    }

    /// Rein textuell wie Node `path.resolve`: `.` und `..` auflösen, sonst nichts.
    /// Bewusst NICHT `standardizingPath` — das kürzt `/private/var` still zu `/var`.
    static func absolutePath(_ path: String, relativeTo base: String) -> String {
        let joined = path.hasPrefix("/") ? path : base + "/" + path
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Ordnername unter `projects/` — identisch zu Claude Codes Kodierung.
    static func encodedProjectName(_ path: String) -> String {
        let sanitized = String(path.utf16.map { unit -> Character in
            let isAlnum = (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
            return isAlnum ? Character(UnicodeScalar(UInt8(unit))) : "-"
        })
        guard sanitized.count > maxEncodedLength else { return sanitized }
        let suffix = String(Int64(claudeHash(path)).magnitude, radix: 36)
        return "\(sanitized.prefix(maxEncodedLength))-\(suffix)"
    }

    /// Java-String-Hash über UTF-16 mit Int32-Überlauf (`(h << 5) - h + c | 0`).
    static func claudeHash(_ string: String) -> Int32 {
        var hash: Int32 = 0
        for unit in string.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(unit)
        }
        return hash
    }
}
