import LaunchAtLogin
import SwiftUI

struct GeneralSettingsPage: View {
    @AppStorage("updateCheckEnabled") private var updateCheckEnabled = true
    @ObservedObject private var themeManager = ThemeManager.shared
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var usageProfile: AppUsageProfile = AppPreferences.shared.usageProfile

    var body: some View {
        SettingsPageContainer(
            title: "General",
            subtitle: "App-wide basics: profile, appearance, startup, updates."
        ) {
            SettingsSection("Usage Profile") {
                SettingsPickerRow(
                    title: "Profile",
                    subtitle: "Switches Dock vs. menu-bar app, Agent Chats and AI enrichment. This is powerful - hence first position with a clear description.",
                    selection: $usageProfile,
                    options: AppUsageProfile.allCases
                ) { profile in
                    Text(profile.displayName)
                }
                .onChange(of: usageProfile) { _, newValue in
                    applyProfileChange(newValue)
                }
            }

            SettingsSection("Startup") {
                SettingsRow(
                    title: "Start at Login",
                    subtitle: "Placed next to the profile: with Dictation only the app starts as a menu-bar item."
                ) {
                    LaunchAtLogin.Toggle("")
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(AppTheme.statusWorking)
                }
            }

            SettingsSection("Appearance") {
                SettingsPickerRow(
                    title: "Theme",
                    selection: Binding(
                        get: { themeManager.override },
                        set: { themeManager.setOverride($0) }
                    ),
                    options: AppearanceOverride.allCases
                ) { option in
                    Text(themeName(for: option))
                }
            }

            SettingsSection("Updates") {
                SettingsToggleRow(
                    title: "Check for updates automatically",
                    subtitle: "Daily check on launch.",
                    isOn: $updateCheckEnabled
                )
            }
        }
        .onAppear {
            // Profil kann z. B. vom Onboarding oder anderen Settings-Flächen geändert worden sein.
            usageProfile = AppPreferences.shared.usageProfile
        }
    }

    private func themeName(for option: AppearanceOverride) -> String {
        switch option {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    /// Profilwechsel live anwenden: Pref + Aktivierungs-Policy (Dock/Menuebar) +
    /// Agent-Chats-Fenster oeffnen bzw. schliessen.
    private func applyProfileChange(_ profile: AppUsageProfile) {
        AppProfileActivator.apply(profile)
        if profile.wantsAgentChats {
            WindowRequestCenter.shared.request(.agentChats)
        } else {
            // Primaer- UND Sekundaerfenster schliessen; der Store-State bleibt erhalten.
            AppProfileActivator.closeAgentChatWindows(using: dismissWindow)
        }
    }
}
