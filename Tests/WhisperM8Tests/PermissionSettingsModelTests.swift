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

    func testMicrophonePrimaryActionsUseExpectedSideEffects() async {
        let expectations: [(status: AVAuthorizationStatus, requestCount: Int, openSettingsCount: Int, refreshDelta: Int)] = [
            (.notDetermined, 1, 0, 1),
            (.denied, 0, 1, 0),
            (.restricted, 0, 1, 0)
        ]

        for expectation in expectations {
            var requestCount = 0
            var openSettingsCount = 0
            var refreshCount = 0
            let model = makeModel(
                microphoneStatusProvider: {
                    refreshCount += 1
                    return expectation.status
                },
                accessibilityStatusProvider: { true },
                screenRecordingStatusProvider: { true },
                requestMicrophonePermission: {
                    requestCount += 1
                    return true
                },
                openMicrophoneSettings: {
                    openSettingsCount += 1
                },
                sleep: { _ in }
            )
            let countAfterInit = refreshCount

            await model.performMicrophonePrimaryAction()

            XCTAssertEqual(requestCount, expectation.requestCount, "Request count for \(expectation.status)")
            XCTAssertEqual(openSettingsCount, expectation.openSettingsCount, "Open-settings count for \(expectation.status)")
            XCTAssertEqual(refreshCount, countAfterInit + expectation.refreshDelta, "Refresh count for \(expectation.status)")
        }
    }

    func testOptionalPermissionPrimaryActionsRequestAndOpenSettings() {
        enum Action {
            case accessibility
            case screenRecording
        }

        let expectations: [(action: Action, accessibilityGranted: Bool, screenRecordingGranted: Bool)] = [
            (.accessibility, false, true),
            (.screenRecording, true, false)
        ]

        for expectation in expectations {
            var accessibilityRefreshCount = 0
            var screenRecordingRefreshCount = 0
            var requestAccessibilityCount = 0
            var openAccessibilityCount = 0
            var requestScreenRecordingCount = 0
            var openScreenRecordingCount = 0
            let model = makeModel(
                microphoneStatusProvider: { .authorized },
                accessibilityStatusProvider: {
                    accessibilityRefreshCount += 1
                    return expectation.accessibilityGranted
                },
                screenRecordingStatusProvider: {
                    screenRecordingRefreshCount += 1
                    return expectation.screenRecordingGranted
                },
                requestAccessibilityPermission: {
                    requestAccessibilityCount += 1
                },
                requestScreenRecordingPermission: {
                    requestScreenRecordingCount += 1
                    return true
                },
                openAccessibilitySettings: {
                    openAccessibilityCount += 1
                },
                openScreenRecordingSettings: {
                    openScreenRecordingCount += 1
                },
                sleep: { _ in }
            )
            let accessibilityCountAfterInit = accessibilityRefreshCount
            let screenRecordingCountAfterInit = screenRecordingRefreshCount

            switch expectation.action {
            case .accessibility:
                model.performAccessibilityPrimaryAction()
                XCTAssertEqual(requestAccessibilityCount, 1)
                XCTAssertEqual(openAccessibilityCount, 1)
                XCTAssertEqual(requestScreenRecordingCount, 0)
                XCTAssertEqual(openScreenRecordingCount, 0)
            case .screenRecording:
                model.performScreenRecordingPrimaryAction()
                XCTAssertEqual(requestAccessibilityCount, 0)
                XCTAssertEqual(openAccessibilityCount, 0)
                XCTAssertEqual(requestScreenRecordingCount, 1)
                XCTAssertEqual(openScreenRecordingCount, 1)
            }

            XCTAssertEqual(accessibilityRefreshCount, accessibilityCountAfterInit)
            XCTAssertEqual(screenRecordingRefreshCount, screenRecordingCountAfterInit)
        }
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
        requestMicrophonePermission: @escaping PermissionSettingsModel.AsyncRequestAction = { true },
        requestAccessibilityPermission: @escaping PermissionSettingsModel.RequestAction = {},
        requestScreenRecordingPermission: @escaping PermissionSettingsModel.BooleanRequestAction = { true },
        openMicrophoneSettings: @escaping PermissionSettingsModel.OpenSettingsAction = {},
        openAccessibilitySettings: @escaping PermissionSettingsModel.OpenSettingsAction = {},
        openScreenRecordingSettings: @escaping PermissionSettingsModel.OpenSettingsAction = {},
        sleep: @escaping PermissionSettingsModel.SleepAction
    ) -> PermissionSettingsModel {
        PermissionSettingsModel(
            microphoneStatusProvider: microphoneStatusProvider,
            accessibilityStatusProvider: accessibilityStatusProvider,
            screenRecordingStatusProvider: screenRecordingStatusProvider,
            requestMicrophonePermission: requestMicrophonePermission,
            requestAccessibilityPermission: requestAccessibilityPermission,
            requestScreenRecordingPermission: requestScreenRecordingPermission,
            openMicrophoneSettings: openMicrophoneSettings,
            openAccessibilitySettings: openAccessibilitySettings,
            openScreenRecordingSettings: openScreenRecordingSettings,
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
