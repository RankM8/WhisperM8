import Foundation

struct AgentResourceSessionDescriptor: Equatable, Hashable {
    var id: UUID
    var projectName: String
    var projectPath: String
    var title: String
    var provider: AgentProvider
    var rootProcessID: Int32?
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

struct AgentResourceMonitor {
    var processSamples: () -> [AgentResourceProcessSample] = Self.currentProcessSamples
    var totalMemoryBytes: () -> Int64? = Self.currentTotalMemoryBytes

    func snapshot(for descriptors: [AgentResourceSessionDescriptor]) -> AgentResourceSnapshot {
        let samples = processSamples()
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
                processes: processSnapshots.sorted { $0.memoryBytes > $1.memoryBytes }
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

    static func parseProcessSamples(_ output: String) -> [AgentResourceProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let parentPID = Int32(parts[1]),
                  let cpuPercent = Double(parts[2]),
                  let rssKilobytes = Int64(parts[3])
            else {
                return nil
            }
            return AgentResourceProcessSample(
                pid: pid,
                parentPID: parentPID,
                cpuPercent: cpuPercent,
                memoryBytes: rssKilobytes * 1024,
                command: String(parts[4])
            )
        }
    }

    static func currentProcessSamples() -> [AgentResourceProcessSample] {
        let output = runProcess(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,%cpu=,rss=,comm="]
        )
        return parseProcessSamples(output)
    }

    /// hw.memsize ändert sich zur Laufzeit nie — einmal lesen, dann aus dem
    /// Cache (P2 S5: halbiert die Forks pro Refresh).
    private static let cachedTotalMemoryBytes: Int64? = {
        let output = runProcess(executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"])
        return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }()

    static func currentTotalMemoryBytes() -> Int64? {
        cachedTotalMemoryBytes
    }

    /// Forkt einen Subprocess und sammelt stdout. Wichtig: erst stdout
    /// vollstaendig lesen DANN `waitUntilExit()` — sonst kann der Child
    /// blockieren weil der Pipe-Puffer (~64 KB) voll laeuft und auf einen
    /// Leser wartet. Symptom des alten Bugs: ps-Children blieben als
    /// "sleeping" Prozesse stehen und unser Parent-Thread sass in
    /// waitUntilExit fest. Plus: stderr-Pipe leeren damit auch dort kein
    /// Block entsteht.
    private static func runProcess(executable: String, arguments: [String]) -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ""
        }

        // stdout vor waitUntilExit lesen — Pipe-Puffer waere sonst der
        // Deadlock-Risiko. `readDataToEndOfFile` blockiert bis der Child
        // seinen stdout schliesst, was bei Exit passiert.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        // stderr leer-lesen damit der Child nicht in einer write() haengt
        // (rare, aber moeglich bei Diagnostics).
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}
