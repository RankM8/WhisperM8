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

    /// Endet mit der Quelle (`deinit` der Subscription), auch ohne `stop()`.
    private var subscription: FSEventsSubscription?
    /// Die Ordner, die der laufende Stream tatsächlich beobachtet.
    private(set) var watchedPaths: [String] = []
    private var watchedRoots: [ClaudeSessionRegistry.Root] = [] {
        didSet {
            let map = Self.directoryProfileMap(for: watchedRoots)
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

    /// Alle bekannten Einträge zu einer Session-ID, je Prozess einer.
    func records(forExternalSessionID id: String) -> [ClaudeSessionRecord] {
        recordsByPID.values.filter { $0.sessionID.caseInsensitiveCompare(id) == .orderedSame }
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
        watchedRoots = []
        watchedPaths = []
        recordsByPID = [:]
        eventTouchedAt = [:]
    }

    // MARK: - Voll-Scan (Start + Sicherheitsnetz)

    func rescan() async {
        let roots = rootsProvider()
        // Auch neu: ein `sessions`-Ordner, den es beim letzten Start des
        // Streams noch nicht gab (erste Session eines Kontos) — sonst kämen
        // dessen Wechsel nur im Takt des Voll-Scans.
        if roots != watchedRoots || Self.existingPaths(of: roots) != watchedPaths {
            restartStream(roots: roots)
        }
        let isAlive = self.isAlive
        let started = now()
        // Gemessen wird nur der Scan selbst auf der Queue. Früher lief die Uhr
        // ab hier bis zur Rückkehr auf den MainActor: Beim App-Start zählte
        // `claude_registry_scan_slow` so den Stau des Main Threads mit
        // (Testlauf 13.11.2026: 460–490 ms bei 1–2 Dateien, nur beim Start).
        let (records, scanSeconds) = await withCheckedContinuation { continuation in
            queue.async {
                let clock = ContinuousClock()
                let begin = clock.now
                let records = ClaudeSessionRegistry.scan(roots: roots, isAlive: isAlive)
                let elapsed = clock.now - begin
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                continuation.resume(returning: (records, seconds))
            }
        }
        let elapsedMs = scanSeconds * 1000
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
        // keinen `sessions`-Ordner; `rescan` startet neu, sobald es ihn gibt.
        let paths = Self.existingPaths(of: roots)
        watchedPaths = paths
        guard !paths.isEmpty else { return }

        guard let subscription = FSEventsSubscription(
            paths: paths,
            latency: 0.05,
            flags: FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents),
            queue: queue,
            handler: { [weak self] paths, _ in self?.handleEventsOffMain(paths: paths) }
        ) else {
            Logger.agentPerformance.error("claude_registry_fsevents_start_failed")
            return
        }
        self.subscription = subscription
    }

    nonisolated static func existingPaths(of roots: [ClaudeSessionRegistry.Root]) -> [String] {
        roots.map(\.url.path).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func stopStream() {
        subscription?.cancel()
        subscription = nil
    }

    /// Ordner → Profil. FSEvents liefert KANONISCHE Pfade (Symlinks und
    /// `/var` → `/private/var` aufgelöst); deshalb steht jeder Ordner unter
    /// Original- UND realpath-Schlüssel (LR-AK-038).
    nonisolated static func directoryProfileMap(for roots: [ClaudeSessionRegistry.Root]) -> [String: String] {
        var map: [String: String] = [:]
        for root in roots {
            for key in [root.url.path, canonicalPath(root.url.path)] where map[key] == nil {
                map[key] = root.profileName
            }
        }
        return map
    }

    /// `realpath(3)`; bei Fehler (Ordner fehlt) der Eingabepfad.
    nonisolated static func canonicalPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// Profil zu einem Event-Ordner: erst exakt, dann kanonisch.
    nonisolated static func profile(forEventDirectory directory: String, in map: [String: String]) -> String? {
        map[directory] ?? map[canonicalPath(directory)]
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
                  let profile = Self.profile(forEventDirectory: url.deletingLastPathComponent().path, in: profiles),
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
