import AVFoundation
import Observation

@Observable
@MainActor
final class PermissionSettingsModel {
    typealias MicrophoneStatusProvider = @MainActor () -> AVAuthorizationStatus
    typealias BooleanStatusProvider = @MainActor () -> Bool
    typealias AsyncRequestAction = @MainActor () async -> Bool
    typealias RequestAction = @MainActor () -> Void
    typealias BooleanRequestAction = @MainActor () -> Bool
    typealias OpenSettingsAction = @MainActor () -> Void
    typealias SleepAction = @Sendable (Duration) async throws -> Void

    var microphoneStatus: AVAuthorizationStatus
    var accessibilityGranted: Bool
    var screenRecordingGranted: Bool

    @ObservationIgnored private let microphoneStatusProvider: MicrophoneStatusProvider
    @ObservationIgnored private let accessibilityStatusProvider: BooleanStatusProvider
    @ObservationIgnored private let screenRecordingStatusProvider: BooleanStatusProvider
    @ObservationIgnored private let requestMicrophonePermission: AsyncRequestAction
    @ObservationIgnored private let requestAccessibilityPermission: RequestAction
    @ObservationIgnored private let requestScreenRecordingPermission: BooleanRequestAction
    @ObservationIgnored private let openMicrophoneSettings: OpenSettingsAction
    @ObservationIgnored private let openAccessibilitySettings: OpenSettingsAction
    @ObservationIgnored private let openScreenRecordingSettings: OpenSettingsAction
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let sleep: SleepAction
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(
        microphoneStatusProvider: @escaping MicrophoneStatusProvider = { PermissionService.microphoneAuthorizationStatus },
        accessibilityStatusProvider: @escaping BooleanStatusProvider = { PermissionService.hasAccessibilityPermission },
        screenRecordingStatusProvider: @escaping BooleanStatusProvider = { PermissionService.hasScreenRecordingPermission },
        requestMicrophonePermission: @escaping AsyncRequestAction = { await PermissionService.requestMicrophonePermission() },
        requestAccessibilityPermission: @escaping RequestAction = { PermissionService.requestAccessibilityPermission() },
        requestScreenRecordingPermission: @escaping BooleanRequestAction = { PermissionService.requestScreenRecordingPermission() },
        openMicrophoneSettings: @escaping OpenSettingsAction = { PermissionService.openMicrophonePrivacySettings() },
        openAccessibilitySettings: @escaping OpenSettingsAction = { PermissionService.openAccessibilityPrivacySettings() },
        openScreenRecordingSettings: @escaping OpenSettingsAction = { PermissionService.openScreenRecordingPrivacySettings() },
        pollingInterval: Duration = .seconds(1),
        sleep: @escaping SleepAction = { duration in try await Task.sleep(for: duration) }
    ) {
        self.microphoneStatusProvider = microphoneStatusProvider
        self.accessibilityStatusProvider = accessibilityStatusProvider
        self.screenRecordingStatusProvider = screenRecordingStatusProvider
        self.requestMicrophonePermission = requestMicrophonePermission
        self.requestAccessibilityPermission = requestAccessibilityPermission
        self.requestScreenRecordingPermission = requestScreenRecordingPermission
        self.openMicrophoneSettings = openMicrophoneSettings
        self.openAccessibilitySettings = openAccessibilitySettings
        self.openScreenRecordingSettings = openScreenRecordingSettings
        self.pollingInterval = pollingInterval
        self.sleep = sleep
        self.microphoneStatus = microphoneStatusProvider()
        self.accessibilityGranted = accessibilityStatusProvider()
        self.screenRecordingGranted = screenRecordingStatusProvider()
    }

    deinit {
        // deinit ist nonisolated — daher direkte Task-Cancellation statt der
        // MainActor-isolierten stopPolling()-Methode.
        pollingTask?.cancel()
    }

    var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    var requiredPermissionsGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    var headerText: String {
        requiredPermissionsGranted
            ? "Required permissions granted — Screen Recording optional"
            : "WhisperM8 needs system access"
    }

    var headerTone: SettingsStatusTone {
        requiredPermissionsGranted ? .ok : .warn
    }

    var isPolling: Bool {
        pollingTask != nil
    }

    var microphoneStatusText: String {
        switch microphoneStatus {
        case .authorized:
            return "Granted"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    var microphonePrimaryButtonTitle: String {
        switch microphoneStatus {
        case .authorized:
            return "Check Again"
        case .denied, .restricted:
            return "Open Settings"
        case .notDetermined:
            return "Grant"
        @unknown default:
            return "Open Settings"
        }
    }

    func refresh() {
        microphoneStatus = microphoneStatusProvider()
        accessibilityGranted = accessibilityStatusProvider()
        screenRecordingGranted = screenRecordingStatusProvider()
    }

    func startPolling() {
        stopPolling()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let pollingInterval = self?.pollingInterval,
                      let sleep = self?.sleep else {
                    break
                }

                do {
                    try await sleep(pollingInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard let self else { break }
                refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func performMicrophonePrimaryAction() async {
        switch microphoneStatus {
        case .authorized:
            refresh()
        case .notDetermined:
            _ = await requestMicrophonePermission()
            refresh()
        case .denied, .restricted:
            openMicrophoneSettings()
        @unknown default:
            openMicrophoneSettings()
        }
    }

    func performAccessibilityPrimaryAction() {
        if accessibilityGranted {
            refresh()
        } else {
            requestAccessibilityPermission()
            openAccessibilitySettings()
        }
    }

    func performScreenRecordingPrimaryAction() {
        if screenRecordingGranted {
            refresh()
        } else {
            _ = requestScreenRecordingPermission()
            openScreenRecordingSettings()
        }
    }

    func openMicrophonePrivacySettings() {
        openMicrophoneSettings()
    }

    func openAccessibilityPrivacySettings() {
        openAccessibilitySettings()
    }

    func openScreenRecordingPrivacySettings() {
        openScreenRecordingSettings()
    }
}
