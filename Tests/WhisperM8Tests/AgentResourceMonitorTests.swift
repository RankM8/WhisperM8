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

    // MARK: - LR-AU-003: kein ps -ax mehr

    func testCurrentProcessSamplesRunsPsOnlyForChatPIDsAndChildren() {
        var calls: [(String, [String])] = []
        let samples = AgentResourceMonitor.currentProcessSamples(
            rootPIDs: [10, 20],
            descendants: { roots in roots + [11, 21] },
            run: { exe, args in
                calls.append((exe, args))
                return "10 1 0.5 100 codex\n11 10 0.1 50 node\n"
            }
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1.first, "-p")
        XCTAssertEqual(calls.first?.1[1], "10,20,11,21")
        XCTAssertFalse(calls.first?.1.contains("-ax") ?? true)
        XCTAssertFalse(calls.first?.1.contains("-axo") ?? true)
        XCTAssertEqual(samples.map(\.pid), [10, 11])
    }

    func testSnapshotWithoutRunningChatsForksNothing() {
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

    func testDescendantPIDsFindsRealChildren() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let found = AgentResourceMonitor.descendantPIDs(of: [getpid()])
        XCTAssertTrue(found.contains(getpid()))
        XCTAssertTrue(found.contains(child.processIdentifier), "found=\(found)")
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
