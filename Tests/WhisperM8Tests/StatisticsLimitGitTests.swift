import XCTest
@testable import WhisperM8

/// Limit- und Git-Sammler der Statistik: Cache-Datei → Snapshot, Kontoschlüssel,
/// Einhakstellen der Fetcher, Git-/gh-Parsing und Cursor ohne Doppelzählung.
final class StatisticsLimitGitTests: XCTestCase {
    private var tempDir: URL!
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("statistics-collectors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StatisticsLimitRecorder.uninstall()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: - Limits: Cache-Datei

    private func makeFetcher() -> ClaudeAccountUsageFetcher {
        var fetcher = ClaudeAccountUsageFetcher()
        fetcher.temporaryDirectory = tempDir.path
        return fetcher
    }

    /// Eindeutiger Profilname, damit der Alt-Pfad unter /tmp nie zufällig trifft.
    private func uniqueProfile() -> String { "stats-test-\(UUID().uuidString.prefix(8))" }

    func testCacheFileBecomesSnapshotWithPlan() throws {
        let profile = uniqueProfile()
        let cache = tempDir.appendingPathComponent("claude-usage-cache-\(profile).json")
        try Data("""
        {"five_hour":{"utilization":42.5,"resets_at":"2026-11-05T15:00:00Z"},
         "seven_day":{"utilization":71,"resets_at":"2026-11-10T08:00:00.000Z"}}
        """.utf8).write(to: cache)
        let mtime = date(2026, 11, 5, 10)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: cache.path)

        var account = ClaudeAccountProfile(name: profile, configDir: tempDir)
        account.emailAddress = "a@example.com"
        account.planDisplayName = "Max 20×"
        let fetcher = makeFetcher()
        let entries = StatisticsLimitCollector.entries(
            profiles: [account],
            cache: { fetcher.cachedUsage(forProfile: $0) },
            codex: nil
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.account, profile)
        XCTAssertEqual(entry.provider, "claude")
        XCTAssertEqual(entry.plan, "Max 20×")
        XCTAssertEqual(entry.snapshot.fiveHourPercent, 42.5)
        XCTAssertEqual(entry.snapshot.weekPercent, 71)
        XCTAssertNotNil(entry.snapshot.weekResetsAt)
        XCTAssertEqual(entry.snapshot.capturedAt.timeIntervalSince1970, mtime.timeIntervalSince1970, accuracy: 1)
    }

