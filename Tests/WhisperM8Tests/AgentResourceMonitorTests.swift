import Foundation
import XCTest
@testable import WhisperM8

final class AgentResourceMonitorTests: XCTestCase {
    func testAgentResourceMonitorAggregatesSyntheticProcessTree() {
        let sessionID = UUID()
        let monitor = AgentResourceMonitor(
            processSamples: { _ in
                [
                    AgentResourceProcessSample(pid: 10, parentPID: 1, cpuPercent: 0.6, memoryBytes: 100_000, command: "codex"),
                    AgentResourceProcessSample(pid: 11, parentPID: 10, cpuPercent: 0.4, memoryBytes: 50_000, command: "node"),
                    AgentResourceProcessSample(pid: 99, parentPID: 1, cpuPercent: 9.0, memoryBytes: 900_000, command: "other")
                ]
            },
            totalMemoryBytes: { 1_000_000 }
        )

        let snapshot = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(
                id: sessionID,
                projectName: "Repo",
                projectPath: "/tmp/repo",
                title: "Codex Chat",
                provider: .codex,
                rootProcessID: 10
            )
        ])

        XCTAssertEqual(snapshot.runningSessionCount, 1)
        XCTAssertEqual(snapshot.totalCPUPercent, 1.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.totalMemoryBytes, 150_000)
        XCTAssertEqual(snapshot.projects.first?.sessions.first?.processes.map(\.pid), [10, 11])
        XCTAssertEqual(try XCTUnwrap(snapshot.ramSharePercent), 15.0, accuracy: 0.001)
    }

    func testAgentResourceMonitorOmitsRamShareWithoutTotalMemory() {
        let monitor = AgentResourceMonitor(
            processSamples: { _ in
                [AgentResourceProcessSample(pid: 10, parentPID: 1, cpuPercent: 0.1, memoryBytes: 100_000, command: "codex")]
            },
            totalMemoryBytes: { nil }
        )

        let snapshot = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(
                id: UUID(),
                projectName: "Repo",
                projectPath: "/tmp/repo",
                title: "Codex Chat",
                provider: .codex,
                rootProcessID: 10
            )
        ])

        XCTAssertNil(snapshot.ramSharePercent)
    }

    func testAgentResourceMonitorIgnoresDescriptorsWithoutRunningProcess() {
        let monitor = AgentResourceMonitor(
            processSamples: { _ in
                [AgentResourceProcessSample(pid: 10, parentPID: 1, cpuPercent: 0.1, memoryBytes: 100_000, command: "codex")]
            },
            totalMemoryBytes: { 1_000_000 }
        )

        let snapshot = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(
                id: UUID(),
                projectName: "Repo",
                projectPath: "/tmp/repo",
                title: "Closed Chat",
                provider: .codex,
                rootProcessID: nil
            )
        ])

        XCTAssertEqual(snapshot.runningSessionCount, 0)
        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    // MARK: - libproc statt ps

    private func reading(_ pid: Int32, parent: Int32 = 0, cpu: UInt64, memory: Int64 = 1_000) -> AgentResourceProcessReading {
        AgentResourceProcessReading(pid: pid, parentPID: parent, cpuTimeNanos: cpu, memoryBytes: memory, command: "claude")
    }

    /// Eine Sekunde Wandzeit, eine halbe Sekunde CPU = 50 %; zwei Kerne voll = 200 %.
    func testCPUTrackerComputesPercentOverInterval() {
        let tracker = AgentResourceCPUTracker()
        XCTAssertTrue(tracker.needsBaseline([10]))
        XCTAssertEqual(tracker.update([reading(10, cpu: 1_000_000_000), reading(11, cpu: 0)], at: 5_000_000_000), [:])
        XCTAssertFalse(tracker.needsBaseline([10, 11]))
        let percents = tracker.update(
            [reading(10, cpu: 1_500_000_000), reading(11, cpu: 2_000_000_000)], at: 6_000_000_000)
        XCTAssertEqual(try XCTUnwrap(percents[10]), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(percents[11]), 200, accuracy: 0.001)
    }

    func testCPUTrackerTreatsReusedPIDAsNewProcessAndForgetsGoneOnes() {
        let tracker = AgentResourceCPUTracker()
        tracker.update([reading(10, cpu: 9_000_000_000), reading(11, cpu: 1)], at: 1_000)
        // PID 10 gehört jetzt einem neuen Prozess mit weniger CPU-Zeit.
        XCTAssertNil(tracker.update([reading(10, cpu: 5)], at: 2_000)[10])
        XCTAssertTrue(tracker.needsBaseline([11]))
    }

    func testFirstSampleWaitsForBaselineThenReportsPercent() {
        let tracker = AgentResourceCPUTracker()
        var clock: UInt64 = 0
        var cpu: UInt64 = 0
        var waits: [TimeInterval] = []
        let read: ([Int32]) -> [AgentResourceProcessReading] = { roots in
            XCTAssertEqual(roots, [10])
            return [self.reading(10, cpu: cpu, memory: 4_096), self.reading(11, parent: 10, cpu: cpu)]
        }
        let samples = AgentResourceMonitor.currentProcessSamples(
            rootPIDs: [10], read: read, tracker: tracker, now: { clock },
            wait: { seconds in
                waits.append(seconds)
                clock += 1_000_000_000
                cpu += 250_000_000
            })
        XCTAssertEqual(waits, [AgentResourceMonitor.baselineInterval])
        XCTAssertEqual(samples.map(\.pid), [10, 11])
        XCTAssertEqual(samples.first?.parentPID, 0)
        XCTAssertEqual(samples.last?.parentPID, 10)
        XCTAssertEqual(samples.first?.memoryBytes, 4_096)
        XCTAssertEqual(try XCTUnwrap(samples.first?.cpuPercent), 25, accuracy: 0.001)

        // Zweiter Refresh rechnet gegen den ersten, ohne zu warten.
        clock += 2_000_000_000
        cpu += 2_000_000_000
        let next = AgentResourceMonitor.currentProcessSamples(
            rootPIDs: [10], read: read, tracker: tracker, now: { clock }, wait: { waits.append($0) })
        XCTAssertEqual(waits.count, 1)
        XCTAssertEqual(try XCTUnwrap(next.first?.cpuPercent), 100, accuracy: 0.001)
    }

    func testMachTimeConversionIsMonotonic() {
        XCTAssertEqual(AgentResourceMonitor.machTimeToNanos(0), 0)
        XCTAssertGreaterThan(AgentResourceMonitor.machTimeToNanos(1_000_000), 0)
    }

    func testSnapshotWithoutRunningChatsMeasuresNothing() {
        var asked = 0
        let monitor = AgentResourceMonitor(processSamples: { _ in asked += 1; return [] }, totalMemoryBytes: { nil })
        _ = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(id: UUID(), projectName: "R", projectPath: "/r", title: "t", provider: .codex, rootProcessID: nil)
        ])
        XCTAssertEqual(asked, 0)
    }

    func testSnapshotPassesRootPIDsToSampler() {
        var received: [Int32] = []
        let monitor = AgentResourceMonitor(processSamples: { received = $0; return [] }, totalMemoryBytes: { nil })
        _ = monitor.snapshot(for: [
            AgentResourceSessionDescriptor(id: UUID(), projectName: "R", projectPath: "/r", title: "a", provider: .codex, rootProcessID: 42),
            AgentResourceSessionDescriptor(id: UUID(), projectName: "R", projectPath: "/r", title: "b", provider: .codex, rootProcessID: nil)
        ])
        XCTAssertEqual(received, [42])
    }

    /// Echter Prozessbaum: eigener Prozess als Wurzel, ein `sleep` als Kind.
    func testReadProcessesFindsRealChildWithMemoryAndPath() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let readings = AgentResourceMonitor.readProcesses(rootPIDs: [getpid()])
        let me = try XCTUnwrap(readings.first { $0.pid == getpid() })
        XCTAssertGreaterThan(me.memoryBytes, 0)
        XCTAssertGreaterThan(me.cpuTimeNanos, 0)
        let sleeper = try XCTUnwrap(readings.first { $0.pid == child.processIdentifier }, "readings=\(readings.map(\.pid))")
        XCTAssertEqual(sleeper.parentPID, getpid())
        XCTAssertEqual(sleeper.command, "/bin/sleep")
        XCTAssertNil(AgentResourceMonitor.readProcess(999_999, parentPID: 0))
    }

    func testProcessKeyIgnoresTitleChangesAndOrder() {
        let id1 = UUID(), id2 = UUID()
        func d(_ id: UUID, _ title: String, _ pid: Int32?) -> AgentResourceSessionDescriptor {
            AgentResourceSessionDescriptor(id: id, projectName: "R", projectPath: "/r", title: title, provider: .codex, rootProcessID: pid)
        }
        let base = AgentResourceRefreshPolicy.processKey([d(id1, "alt", 1), d(id2, "x", 2)])
        XCTAssertEqual(base, AgentResourceRefreshPolicy.processKey([d(id2, "neu", 2), d(id1, "anders", 1)]))
        XCTAssertNotEqual(base, AgentResourceRefreshPolicy.processKey([d(id1, "alt", 1), d(id2, "x", 3)]))
    }

    func testBadgeIntervalIsThirtySeconds() {
        XCTAssertEqual(AgentResourceRefreshPolicy.badgeInterval, .seconds(30))
        XCTAssertGreaterThan(AgentResourceRefreshPolicy.changeDebounce, .zero)
    }
}
