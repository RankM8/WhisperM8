import SwiftUI

struct PermissionsSettingsView: View {
    @State private var microphoneStatus = PermissionService.microphoneAuthorizationStatus
    @State private var accessibilityGranted = PermissionService.hasAccessibilityPermission
    @State private var screenRecordingGranted = PermissionService.hasScreenRecordingPermission
    @State private var permissionTimer: Timer?

    private var microphoneGranted: Bool {
        microphoneStatus == .authorized
    }

    private var allGranted: Bool {
        microphoneGranted && accessibilityGranted
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: allGranted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.system(size: 28))
                        .foregroundStyle(allGranted ? .green : .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(allGranted ? "All system permissions are active" : "WhisperM8 needs system access")
                            .font(.headline)
                        Text("You can re-check or repair permissions here without running onboarding again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Refresh") {
                        refreshPermissions()
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Required") {
                SystemPermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to record your voice for transcription.",
                    statusText: microphoneStatusText,
                    isGranted: microphoneGranted,
                    primaryButtonTitle: microphonePrimaryButtonTitle,
                    primaryAction: handleMicrophoneAction,
                    secondaryButtonTitle: "Open Settings",
                    secondaryAction: PermissionService.openMicrophonePrivacySettings
                )

                SystemPermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required for auto-paste and selected text capture.",
                    statusText: accessibilityGranted ? "Granted" : "Not granted",
                    isGranted: accessibilityGranted,
                    primaryButtonTitle: accessibilityGranted ? "Check Again" : "Grant",
                    primaryAction: handleAccessibilityAction,
                    secondaryButtonTitle: "Open Settings",
                    secondaryAction: PermissionService.openAccessibilityPrivacySettings
                )
            }

            Section("Optional Visual Context") {
                SystemPermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Required only when you add screenshots or screen clips as context.",
                    statusText: screenRecordingGranted ? "Granted" : "Not granted",
                    isGranted: screenRecordingGranted,
                    primaryButtonTitle: screenRecordingGranted ? "Check Again" : "Grant",
                    primaryAction: handleScreenRecordingAction,
                    secondaryButtonTitle: "Open Settings",
                    secondaryAction: PermissionService.openScreenRecordingPrivacySettings
                )
            }

            Section("What happens without permissions") {
                Text("Without Microphone access, recording cannot start. Without Accessibility access, WhisperM8 can still transcribe and copy to clipboard, but auto-paste and selected text capture will be blocked by macOS. Screen Recording is optional and only needed for screenshot or screen clip context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshPermissions()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }
    }

    private var microphoneStatusText: String {
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

    private var microphonePrimaryButtonTitle: String {
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

    private func handleMicrophoneAction() {
        switch microphoneStatus {
        case .authorized:
            refreshPermissions()
        case .notDetermined:
            Task {
                _ = await PermissionService.requestMicrophonePermission()
                await MainActor.run {
                    refreshPermissions()
                }
            }
        case .denied, .restricted:
            PermissionService.openMicrophonePrivacySettings()
        @unknown default:
            PermissionService.openMicrophonePrivacySettings()
        }
    }

    private func handleAccessibilityAction() {
        if accessibilityGranted {
            refreshPermissions()
        } else {
            PermissionService.requestAccessibilityPermission()
            PermissionService.openAccessibilityPrivacySettings()
        }
    }

    private func handleScreenRecordingAction() {
        if screenRecordingGranted {
            refreshPermissions()
        } else {
            _ = PermissionService.requestScreenRecordingPermission()
            PermissionService.openScreenRecordingPrivacySettings()
        }
    }

    private func refreshPermissions() {
        microphoneStatus = PermissionService.microphoneAuthorizationStatus
        accessibilityGranted = PermissionService.hasAccessibilityPermission
        screenRecordingGranted = PermissionService.hasScreenRecordingPermission
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refreshPermissions()
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}

struct SystemPermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let statusText: String
    let isGranted: Bool
    let primaryButtonTitle: String
    let primaryAction: () -> Void
    let secondaryButtonTitle: String
    let secondaryAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(isGranted ? .green : .blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(minWidth: 86, alignment: .trailing)

            if isGranted {
                Button(primaryButtonTitle) {
                    primaryAction()
                }
                .buttonStyle(.borderless)
            } else {
                Button(primaryButtonTitle) {
                    primaryAction()
                }
                .buttonStyle(.borderedProminent)
            }

            Button(secondaryButtonTitle) {
                secondaryAction()
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}
