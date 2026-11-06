import Foundation
import Observation
import os

/// Liest die Protokolle von Claude Code und Codex und trägt Token-Verbrauch,
/// Subagent-Starts und Codex-Limits in den `StatisticsStore` ein.
///
/// Leitlinie ist, dass die App davon nichts merkt:
/// - eigene serielle Queue (`.utility`, im Backfill `.background`), nie Main-Thread-I/O;
/// - kein Dauerbeobachten der Dateien: ein Lauf ~30 s nach dem Start, danach
///   alle 15 Minuten (großzügige Timer-Toleranz, im Stromsparmodus stündlich)
///   und auf Wunsch der Seite;
/// - je Datei ein Cursor, unveränderte Dateien werden nur ge-`stat`-et;
/// - gelesen wird in 1-MB-Stücken, nie eine ganze Datei;
/// - das erste Einlesen der Historie (Backfill) ist gedrosselt: Bei Diktat,
///   Stromsparmodus oder Hitze bricht es ab und plant sich neu, auf Wunsch des
///   Nutzers pausiert es. Neue Zeilen bekannter Dateien liest jeder Lauf trotzdem.
final class StatisticsLogScanner: @unchecked Sendable {
    static let shared = StatisticsLogScanner()

    /// Abhängigkeiten, in Tests ersetzbar.
    struct Dependencies {
        var sources: () -> [StatisticsLogSource] = { StatisticsLogSource.live() }
        var store: StatisticsStore = .shared
        /// Ordner für Cursor und Dedup; Standard: der Ordner des Stores.
        var stateDirectory: URL?
        /// Pro Lauf frisch geholt, damit ein Zeitzonenwechsel greift.
        var calendar: () -> Calendar = { .current }
        var isEnabled: () -> Bool = { StatisticsSettings.isEnabled() }
        /// Diktat läuft, Stromsparmodus, Hitze — dann ruht das Einlesen der Historie.
        var shouldYield: () -> Bool = { StatisticsScanThrottle.shouldYield() }
        var isLowPowerMode: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
        /// Entpacker für `.jsonl.zst`; `nil`, wenn keiner da ist.
        var decompressor: () -> StatisticsDecompressing? = { StatisticsZstdDecompressor.live() }
        var now: () -> Date = Date.init
        /// Pause zwischen zwei Dateien im Backfill.
        var backfillFileDelay: TimeInterval = 0.02
        /// Musste der Backfill Platz machen: neuer Versuch nach so vielen Sekunden.
        var yieldRetryDelay: TimeInterval = 60
        /// Im Backfill wird gesichert, wenn seit dem letzten Sichern so viel
        /// Zeit vergangen ist oder so viele Bytes gelesen wurden.
        var backfillFlushInterval: TimeInterval = 30
        var backfillFlushBytes: Int64 = 512 << 20
    }

    /// Ergebnis eines Laufs.
    enum Outcome: Equatable {
        case finished
        /// Historie unvollständig: Pause des Nutzers oder Drossel.
        case deferred
        case cancelled
        /// „Löschen…“ während des Laufs: nichts gesichert.
        case aborted
        case disabled
    }

