import Foundation
import Observation
import os

/// Liest die Protokolle von Claude Code und Codex und trägt Token-Verbrauch,
/// Subagent-Starts und Codex-Limits in den `StatisticsStore` ein.
///
/// Leitlinie ist, dass die App davon nichts merkt:
/// - eigene serielle Queue (`.utility`, im Backfill `.background`), nie Main-Thread-I/O;
/// - kein Dauerbeobachten der Dateien: ein Lauf ~30 s nach dem Start, danach
///   alle 15 Minuten (großzügige Timer-Toleranz) und auf Wunsch der Seite;
/// - je Datei ein Cursor, unveränderte Dateien werden nur ge-`stat`-et;
/// - gelesen wird in 1-MB-Stücken, nie eine ganze Datei;
/// - das erste Einlesen der Historie (Backfill) ist gedrosselt und pausiert
///   bei Diktat, Stromsparmodus, Hitze oder auf Wunsch.
final class StatisticsLogScanner: @unchecked Sendable {
    static let shared = StatisticsLogScanner()

    /// Abhängigkeiten, in Tests ersetzbar.
    struct Dependencies {
        var sources: () -> [StatisticsLogSource] = { StatisticsLogSource.live() }
        var store: StatisticsStore = .shared
        /// Ordner für Cursor und Dedup; Standard: der Ordner des Stores.
        var stateDirectory: URL?
        var calendar: Calendar = .current
        var isEnabled: () -> Bool = { StatisticsSettings.isEnabled() }
        /// Diktat läuft, Stromsparmodus, Hitze — dann wartet der Leser.
        var shouldYield: () -> Bool = { StatisticsScanThrottle.shouldYield() }
        var now: () -> Date = Date.init
        /// Pause zwischen zwei Dateien im Backfill.
        var backfillFileDelay: TimeInterval = 0.02
        /// Wie oft im Pausenzustand nachgesehen wird.
        var pausePollInterval: TimeInterval = 2
        /// Im Backfill wird alle so vielen Dateien gesichert.
        var backfillFlushEvery = 50
    }

    static let initialDelay: TimeInterval = 30
    static let interval: TimeInterval = 15 * 60
    static let minimumGap: TimeInterval = 60

    private let deps: Dependencies
    private let queue = DispatchQueue(label: "com.whisperm8.statistics.logscanner", qos: .utility)
    private let controlQueue = DispatchQueue(label: "com.whisperm8.statistics.logscanner.control", qos: .utility)
    private let logger = os.Logger(subsystem: "com.whisperm8.app", category: "statistics")
    private let state = OSAllocatedUnfairLock(initialState: ControlState())

    private struct ControlState {
        var started = false
        var running = false
        var scheduled = false
        var rerunRequested = false
        var cancelRequested = false
        var rescanRequested = false
        var userPaused = false
        var userPauseLoaded = false
        /// Stand des letzten Laufs: Backfill fertig? `nil` = noch unbekannt.
        var backfillFinished: Bool?
        var lastRunEnd: Date?
    }

    private var timer: DispatchSourceTimer?
    private var runtimeInstalled = false

    init(dependencies: Dependencies = Dependencies()) {
        self.deps = dependencies
    }

    private var stateFiles: StatisticsScanStateFiles {
        StatisticsScanStateFiles(directory: deps.stateDirectory ?? deps.store.directory)
    }

    // MARK: - Fassade

    /// Beim App-Start aufrufen. Trägt die Aufrufe der Seite in
    /// `StatisticsRuntime` ein und startet die Läufe, wenn die Statistik an ist.
    @MainActor
    func start() {
        installRuntimeHooksIfNeeded()
        StatisticsScanThrottle.startObservingDictation()
        guard deps.isEnabled() else { return }
        resume()
    }

