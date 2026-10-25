import Darwin
import Foundation

struct AgentResourceSessionDescriptor: Equatable, Hashable {
    var id: UUID
    var projectName: String
    var projectPath: String
    var title: String
    var provider: AgentProvider
    var rootProcessID: Int32?
    /// Session-Art fuers Icon im Resource-Popover (Terminal vs. Provider-Logo).
    /// Optional mit Default, damit bestehende Aufrufer/Tests unveraendert bauen.
    var kind: AgentSessionKind? = nil
}

struct AgentResourceProcessSample: Equatable {
    var pid: Int32
    var parentPID: Int32
    var cpuPercent: Double
    var memoryBytes: Int64
    var command: String
}

struct AgentResourceProcessSnapshot: Identifiable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var command: String
    var cpuPercent: Double
    var memoryBytes: Int64
}

struct AgentResourceSessionSnapshot: Identifiable, Equatable {
    var id: UUID
    var title: String
    var provider: AgentProvider
    var rootProcessID: Int32
    var cpuPercent: Double
    var memoryBytes: Int64
    var processes: [AgentResourceProcessSnapshot]
    /// Session-Art (siehe Descriptor) — `nil` wird als `.chat` interpretiert.
    var kind: AgentSessionKind? = nil
}

struct AgentResourceProjectSnapshot: Identifiable, Equatable {
    var id: String { projectPath }
    var projectName: String
    var projectPath: String
    var cpuPercent: Double
    var memoryBytes: Int64
    var sessions: [AgentResourceSessionSnapshot]
}

struct AgentResourceSnapshot: Equatable {
    var generatedAt: Date
    var runningSessionCount: Int
    var totalCPUPercent: Double
    var totalMemoryBytes: Int64
    var totalSystemMemoryBytes: Int64?
    var projects: [AgentResourceProjectSnapshot]

    static let empty = AgentResourceSnapshot(
        generatedAt: Date(),
        runningSessionCount: 0,
        totalCPUPercent: 0,
        totalMemoryBytes: 0,
        totalSystemMemoryBytes: nil,
        projects: []
    )

    var ramSharePercent: Double? {
        guard let totalSystemMemoryBytes, totalSystemMemoryBytes > 0 else { return nil }
        return (Double(totalMemoryBytes) / Double(totalSystemMemoryBytes)) * 100
    }
}

/// Takt- und Entprellregeln des Ressourcen-Badges (LR-AU-003) — pur und
/// testbar.
enum AgentResourceRefreshPolicy {
    /// Badge-Betrieb (Popover zu): Zähler + Summe brauchen keine 10-s-Auflösung.
    static let badgeInterval: Duration = .seconds(30)
    /// Popover offen: der User schaut aktiv hin.
    static let popoverInterval: Duration = .seconds(2)
    /// Wartezeit, bis eine Änderung der Chat-Prozesse einen Refresh auslöst.
    static let changeDebounce: Duration = .seconds(1)

    /// Nur was die Messung ändert: Session-ID + Wurzel-PID. Titel-, Status- oder
    /// Projektwechsel verändern den Schlüssel nicht und lösen keine Messung aus.
    static func processKey(_ descriptors: [AgentResourceSessionDescriptor]) -> String {
        descriptors
            .map { "\($0.id.uuidString):\($0.rootProcessID ?? 0)" }
            .sorted()
            .joined(separator: ",")
    }
}

struct AgentResourceMonitor {
    /// Bekommt die Wurzel-PIDs der Chats und liefert nur deren Prozessbäume.
    var processSamples: ([Int32]) -> [AgentResourceProcessSample] = { Self.currentProcessSamples(rootPIDs: $0) }
    var totalMemoryBytes: () -> Int64? = Self.currentTotalMemoryBytes