    func testStatuslineCaptureTimeBeatsOlderMtime() throws {
        let profile = uniqueProfile()
        let cache = tempDir.appendingPathComponent("claude-usage-cache-\(profile).json")
        let captured = date(2026, 11, 5, 18)
        try Data("""
        {"five_hour":{"utilization":10},"statusline_captured_at":\(Int(captured.timeIntervalSince1970))}
        """.utf8).write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: date(2026, 11, 5, 8)], ofItemAtPath: cache.path)

        let usage = try XCTUnwrap(makeFetcher().cachedUsage(forProfile: profile))
        XCTAssertEqual(usage.fetchedAt.timeIntervalSince1970, captured.timeIntervalSince1970, accuracy: 1)
    }

    /// `statusline_captured_at` gilt nicht für das modellbezogene Limit: das
    /// liefert nur der Abruf, es ist so alt wie die Datei.
    func testModelScopedLimitKeepsFileAgeWhenStatuslineRefreshed() throws {
        let profile = uniqueProfile()
        let cache = tempDir.appendingPathComponent("claude-usage-cache-\(profile).json")
        let captured = date(2026, 11, 5, 18)
        let fileTime = date(2026, 11, 5, 17)
        try Data("""
        {"five_hour":{"utilization":10},"limits":[{"kind":"weekly_scoped","percent":30}],"statusline_captured_at":\(Int(captured.timeIntervalSince1970))}
        """.utf8).write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: fileTime], ofItemAtPath: cache.path)

        let usage = try XCTUnwrap(makeFetcher().cachedUsage(forProfile: profile))
        XCTAssertEqual(usage.fetchedAt.timeIntervalSince1970, captured.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(usage.modelWeeklyFetchedAt?.timeIntervalSince1970 ?? 0, fileTime.timeIntervalSince1970, accuracy: 1)

        // Frisch abgerufen (ohne Statuszeilen-Stempel): kein eigener Zeitpunkt.
        try Data(#"{"five_hour":{"utilization":10},"limits":[{"kind":"weekly_scoped","percent":30}]}"#.utf8).write(to: cache)
        XCTAssertNil(try XCTUnwrap(makeFetcher().cachedUsage(forProfile: profile)).modelWeeklyFetchedAt)
    }

    func testBrokenOrMissingCacheYieldsNoSnapshot() throws {
        let broken = uniqueProfile()
        try Data("{nicht json".utf8).write(to: tempDir.appendingPathComponent("claude-usage-cache-\(broken).json"))
        let missing = uniqueProfile()
        let fetcher = makeFetcher()
        XCTAssertNil(fetcher.cachedUsage(forProfile: broken))
        XCTAssertNil(fetcher.cachedUsage(forProfile: missing))

        var a = ClaudeAccountProfile(name: broken, configDir: tempDir)
        a.emailAddress = "a@example.com"
        var b = ClaudeAccountProfile(name: missing, configDir: tempDir)
        b.emailAddress = "b@example.com"
        let loggedOut = ClaudeAccountProfile(name: "ausgeloggt", configDir: tempDir)
        let entries = StatisticsLimitCollector.entries(
            profiles: [a, b, loggedOut],
            cache: { fetcher.cachedUsage(forProfile: $0) },
            codex: nil
        )
        XCTAssertTrue(entries.isEmpty)
    }

    func testErrorStateWithoutLimitsIsNoSnapshot() {
        let usage = ClaudeAccountUsage(fetchedAt: Date(), isLive: false, liveFetchProblem: .network)
        XCTAssertNil(StatisticsLimitMapping.entry(claude: usage, profile: "main", plan: nil))
    }

    // MARK: - Limits: Kontoschlüssel und Codex

    func testAccountKeys() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        let extra = home.appendingPathComponent(".gpt-profiles/Firma/codex/auth.json")
        let main = home.appendingPathComponent(".config/claude-code-proxy/codex/auth.json")
        XCTAssertEqual(StatisticsLimitMapping.gptAccountKey(proxyAuthFile: extra), "chatgpt:Firma")
        XCTAssertEqual(StatisticsLimitMapping.gptAccountKey(proxyAuthFile: main), "chatgpt:main")
        XCTAssertEqual(CodexUsageFetcher(proxyAuthFile: extra).statisticsAccount, "chatgpt:Firma")
        XCTAssertEqual(CodexUsageFetcher().statisticsAccount, "codex")
    }

    func testCodexWindowsMapByLength() throws {
        let usage = CodexUsage(
            primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil),
            secondary: .init(usedPercent: 80, windowMinutes: 10080, resetsAt: date(2026, 11, 9)),
            planType: "pro",
            capturedAt: date(2026, 11, 5)
        )
        let entry = try XCTUnwrap(StatisticsLimitMapping.entry(codex: usage, account: "codex"))
        XCTAssertEqual(entry.provider, "chatgpt")
        XCTAssertEqual(entry.plan, "Pro")
        XCTAssertEqual(entry.snapshot.fiveHourPercent, 12)
        XCTAssertEqual(entry.snapshot.weekPercent, 80)
        XCTAssertEqual(entry.snapshot.weekResetsAt, date(2026, 11, 9))

        // Nur ein Wochenfenster (Proxy-Konto ohne 5h-Limit).
        let weekOnly = CodexUsage(primary: .init(usedPercent: 4, windowMinutes: 10080, resetsAt: nil))
        let weekEntry = try XCTUnwrap(StatisticsLimitMapping.entry(codex: weekOnly, account: "chatgpt:main"))
        XCTAssertNil(weekEntry.snapshot.fiveHourPercent)
        XCTAssertEqual(weekEntry.snapshot.weekPercent, 4)
    }

    func testApplyKeepsWeeklyPeakAndIgnoresOlderSnapshot() {
        var db = StatsDatabase()
        func entry(_ week: Double, _ at: Date) -> StatisticsLimitEntry {
            StatisticsLimitEntry(account: "main", provider: "claude", plan: "Max",
                                 snapshot: LimitSnapshot(weekPercent: week, capturedAt: at))
        }
        StatisticsLimitMapping.apply(entry(60, date(2026, 11, 4)), to: &db, calendar: calendar)
        StatisticsLimitMapping.apply(entry(40, date(2026, 11, 5)), to: &db, calendar: calendar)
        StatisticsLimitMapping.apply(entry(99, date(2026, 11, 3)), to: &db, calendar: calendar)

        let history = db.limits["main"]
        XCTAssertEqual(history?.plan, "Max")
        XCTAssertEqual(history?.current?.weekPercent, 40)
        XCTAssertEqual(history?.weeklyPeaks["2026-11-02"], 60)
    }

    func testFetcherHookRecordsOnlyWhenSinkInstalled() async {
        let auth = tempDir.appendingPathComponent(".gpt-profiles/Firma/codex/auth.json")
        try? FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(#"{"access":"token-placeholder","accountId":"acct"}"#.utf8).write(to: auth)
        let body = Data("""
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":33,"limit_window_seconds":18000,"reset_at":1790000000}}}
        """.utf8)
        let fetcher = CodexUsageFetcher(proxyAuthFile: auth, httpBody: { _ in body })

        let recorded = LockedEntries()
        // Ohne Ziel: nichts passiert.
        _ = await fetcher.fetchLiveUsage()
        XCTAssertFalse(StatisticsLimitRecorder.isActive)

        StatisticsLimitRecorder.install { recorded.append($0) }
        _ = await fetcher.fetchLiveUsage()
        let entries = recorded.all
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.account, "chatgpt:Firma")
        XCTAssertEqual(entries.first?.snapshot.fiveHourPercent, 33)
        XCTAssertEqual(entries.first?.plan, "Plus")
    }

    func testRecentCodexUsageReadsOnlyTodayAndYesterday() throws {
        let root = tempDir.appendingPathComponent("sessions", isDirectory: true)
        let now = date(2026, 11, 5)
        let line = #"{"timestamp":"2026-11-04T10:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":21,"window_minutes":300}}}}"#
        let yesterday = root.appendingPathComponent("2026/11/04", isDirectory: true)
        try FileManager.default.createDirectory(at: yesterday, withIntermediateDirectories: true)
        try Data((line + "\n").utf8).write(to: yesterday.appendingPathComponent("rollout.jsonl"))
        let old = root.appendingPathComponent("2026/10/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data((line + "\n").utf8).write(to: old.appendingPathComponent("rollout.jsonl"))

        let usage = StatisticsLimitCollector.recentCodexUsage(sessionsRoot: root, now: now, calendar: calendar)
        XCTAssertEqual(usage?.primary?.usedPercent, 21)
        XCTAssertNil(StatisticsLimitCollector.recentCodexUsage(sessionsRoot: root, now: date(2026, 11, 20), calendar: calendar))
    }

    // MARK: - Git: Parsing

    func testParseLogSkipsGarbage() {
        let text = "abc1234def\t1793900000\n\nkaputt\nzzzzzzzz\t1\nfeedbeef00\tnope\n0123456789abcdef\t1793800000\n"
        let commits = StatisticsGitParsing.parseLog(text)
        XCTAssertEqual(commits.map(\.hash), ["abc1234def", "0123456789abcdef"])
        XCTAssertEqual(commits.first?.date, Date(timeIntervalSince1970: 1_793_900_000))
    }

    func testParsePullRequests() throws {
        let json = #"[{"number":12,"createdAt":"2026-11-05T09:30:00Z"},{"number":"x"},{"number":7,"createdAt":"2026-10-01T08:00:00.123Z"}]"#
        let prs = try XCTUnwrap(StatisticsGitParsing.parsePullRequests(json))
        XCTAssertEqual(prs.map(\.number), [12, 7])
        XCTAssertNil(StatisticsGitParsing.parsePullRequests("not json"))
        XCTAssertEqual(StatisticsGitParsing.parsePullRequests("[]"), [])
    }

    // MARK: - Git: Scanner mit Spy

    private func makeScanner(_ spy: SpyRunner, gh: Bool = true, now: Date) -> StatisticsGitScanner {
        var scanner = StatisticsGitScanner()
        scanner.runner = spy
        scanner.commandPath = { name in
            switch name {
            case "git": return "/spy/git"
            case "gh": return gh ? "/spy/gh" : nil
            default: return nil
            }
        }
        scanner.hasGitDirectory = { _ in true }
        scanner.now = { now }
        scanner.calendar = calendar
        return scanner
    }

    func testFirstRunCountsHistoryAndSecondRunDoesNotDoubleCount() {
        let now = date(2026, 11, 5, 18)
        let c1 = Int(date(2026, 11, 5, 9).timeIntervalSince1970)
        let c2 = Int(date(2026, 11, 4, 22).timeIntervalSince1970)
        let spy = SpyRunner()
        spy.logOutput = "aaaaaaa1\t\(c1)\nbbbbbbb2\t\(c2)\n"
        spy.prOutput = #"[{"number":3,"createdAt":"2026-11-05T09:30:00Z"}]"#

        var cursor = StatisticsGitCursor()
        let first = makeScanner(spy, now: now).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(first.commits["2026-11-05"]?["app"], 1)
        XCTAssertEqual(first.commits["2026-11-04"]?["app"], 1)
        XCTAssertEqual(first.pullRequests["2026-11-05"]?["app"], 1)
        // Erster Lauf: 365 Tage zurück, mit E-Mail als fester Zeichenkette.
        let logCall = spy.calls.first { $0.arguments.contains("log") }
        XCTAssertTrue(logCall?.arguments.contains("--author=me@example.com") ?? false)
        XCTAssertTrue(logCall?.arguments.contains("--fixed-strings") ?? false)
        let since = Int(now.addingTimeInterval(-365 * 24 * 3600).timeIntervalSince1970)
        XCTAssertTrue(logCall?.arguments.contains("--since=@\(since)") ?? false)

        // Zweiter Lauf: gleiche Commits erneut plus ein neuer, gleicher PR plus neuer.
        let c3 = Int(date(2026, 11, 5, 19).timeIntervalSince1970)
        spy.logOutput = "aaaaaaa1\t\(c1)\nbbbbbbb2\t\(c2)\nccccccc3\t\(c3)\n"
        spy.prOutput = #"[{"number":3,"createdAt":"2026-11-05T09:30:00Z"},{"number":4,"createdAt":"2026-11-05T20:00:00Z"}]"#
        spy.calls = []
        let later = date(2026, 11, 5, 20)
        let second = makeScanner(spy, now: later).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(second.commits, ["2026-11-05": ["app": 1]])
        XCTAssertEqual(second.pullRequests, ["2026-11-05": ["app": 1]])
        let overlapSince = Int(now.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970)
        XCTAssertTrue(spy.calls.first { $0.arguments.contains("log") }?.arguments.contains("--since=@\(overlapSince)") ?? false)
    }

    func testCursorSurvivesRoundTripAndPreventsDoubleCount() throws {
        let now = date(2026, 11, 5, 18)
        let spy = SpyRunner()
        spy.logOutput = "aaaaaaa1\t\(Int(now.timeIntervalSince1970) - 60)\n"
        var cursor = StatisticsGitCursor()
        _ = makeScanner(spy, gh: false, now: now).scan(projectPaths: ["/repos/app"], cursor: &cursor)

        let url = tempDir.appendingPathComponent("git-cursor.json")
        try cursor.save(to: url)
        var loaded = StatisticsGitCursor.load(from: url)
        XCTAssertEqual(loaded, cursor)

        let again = makeScanner(spy, gh: false, now: now.addingTimeInterval(3600)).scan(projectPaths: ["/repos/app"], cursor: &loaded)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(StatisticsGitCursor.load(from: tempDir.appendingPathComponent("fehlt.json")), StatisticsGitCursor())
    }

    func testWorktreesOfSameRepoCountOnceUnderMainProject() {
        let spy = SpyRunner()
        spy.commonDir = "/repos/app/.git"
        spy.logOutput = "aaaaaaa1\t\(Int(date(2026, 11, 5).timeIntervalSince1970))\n"
        var cursor = StatisticsGitCursor()
        let delta = makeScanner(spy, gh: false, now: date(2026, 11, 5, 18))
            .scan(projectPaths: ["/repos/app/.claude/worktrees/feature", "/repos/app"], cursor: &cursor)
        XCTAssertEqual(delta.commits, ["2026-11-05": ["app": 1]])
        XCTAssertEqual(spy.calls.filter { $0.arguments.contains("log") }.count, 1)
    }

    func testMissingGhIsSilentAndCommitsStillCount() {
        let spy = SpyRunner()
        spy.logOutput = "aaaaaaa1\t\(Int(date(2026, 11, 5).timeIntervalSince1970))\n"
        var problems: [String] = []
        var scanner = makeScanner(spy, gh: false, now: date(2026, 11, 5, 18))
        scanner.reportProblem = { problems.append($0) }
        var cursor = StatisticsGitCursor()
        let delta = scanner.scan(projectPaths: ["/repos/app"], cursor: &cursor)

        XCTAssertEqual(delta.commits["2026-11-05"]?["app"], 1)
        XCTAssertTrue(delta.pullRequests.isEmpty)
        XCTAssertFalse(spy.calls.contains { $0.executable == "/spy/gh" })
        XCTAssertEqual(problems, ["gh_missing"])
    }

    func testFailingGhAndNonGitHubRemoteAreSkipped() {
        let spy = SpyRunner()
        spy.logOutput = ""
        spy.ghStatus = 1
        var cursor = StatisticsGitCursor()
        var problems: [String] = []
        var scanner = makeScanner(spy, now: date(2026, 11, 5, 18))
        scanner.reportProblem = { problems.append($0) }
        XCTAssertTrue(scanner.scan(projectPaths: ["/repos/app"], cursor: &cursor).isEmpty)
        XCTAssertEqual(problems, ["gh_pr_list_failed"])

        spy.remotes = "origin\tgit@gitlab.com:x/app.git (fetch)\n"
        spy.calls = []
        _ = scanner.scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertFalse(spy.calls.contains { $0.executable == "/spy/gh" })
    }

    func testMissingEmailKeepsHistoryForLater() {
        let spy = SpyRunner()
        spy.email = ""
        var cursor = StatisticsGitCursor()
        _ = makeScanner(spy, gh: false, now: date(2026, 11, 5, 18)).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertFalse(spy.calls.contains { $0.arguments.contains("log") })

        spy.email = "me@example.com"
        spy.logOutput = "aaaaaaa1\t\(Int(date(2026, 3, 1).timeIntervalSince1970))\n"
        let delta = makeScanner(spy, gh: false, now: date(2026, 11, 6, 18)).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(delta.commits["2026-03-01"]?["app"], 1)
    }

    func testParseLogReadsAuthorTimeAndSubjectWithTabs() throws {
        let text = "abc1234def\t1793900000\t1793800000\tfix: Tab\tim Betreff\nfeedbeef00\t1793900000\tkaputt\tx\n"
        let commits = StatisticsGitParsing.parseLog(text)
        XCTAssertEqual(commits.count, 1)
        let commit = try XCTUnwrap(commits.first)
        XCTAssertEqual(commit.authorDate, Date(timeIntervalSince1970: 1_793_800_000))
        XCTAssertEqual(commit.subject, "fix: Tab\tim Betreff")
        XCTAssertTrue(commit.identity.hasPrefix("id:1793800000:"))
        // Stabil über Prozesse: fester FNV-1a-Wert.
        XCTAssertEqual(StatisticsGitParsing.stableHash(""), "cbf29ce484222325")
    }

    /// Rebase, Amend und Cherry-Pick: neuer Hash, neue Commit-Zeit, gleiche
    /// Autor-Zeit und gleicher Betreff → zählt nicht erneut.
    func testRewrittenCommitsCountOnce() {
        let now = date(2026, 11, 5, 18)
        let authored = Int(date(2026, 11, 3, 10).timeIntervalSince1970)
        let committed = Int(date(2026, 11, 3, 10).timeIntervalSince1970)
        let spy = SpyRunner()
        // Erster Lauf: Commit plus Cherry-Pick auf einem zweiten Branch.
        let picked = Int(date(2026, 11, 4, 9).timeIntervalSince1970)
        spy.logOutput = "aaaaaaa1\t\(committed)\t\(authored)\tfeat: Statistik\n"
            + "bbbbbbb2\t\(picked)\t\(authored)\tfeat: Statistik\n"
        var cursor = StatisticsGitCursor()
        let first = makeScanner(spy, gh: false, now: now).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(first.commits, ["2026-11-03": ["app": 1]], "Tag nach Autor-Zeit, Cherry-Pick zählt nicht")

        // Rebase: wieder neuer Hash und neue Commit-Zeit, dazu ein echter neuer Commit.
        let rebased = Int(date(2026, 11, 5, 19).timeIntervalSince1970)
        let fresh = Int(date(2026, 11, 5, 19).timeIntervalSince1970)
        spy.logOutput = "ccccccc3\t\(rebased)\t\(authored)\tfeat: Statistik\n"
            + "ddddddd4\t\(fresh)\t\(fresh)\tfix: neu\n"
        let second = makeScanner(spy, gh: false, now: date(2026, 11, 5, 20)).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(second.commits, ["2026-11-05": ["app": 1]])
    }

    /// Ein alter Commit, der nach einem Rebase mit neuer Commit-Zeit
    /// auftaucht, ist umgeschrieben: seine Identität ist längst aus dem Cursor
    /// geräumt, gezählt wird er trotzdem nicht.
    func testOldCommitRewrittenAfterWindowIsNotCountedAgain() {
        let spy = SpyRunner()
        let authored = Int(date(2026, 10, 1, 10).timeIntervalSince1970)
        spy.logOutput = "aaaaaaa1\t\(authored)\t\(authored)\tfeat: alt\n"
        var cursor = StatisticsGitCursor()
        let first = makeScanner(spy, gh: false, now: date(2026, 10, 1, 18)).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(first.commits, ["2026-10-01": ["app": 1]])

        // Stündliche Läufe bis zum 5.11. räumen den Eintrag aus dem Fenster.
        _ = makeScanner(spy, gh: false, now: date(2026, 11, 5, 17)).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertTrue(cursor.repos.values.allSatisfy { $0.recentCommits.isEmpty })

        let rebased = Int(date(2026, 11, 5, 17).addingTimeInterval(1800).timeIntervalSince1970)
        spy.logOutput = "bbbbbbb2\t\(rebased)\t\(authored)\tfeat: alt\n"
        let again = makeScanner(spy, gh: false, now: date(2026, 11, 5, 18)).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertTrue(again.commits.isEmpty)
    }

    /// Cursor aus der Vorversion (Hash → Commit-Zeit) bleibt gültig: was
    /// darin steht, zählt nach dem Update nicht noch einmal.
    func testLegacyHashCursorPreventsDoubleCountAfterUpdate() throws {
        let now = date(2026, 11, 5, 18)
        let commitTime = Int(date(2026, 11, 5, 9).timeIntervalSince1970)
        let lastRun = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let legacy = """
        {"repos":{"/repos/app/.git":{"lastRunAt":"\(lastRun)","recentCommits":{"aaaaaaa1":\(commitTime)},"pullRequests":[]}}}
        """
        let url = tempDir.appendingPathComponent("legacy-cursor.json")
        try Data(legacy.utf8).write(to: url)
        var cursor = StatisticsGitCursor.load(from: url)
        XCTAssertEqual(cursor.repos["/repos/app/.git"]?.recentCommits["aaaaaaa1"], Double(commitTime))

        let spy = SpyRunner()
        spy.logOutput = "aaaaaaa1\t\(commitTime)\t\(commitTime)\tfeat: schon gezählt\n"
            + "bbbbbbb2\t\(commitTime + 60)\t\(commitTime + 60)\tfeat: neu\n"
        let delta = makeScanner(spy, gh: false, now: now).scan(projectPaths: ["/repos/app"], cursor: &cursor)
        XCTAssertEqual(delta.commits, ["2026-11-05": ["app": 1]])
    }

    func testDeltaAppliesToDays() {
        var db = StatsDatabase()
        db.updateDay("2026-11-05") { $0.commits["app"] = 2 }
        let delta = StatisticsGitDelta(
            commits: ["2026-11-05": ["app": 3, "web": 1]],
            pullRequests: ["2026-11-04": ["app": 1]]
        )
        delta.apply(to: &db)
        XCTAssertEqual(db.days["2026-11-05"]?.commits, ["app": 5, "web": 1])
        XCTAssertEqual(db.days["2026-11-04"]?.pullRequests, ["app": 1])
    }
}

