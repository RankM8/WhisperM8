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

/// Branch eines Ordners aus `.git/HEAD`, ohne `git`-Subprozess. Folgt bei
/// Arbeitskopien der `gitdir:`-Datei. Zwei bis drei kleine Lesezugriffe.
enum GitHeadReader {
    static func branch(at directory: String, fileManager: FileManager = .default) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for _ in 0..<40 {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir: URL
                if isDirectory.boolValue {
                    gitDir = dotGit
                } else {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                        : url.appendingPathComponent(path).standardizedFileURL
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                return branch(fromHead: head)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
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
