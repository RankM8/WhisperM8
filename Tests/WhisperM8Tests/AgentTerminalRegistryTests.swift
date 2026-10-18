import XCTest
@testable import WhisperM8

/// LR-TRM-001: „Alle Chats stoppen" zahlt die Ctrl+C-Wartezeit einmal für alle
/// statt pro PTY (vorher 260 ms × Chats auf dem Main Thread).
@MainActor
final class AgentTerminalRegistryTests: XCTestCase {
    private func startSleepers(_ count: Int, in registry: AgentTerminalRegistry) -> [UUID] {
        (0..<count).map { _ in
            let id = UUID()
            registry.startController(
                sessionID: id,
                command: AgentLaunchCommand(
                    executablePath: "/bin/sleep",
                    arguments: ["60"],
                    workingDirectory: NSTemporaryDirectory(),
                    keyboardProfile: .plainShell
                ),
                onLaunched: {},
                onTerminated: { _ in }
            )
            return id
        }
    }

    func testTerminateAllPaysGraceWaitOnlyOnce() {
        let spy = SleepSpy()
        let registry = AgentTerminalRegistry(sleep: { spy($0) })
        let ids = startSleepers(5, in: registry)
        XCTAssertEqual(registry.activeSessionIDs.count, 5)

        let stopped = registry.terminateAll()

        XCTAssertEqual(spy.calls, [80_000, 180_000], "genau eine 80-ms- und eine 180-ms-Pause für alle")
        XCTAssertEqual(Set(stopped), Set(ids), "alle IDs werden zurückgegeben")
        XCTAssertTrue(registry.activeSessionIDs.isEmpty)
        XCTAssertTrue(ids.allSatisfy { registry.controller(for: $0) == nil })
    }

    func testTerminateAllWithoutRunningChatsDoesNotSleep() {
        let spy = SleepSpy()
        let registry = AgentTerminalRegistry(sleep: { spy($0) })
        XCTAssertEqual(registry.terminateAll(), [])
        XCTAssertTrue(spy.calls.isEmpty)
    }
}
