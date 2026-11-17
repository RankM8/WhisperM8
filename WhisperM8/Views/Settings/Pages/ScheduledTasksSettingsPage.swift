import SwiftUI

/// Einstellungen › Labs › Geplante Aufgaben (WM8-110). Ein Schalter, ab Werk
/// aus. Aufgaben stehen im Abschnitt „Geplant“ der Seitenleiste (Paket 2) und
/// in `whisperm8 schedule`.
struct ScheduledTasksSettingsPage: View {
    @AppStorage(PreferenceKeys.scheduledTasksEnabled) private var enabled = false

    var body: some View {
        SettingsPageContainer(
            title: "Scheduled tasks",
            subtitle: "Recurring Claude runs that WhisperM8 starts at a set time."
        ) {
            SettingsLabsNotice("New and experimental. Off by default. Runs only start while WhisperM8 is running; a run missed while the Mac slept or the app was closed is caught up within 12 hours.")

            SettingsSection("Scheduled tasks") {
                SettingsToggleRow(
                    title: "Run scheduled tasks",
                    subtitle: "At each scheduled time, WhisperM8 starts claude -p in the task's project folder and account. Each run becomes a normal chat. A run keeps going when WhisperM8 restarts.",
                    isOn: $enabled
                )
            }

            SettingsHelpText("Tasks appear at the bottom of the sidebar under Scheduled, below the chats: add them with +, open one for its runs. The command line works too: whisperm8 schedule add, list, run, pause and resume.")
        }
        .onChange(of: enabled) { _, isOn in
            ScheduledTaskRuntime.shared.settingChanged(enabled: isOn)
        }
    }
}
