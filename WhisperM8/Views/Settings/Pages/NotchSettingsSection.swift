import SwiftUI

/// Einstellungen der Statusanzeige an der Notch (Tab Workspace der Agent-Chats-Seite).
struct NotchSettingsSection: View {
    @AppStorage(PreferenceKeys.notchStatusEnabled) private var isEnabled = true
    @AppStorage(PreferenceKeys.notchStatusScreen) private var screenRaw = NotchScreenChoice.auto.rawValue
    @AppStorage(PreferenceKeys.notchStatusHideFromCapture) private var hideFromCapture = true
    @AppStorage(PreferenceKeys.notchStatusShowFreshDone) private var showFreshDone = true
    @AppStorage(PreferenceKeys.notchStatusExpandOnHover) private var expandOnHover = false

    var body: some View {
        if AppPreferences.shared.isNotchStatusFeatureEnabled {
            SettingsSection("Notch Status") {
                SettingsToggleRow(
                    title: "Show chat status at the notch",
                    subtitle: "A small strip at the notch shows how many chats are working or waiting for you. Click it to see the list and jump to a chat. On a display without a notch, the Agent Chats window's display always shows a dark pill instead. On by default.",
                    isOn: $isEnabled
                )

                SettingsPickerRow(
                    title: "Display",
                    subtitle: "Where the notch strip appears. Automatic uses the built-in display with a notch, otherwise the main display. The pill always follows the Agent Chats window when its display has no notch.",
                    selection: $screenRaw,
                    options: NotchScreenChoice.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(settingsLocalized: screenLabel(for: rawValue))
                }

                SettingsToggleRow(
                    title: "Hide from screenshots and screen sharing",
                    subtitle: "Asks macOS to keep the strip out of screenshots and screen sharing. Some recording and meeting apps may still show it.",
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

                SettingsButtonRow(
                    title: "Pill position",
                    subtitle: "Drag the pill anywhere on its display; each display remembers its own spot. Double-click the pill to put it back at the top center."
                ) {
                    Button("Reset position") {
                        AppPreferences.shared.notchPillPositions = [:]
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }

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