    func snapshot(for descriptors: [AgentResourceSessionDescriptor]) -> AgentResourceSnapshot {
        let rootPIDs = descriptors.compactMap(\.rootProcessID)
        // Ohne laufende Chats gibt es nichts zu messen.
        let samples = rootPIDs.isEmpty ? [] : processSamples(rootPIDs)
        let byPID = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        let childrenByParent = Dictionary(grouping: samples, by: \.parentPID)

        var groupedSessions: [String: (projectName: String, projectPath: String, sessions: [AgentResourceSessionSnapshot])] = [:]

        for descriptor in descriptors {
            guard let rootPID = descriptor.rootProcessID, byPID[rootPID] != nil else { continue }
            let processIDs = processTree(rootPID: rootPID, childrenByParent: childrenByParent)
            let processSnapshots = processIDs.compactMap { byPID[$0] }.map { sample in
                AgentResourceProcessSnapshot(
                    pid: sample.pid,
                    command: sample.command,
                    cpuPercent: sample.cpuPercent,
                    memoryBytes: sample.memoryBytes
                )
            }
            guard !processSnapshots.isEmpty else { continue }

            let session = AgentResourceSessionSnapshot(
                id: descriptor.id,
                title: descriptor.title,
                provider: descriptor.provider,
                rootProcessID: rootPID,
                cpuPercent: processSnapshots.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: processSnapshots.reduce(0) { $0 + $1.memoryBytes },
                processes: processSnapshots.sorted { $0.memoryBytes > $1.memoryBytes },
                kind: descriptor.kind
            )

            var group = groupedSessions[descriptor.projectPath]
                ?? (descriptor.projectName, descriptor.projectPath, [])
            group.sessions.append(session)
            groupedSessions[descriptor.projectPath] = group
        }

        let projects: [AgentResourceProjectSnapshot] = groupedSessions.values.map { group in
            let sessions = group.sessions.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return AgentResourceProjectSnapshot(
                projectName: group.projectName,
                projectPath: group.projectPath,
                cpuPercent: sessions.reduce(0) { $0 + $1.cpuPercent },
                memoryBytes: sessions.reduce(0) { $0 + $1.memoryBytes },
                sessions: sessions
            )
        }
        .sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }

