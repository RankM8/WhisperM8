import XCTest
@testable import WhisperM8

@MainActor
final class SettingsKitTests: XCTestCase {
    func testFeedbackStateTriggersAndResetsAfterInjectedSleepResolves() async throws {
        let sleep = ManualSleep()
        let state = SettingsFeedbackState(duration: .seconds(1), sleep: { duration in
            try await sleep.sleep(duration)
        })

        state.trigger()
        try await waitUntil { sleep.startCount == 1 }

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(sleep.startCount, 1)

        sleep.resolveNext()
        try await waitUntil { !state.isActive }

        XCTAssertFalse(state.isActive)
    }

    func testFeedbackStateCancelsOlderResetWhenTriggeredAgain() async throws {
        let sleep = ManualSleep()
        let state = SettingsFeedbackState(duration: .seconds(1), sleep: { duration in
            try await sleep.sleep(duration)
        })

        state.trigger()
        try await waitUntil { sleep.startCount == 1 }

        state.trigger()
        try await waitUntil { sleep.startCount == 2 && sleep.cancelCount == 1 }

        XCTAssertTrue(state.isActive)
        XCTAssertEqual(sleep.startCount, 2)
        XCTAssertEqual(sleep.cancelCount, 1)

        sleep.resolveNext()
        try await waitUntil { !state.isActive }

        XCTAssertFalse(state.isActive)
    }

    func testCopyCommandActionUsesClipboardAndFeedback() {
        var copied: [String] = []
        let clipboard = ClosureClipboardClient { copied.append($0) }
        let feedback = SettingsFeedbackState(duration: .seconds(1), sleep: { _ in })

        SettingsCopyCommandAction.copy(
            command: "codex --version",
            clipboard: clipboard,
            feedback: feedback
        )

        XCTAssertEqual(copied, ["codex --version"])
        XCTAssertTrue(feedback.isActive)
    }

    func testStatusToneTokenMappingIsComplete() {
        let tokenNames = Dictionary(uniqueKeysWithValues: SettingsStatusTone.allCases.map { ($0, $0.tokenName) })

        XCTAssertEqual(tokenNames[.ok], "statusWorking")
        XCTAssertEqual(tokenNames[.warn], "statusAwaiting")
        XCTAssertEqual(tokenNames[.error], "statusError")
        XCTAssertEqual(tokenNames[.off], "textTertiary")
        XCTAssertEqual(tokenNames.count, SettingsStatusTone.allCases.count)
    }

    func testTabSelectionModelSwitchesAndFallsBackToFirstForUnknownID() {
        let tabs = [
            SettingsTab(id: "modes", title: "Modes"),
            SettingsTab(id: "templates", title: "Templates")
        ]
        var model = SettingsTabSelectionModel(tabs: tabs, selection: "missing")

        XCTAssertEqual(model.selection, "modes")

        model.select("templates")
        XCTAssertEqual(model.selection, "templates")

        model.select("unknown")
        XCTAssertEqual(model.selection, "modes")
    }

    @MainActor
    func testFeedbackStateResetStopsPendingTaskImmediately() async throws {
        let sleep = ManualSleep()
        let feedback = SettingsFeedbackState(duration: .seconds(5)) { duration in
            try await sleep.sleep(duration)
        }

        feedback.trigger()
        try await waitUntil { sleep.startCount == 1 }
        XCTAssertTrue(feedback.isActive)

        feedback.reset()
        XCTAssertFalse(feedback.isActive)
        try await waitUntil { sleep.cancelCount == 1 }

        // Die alte Reset-Task ist gecancelt; ein spaeter Completion-Pfad darf
        // den sofort zurueckgesetzten Zustand nicht wieder veraendern.
        XCTAssertFalse(feedback.isActive)
    }

    func testTabSelectionModelWithEmptyTabListDoesNotCrashAndKeepsSelection() {
        var model = SettingsTabSelectionModel(tabs: [SettingsTab<String>](), selection: "anything")
        XCTAssertEqual(model.resolvedSelection, "anything")
        model.select("other")
        XCTAssertEqual(model.selection, "anything")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Bedingung wurde nicht rechtzeitig erfuellt")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
private final class ManualSleep: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func sleep(_ duration: Duration) async throws {
        startCount += 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelCount += 1
                if !self.continuations.isEmpty {
                    let continuation = self.continuations.removeFirst()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    func resolveNext() {
        precondition(!continuations.isEmpty)
        let continuation = continuations.removeFirst()
        continuation.resume()
    }
}
