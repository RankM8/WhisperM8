import KeyboardShortcuts
import SwiftUI

/// Abschnitt „Pille und Notch“ auf der Seite General: alles, was die vereinte
/// Pille betrifft (Diktat und Chat-Status in einer Pille). Recording und Agent
/// Chats verweisen hierher. Nur mit eingeschalteter vereinter Pille; sonst
/// gelten die alten Abschnitte dort.
struct PillSettingsSection: View {
    @AppStorage(PreferenceKeys.notchStatusEnabled) private var isStatusEnabled = true
    @AppStorage(PreferenceKeys.notchStatusHideFromCapture) private var hideFromCapture = true
    @AppStorage(PreferenceKeys.notchStatusShowFreshDone) private var showFreshDone = true
    @AppStorage(PreferenceKeys.notchStatusExpandOnHover) private var expandOnHover = false
    @AppStorage(PreferenceKeys.pillSolidBlackEnabled) private var solidBlack = false

    var body: some View {
        if AppPreferences.shared.isUnifiedPillEnabled {
            SettingsSection("Pill and Notch") {
                if AppPreferences.shared.isNotchStatusFeatureEnabled {
                    SettingsToggleRow(
                        title: "Show chat status in the pill",
                        subtitle: "The pill at the top of the screen (on a MacBook: the notch) shows how many chats are working or waiting for you. Click the counters for the list, click the gray core to start dictating. Off: the pill only appears while you dictate or use the controller.",
                        isOn: $isStatusEnabled
                    )
                }

                SettingsToggleRow(
                    title: "Solid black background",
                    subtitle: "Draws the pill in deep black like the notch, also on displays without one, instead of dark glass. Applies to every state: at rest, the list, dictation and the controller island.",
                    isOn: $solidBlack
                )

                SettingsToggleRow(
                    title: "Hide from screenshots and screen sharing",
                    subtitle: "Applies to the whole pill, dictation included. Asks macOS to keep it out of screenshots and screen sharing; some recording and meeting apps may still show it.",
                    isOn: $hideFromCapture
                )

                if AppPreferences.shared.isNotchStatusFeatureEnabled {
                    SettingsToggleRow(
                        title: "Show finished chats",
                        subtitle: "Counts chats that just finished and briefly widens the pill when one does.",
                        isOn: $showFreshDone
                    )

                    SettingsToggleRow(
                        title: "Open the list on hover",
                        subtitle: "In addition to clicking, only while you are not dictating.",
                        isOn: $expandOnHover
                    )
                }

                SettingsButtonRow(
                    title: "Pill position",
                    subtitle: "Drag the pill anywhere on a display without a notch; each display remembers its own spot. Double-click the pill to put it back at the top center. At the notch the pill stays put."
                ) {
                    Button("Reset position") {
                        AppPreferences.shared.notchPillPositions = [:]
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }

                if AppPreferences.shared.isNotchStatusFeatureEnabled {
                    SettingsKeyRecorderRow(
                        title: "Open status list hotkey",
                        subtitle: "Opens the chat list with the keyboard: arrow keys choose, Return opens the chat, Esc closes.",
                        name: .openNotchStatusList
                    )

                    SettingsKeyRecorderRow(
                        title: "Show or hide status hotkey",
                        subtitle: "Turns the chat status in the pill on or off from anywhere.",
                        name: .toggleNotchStatus
                    )
                }
            }
        }
    }
}

/// Verweis aus Recording und Agent Chats auf den Abschnitt „Pille und Notch“.
struct PillSettingsLinkRow: View {
    let subtitle: String

    var body: some View {
        SettingsButtonRow(title: "Pill and notch", subtitle: subtitle) {
            Button("Open in General") {
                WindowRequestCenter.shared.requestSettings(routeID: SettingsPage.general.rawValue)
            }
            .buttonStyle(SettingsButtonStyle.standard)
        }
    }
}