// MARK: - Testhelfer

private final class LockedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [StatisticsLimitEntry] = []
    func append(_ entry: StatisticsLimitEntry) { lock.lock(); entries.append(entry); lock.unlock() }
    var all: [StatisticsLimitEntry] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// Spielt git und gh nach: antwortet je nach Unterbefehl, merkt sich die Aufrufe.
private final class SpyRunner: StatisticsCommandRunning, @unchecked Sendable {
    struct Call {
        var executable: String
        var arguments: [String]
    }

    var calls: [Call] = []
    var email = "me@example.com"
    var commonDir: String?
    var remotes = "origin\tgit@github.com:me/app.git (fetch)\n"
    var logOutput = ""
    var prOutput = "[]"
    var ghStatus: Int32 = 0

    func run(executable: String, arguments: [String], directory: String, timeout: TimeInterval) -> StatisticsCommandResult? {
        calls.append(Call(executable: executable, arguments: arguments))
        if executable == "/spy/gh" {
            return StatisticsCommandResult(status: ghStatus, stdout: prOutput)
        }
        if arguments.contains("rev-parse") {
            return StatisticsCommandResult(status: 0, stdout: (commonDir ?? directory + "/.git") + "\n")
        }
        if arguments.contains("config") {
            return StatisticsCommandResult(status: email.isEmpty ? 1 : 0, stdout: email + "\n")
        }
        if arguments.contains("remote") {
            return StatisticsCommandResult(status: 0, stdout: remotes)
        }
        if arguments.contains("log") {
            return StatisticsCommandResult(status: 0, stdout: logOutput)
        }
        return nil
    }
}