        return AgentResourceSnapshot(
            generatedAt: Date(),
            runningSessionCount: projects.reduce(0) { $0 + $1.sessions.count },
            totalCPUPercent: projects.reduce(0) { $0 + $1.cpuPercent },
            totalMemoryBytes: projects.reduce(0) { $0 + $1.memoryBytes },
            totalSystemMemoryBytes: totalMemoryBytes(),
            projects: projects
        )
    }

    private func processTree(
        rootPID: Int32,
        childrenByParent: [Int32: [AgentResourceProcessSample]]
    ) -> [Int32] {
        var result: [Int32] = []
        var seen: Set<Int32> = []
        var queue = [rootPID]

        while let pid = queue.first {
            queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: childrenByParent[pid, default: []].map(\.pid))
        }

        return result
    }

    /// Wartezeit für die erste Messung eines Prozesses: CPU-Prozente brauchen
    /// zwei Zeitpunkte. Danach rechnet jeder Refresh gegen den vorigen.
    static let baselineInterval: TimeInterval = 0.3

    /// Prozesse der Chats samt Kindern, direkt über libproc gelesen. Früher
    /// lief hier `/bin/ps`; das schrieb in einer App mit `LANG=de_DE` die CPU
    /// mit Komma, der Parser verwarf jede Zeile und das Badge zeigte 0.
    static func currentProcessSamples(
        rootPIDs: [Int32],
        read: ([Int32]) -> [AgentResourceProcessReading] = { readProcesses(rootPIDs: $0) },
        tracker: AgentResourceCPUTracker = .shared,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> [AgentResourceProcessSample] {
        var readings = read(rootPIDs)
        if tracker.needsBaseline(readings.map(\.pid)) {
            tracker.update(readings, at: now())
            wait(baselineInterval)
            readings = read(rootPIDs)
        }
        let percents = tracker.update(readings, at: now())
        return readings.map { reading in
            AgentResourceProcessSample(
                pid: reading.pid,
                parentPID: reading.parentPID,
                cpuPercent: percents[reading.pid] ?? 0,
                memoryBytes: reading.memoryBytes,
                command: reading.command
            )
        }
    }

    /// Wurzeln und alle Nachfahren mit Rohwerten. Die Wurzeln bekommen
    /// `parentPID` 0: Der Baum wird nur von ihnen abwärts aufgebaut.
    static func readProcesses(rootPIDs: [Int32]) -> [AgentResourceProcessReading] {
        var result: [AgentResourceProcessReading] = []
        var seen = Set<Int32>()
        var queue = rootPIDs.map { (pid: $0, parent: Int32(0)) }
        while !queue.isEmpty {
            let (pid, parent) = queue.removeFirst()
            guard pid > 0, seen.insert(pid).inserted, let reading = readProcess(pid, parentPID: parent) else { continue }
            result.append(reading)
            queue.append(contentsOf: childPIDs(of: pid).map { (pid: $0, parent: pid) })
        }
        return result
    }

    /// CPU-Zeit und Speicher wie in der Aktivitätsanzeige (`phys_footprint`).
    /// `nil`, wenn der Prozess schon weg ist.
    static func readProcess(_ pid: Int32, parentPID: Int32) -> AgentResourceProcessReading? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else { return nil }
        return AgentResourceProcessReading(
            pid: pid,
            parentPID: parentPID,
            cpuTimeNanos: machTimeToNanos(usage.ri_user_time &+ usage.ri_system_time),
            memoryBytes: Int64(clamping: usage.ri_phys_footprint),
            command: executablePath(of: pid)
        )
    }

    /// `ri_user_time`/`ri_system_time` zählen auf Apple Silicon in Mach-Ticks,
    /// nicht in Nanosekunden.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func machTimeToNanos(_ ticks: UInt64) -> UInt64 {
        guard timebase.denom > 0 else { return ticks }
        return ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(timebase.denom)
    }

    private static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(cString: buffer)
        }
        return "pid \(pid)"
    }

    private static func childPIDs(of pid: Int32) -> [Int32] {
        var capacity = 64
        while true {
            var buffer = [Int32](repeating: 0, count: capacity)
            let bytes = buffer.withUnsafeMutableBytes {
                proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0 else { return [] }
            // libproc liefert je nach Version Anzahl oder Bytes — beides abfangen.
            let count = bytes > Int32(capacity) ? Int(bytes) / MemoryLayout<Int32>.stride : Int(bytes)
            if count >= capacity { capacity *= 4; continue }
            return buffer.prefix(count).filter { $0 > 0 }
        }
    }

    static func currentTotalMemoryBytes() -> Int64? {
        Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Rohwerte eines Prozesses: CPU-Zeit seit Prozessstart und Speicher.
struct AgentResourceProcessReading: Equatable {
    var pid: Int32
    var parentPID: Int32
    var cpuTimeNanos: UInt64
    var memoryBytes: Int64
    var command: String
}

/// Merkt sich die CPU-Zeit jedes Prozesses vom letzten Refresh. Daraus wird
/// die Auslastung im Intervall seitdem, also ein echter aktueller Wert.
/// 100 % entsprechen einem voll ausgelasteten Kern, wie in der Aktivitätsanzeige.
final class AgentResourceCPUTracker: @unchecked Sendable {
    static let shared = AgentResourceCPUTracker()

    private struct Mark {
        var cpuTimeNanos: UInt64
        var at: UInt64
    }

    private let lock = NSLock()
    private var marks: [Int32: Mark] = [:]

    /// Fehlt für einen der Prozesse ein früherer Wert?
    func needsBaseline(_ pids: [Int32]) -> Bool {
        lock.withLock { pids.contains { marks[$0] == nil } }
    }

    /// Prozent seit dem letzten Wert je PID; ohne früheren Wert keiner.
    /// Vergisst Prozesse, die nicht mehr gemeldet werden.
    @discardableResult
    func update(_ readings: [AgentResourceProcessReading], at now: UInt64) -> [Int32: Double] {
        lock.withLock {
            var percents: [Int32: Double] = [:]
            var next: [Int32: Mark] = [:]
            for reading in readings {
                // Weniger CPU-Zeit als zuvor: Die PID gehört einem neuen Prozess.
                if let mark = marks[reading.pid], now > mark.at, reading.cpuTimeNanos >= mark.cpuTimeNanos {
                    percents[reading.pid] = Double(reading.cpuTimeNanos - mark.cpuTimeNanos) / Double(now - mark.at) * 100
                }
                next[reading.pid] = Mark(cpuTimeNanos: reading.cpuTimeNanos, at: now)
            }
            marks = next
            return percents
        }
    }
}
