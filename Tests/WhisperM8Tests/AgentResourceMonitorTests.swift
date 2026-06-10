import Foundation
import XCTest
@testable import WhisperM8

final class AgentResourceMonitorTests: XCTestCase {
    func testAgentResourceMonitorAggregatesSyntheticProcessTree() {
        let sessionID = UUID()
        let monitor = AgentResourceMonitor(
            processSamples: {
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
            processSamples: {
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
            processSamples: {
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
}
