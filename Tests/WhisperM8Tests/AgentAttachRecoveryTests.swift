import XCTest
@testable import WhisperM8

/// Review-Befunde 11.11.2026 zum Rückweg nach einem gescheiterten Attach.
final class AgentAttachRecoveryTests: XCTestCase {
    // SwiftTerm liefert im forkpty-Pfad den ROHEN waitpid-Status.
    func testDecodesRawWaitStatus() {
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: 0), .exited(0))
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: 256), .exited(1), "exit(1)")
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: 2 << 8), .exited(2))
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: 15), .signaled(15), "SIGTERM")
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: 9), .signaled(9), "SIGKILL")
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: 1), .signaled(1), "SIGHUP")
        XCTAssertEqual(AgentAttachRecovery.decode(waitStatus: nil), .unknown)
    }

    func testOnlyAQuickNonZeroExitOfAnAttachCountsAsFailure() {
        func failed(_ attach: Bool, _ raw: Int32?, _ seconds: TimeInterval?) -> Bool {
            AgentAttachRecovery.isQuickFailedAttach(
                isBackgroundAttachFallback: attach,
                end: AgentAttachRecovery.decode(waitStatus: raw),
                runDuration: seconds)
        }
        XCTAssertTrue(failed(true, 256, 0.4), "attach meldet „No job matching“ sofort")
        XCTAssertFalse(failed(true, 256, 3 * 3600), "Agent endete nach Stunden: kein Rückweg")
        XCTAssertFalse(failed(true, 15, 0.4), "von außen getötet: kein Rückweg")
        XCTAssertFalse(failed(true, 9, 0.4), "SIGKILL: kein Rückweg")
        XCTAssertFalse(failed(true, 0, 0.4), "sauberes Ende")
        XCTAssertFalse(failed(true, 256, nil), "Startzeit unbekannt")
        XCTAssertFalse(failed(false, 256, 0.4), "normales --resume: nie ein Rückweg (keine Schleife)")
    }

    func testNextStepReattachesOnceWhileWorkerIsListedAndResumesOnlyWithoutWorker() {
        XCTAssertEqual(AgentAttachRecovery.nextStep(workerStillListed: true, reattachAlreadyTried: false), .reattach)
        XCTAssertEqual(AgentAttachRecovery.nextStep(workerStillListed: true, reattachAlreadyTried: true), .giveUp,
                       "Worker noch da und schon einmal neu angehängt: kein zweiter Prozess")
        XCTAssertEqual(AgentAttachRecovery.nextStep(workerStillListed: false, reattachAlreadyTried: false), .resume)
        XCTAssertEqual(AgentAttachRecovery.nextStep(workerStillListed: false, reattachAlreadyTried: true), .resume)
    }

    @MainActor
    func testReattachMemoryExpires() {
        let id = UUID()
        let start = Date()
        XCTAssertFalse(AgentAttachRecovery.reattachAlreadyTried(id, now: start))
        AgentAttachRecovery.noteReattach(id, now: start)
        XCTAssertTrue(AgentAttachRecovery.reattachAlreadyTried(id, now: start.addingTimeInterval(5)))
        XCTAssertFalse(AgentAttachRecovery.reattachAlreadyTried(id, now: start.addingTimeInterval(AgentAttachRecovery.reattachMemory + 1)))
    }

    func testClosedTabGetsNoInvisibleRestart() {
        let id = UUID()
        var state = AgentUIState()
        XCTAssertFalse(AgentAttachRecovery.isOpen(id, in: state))
        state.windows = [AgentChatWindowState(openTabIDs: [id])]
        XCTAssertTrue(AgentAttachRecovery.isOpen(id, in: state))
    }
}
