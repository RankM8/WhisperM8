import SwiftUI

struct ContextPrivacySettingsPage: View {
    @AppStorage("selectedContextCaptureEnabled") private var selectedContextCaptureEnabled = true
    @AppStorage("visualContextCaptureEnabled") private var visualContextCaptureEnabled = true
    @AppStorage("maxScreenshotsPerRecording") private var maxScreenshotsPerRecording = AppPreferences.defaultMaxScreenshotsPerRecording
    @AppStorage("maxScreenRecordingDuration") private var maxScreenRecordingDuration = 30.0
    @AppStorage("deleteContextFilesAfterProcessing") private var deleteContextFilesAfterProcessing = false

    var body: some View {
        SettingsPageContainer(
            title: "Context & Privacy",
            subtitle: "What WhisperM8 may capture alongside your voice - and what happens to it."
        ) {
            SettingsSection("Text Context") {
                SettingsToggleRow(
                    title: "Use selected text as context",
                    subtitle: "Reads the current selection (needs Accessibility permission) so modes like Reply understand what you refer to.",
                    isOn: $selectedContextCaptureEnabled
                )
            }

            SettingsSection("Visual Context") {
                SettingsToggleRow(
                    title: "Allow screenshots and screen clips as context",
                    subtitle: "Needs Screen Recording permission (optional) - see Permissions.",
                    isOn: $visualContextCaptureEnabled
                )

                if visualContextCaptureEnabled {
                    SettingsStepperRow(
                        title: "Screenshots per recording",
                        value: $maxScreenshotsPerRecording,
                        in: 1...AppPreferences.maximumScreenshotsPerRecording,
                        format: .number
                    )

                    ScreenClipDurationRow(
                        title: "Max screen clip",
                        value: $maxScreenRecordingDuration,
                        range: 5...60
                    )

                    SettingsToggleRow(
                        title: "Delete visual context files after processing",
                        isOn: $deleteContextFilesAfterProcessing
                    )
                }
            }

            SettingsSection("Privacy") {
                SettingsHelpText("Audio goes only to your chosen transcription provider (Groq/OpenAI). Context text, screenshots and clips go only to Codex when a mode requests them. Nothing else leaves your machine; history is stored locally under Application Support.")
                    .padding(.vertical, 11)
                    .padding(.horizontal, 2)
            }
        }
    }
}

private struct ScreenClipDurationRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        SettingsRow(title: title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: 5)
                    .tint(AppTheme.accent)
                    .frame(width: 180)

                Text("\(Int(value)) s")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}
