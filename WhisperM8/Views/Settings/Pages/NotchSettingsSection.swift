import SwiftUI

/// Einstellungen der Statusanzeige an der Notch (Tab Workspace der Agent-Chats-Seite).
struct NotchSettingsSection: View {
    @AppStorage(PreferenceKeys.notchStatusEnabled) private var isEnabled = false
    @AppStorage(PreferenceKeys.notchStatusScreen) private var screenRaw = NotchScreenChoice.auto.rawValue
    @AppStorage(PreferenceKeys.notchStatusHideFromCapture) private var hideFromCapture = true
    @AppStorage(PreferenceKeys.notchStatusShowFreshDone) private var showFreshDone = true
    @AppStorage(PreferenceKeys.notchStatusExpandOnHover) private var expandOnHover = false

    var body: some View {
        if AppPreferences.shared.isNotchStatusFeatureEnabled {
            SettingsSection("Notch Status") {
                SettingsToggleRow(
                    title: "Show chat status at the notch",
                    subtitle: "A small strip at the notch (or a pill at the top of the screen without one) shows how many chats are working or waiting for you. Click it to see the list and jump to a chat. Off by default.",
                    isOn: $isEnabled
                )

                SettingsPickerRow(
                    title: "Display",
                    subtitle: "Automatic uses the built-in display with a notch, otherwise the main display.",
                    selection: $screenRaw,
                    options: NotchScreenChoice.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(settingsLocalized: screenLabel(for: rawValue))
                }

                SettingsToggleRow(
                    title: "Hide from screenshots and screen sharing",
                    subtitle: "Keeps chat titles out of recordings and shared screens.",
                    isOn: $hideFromCapture
                )

                SettingsToggleRow(
                    title: "Show finished chats",
                    subtitle: "Counts chats that just finished and briefly widens the strip when one does.",
                    isOn: $showFreshDone
                )

                SettingsToggleRow(
                    title: "Open the list on hover",
                    subtitle: "In addition to clicking. Off by default so the list does not pop open when the pointer passes by.",
                    isOn: $expandOnHover
                )

                SettingsKeyRecorderRow(
                    title: "Show or hide hotkey",
                    subtitle: "Turns the notch status on or off from anywhere.",
                    name: .toggleNotchStatus
                )
            }
        }
    }

    private func screenLabel(for rawValue: String) -> String {
        switch rawValue {
        case NotchScreenChoice.auto.rawValue: return "Automatic"
        case NotchScreenChoice.builtIn.rawValue: return "Built-in display"
        case NotchScreenChoice.main.rawValue: return "Main display"
        default: return rawValue
        }
    }
}
