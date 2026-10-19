import Darwin
import XCTest
@testable import WhisperM8

/// LR-AU-005: Wann das Beenden eines laufenden Prozesses nachfragen muss.
final class ProcessEndConfirmationTests: XCTestCase {
    func testTerminalAsksOnlyWithRunningChildProcess() {
        XCTAssertFalse(ProcessEndConfirmation.terminalNeedsConfirmation(isRunning: true, shellHasChildProcess: false))
        XCTAssertTrue(ProcessEndConfirmation.terminalNeedsConfirmation(isRunning: true, shellHasChildProcess: true))
        XCTAssertFalse(ProcessEndConfirmation.terminalNeedsConfirmation(isRunning: false, shellHasChildProcess: true))
    }

    func testRestartAsksWhenBusyOrDraftButNotWhenIdle() {
        func ask(_ running: Bool, _ runtime: AgentSessionRuntimeStatus?, _ draft: Bool) -> Bool {
            ProcessEndConfirmation.restartNeedsConfirmation(
                isRunning: running, runtime: runtime, mayHaveUnsentInput: draft)
        }
        XCTAssertTrue(ask(true, .working, false))
        XCTAssertTrue(ask(true, .awaitingInput, false))
        XCTAssertTrue(ask(true, .idle, true))
        XCTAssertFalse(ask(true, .idle, false))
        XCTAssertFalse(ask(true, nil, false))
        XCTAssertFalse(ask(false, .working, true), "kein Prozess, nichts zu verlieren")
    }

    func testBackgroundRemovalAsksWhileRunningOrWorking() {
        XCTAssertTrue(ProcessEndConfirmation.backgroundRemoveNeedsConfirmation(isRunning: true, runtime: .idle))
        XCTAssertTrue(ProcessEndConfirmation.backgroundRemoveNeedsConfirmation(isRunning: false, runtime: .working))
        XCTAssertFalse(ProcessEndConfirmation.backgroundRemoveNeedsConfirmation(isRunning: false, runtime: .idle))
        XCTAssertFalse(ProcessEndConfirmation.backgroundRemoveNeedsConfirmation(isRunning: false, runtime: nil))
    }

    func testChildProcessDetectionSeesARealChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        // Elternprozess = dieser Testprozess selbst
        XCTAssertTrue(ProcessChildren.hasChildProcess(of: getpid()))
        XCTAssertFalse(ProcessChildren.hasChildProcess(of: process.processIdentifier))
        XCTAssertFalse(ProcessChildren.hasChildProcess(of: 0))
    }
}
