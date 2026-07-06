import AVFoundation
import XCTest
@testable import WhisperM8

@MainActor
final class PermissionSettingsModelTests: XCTestCase {
    func testHeaderReportsRequiredGrantedEvenWhenScreenRecordingIsMissing() {
        let model = makeModel(
            microphoneStatus: .authorized,
            accessibilityGranted: true,
            screenRecordingGranted: false
        )

        XCTAssertTrue(model.requiredPermissionsGranted)
        XCTAssertEqual(model.headerText, "Required permissions granted — Screen Recording optional")
        XCTAssertEqual(model.headerTone, .ok)
    }

    func testHeaderReportsSystemAccessNeededWhenMicrophoneIsMissing() {
        let model = makeModel(
            microphoneStatus: .denied,
            accessibilityGranted: true,
            screenRecordingGranted: true
        )

        XCTAssertFalse(model.requiredPermissionsGranted)
        XCTAssertEqual(model.headerText, "WhisperM8 needs system access")
        XCTAssertEqual(model.headerTone, .warn)
    }

    func testHeaderReportsSystemAccessNeededWhenAccessibilityIsMissing() {
        let model = makeModel(
            microphoneStatus: .authorized,
            accessibilityGranted: false,
            screenRecordingGranted: true
        )

        XCTAssertFalse(model.requiredPermissionsGranted)
        XCTAssertEqual(model.headerText, "WhisperM8 needs system access")
        XCTAssertEqual(model.headerTone, .warn)
    }

    func testPollingRefreshesAfterInjectedSleepResolves() async throws {
        let sleep = ManualPermissionSleep()
        var microphoneStatus = AVAuthorizationStatus.notDetermined
        var refreshCount = 0
        let model = makeModel(
            microphoneStatusProvider: {
                refreshCount += 1
                return microphoneStatus
            },
            accessibilityStatusProvider: { true },
            screenRecordingStatusProvider: { false },
            sleep: sleepAction(for: sleep)
        )
        let countAfterInit = refreshCount

        model.startPolling()
        try await waitUntil { sleep.startCount == 1 }

        microphoneStatus = .authorized
        sleep.resolveNext()

        try await waitUntil { refreshCount > countAfterInit && model.microphoneStatus == .authorized }
        XCTAssertTrue(model.isPolling)

        model.stopPolling()
    }

    func testStopPollingCancelsPendingPollingTask() async throws {
        let sleep = ManualPermissionSleep()
        let model = makeModel(sleep: sleepAction(for: sleep))

        model.startPolling()
        try await waitUntil { sleep.startCount == 1 }
        XCTAssertTrue(model.isPolling)

        model.stopPolling()

        try await waitUntil { sleep.cancelCount == 1 }
        XCTAssertFalse(model.isPolling)
    }

    func testStartPollingCancelsExistingTaskBeforeStartingANewOne() async throws {
        let sleep = ManualPermissionSleep()
        let model = makeModel(sleep: sleepAction(for: sleep))

        model.startPolling()
        try await waitUntil { sleep.startCount == 1 }

        model.startPolling()

        try await waitUntil { sleep.cancelCount == 1 && sleep.startCount == 2 }
        XCTAssertTrue(model.isPolling)

        model.stopPolling()
        try await waitUntil { sleep.cancelCount == 2 }
    }

    private func makeModel(
        microphoneStatus: AVAuthorizationStatus = .authorized,
        accessibilityGranted: Bool = true,
        screenRecordingGranted: Bool = true,
        sleep: @escaping PermissionSettingsModel.SleepAction = { _ in }
    ) -> PermissionSettingsModel {
        makeModel(
            microphoneStatusProvider: { microphoneStatus },
            accessibilityStatusProvider: { accessibilityGranted },
            screenRecordingStatusProvider: { screenRecordingGranted },
            sleep: sleep
        )
    }

    private func makeModel(
        microphoneStatusProvider: @escaping PermissionSettingsModel.MicrophoneStatusProvider,
        accessibilityStatusProvider: @escaping PermissionSettingsModel.BooleanStatusProvider,
        screenRecordingStatusProvider: @escaping PermissionSettingsModel.BooleanStatusProvider,
        sleep: @escaping PermissionSettingsModel.SleepAction
    ) -> PermissionSettingsModel {
        PermissionSettingsModel(
            microphoneStatusProvider: microphoneStatusProvider,
            accessibilityStatusProvider: accessibilityStatusProvider,
            screenRecordingStatusProvider: screenRecordingStatusProvider,
            requestMicrophonePermission: { true },
            requestAccessibilityPermission: {},
            requestScreenRecordingPermission: { true },
            openMicrophoneSettings: {},
            openAccessibilitySettings: {},
            openScreenRecordingSettings: {},
            pollingInterval: .milliseconds(10),
            sleep: sleep
        )
    }

    private func sleepAction(for manualSleep: ManualPermissionSleep) -> PermissionSettingsModel.SleepAction {
        { duration in
            try await manualSleep.sleep(duration)
        }
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
private final class ManualPermissionSleep: @unchecked Sendable {
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
