import SwiftUI
import LaunchAtLogin

struct BehaviorSettingsView: View {
    @AppStorage("autoPasteEnabled") private var autoPasteEnabled = true
    @AppStorage("audioDuckingEnabled") private var audioDuckingEnabled = true
    @AppStorage("audioDuckingFactor") private var audioDuckingFactor = 0.2
    @AppStorage("overlayStyle") private var overlayStyleRaw = OverlayStyle.full.rawValue
    @AppStorage("selectedContextCaptureEnabled") private var selectedContextCaptureEnabled = true
    @AppStorage("visualContextCaptureEnabled") private var visualContextCaptureEnabled = true
    @AppStorage("maxScreenshotsPerRecording") private var maxScreenshotsPerRecording = AppPreferences.defaultMaxScreenshotsPerRecording
    @AppStorage("maxScreenRecordingDuration") private var maxScreenRecordingDuration = 30.0
    @AppStorage("deleteContextFilesAfterProcessing") private var deleteContextFilesAfterProcessing = false
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var usageProfile: AppUsageProfile = AppPreferences.shared.usageProfile

    var body: some View {
        Form {
            Section("Usage") {
                Picker("Profile", selection: $usageProfile) {
                    ForEach(AppUsageProfile.allCases, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .onChange(of: usageProfile) { _, newValue in
                    applyProfileChange(newValue)
                }

                Text(usageProfile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Erscheinungsbild") {
                Picker("Theme", selection: Binding(
                    get: { themeManager.override },
                    set: { themeManager.setOverride($0) }
                )) {
                    ForEach(AppearanceOverride.allCases) { option in
                        Label(option.displayName, systemImage: option.systemImage)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("\"System\" folgt macOS. Bei \"Hell\" / \"Dunkel\" wird auch Claude Code (über ~/.claude.json → light / dark-ansi) entsprechend umgestellt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-paste after transcription", isOn: $autoPasteEnabled)

                Text(autoPasteEnabled
                    ? "Transcribed text will be automatically pasted"
                    : "Transcribed text will only be copied to clipboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Selected Context") {
                Toggle("Use selected text as context", isOn: $selectedContextCaptureEnabled)

                Text("When enabled, WhisperM8 can capture highlighted text from the active app before recording and pass it to context-aware modes like Slack, WhatsApp, and Email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Visual Context") {
                Toggle("Allow screenshots and screen clips as context", isOn: $visualContextCaptureEnabled)

                Stepper(
                    "Screenshots per recording: \(maxScreenshotsPerRecording)",
                    value: $maxScreenshotsPerRecording,
                    in: 1...AppPreferences.maximumScreenshotsPerRecording
                )

                HStack {
                    Text("Max screen clip")
                    Slider(value: $maxScreenRecordingDuration, in: 5...60, step: 5)
                    Text("\(Int(maxScreenRecordingDuration))s")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }

                Toggle("Delete visual context files after processing", isOn: $deleteContextFilesAfterProcessing)

                Text("Clipboard screenshots are captured automatically while recording when you use macOS screenshot-to-clipboard. Screen clips still require Screen Recording permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio Ducking") {
                Toggle("Reduce system volume while recording", isOn: $audioDuckingEnabled)

                if audioDuckingEnabled {
                    HStack {
                        Text("Target volume")
                        Slider(value: $audioDuckingFactor, in: 0.05...0.3, step: 0.05)
                        Text("\(Int(audioDuckingFactor * 100))%")
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }

                    Text("System volume will be set to \(Int(audioDuckingFactor * 100))% during recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recording Overlay") {
                Picker("Overlay UI", selection: $overlayStyleRaw) {
                    ForEach(OverlayStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Button("Reset Overlay Position") {
                    OverlayPositionStore.clearPosition()
                }

                Text("Overlay is draggable and remembers its position.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LaunchAtLogin.Toggle("Start at Login")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Falls das Profil anderswo geändert wurde, den Picker synchron halten.
            usageProfile = AppPreferences.shared.usageProfile
        }
    }

    /// Profilwechsel live anwenden: Pref + Aktivierungs-Policy (Dock/Menüleiste) +
    /// Agent-Chats-Fenster öffnen bzw. schließen.
    private func applyProfileChange(_ profile: AppUsageProfile) {
        AppProfileActivator.apply(profile)
        if profile.wantsAgentChats {
            WindowRequestCenter.shared.request(.agentChats)
        } else {
            // Primär- UND Sekundärfenster (abgelöste Tabs) schließen — der Store-State
            // bleibt erhalten, ein Rückwechsel stellt alles wieder her.
            AppProfileActivator.closeAgentChatWindows(using: dismissWindow)
        }
    }
}
