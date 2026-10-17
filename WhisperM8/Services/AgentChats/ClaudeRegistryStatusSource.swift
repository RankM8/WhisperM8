import CoreServices
import Foundation
import os

/// Beobachtet Claudes Session-Registry aller Konten
/// (`<config-dir>/sessions/<pid>.json`) und meldet jede Änderung an den
/// `AgentSessionStatusCoordinator` (Plan claude-status-aus-registry.md, S2).
///
/// FSEvents auf genau die `sessions`-Ordner (wenige, kleine Dateien, nur bei
/// Statuswechseln geschrieben), Lesen und Parsen auf der FSEvents-Queue —
/// der MainActor bekommt nur fertige Records. Ein seltener Voll-Scan fängt
/// verpasste Events und neu angelegte Profile ab.
@MainActor
final class ClaudeRegistryStatusSource {
    static let shared = ClaudeRegistryStatusSource()

    /// Änderung eines lebenden Eintrags.
    var onRecord: ((ClaudeSessionRecord) -> Void)?
    /// Eintrag verschwunden (Prozess beendet) — der zuletzt bekannte Stand,
    /// damit der Empfänger die PID prüfen kann: beim Resume leben kurz zwei
    /// Prozesse mit derselben Session-ID.
    var onRemoved: ((ClaudeSessionRecord) -> Void)?

    private let rootsProvider: () -> [ClaudeSessionRegistry.Root]
    private let isAlive: ClaudeSessionRegistry.LivenessCheck
    private let rescanInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.whisperm8.app.claude-registry", qos: .utility)

    private var stream: FSEventStreamRef?
    private var watchedRoots: [ClaudeSessionRegistry.Root] = [] {
        didSet {
            let map = Dictionary(watchedRoots.map { ($0.url.path, $0.profileName) },
                                 uniquingKeysWith: { first, _ in first })
            directoryProfiles.withLock { $0 = map }
        }
    }
    /// Ordner → Profil, lesbar von der FSEvents-Queue.
    nonisolated private let directoryProfiles = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private var rescanTask: Task<Void, Never>?
    /// Letzter gemeldeter Stand je PID — Basis für Diff und Entfernen.
    private(set) var recordsByPID: [Int32: ClaudeSessionRecord] = [:]
    /// Wann ein Datei-Ereignis eine PID zuletzt angefasst hat. Ein Voll-Scan,
    /// der davor begann, darf diese PID weder überschreiben noch entfernen —
    /// auch nach einem Löschen nicht (Grabstein): sonst holte ein Scan, der
    /// die Datei kurz vor dem Prozessende noch las, den toten Eintrag zurück.
    private var eventTouchedAt: [Int32: Date] = [:]
    var now: () -> Date = { Date() }

    init(
        rootsProvider: @escaping () -> [ClaudeSessionRegistry.Root] = { ClaudeSessionRegistry.roots() },
        isAlive: @escaping ClaudeSessionRegistry.LivenessCheck = ClaudeSessionRegistry.isProcessAlive,
        rescanInterval: TimeInterval = 10
    ) {
        self.rootsProvider = rootsProvider
        self.isAlive = isAlive
        self.rescanInterval = rescanInterval
    }

    var isRunning: Bool { rescanTask != nil }

    /// Aktueller Eintrag zu Claudes Session-ID (z. B. direkt nach der Bindung).
    func record(forExternalSessionID id: String) -> ClaudeSessionRecord? {
        ClaudeSessionRegistry.indexBySessionID(Array(recordsByPID.values))[id]
    }

    func start() {
        guard rescanTask == nil else { return }
        rescanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.rescan()
                guard let interval = self?.rescanInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        Logger.agentPerformance.info("claude_registry_source_started")
    }

    func stop() {
        rescanTask?.cancel()
        rescanTask = nil
        stopStream()
        recordsByPID = [:]
        eventTouchedAt = [:]
    }

    // MARK: - Voll-Scan (Start + Sicherheitsnetz)

