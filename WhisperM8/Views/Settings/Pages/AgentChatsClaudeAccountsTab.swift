import AppKit
import SwiftUI

/// Settings-Tab „Claude Accounts": Übersicht aller Claude-Code-Account-Profile
/// (main = `~/.claude`, Zusatz-Accounts = `~/.claude-profiles/<name>`), Wechsel
/// des aktiven Accounts für neue Chats und Anlegen neuer Profile. Teilt die
/// Profil-Struktur mit dem `ccs`-Terminal-CLI — beide steuern dieselbe
/// `.active`-Datei. Credentials verwaltet Claude Code selbst (Keychain pro
/// Config-Dir); WhisperM8 liest nur Metadaten.
struct AgentChatsClaudeAccountsTab: View {
    private let profileService = ClaudeAccountProfiles()

    @State private var profiles: [ClaudeAccountProfile] = []
    @State private var activeProfileName = ClaudeAccountProfiles.mainProfileName
    @State private var newProfileName = ""
    @State private var feedback: String?
    @State private var feedbackTone: SettingsHelpText.Tone = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Active Account") {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }

                SettingsHelpText("The active account applies to newly started Claude chats. Running sessions keep the account they were started with, and every chat resumes under its original account automatically. Background agents (claude --bg) currently always use the main account.")
            }

            SettingsSection("Add Account") {
                SettingsRow(
                    title: "New account profile",
                    subtitle: "Creates a separate Claude login (own CLAUDE_CONFIG_DIR) that stays signed in permanently. Settings, plugins, and commands are shared with the main account."
                ) {
                    HStack(spacing: 8) {
                        TextField("e.g. power-user2", text: $newProfileName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(width: 180)

                        Button("Create & Log in…") {
                            createProfileAndLogin()
                        }
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(!ClaudeAccountProfiles.isValidProfileName(
                            newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                    }
                }

                SettingsHelpText("A Terminal window opens with the new profile — complete the one-time browser login there (Claude asks for it automatically), then come back and refresh. No re-login is ever needed afterwards.")
            }

            if let feedback {
                SettingsHelpText(feedback, tone: feedbackTone)
            }

            SettingsButtonRow(title: "Refresh", subtitle: "Reload profiles, login state, and usage data.") {
                Button("Refresh") {
                    reload()
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: - Rows

    @ViewBuilder
    private func profileRow(_ profile: ClaudeAccountProfile) -> some View {
        let isActive = profile.name == activeProfileName

        SettingsRow(
            title: profile.isMain ? "\(profile.name) · Main account" : profile.name,
            subtitle: profileSubtitle(profile)
        ) {
            HStack(spacing: 10) {
                if let usage = usageText(for: profile) {
                    Text(usage)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                if !profile.isLoggedIn {
                    Button("Log in…") {
                        openLoginTerminal(for: profile)
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .help("Opens Terminal with this profile — complete the one-time browser login there.")
                }

                if isActive {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(AppTheme.statusWorking)
                            .frame(width: 8, height: 8)
                        Text("Active")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                } else {
                    Button("Set Active") {
                        setActive(profile)
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }

                if !profile.isMain {
                    Button("Remove…") {
                        removeProfile(profile)
                    }
                    .buttonStyle(SettingsButtonStyle.destructive)
                    .disabled(isActive)
                    .help(isActive
                        ? "Switch to another account before removing this profile."
                        : "Removes the profile folder. The Keychain login stays until you delete it manually.")
                }
            }
        }
    }

    private func profileSubtitle(_ profile: ClaudeAccountProfile) -> String {
        if let email = profile.emailAddress {
            if let org = profile.organizationName, !org.isEmpty {
                return "\(email) · \(org)"
            }
            return email
        }
        return "Not logged in yet — click “Log in…” and finish the one-time browser login."
    }

    private func usageText(for profile: ClaudeAccountProfile) -> String? {
        guard let usage = profileService.usageSnapshot(forProfile: profile.name) else {
            return nil
        }
        var parts: [String] = []
        if let fiveHour = usage.fiveHourUtilization {
            parts.append("5h \(Int(fiveHour.rounded()))%")
        }
        if let sevenDay = usage.sevenDayUtilization {
            parts.append("week \(Int(sevenDay.rounded()))%")
        }
        guard !parts.isEmpty else { return nil }
        let age = Int(Date().timeIntervalSince(usage.fetchedAt) / 60)
        parts.append(age < 1 ? "now" : "\(age)m ago")
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func reload() {
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
    }

    private func setActive(_ profile: ClaudeAccountProfile) {
        do {
            try profileService.setActiveProfile(profile.name)
            activeProfileName = profile.name
            showFeedback("New Claude chats now start as “\(profile.name)”. Running sessions are not affected.", tone: .secondary)
        } catch {
            showFeedback("Could not switch account: \(error.localizedDescription)", tone: .error)
        }
    }

    private func createProfileAndLogin() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let profile = try profileService.createProfile(named: name)
            newProfileName = ""
            reload()
            openLoginTerminal(for: profile)
            showFeedback("Profile “\(name)” created. Complete the login in the Terminal window, then hit Refresh.", tone: .secondary)
        } catch {
            showFeedback(error.localizedDescription, tone: .error)
        }
    }

    /// Öffnet Terminal.app mit einer `.command`-Datei, die Claude unter dem
    /// Profil-Config-Dir startet. Nicht eingeloggt → Claude führt selbst durch
    /// den Browser-Login. Bewusst KEIN eingebettetes PTY: der einmalige
    /// OAuth-Flow gehört in eine sichtbare, vom User kontrollierte Shell.
    private func openLoginTerminal(for profile: ClaudeAccountProfile) {
        guard let claudePath = AgentCommandBuilder.commandPath("claude") else {
            showFeedback("Claude CLI not found — install Claude Code first.", tone: .error)
            return
        }
        let script = """
        #!/bin/zsh
        export CLAUDE_CONFIG_DIR="\(profile.configDir.path)"
        echo "WhisperM8 · Claude account profile “\(profile.name)”"
        echo "Log in once (/login) — afterwards this profile stays signed in permanently."
        exec "\(claudePath)"
        """
        let commandURL = profile.configDir.appendingPathComponent("login.command")
        do {
            try script.write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: commandURL.path
            )
            NSWorkspace.shared.open(commandURL)
        } catch {
            showFeedback("Could not open the login Terminal: \(error.localizedDescription)", tone: .error)
        }
    }

    private func removeProfile(_ profile: ClaudeAccountProfile) {
        let alert = NSAlert()
        alert.messageText = "Remove account profile “\(profile.name)”?"
        alert.informativeText = "Deletes \(profile.configDir.path) including its chat history. The Keychain login entry is kept — remove it via Keychain Access if you want it gone. Sessions that ran under this profile can no longer be resumed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(at: profile.configDir)
            reload()
            showFeedback("Profile “\(profile.name)” removed.", tone: .secondary)
        } catch {
            showFeedback("Could not remove profile: \(error.localizedDescription)", tone: .error)
        }
    }

    private func showFeedback(_ message: String, tone: SettingsHelpText.Tone) {
        feedback = message
        feedbackTone = tone
    }
}
