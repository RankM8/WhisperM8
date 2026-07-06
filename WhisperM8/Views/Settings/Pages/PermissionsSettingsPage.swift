import SwiftUI

struct PermissionsSettingsPage: View {
    @State private var model: PermissionSettingsModel

    @MainActor
    init(model: PermissionSettingsModel? = nil) {
        self._model = State(initialValue: model ?? PermissionSettingsModel())
    }

    var body: some View {
        SettingsPageContainer(
            title: "Permissions",
            subtitle: "Re-check or repair system permissions without running onboarding again."
        ) {
            SettingsSection("System Access") {
                SettingsStatusRow(
                    title: "Permissions",
                    subtitle: "Re-check or repair system permissions without running onboarding again.",
                    tone: model.headerTone,
                    detail: model.headerText
                ) {
                    Button("Refresh") {
                        model.refresh()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }
            }

            SettingsSection("Required") {
                permissionRow(
                    title: "Microphone",
                    subtitle: "Required to record your voice for transcription.",
                    statusText: model.microphoneStatusText,
                    isGranted: model.microphoneGranted,
                    primaryTitle: model.microphonePrimaryButtonTitle,
                    primaryAction: {
                        Task { await model.performMicrophonePrimaryAction() }
                    },
                    secondaryAction: model.openMicrophonePrivacySettings
                )

                permissionRow(
                    title: "Accessibility",
                    subtitle: "Required for auto-paste and selected text capture.",
                    statusText: model.accessibilityGranted ? "Granted" : "Not granted",
                    isGranted: model.accessibilityGranted,
                    primaryTitle: model.accessibilityGranted ? "Check Again" : "Grant",
                    primaryAction: model.performAccessibilityPrimaryAction,
                    secondaryAction: model.openAccessibilityPrivacySettings
                )
            }

            SettingsSection("Optional · Visual Context") {
                permissionRow(
                    title: "Screen Recording",
                    subtitle: "Required only when you add screenshots or screen clips as context. Visual context can be configured in Context & Privacy.",
                    statusText: model.screenRecordingGranted ? "Granted" : "Not granted",
                    isGranted: model.screenRecordingGranted,
                    primaryTitle: model.screenRecordingGranted ? "Check Again" : "Grant",
                    primaryAction: model.performScreenRecordingPrimaryAction,
                    secondaryAction: model.openScreenRecordingPrivacySettings
                )
            }

            SettingsSection("What happens without permissions") {
                SettingsHelpText("Without Microphone access, recording cannot start. Without Accessibility access, WhisperM8 can still transcribe and copy to clipboard, but auto-paste and selected text capture will be blocked by macOS. Screen Recording is optional and only needed for screenshot or screen clip context.")
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            model.refresh()
            model.startPolling()
        }
        .onDisappear {
            model.stopPolling()
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        statusText: String,
        isGranted: Bool,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        SettingsStatusRow(
            title: title,
            subtitle: subtitle,
            tone: isGranted ? .ok : .warn,
            detail: statusText
        ) {
            Button(primaryTitle) {
                primaryAction()
            }
            .buttonStyle(isGranted ? SettingsButtonStyle.standard : SettingsButtonStyle.primary)

            Button("Open Settings") {
                secondaryAction()
            }
            .buttonStyle(SettingsButtonStyle.standard)
        }
    }
}