    /// Hält Timer und laufenden Lauf an. Bereits gesicherte Stände bleiben.
    func stop() {
        state.withLock {
            $0.started = false
            if $0.running { $0.cancelRequested = true }
        }
        controlQueue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// Neue Protokollzeilen jetzt lesen — frühestens `minimumGap` nach dem letzten Lauf.
    func requestScan() {
        let (lastEnd, busy) = state.withLock { ($0.lastRunEnd, $0.running || $0.scheduled) }
        guard !busy else { return }
        let earliest = lastEnd.map { $0.addingTimeInterval(Self.minimumGap) } ?? deps.now()
        scheduleRun(after: max(0, earliest.timeIntervalSince(deps.now())))
    }

    func setBackfillPaused(_ paused: Bool) {
        state.withLock {
            $0.userPaused = paused
            $0.userPauseLoaded = true
        }
        deps.store.update { db in db.backfill.isPaused = paused }
    }

    /// Cursor und Dedup verwerfen, gezählte Werte leeren, alles neu einlesen.
    func rescanAll() {
        if !markRescanRequested() { scheduleRun(after: 0, force: true) }
    }

    /// Merkt „Neu einlesen“ für den nächsten Lauf vor und bricht einen
    /// laufenden ab. Liefert, ob gerade ein Lauf aktiv war.
    @discardableResult
    func markRescanRequested() -> Bool {
        state.withLock { s -> Bool in
            s.rescanRequested = true
            s.backfillFinished = false
            if s.running {
                s.cancelRequested = true
                s.rerunRequested = true
            }
            return s.running
        }
    }

    // MARK: - Planung

    @MainActor
    private func installRuntimeHooksIfNeeded() {
        guard !runtimeInstalled else { return }
        runtimeInstalled = true
        StatisticsRuntime.requestScan = { [weak self] in self?.requestScan() }
        StatisticsRuntime.setBackfillPaused = { [weak self] paused in self?.setBackfillPaused(paused) }
        StatisticsRuntime.rescanAll = { [weak self] in self?.rescanAll() }
        StatisticsRuntime.onEnabledChanged { [weak self] enabled in
            guard let self else { return }
            if enabled { self.resume() } else { self.stop() }
        }
    }

    private func resume() {
        let wasStarted = state.withLock { s -> Bool in
            let was = s.started
            s.started = true
            return was
        }
        guard !wasStarted else { return }
        controlQueue.async { [self] in
            timer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: controlQueue)
            source.schedule(
                deadline: .now() + Self.initialDelay,
                repeating: Self.interval,
                leeway: .seconds(120)
            )
            source.setEventHandler { [weak self] in self?.scheduleRun(after: 0) }
            timer = source
            source.resume()
        }
    }

