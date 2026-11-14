import Foundation

/// Ordner und Branch aus dem Verlaufsende (WM8-60). Läuft im Tail-Read des
/// `AgentSessionRuntimeWatcher` abseits des Main Threads.
struct AgentWorkingLocation: Equatable {
    var cwd: String
    var branch: String?
}

enum AgentWorkingLocationExtractor {
    /// Pur: die letzte Zeile, die einen Ordner nennt. Claude schreibt `cwd`
    /// und `gitBranch` in jede Nachrichtenzeile; Codex `cwd` je Turn im
    /// `turn_context` (Branch nur in `session_meta.git` am Dateianfang).
    static func location(in tail: String, provider: AgentProvider) -> AgentWorkingLocation? {
        let lines = tail.split(omittingEmptySubsequences: true) { $0.isNewline }
        for line in lines.reversed() where line.contains("\"cwd\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch provider {
            case .claude:
                guard let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
                return AgentWorkingLocation(cwd: cwd, branch: object["gitBranch"] as? String)
            case .codex:
                guard let type = object["type"] as? String,
                      type == "turn_context" || type == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      let cwd = payload["cwd"] as? String, !cwd.isEmpty else { continue }
                let git = payload["git"] as? [String: Any]
                return AgentWorkingLocation(cwd: cwd, branch: git?["branch"] as? String)
            }
        }
        return nil
    }
}

/// Repo-Wurzel, Git-Verzeichnis und Branch eines Ordners.
struct GitLocation: Equatable {
    /// Ordner, in dem `.git` liegt.
    var root: String
    /// Das echte Git-Verzeichnis (bei Arbeitskopien das Ziel von `gitdir:`).
    var gitDir: String
    /// `nil` bei losgelöstem HEAD.
    var branch: String?
    /// Standard-Branch des Repos (`origin/HEAD`), `nil` wenn unbekannt.
    var defaultBranch: String? = nil
}

/// Liest `.git/HEAD`, ohne `git`-Subprozess. Folgt bei Arbeitskopien der
/// `gitdir:`-Datei. Wenige `stat` und ein, zwei kleine Lesezugriffe.
enum GitHeadReader {
    static func location(at directory: String, fileManager: FileManager = .default) -> GitLocation? {
        // Gelöschter Ordner (Arbeitskopie entfernt): nicht nach oben bis zum
        // Repo des Hauptordners laufen, sonst stünde dessen Branch da.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for _ in 0..<40 {
            let dotGit = url.appendingPathComponent(".git")
            var dotGitIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &dotGitIsDirectory) {
                let gitDir: URL
                if dotGitIsDirectory.boolValue {
                    gitDir = dotGit
                } else {
                    guard let text = readSmallFile(dotGit),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = (path.hasPrefix("/") ? URL(fileURLWithPath: path)
                        : url.appendingPathComponent(path)).standardizedFileURL
                }
                let head = readSmallFile(gitDir.appendingPathComponent("HEAD"))
                return GitLocation(root: url.path, gitDir: gitDir.path, branch: head.flatMap(branch(fromHead:)),
                                   defaultBranch: defaultBranch(gitDir: gitDir))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    /// Standard-Branch aus `refs/remotes/origin/HEAD` im gemeinsamen
    /// Git-Verzeichnis (bei Arbeitskopien über `commondir`). Ein kleiner
    /// Lesezugriff; fehlt die Datei, `nil`.
    static func defaultBranch(gitDir: URL) -> String? {
        var common = gitDir
        if let text = readSmallFile(gitDir.appendingPathComponent("commondir")) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            common = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : gitDir.appendingPathComponent(path))
                .standardizedFileURL
        }
        guard let text = readSmallFile(common.appendingPathComponent("refs/remotes/origin/HEAD")) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/remotes/origin/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let branch = String(trimmed.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }

    /// Was in `.git` steht, bestimmt das Repo, und das kann fremd sein
    /// (geklont, entpackt). Gelesen werden deshalb nur reguläre Dateien bis
    /// `maxBytes` — eine riesige Datei oder eine Pipe an dieser Stelle darf
    /// den Poll weder aufblähen noch hängen lassen (Vic, WM8-60).
    static func readSmallFile(_ url: URL, maxBytes: Int = 4096) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pur: `ref: refs/heads/<branch>` → Branch; losgelöster HEAD → `nil`.
    static func branch(fromHead head: String) -> String? {
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let branch = String(trimmed.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }
}
