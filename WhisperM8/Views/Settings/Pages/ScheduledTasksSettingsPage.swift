import SwiftUI

/// Einstellungen › Labs › Geplante Aufgaben (WM8-110, Paket 1). Ein Schalter,
/// ab Werk aus. Die Ansicht in der Seitenleiste kommt mit Paket 2; bis dahin
/// werden Aufgaben über `whisperm8 schedule` angelegt und gesehen.
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

            SettingsHelpText("Tasks are set up with the command line for now: whisperm8 schedule add, list, run, pause and resume. A view in the sidebar follows.")
        }
        .onChange(of: enabled) { _, isOn in
            ScheduledTaskRuntime.shared.settingChanged(enabled: isOn)
        }
    }
}
