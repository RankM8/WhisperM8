import Foundation

/// Eine geänderte Datei aus `git status --porcelain=v2 -z`, zugeordnet zu
/// Staged bzw. Unstaged (eine Datei kann in beiden Bereichen auftauchen,
/// z. B. teilweise gestaged).
struct GitChangeEntry: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case modified
        case added
        case deleted
        case renamed
        case untracked
        case conflicted
    }

    enum Area: Equatable, Hashable {
        case staged
        case unstaged
    }

    /// Repo-relativer Pfad (bei Renames: der NEUE Pfad).
    var path: String
    var kind: Kind
    var area: Area
}

/// Momentaufnahme der Working-Tree-Änderungen eines Projekts für das
/// Changes-Panel. Ein einziger Git-Spawn pro Refresh; `--no-optional-locks`
/// ist Pflicht, sonst schriebe `git status` den Index-Refresh zurück und
/// triggerte den FSEvents-Watcher des Panels — eine Endlos-Schleife.
struct GitChangesSnapshot: Equatable {
    var branch: String?
    var entries: [GitChangeEntry]
    /// true, wenn die Liste beim Cap abgeschnitten wurde (Riesen-Status,
    /// z. B. vergessenes node_modules) — die UI weist darauf hin.
    var truncated: Bool
    var isGitRepository: Bool

    static let entryCap = 500

    var stagedEntries: [GitChangeEntry] { entries.filter { $0.area == .staged } }
    var unstagedEntries: [GitChangeEntry] { entries.filter { $0.area == .unstaged } }

    /// Parst die NUL-terminierte porcelain-v2-Ausgabe (mit `--branch`-Header).
    /// Rename-Einträge (`2 …`) tragen ZWEI NUL-Felder (neuer Pfad, alter
    /// Pfad) — der Iterator konsumiert das zweite Feld mit.
    static func parse(porcelainV2 output: String) -> (branch: String?, entries: [GitChangeEntry], truncated: Bool) {
        var branch: String?
        var entries: [GitChangeEntry] = []
        var truncated = false

        let fields = output.split(separator: "\u{0}", omittingEmptySubsequences: true)
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1

            if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst("# branch.head ".count))
                branch = value == "(detached)" ? "detached" : value
                continue
            }
            guard !record.hasPrefix("#") else { continue }

            if entries.count >= entryCap * 2 {
                truncated = true
                break
            }

            if record.hasPrefix("? ") {
                entries.append(GitChangeEntry(
                    path: String(record.dropFirst(2)),
                    kind: .untracked,
                    area: .unstaged
                ))
                continue
            }
            if record.hasPrefix("u ") {
                // Konflikt: Pfad ist das letzte Feld des Records.
                if let path = conflictPath(record) {
                    entries.append(GitChangeEntry(path: path, kind: .conflicted, area: .unstaged))
                }
                continue
            }
            guard record.hasPrefix("1 ") || record.hasPrefix("2 ") else { continue }

            let isRename = record.hasPrefix("2 ")
            // `1 XY sub mH mI mW hH hI path` / `2 XY sub mH mI mW hH hI Xscore path`
            let parts = record.split(separator: " ", maxSplits: isRename ? 9 : 8, omittingEmptySubsequences: false)
            guard parts.count >= (isRename ? 10 : 9), parts[1].count == 2 else { continue }
            let path = String(parts.last ?? "")
            if isRename {
                // Zweites NUL-Feld (alter Pfad) überspringen.
                index += 1
            }

            let statusPair = Array(parts[1])
            let stagedCode = statusPair[0]
            let unstagedCode = statusPair[1]
            if stagedCode != ".", let kind = kind(for: stagedCode) {
                entries.append(GitChangeEntry(path: path, kind: kind, area: .staged))
            }
            if unstagedCode != ".", let kind = kind(for: unstagedCode) {
                entries.append(GitChangeEntry(path: path, kind: kind, area: .unstaged))
            }
        }

        if entries.count > entryCap {
            entries = Array(entries.prefix(entryCap))
            truncated = true
        }
        return (branch, entries, truncated)
    }

    private static func kind(for code: Character) -> GitChangeEntry.Kind? {
        switch code {
        case "M", "T": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        default: return nil
        }
    }

    private static func conflictPath(_ record: Substring) -> String? {
        // `u XY sub m1 m2 m3 mW h1 h2 h3 path`
        let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard parts.count >= 11 else { return nil }
        return String(parts.last ?? "")
    }

    /// Lädt den Snapshot off-main (Muster `GitProjectStatus.load`). Ein
    /// einzelner Spawn; nil-Branch + leere Liste bei sauberem Repo.
    static func load(
        path: String,
        runner: @escaping GitProjectStatus.Runner = GitProjectStatus.git
    ) async -> GitChangesSnapshot {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: path + "/.git") else {
                return GitChangesSnapshot(branch: nil, entries: [], truncated: false, isGitRepository: false)
            }
            guard let output = runner([
                "--no-optional-locks", "-C", path,
                "status", "--porcelain=v2", "-z", "--branch",
            ]) else {
                return GitChangesSnapshot(branch: nil, entries: [], truncated: false, isGitRepository: false)
            }
            let parsed = parse(porcelainV2: output)
            return GitChangesSnapshot(
                branch: parsed.branch,
                entries: parsed.entries,
                truncated: parsed.truncated,
                isGitRepository: true
            )
        }.value
    }
}