    static let initialDelay: TimeInterval = 30
    static let interval: TimeInterval = 15 * 60
    static let lowPowerInterval: TimeInterval = 60 * 60
    static let minimumGap: TimeInterval = 60
    /// Codex-Lesestände verschwundener Threads bleiben so lange (Sekunden seit
    /// mtime), damit ein gerade komprimierter Thread nicht von vorn zählt.
    static let codexCursorGrace: TimeInterval = 30 * 24 * 3600
    /// Fehlt zstd, wird so lange nicht erneut gesucht.
    static let decompressorRetry: TimeInterval = 6 * 3600

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
        /// Letzte erfolglose Suche nach zstd.
        var decompressorMissingSince: Date?
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
        // Fortsetzen wartet nicht auf den nächsten Timer.
        if !paused { scheduleRun(after: 1) }
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
            source.setEventHandler { [weak self] in self?.timerFired() }
            timer = source
            source.resume()
        }
    }

    /// Im Stromsparmodus läuft der Timer-Lauf nur noch stündlich.
    private func timerFired() {
        if deps.isLowPowerMode() {
            let lastEnd = state.withLock { $0.lastRunEnd }
            if let lastEnd, deps.now().timeIntervalSince(lastEnd) < Self.lowPowerInterval - 120 { return }
        }
        scheduleRun(after: 0)
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
        let outcome = performScan()
        let (rerun, paused) = state.withLock { s -> (Bool, Bool) in
            s.running = false
            s.lastRunEnd = deps.now()
            let rerun = s.rerunRequested
            s.rerunRequested = false
            return (rerun, s.userPaused)
        }
        if rerun {
            scheduleRun(after: 0, force: true)
        } else if outcome == .deferred, !paused {
            // Drossel statt Warteschleife: später neu ansetzen, die Queue bleibt frei.
            scheduleRun(after: deps.yieldRetryDelay)
        }
    }

    private var isCancelled: Bool { state.withLock { $0.cancelRequested } }

    // MARK: - Ein Lauf

    /// Ein vollständiger Lauf auf der aufrufenden Queue. Intern statt privat,
    /// damit Tests ihn synchron fahren können.
    @discardableResult
    func performScan() -> Outcome {
        let files = stateFiles
        let rescan = state.withLock { s -> Bool in
            let value = s.rescanRequested
            s.rescanRequested = false
            return value
        }
        if rescan { resetForRescan(files) }
        guard deps.isEnabled() else { return .disabled }

        let calendar = deps.calendar()
        // Alles, was dieser Lauf sichert, gilt nur für diese Generation des Stores.
        let generation = deps.store.generation
        let startedAt = deps.now()
        let snapshot = deps.store.snapshotSync()
        state.withLock { s in
            if !s.userPauseLoaded {
                s.userPaused = snapshot.backfill.isPaused
                s.userPauseLoaded = true
            }
        }
        let backfillMode = rescan || snapshot.backfill.finishedAt == nil

        let persistence = files.loadCursors()
        var cursors = persistence.saved
        let dedup = files.loadDedup()
        let listed = StatisticsLogLister.list(deps.sources())

        // Verschwundene Dateien vergessen, damit die Cursor-Datei nicht wächst.
        // Codex-Threads erst nach einer Schonfrist: Codex komprimiert alte
        // Protokolle, und für einen Augenblick fehlt der Thread ganz.
        let listedKeys = Set(listed.map(\.cursorKey))
        let graceLimit = startedAt.timeIntervalSince1970 - Self.codexCursorGrace
        cursors = cursors.filter { key, cursor in
            listedKeys.contains(key) || (key.hasPrefix(StatisticsLogFile.codexKeyPrefix) && cursor.mtime > graceLimit)
        }

        // Neue Zeilen bekannter Dateien sind „inkrementell“ und laufen immer;
        // im Backfill sind Dateien ohne Lesestand Historie und unterliegen
        // Pause und Drossel. Neueste zuerst: Woche und Monat stimmen schnell.
        var incremental: [StatisticsLogFile] = []
        var history: [StatisticsLogFile] = []
        for file in listed where file.needsRead(cursors[file.cursorKey]) {
            if backfillMode, cursors[file.cursorKey] == nil { history.append(file) } else { incremental.append(file) }
        }
        history.sort { $0.mtime > $1.mtime }

        if backfillMode {
            let total = listed.count
            let done = total - incremental.count - history.count
            let now = deps.now()
            deps.store.update(ifGeneration: generation) { db in
                db.backfill.totalFiles = total
                db.backfill.processedFiles = done
                if db.backfill.startedAt == nil { db.backfill.startedAt = now }
                db.backfill.finishedAt = nil
            }
        }

        // Gemessen wird nur der inkrementelle Lauf; der Backfill dauert gewollt Minuten.
        let perfToken = backfillMode ? nil : PerfBudgets.statisticsScan.begin()
        var batch = StatisticsScanBatch(calendar: calendar)
        var run = RunCounters()
        let context = FlushContext(files: files, persistence: persistence, dedup: dedup, generation: generation)

        for file in incremental {
            if isCancelled { cancel(perfToken); return .cancelled }
            read(file, cursors: &cursors, dedup: dedup, batch: &batch, run: &run)
        }

        var outcome = Outcome.finished
        var lastFlush = deps.now()
        var bytesSinceFlush: Int64 = 0
        var processedSinceFlush = 0
        for file in history {
            if isCancelled { cancel(perfToken); return .cancelled }
            if state.withLock({ $0.userPaused }) || deps.shouldYield() {
                outcome = .deferred
                break
            }
            read(file, cursors: &cursors, dedup: dedup, batch: &batch, run: &run)
            processedSinceFlush += 1
            bytesSinceFlush += file.size
            if deps.now().timeIntervalSince(lastFlush) >= deps.backfillFlushInterval || bytesSinceFlush >= deps.backfillFlushBytes {
                let processed = processedSinceFlush
                guard flush(&batch, cursors: cursors, context, extra: { db in
                    db.backfill.processedFiles = min(db.backfill.totalFiles, db.backfill.processedFiles + processed)
                }) else { cancel(perfToken); return .aborted }
                lastFlush = deps.now()
                bytesSinceFlush = 0
                processedSinceFlush = 0
            }
            if deps.backfillFileDelay > 0 { Thread.sleep(forTimeInterval: deps.backfillFileDelay) }
        }

        let finishedAt = deps.now()
        let info = StatsScanInfo(
            finishedAt: finishedAt,
            filesRead: run.filesRead,
            duration: finishedAt.timeIntervalSince(startedAt),
            skippedCompressedFiles: run.skippedCompressed > 0 ? run.skippedCompressed : nil
        )
        let processed = processedSinceFlush
        let complete = outcome == .finished
        let ok = flush(&batch, cursors: cursors, context) { db in
            db.lastScan = info
            guard backfillMode else { return }
            if complete {
                db.backfill.processedFiles = db.backfill.totalFiles
                db.backfill.finishedAt = finishedAt
            } else {
                db.backfill.processedFiles = min(db.backfill.totalFiles, db.backfill.processedFiles + processed)
            }
        }
        if let perfToken {
            if ok { PerfBudgets.statisticsScan.end(perfToken) } else { cancel(perfToken) }
        }
        guard ok else { return .aborted }
        if complete { state.withLock { $0.backfillFinished = true } }
        logger.info("statistics_scan_done files=\(run.filesRead, privacy: .public) backfill=\(backfillMode, privacy: .public) deferred=\(!complete, privacy: .public) skippedZst=\(run.skippedCompressed, privacy: .public) failed=\(run.failed, privacy: .public) ms=\(Int(finishedAt.timeIntervalSince(startedAt) * 1000), privacy: .public)")
        return outcome
    }

    private struct RunCounters {
        var filesRead = 0
        var skippedCompressed = 0
        var failed = 0
        /// Einmal pro Lauf aufgelöst, erst wenn eine `.zst` ansteht.
        var decompressor: StatisticsDecompressing??
    }

    private struct FlushContext {
        let files: StatisticsScanStateFiles
        let persistence: StatisticsCursorPersistence
        let dedup: StatisticsDedupSet
        let generation: Int
    }

    private func read(
        _ file: StatisticsLogFile,
        cursors: inout [String: StatisticsFileCursor],
        dedup: StatisticsDedupSet,
        batch: inout StatisticsScanBatch,
        run: inout RunCounters
    ) {
        var decompressor: StatisticsDecompressing?
        if file.isCompressed {
            if run.decompressor == nil { run.decompressor = .some(resolveDecompressor()) }
            decompressor = run.decompressor ?? nil
        }
        let result = StatisticsLogFileReader.process(
            file,
            cursor: cursors[file.cursorKey],
            dedup: dedup,
            batch: &batch,
            decompressor: decompressor,
            shouldStop: { [self] in isCancelled }
        )
        switch result {
        case .read(let cursor):
            cursors[file.cursorKey] = cursor
            run.filesRead += 1
        case .skipped:
            run.skippedCompressed += 1
        case .failed:
            run.failed += 1
        }
    }

    private func resolveDecompressor() -> StatisticsDecompressing? {
        let now = deps.now()
        let missingSince = state.withLock { $0.decompressorMissingSince }
        if let missingSince, now.timeIntervalSince(missingSince) < Self.decompressorRetry { return nil }
        let found = deps.decompressor()
        state.withLock { $0.decompressorMissingSince = found == nil ? now : nil }
        if found == nil { logger.info("statistics_zstd_missing") }
        return found
    }

    private func cancel(_ token: PerformanceBudget.Token?) {
        if let token { PerfBudgets.statisticsScan.cancel(token) }
    }

    /// Schreibt einen Abschnitt: erst die Zahlen in den Store (und dort sofort
    /// auf die Platte), dann Cursor und Dedup. Stürzt die App genau dazwischen
    /// ab, zählt ein Abschnitt im schlimmsten Fall doppelt — verloren geht nichts.
    /// `false`: Seit dem Start des Laufs wurde gelöscht („Löschen…“); der Lauf
    /// bricht ab und sichert nichts mehr (auch keinen neu angelegten Ordner).
    private func flush(
        _ batch: inout StatisticsScanBatch,
        cursors: [String: StatisticsFileCursor],
        _ context: FlushContext,
        extra: @escaping @Sendable (inout StatsDatabase) -> Void
    ) -> Bool {
        let snapshot = batch
        deps.store.update(ifGeneration: context.generation) { db in
            snapshot.apply(to: &db)
            extra(&db)
        }
        deps.store.flush()
        let current = deps.store.performIfCurrent(context.generation) { [logger] in
            do {
                try context.persistence.save(cursors)
                if context.dedup.hasChanges { try context.files.saveDedup(context.dedup) }
            } catch {
                logger.error("statistics_scan_state_write_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        guard current else {
            logger.info("statistics_scan_aborted reason=state_removed")
            return false
        }
        batch.clear()
        return true
    }

    private func resetForRescan(_ files: StatisticsScanStateFiles) {
        files.removeAll()
        let now = deps.now()
        deps.store.update { db in
            for key in Array(db.days.keys) { db.days[key]?.clearScanned() }
            let paused = db.backfill.isPaused
            db.backfill = StatsBackfillState()
            db.backfill.startedAt = now
            db.backfill.isPaused = paused
        }
        logger.info("statistics_rescan_all")
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
