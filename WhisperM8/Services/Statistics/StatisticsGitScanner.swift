import Foundation

// Zählt eigene Commits und Pull Requests in den Projektordnern der Chats.
// Reiner Rechenkern ohne Timer und ohne Store: bekommt Projektpfade und den
// Cursor, liefert die neuen Zählungen je Tag. Subprozesse laufen über
// `StatisticsCommandRunning`, damit Tests ohne echtes git/gh auskommen.

// MARK: - Subprozesse

struct StatisticsCommandResult: Equatable, Sendable {
    var status: Int32
    var stdout: String
}

protocol StatisticsCommandRunning: Sendable {
    /// Synchron, mit Deadline. `nil`, wenn der Prozess nicht startete.
    func run(executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> StatisticsCommandResult?
}

/// Standard-Runner: korrigierte Login-Umgebung, stdout bis EOF lesen und
/// danach warten (sonst verklemmt ein voller Pipe-Puffer beide Seiten), stderr
/// ins Nichts, Abbruch nach `timeout` — wie `GitProjectStatus.git`.
struct StatisticsProcessRunner: StatisticsCommandRunning {
    func run(executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> StatisticsCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = LoginShellEnvironment.shared.processEnvironment()
        // Nie auf eine Eingabe warten, keine Farben, keine Update-Hinweise.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .background
        do {
            try process.run()
        } catch {
            return nil
        }
        let kill = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        kill.cancel()
        return StatisticsCommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: data, as: UTF8.self)
        )
    }
}

// MARK: - Cursor

/// Merkt je Repository (Schlüssel: absolutes `git-common-dir`, damit Worktrees
/// desselben Repos nicht doppelt zählen), was schon gezählt ist.
struct StatisticsGitCursor: Codable, Equatable, Sendable {
    struct Repo: Codable, Equatable, Sendable {
        var lastRunAt: Date
        /// Hash → Commit-Zeit (Epoch) der Commits im Überlappungsfenster.
        var recentCommits: [String: Double] = [:]
        /// Bereits gezählte PR-Nummern.
        var pullRequests: Set<Int> = []

        init(lastRunAt: Date, recentCommits: [String: Double] = [:], pullRequests: Set<Int> = []) {
            self.lastRunAt = lastRunAt
            self.recentCommits = recentCommits
            self.pullRequests = pullRequests
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastRunAt = try c.decode(Date.self, forKey: .lastRunAt)
            recentCommits = try c.decodeIfPresent([String: Double].self, forKey: .recentCommits) ?? [:]
            pullRequests = try c.decodeIfPresent(Set<Int>.self, forKey: .pullRequests) ?? []
        }
    }

    var repos: [String: Repo] = [:]

    init(repos: [String: Repo] = [:]) {
        self.repos = repos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repos = try c.decodeIfPresent([String: Repo].self, forKey: .repos) ?? [:]
    }

    static func load(from url: URL) -> StatisticsGitCursor {
        guard let data = try? Data(contentsOf: url),
              let cursor = try? JSONDecoder.statistics.decode(StatisticsGitCursor.self, from: data)
        else { return StatisticsGitCursor() }
        return cursor
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder.statistics.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Ergebnis

/// Neue Zählungen eines Laufs: Tagesschlüssel → Projektname → Anzahl.
struct StatisticsGitDelta: Equatable, Sendable {
    var commits: [String: [String: Int]] = [:]
    var pullRequests: [String: [String: Int]] = [:]

    var isEmpty: Bool { commits.isEmpty && pullRequests.isEmpty }

    func apply(to db: inout StatsDatabase) {
        for (day, projects) in commits {
            db.updateDay(day) { stats in
                for (project, count) in projects { stats.commits[project, default: 0] += count }
            }
        }
        for (day, projects) in pullRequests {
            db.updateDay(day) { stats in
                for (project, count) in projects { stats.pullRequests[project, default: 0] += count }
            }
        }
    }
}

// MARK: - Parsing

enum StatisticsGitParsing {
    struct Commit: Equatable {
        var hash: String
        var date: Date
    }

    struct PullRequest: Equatable {
        var number: Int
        var createdAt: Date
    }

    /// Zeilen aus `--format=%H%x09%ct`. Unlesbare Zeilen fallen weg.
    static func parseLog(_ text: String) -> [Commit] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 2,
                  parts[0].count >= 7,
                  parts[0].allSatisfy(\.isHexDigit),
                  let epoch = Double(parts[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return Commit(hash: String(parts[0]), date: Date(timeIntervalSince1970: epoch))
        }
    }

    /// `gh pr list --json number,createdAt`. `nil` bei unlesbarer Ausgabe.
    static func parsePullRequests(_ text: String) -> [PullRequest]? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array.compactMap { item in
            guard let number = (item["number"] as? Int) ?? (item["number"] as? Double).map(Int.init),
                  let created = item["createdAt"] as? String,
                  let date = parseISODate(created)
            else { return nil }
            return PullRequest(number: number, createdAt: date)
        }
    }

    static func parseISODate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}

// MARK: - Scanner

struct StatisticsGitScanner {
    var runner: any StatisticsCommandRunning = StatisticsProcessRunner()
    var commandPath: (String) -> String? = { AgentCommandBuilder.commandPath($0) }
    var hasGitDirectory: (String) -> Bool = { path in
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }
    var now: () -> Date = Date.init
    var calendar: Calendar = .current
    /// Wird für jedes Problem genau einmal pro Prozess aufgerufen (der
    /// Sammler entscheidet, ob er loggt).
    var reportProblem: (String) -> Void = { _ in }