    func rescan() async {
        let roots = rootsProvider()
        if roots != watchedRoots { restartStream(roots: roots) }
        let isAlive = self.isAlive
        let started = now()
        let records = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: ClaudeSessionRegistry.scan(roots: roots, isAlive: isAlive))
            }
        }
        let elapsedMs = now().timeIntervalSince(started) * 1000
        if elapsedMs > 50 {
            Logger.agentPerformance.warning(
                "claude_registry_scan_slow ms=\(Int(elapsedMs), privacy: .public) files=\(records.count, privacy: .public)")
        }
        apply(scanned: records, startedAt: started)
    }

    /// Pur bis auf die Callbacks: gleicht einen Voll-Scan mit dem bekannten
    /// Stand ab und meldet nur echte Änderungen.
    func apply(scanned records: [ClaudeSessionRecord], startedAt: Date = .distantPast) {
        let fresh = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { _, new in new })
        // Ein Datei-Ereignis nach Scan-Beginn ist neuer als der Scan.
        let touchedLater = { (pid: Int32) in (self.eventTouchedAt[pid] ?? .distantPast) > startedAt }
        for (pid, old) in recordsByPID where fresh[pid] == nil && !touchedLater(pid) {
            recordsByPID[pid] = nil
            eventTouchedAt[pid] = nil
            onRemoved?(old)
        }
        for (pid, record) in fresh where recordsByPID[pid] != record && !touchedLater(pid) {
            recordsByPID[pid] = record
            onRecord?(record)
        }
        // Ereignisse vor diesem Scan kann kein späterer Scan mehr überholen.
        eventTouchedAt = eventTouchedAt.filter { $0.value > startedAt }
    }

    /// Einzelne Datei geändert/gelöscht (FSEvents).
    func apply(pid: Int32, record: ClaudeSessionRecord?) {
        eventTouchedAt[pid] = now()
        if let record {
            guard recordsByPID[pid] != record else { return }
            recordsByPID[pid] = record
            onRecord?(record)
        } else if let old = recordsByPID.removeValue(forKey: pid) {
            onRemoved?(old)
        }
    }

    // MARK: - FSEvents

    private func restartStream(roots: [ClaudeSessionRegistry.Root]) {
        stopStream()
        watchedRoots = roots
        // Nur existierende Ordner: ein Profil ohne laufende Session hat noch
        // keinen `sessions`-Ordner; der Voll-Scan nimmt ihn später auf.
        let paths = roots.map(\.url.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info,
                  let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else { return }
            let source = Unmanaged<ClaudeRegistryStatusSource>.fromOpaque(info).takeUnretainedValue()
            source.handleEventsOffMain(paths: paths)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Logger.agentPerformance.error("claude_registry_fsevents_start_failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Läuft auf `queue`: geänderte Dateien lesen, dann gebündelt auf den
    /// MainActor. Eine gerade beschriebene, unlesbare Datei ist KEIN Ende —
    /// nur eine fehlende Datei oder ein toter Prozess.
    nonisolated private func handleEventsOffMain(paths: [String]) {
        let profiles = directoryProfiles.withLock { $0 }
        var updates: [(Int32, ClaudeSessionRecord?)] = []
        var seen = Set<Int32>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let pid = ClaudeSessionRegistry.pid(fromFileName: url.lastPathComponent),
                  let profile = profiles[url.deletingLastPathComponent().path],
                  seen.insert(pid).inserted else { continue }
            switch Self.readChange(fileURL: url, profileName: profile, isAlive: isAlive) {
            case .record(let record): updates.append((pid, record))
            case .removed: updates.append((pid, nil))
            case .unreadable: continue
            }
        }
        guard !updates.isEmpty else { return }
        // `DispatchQueue.main` statt `Task { @MainActor }`: nur so ist die
        // Reihenfolge zweier schneller Schreibvorgänge derselben Datei
        // garantiert (busy → idle darf nicht als idle → busy ankommen).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for (pid, record) in updates { self?.apply(pid: pid, record: record) }
            }
        }
    }

    enum FileChange: Equatable {
        case record(ClaudeSessionRecord)
        case removed
        case unreadable
    }

    nonisolated static func readChange(
        fileURL: URL,
        profileName: String,
        isAlive: ClaudeSessionRegistry.LivenessCheck
    ) -> FileChange {
        guard let data = try? Data(contentsOf: fileURL) else {
            return FileManager.default.fileExists(atPath: fileURL.path) ? .unreadable : .removed
        }
        guard let record = ClaudeSessionRegistry.parse(data: data, profileName: profileName) else {
            return .unreadable
        }
        return isAlive(record.pid, record.procStart) ? .record(record) : .removed
    }
}
