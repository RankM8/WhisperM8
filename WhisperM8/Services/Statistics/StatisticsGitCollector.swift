import Foundation
import os

/// Zählt einmal pro Stunde eigene Commits und Pull Requests der Projektordner
/// im Workspace (`StatisticsGitScanner`) und trägt sie in die Statistik ein.
///
/// Läuft komplett auf einer eigenen Queue mit `.background`-Priorität und
/// setzt im Stromsparmodus oder bei hoher Temperatur aus. Projektpfade kommen
/// aus dem In-Memory-Workspace; alle Subprozesse laufen danach, nie unter dem
/// Store-Lock.
final class StatisticsGitCollector: @unchecked Sendable {
    static let shared = StatisticsGitCollector()

    static let interval: TimeInterval = 3600
    static let cursorFileName = "git-cursor.json"

    private let queue = DispatchQueue(label: "com.whisperm8.statistics.git", qos: .background)
    private let logger = os.Logger(subsystem: "com.whisperm8.app", category: "statistics")

    /// Test-Nähte.
    var store: StatisticsStore = .shared
    var projectPaths: () -> [String] = {
        AgentSessionStore().loadWorkspace().projects.map(\.path)
    }
    var makeScanner: () -> StatisticsGitScanner = { StatisticsGitScanner() }
    var isConstrained: () -> Bool = {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled
            || info.thermalState == .serious
            || info.thermalState == .critical
    }

    // Nur auf `queue`.
    private var timer: DispatchSourceTimer?
    private var reportedProblems: Set<String> = []
    // Nur auf dem Main-Thread.
    private var registeredRuntimeHandler = false

    init() {}

    var cursorURL: URL { store.directory.appendingPathComponent(Self.cursorFileName, isDirectory: false) }

    /// Startet den Sammler (idempotent) und hängt ihn an den Hauptschalter.
    @MainActor
    func start() {
        if !registeredRuntimeHandler {
            registeredRuntimeHandler = true
            StatisticsRuntime.onEnabledChanged { [weak self] enabled in
                if enabled { self?.resume() } else { self?.pause() }
            }
        }
        if StatisticsSettings.isEnabled() { resume() } else { pause() }
    }

    @MainActor
    func stop() {
        pause()
    }

    private func resume() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            // Erster Lauf erst einige Minuten nach dem Start, damit er nicht mit
            // dem App-Start und dem Einlesen der Protokolle konkurriert.
            source.schedule(
                deadline: .now() + 5 * 60,
                repeating: Self.interval,
                leeway: .seconds(10 * 60)
            )
            source.setEventHandler { [weak self] in self?.collectNow() }
            source.resume()
            timer = source
        }
    }

    private func pause() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Ein Lauf. Läuft auf der Sammler-Queue (oder synchron im Test).
    func collectNow() {
        guard StatisticsSettings.isEnabled() else { return }
        guard !isConstrained() else {
            logger.debug("statistics_git_skipped reason=constrained")
            return
        }
        let paths = projectPaths()
        guard !paths.isEmpty else { return }

        var scanner = makeScanner()
        scanner.reportProblem = { [weak self] problem in self?.reportOnce(problem) }
        var cursor = StatisticsGitCursor.load(from: cursorURL)
        let started = Date()
        let delta = scanner.scan(projectPaths: paths, cursor: &cursor)

        if !delta.isEmpty {
            store.update { db in delta.apply(to: &db) }
            // Erst die Zählungen sichern, dann den Cursor: stürzt die App
            // dazwischen ab, zählt der nächste Lauf eher doppelt als gar nicht.
            store.flush()
        }
        do {
            try cursor.save(to: cursorURL)
        } catch {
            logger.error("statistics_git_cursor_write_failed error=\(error.localizedDescription, privacy: .public)")
        }
        let commits = delta.commits.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let pullRequests = delta.pullRequests.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        logger.info(
            "statistics_git_collected repos=\(cursor.repos.count) commits=\(commits) prs=\(pullRequests) durationMs=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
    }

    private func reportOnce(_ problem: String) {
        guard reportedProblems.insert(problem).inserted else { return }
        logger.info("statistics_git_problem kind=\(problem, privacy: .public)")
    }
}