    /// Erster Lauf: so weit zurück.
    var historyDays = 365
    /// Spätere Läufe schauen so weit vor den letzten Lauf zurück — für Commits,
    /// die mit älterem Datum hereinkommen (Pull, Branch-Wechsel).
    var overlap: TimeInterval = 7 * 24 * 3600
    var timeout: TimeInterval = 30

    /// Ein Lauf über alle Projekte. Ändert den Cursor, liefert die neuen Zählungen.
    func scan(projectPaths: [String], cursor: inout StatisticsGitCursor) -> StatisticsGitDelta {
        var delta = StatisticsGitDelta()
        let git = commandPath("git") ?? "/usr/bin/git"
        let gh = commandPath("gh")
        if gh == nil { reportProblem("gh_missing") }

        // Kürzester Pfad zuerst: das Hauptrepo gewinnt vor seinen Worktrees.
        let paths = Array(Set(projectPaths.filter { !$0.isEmpty })).sorted {
            $0.count == $1.count ? $0 < $1 : $0.count < $1.count
        }
        var seenRepos: Set<String> = []
        let currentTime = now()

        for path in paths where hasGitDirectory(path) {
            guard let repoKey = commonDirectory(git: git, path: path), seenRepos.insert(repoKey).inserted else { continue }
            let project = URL(fileURLWithPath: path).lastPathComponent
            var repo = cursor.repos[repoKey] ?? StatisticsGitCursor.Repo(lastRunAt: .distantPast)
            let isFirstRun = repo.lastRunAt == .distantPast
            let historyStart = currentTime.addingTimeInterval(-Double(historyDays) * 24 * 3600)

            if let email = output(git, ["-C", path, "config", "user.email"], in: path)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                let since = isFirstRun ? historyStart : repo.lastRunAt.addingTimeInterval(-overlap)
                let log = output(git, [
                    "-C", path, "log", "--all", "--no-merges", "--fixed-strings",
                    "--author=\(email)",
                    "--since=@\(Int(since.timeIntervalSince1970))",
                    "--format=%H%x09%ct",
                ], in: path)
                guard let log else {
                    reportProblem("git_log_failed")
                    continue // Cursor bleibt stehen, nächster Lauf versucht es erneut.
                }
                for commit in StatisticsGitParsing.parseLog(log) where repo.recentCommits[commit.hash] == nil {
                    repo.recentCommits[commit.hash] = commit.date.timeIntervalSince1970
                    let day = StatisticsTime.dayKey(for: commit.date, calendar: calendar)
                    delta.commits[day, default: [:]][project, default: 0] += 1
                }
                // Nur das Überlappungsfenster (plus einen Tag Puffer) merken.
                let keepFrom = currentTime.addingTimeInterval(-overlap - 24 * 3600).timeIntervalSince1970
                repo.recentCommits = repo.recentCommits.filter { $0.value >= keepFrom }
                // Nur ein gelungener Commit-Lauf rückt den Cursor vor: ohne
                // E-Mail bleibt beim späteren Nachtragen die volle Historie.
                repo.lastRunAt = currentTime
            } else {
                reportProblem("git_user_email_missing")
            }

            if let gh, isGitHubRepository(git: git, path: path) {
                countPullRequests(gh: gh, path: path, project: project, historyStart: historyStart, repo: &repo, delta: &delta)
            }

            cursor.repos[repoKey] = repo
        }
        return delta
    }

    private func countPullRequests(
        gh: String,
        path: String,
        project: String,
        historyStart: Date,
        repo: inout StatisticsGitCursor.Repo,
        delta: inout StatisticsGitDelta
    ) {
        let result = runner.run(
            executable: gh,
            arguments: ["pr", "list", "--author", "@me", "--state", "all", "--json", "number,createdAt", "--limit", "200"],
            directory: path,
            timeout: timeout
        )
        // Kein Login, kein Netz, fremder Host: still überspringen.
        guard let result, result.status == 0,
              let pullRequests = StatisticsGitParsing.parsePullRequests(result.stdout)
        else {
            reportProblem("gh_pr_list_failed")
            return
        }
        for pr in pullRequests where !repo.pullRequests.contains(pr.number) {
            repo.pullRequests.insert(pr.number)
            // Ältere PRs nur als gesehen merken, gezählt wird wie bei Commits
            // höchstens ein Jahr zurück.
            guard pr.createdAt >= historyStart else { continue }
            let day = StatisticsTime.dayKey(for: pr.createdAt, calendar: calendar)
            delta.pullRequests[day, default: [:]][project, default: 0] += 1
        }
    }

    /// Absolutes `git-common-dir` — gleicher Schlüssel für Repo und Worktrees.
    private func commonDirectory(git: String, path: String) -> String? {
        guard let raw = output(git, ["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        let url = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw, isDirectory: true)
            : URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(raw, isDirectory: true)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// `gh` nur, wenn ein Remote auf GitHub zeigt — spart Aufrufe, die sicher scheitern.
    private func isGitHubRepository(git: String, path: String) -> Bool {
        guard let remotes = output(git, ["-C", path, "remote", "-v"], in: path) else { return false }
        return remotes.localizedCaseInsensitiveContains("github.com")
    }

    private func output(_ executable: String, _ arguments: [String], in directory: String) -> String? {
        guard let result = runner.run(executable: executable, arguments: arguments, directory: directory, timeout: timeout),
              result.status == 0
        else { return nil }
        return result.stdout
    }
}