    private func scheduleRun(after delay: TimeInterval, force: Bool = false) {
        let qos: DispatchQoS = state.withLock { s -> DispatchQoS? in
            guard s.started || force else { return nil }
            if s.running {
                if force { s.rerunRequested = true }
                return nil
            }
            guard !s.scheduled else { return nil }
            s.scheduled = true
            // Solange der Backfill nicht sicher fertig ist: niedrigste Stufe.
            return s.backfillFinished == true ? .utility : .background
        } ?? .unspecified
        guard qos != .unspecified else { return }
        let item = DispatchWorkItem(qos: qos, flags: .enforceQoS) { [weak self] in self?.runNow() }
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func runNow() {
        state.withLock {
            $0.scheduled = false
            $0.running = true
            $0.cancelRequested = false
        }
        performScan()
        let rerun = state.withLock { s -> Bool in
            s.running = false
            s.lastRunEnd = deps.now()
            let rerun = s.rerunRequested
            s.rerunRequested = false
            return rerun
        }
        if rerun { scheduleRun(after: 0, force: true) }
    }

    private var isCancelled: Bool { state.withLock { $0.cancelRequested } }

    // MARK: - Ein Lauf

    /// Ein vollständiger Lauf auf der aufrufenden Queue. Intern statt privat,
    /// damit Tests ihn synchron fahren können.
    func performScan() {
        let files = stateFiles
        let rescan = state.withLock { s -> Bool in
            let value = s.rescanRequested
            s.rescanRequested = false
            return value
        }
        if rescan { resetForRescan(files) }
        guard deps.isEnabled() else { return }

        let startedAt = deps.now()
        let snapshot = deps.store.snapshotSync()
        state.withLock { s in
            if !s.userPauseLoaded {
                s.userPaused = snapshot.backfill.isPaused
                s.userPauseLoaded = true
            }
        }
        let backfillMode = rescan || snapshot.backfill.finishedAt == nil

        var cursors = files.loadCursors()
        let dedup = files.loadDedup()
        let listed = StatisticsLogLister.list(deps.sources())

        // Verschwundene Dateien vergessen, damit die Cursor-Datei nicht wächst.
        let listedPaths = Set(listed.map(\.path))
        let before = cursors.files.count
        cursors.files = cursors.files.filter { listedPaths.contains($0.key) }
        var cursorsDirty = cursors.files.count != before
        // Die Cursor-Datei dient zugleich als Merker gegen „Löschen…“ mitten
        // im Lauf, muss also vor dem ersten Abschnitt auf der Platte liegen.
        if cursorsDirty || !files.cursorsExist {
            do {
                try files.saveCursors(cursors)
                cursorsDirty = false
            } catch {
                logger.error("statistics_scan_state_write_failed error=\(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // Neueste zuerst: Woche und Monat stimmen schnell, auch wenn der Backfill noch läuft.
        let pending = listed
            .filter { $0.needsRead(cursors.files[$0.path]) }
            .sorted { $0.mtime > $1.mtime }

        if backfillMode {
            let total = listed.count
            let done = total - pending.count
            let now = deps.now()
            deps.store.update { db in
                db.backfill.totalFiles = total
                db.backfill.processedFiles = done
                if db.backfill.startedAt == nil { db.backfill.startedAt = now }
                db.backfill.finishedAt = nil
            }
        }

        // Gemessen wird nur der inkrementelle Lauf; der Backfill dauert gewollt Minuten.
        var perfToken = backfillMode ? nil : PerfBudgets.statisticsScan.begin()
        var batch = StatisticsScanBatch(calendar: deps.calendar)
        var filesRead = 0
        var sinceFlush = 0

        for file in pending {
            if isCancelled { cancel(perfToken); return }
            switch waitUntilAllowed(backfill: backfillMode) {
            case .cancelled:
                cancel(perfToken)
                return
            case .waited:
                // Wartezeit ist keine Arbeit: diese Messung zählt nicht.
                cancel(perfToken)
                perfToken = nil
            case .immediately:
                break
            }

            cursors.files[file.path] = StatisticsLogFileReader.process(
                file,
                cursor: cursors.files[file.path],
                dedup: dedup,
                batch: &batch
            )
            filesRead += 1
            sinceFlush += 1

            if backfillMode {
                if sinceFlush >= deps.backfillFlushEvery {
                    sinceFlush = 0
                    let processed = filesRead
                    guard flush(&batch, cursors: cursors, dedup: dedup, files: files, extra: { db in
                        db.backfill.processedFiles = min(db.backfill.totalFiles, db.backfill.processedFiles + processed)
                    }) else { cancel(perfToken); return }
                    filesRead = 0
                }
                if deps.backfillFileDelay > 0 { Thread.sleep(forTimeInterval: deps.backfillFileDelay) }
            }
        }

        let finishedAt = deps.now()
        let totalRead = pending.count
        // Ohne gelesene Datei bleibt die Cursor-Datei, wie sie ist.
        let ok = flush(&batch, cursors: cursors, dedup: dedup, files: files, saveCursors: !pending.isEmpty || cursorsDirty) { db in
            db.lastScan = StatsScanInfo(
                finishedAt: finishedAt,
                filesRead: totalRead,
                duration: finishedAt.timeIntervalSince(startedAt)
            )
            if backfillMode {
                db.backfill.processedFiles = db.backfill.totalFiles
                db.backfill.finishedAt = finishedAt
            }
        }
        if let perfToken {
            if ok { PerfBudgets.statisticsScan.end(perfToken) } else { cancel(perfToken) }
        }
        guard ok else { return }
        state.withLock { $0.backfillFinished = true }
        logger.info("statistics_scan_done files=\(totalRead, privacy: .public) backfill=\(backfillMode, privacy: .public) ms=\(Int(finishedAt.timeIntervalSince(startedAt) * 1000), privacy: .public)")
    }

    private func cancel(_ token: PerformanceBudget.Token?) {
        if let token { PerfBudgets.statisticsScan.cancel(token) }
    }

    /// Schreibt einen Abschnitt: erst die Zahlen in den Store (und dort sofort
    /// auf die Platte), dann Cursor und Dedup. Stürzt die App genau dazwischen
    /// ab, zählt ein Abschnitt im schlimmsten Fall doppelt — verloren geht nichts.
    /// `false`: Der Statistik-Ordner wurde mitten im Lauf gelöscht („Löschen…“),
    /// der Lauf bricht ab und verwirft alles.
    private func flush(
        _ batch: inout StatisticsScanBatch,
        cursors: StatisticsScanCursors,
        dedup: StatisticsDedupSet,
        files: StatisticsScanStateFiles,
        saveCursors: Bool = true,
        extra: @escaping @Sendable (inout StatsDatabase) -> Void
    ) -> Bool {
        guard files.cursorsExist else {
            logger.info("statistics_scan_aborted reason=state_removed")
            return false
        }
        let snapshot = batch
        deps.store.update { db in
            snapshot.apply(to: &db)
            extra(&db)
        }
        deps.store.flush()
        do {
            if saveCursors { try files.saveCursors(cursors) }
            if dedup.hasChanges { try files.saveDedup(dedup) }
        } catch {
            logger.error("statistics_scan_state_write_failed error=\(error.localizedDescription, privacy: .public)")
        }
        batch.clear()
        return true
    }

    private func resetForRescan(_ files: StatisticsScanStateFiles) {
        files.removeAll()
        let now = deps.now()
        deps.store.update { db in
            for key in db.days.keys { db.days[key]?.clearScanned() }
            let paused = db.backfill.isPaused
            db.backfill = StatsBackfillState()
            db.backfill.startedAt = now
            db.backfill.isPaused = paused
        }
        logger.info("statistics_rescan_all")
    }

    private enum WaitOutcome { case immediately, waited, cancelled }

    /// Wartet, solange Diktat, Hitze, Stromsparmodus oder (nur im Backfill)
    /// die Pause des Nutzers es verlangen.
    private func waitUntilAllowed(backfill: Bool) -> WaitOutcome {
        var waited = false
        while true {
            if isCancelled { return .cancelled }
            let userPaused = backfill && state.withLock { $0.userPaused }
            guard userPaused || deps.shouldYield() else { return waited ? .waited : .immediately }
            waited = true
            Thread.sleep(forTimeInterval: deps.pausePollInterval)
        }
    }
}

// MARK: - Drossel

/// Billige Merker, ob der Leser gerade Platz machen soll.
enum StatisticsScanThrottle {
    /// Spiegel von `AppState.recordingPhase != .idle`, lesbar von jeder Queue.
    private static let dictationActive = OSAllocatedUnfairLock(initialState: false)
    private static let observing = OSAllocatedUnfairLock(initialState: false)

    static var isDictating: Bool { dictationActive.withLock { $0 } }

    static func shouldYield(processInfo: ProcessInfo = .processInfo) -> Bool {
        if isDictating { return true }
        if processInfo.isLowPowerModeEnabled { return true }
        return processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// Beobachtet den Aufnahme-Status über Observation — kein Polling, kein
    /// Main-Thread-Sprung vom Leser aus.
    @MainActor
    static func startObservingDictation() {
        let first = observing.withLock { running -> Bool in
            defer { running = true }
            return !running
        }
        guard first else { return }
        observeDictation()
    }

    @MainActor
    private static func observeDictation() {
        let phase = withObservationTracking {
            AppState.shared.recordingPhase
        } onChange: {
            // `onChange` kommt vor der Änderung; den neuen Wert im nächsten Durchlauf lesen.
            Task { @MainActor in observeDictation() }
        }
        dictationActive.withLock { $0 = phase != .idle }
    }
}
