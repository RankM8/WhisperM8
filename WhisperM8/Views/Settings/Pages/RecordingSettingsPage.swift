import KeyboardShortcuts
import SwiftUI

struct RecordingSettingsPage: View {
    @AppStorage("showConfirmButtonInOverlay") private var showConfirmButtonInOverlay = true
    @AppStorage("audioDuckingEnabled") private var audioDuckingEnabled = true
    @AppStorage("audioDuckingFactor") private var audioDuckingFactor = 0.2
    @AppStorage("overlayStyle") private var overlayStyleRaw = OverlayStyle.mini.rawValue
    @AppStorage("showModePickerInMiniOverlay") private var showModePickerInMiniOverlay = true
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true

    @State private var deviceManager = AudioDeviceManager.shared
    @State private var selectedDeviceUID: String = ""

    private var inputDeviceOptions: [AudioDevice] {
        [AudioDevice.systemDefault] + deviceManager.availableDevices
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeader

                SettingsSection("Hotkey") {
                    SettingsKeyRecorderRow(
                        title: "Recording Hotkey",
                        subtitle: "Hold to talk, or tap to toggle recording on/off. Short taps under 0.3 s are ignored to prevent accidental stops.",
                        name: .toggleRecording
                    )

                    SettingsToggleRow(
                        title: "Show confirm button (✓) in overlay",
                        subtitle: "The ✓ button stops the recording and starts transcription — same as the hotkey.",
                        isOn: $showConfirmButtonInOverlay
                    )
                }

                SettingsSection("Microphone") {
                    SettingsPickerRow(
                        title: "Input Device",
                        subtitle: "Changes apply to the next recording. Bluetooth devices may fall back to System Default.",
                        selection: $selectedDeviceUID,
                        options: inputDeviceOptions.map(\.uid)
                    ) { uid in
                        Text(inputDeviceName(for: uid))
                    }
                    .onChange(of: selectedDeviceUID) { _, newValue in
                        deviceManager.selectedDeviceUID = newValue.isEmpty ? nil : newValue
                    }
                }

                SettingsSection("Audio Ducking") {
                    SettingsToggleRow(
                        title: "Reduce system volume while recording",
                        isOn: $audioDuckingEnabled
                    )

                    if audioDuckingEnabled {
                        SettingsSliderRow(
                            title: "Target volume",
                            subtitle: "System volume will be set to \(Int(audioDuckingFactor * 100))% during recording.",
                            value: $audioDuckingFactor,
                            in: 0.05...0.3
                        )
                    }
                }

                SettingsSection("Recording Overlay") {
                    SettingsPickerRow(
                        title: "Overlay UI",
                        selection: $overlayStyleRaw,
                        options: OverlayStyle.allCases.map(\.rawValue)
                    ) { rawValue in
                        Text(OverlayStyle(rawValue: rawValue)?.displayName ?? rawValue.capitalized)
                    }

                    SettingsToggleRow(
                        title: "Show mode picker in Mini overlay",
                        subtitle: "Single source now — this is the only toggle for the Mini overlay mode picker.",
                        isOn: $showModePickerInMiniOverlay
                    )

                    SettingsButtonRow(
                        title: "Overlay position",
                        subtitle: "You can also drag the overlay; double-click resets it."
                    ) {
                        Button("Reset Position") {
                            OverlayPositionStore.clearPosition()
                        }
                        .buttonStyle(SettingsButtonStyle.standard)
                    }
                }

                SettingsSection("Delivery") {
                    SettingsToggleRow(
                        title: "Auto-paste after transcription",
                        subtitle: "Pastes the result into the frontmost app; needs Accessibility and falls back to clipboard.",
                        isOn: $autoPasteEnabled
                    )
                }
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.background)
        .onAppear {
            deviceManager.refreshDevices()
            selectedDeviceUID = deviceManager.selectedDeviceUID ?? ""
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recording")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text("Everything that happens while you record — hotkey, microphone, ducking, overlay, delivery.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputDeviceName(for uid: String) -> String {
        guard !uid.isEmpty else {
            return AudioDevice.systemDefault.name
        }

        return deviceManager.availableDevices.first { $0.uid == uid }?.name ?? "Missing device"
    }
}
