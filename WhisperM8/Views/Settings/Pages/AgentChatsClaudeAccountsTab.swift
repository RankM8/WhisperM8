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
    private let usageFetcher = ClaudeAccountUsageFetcher()

    @State private var profiles: [ClaudeAccountProfile] = []
    @State private var activeProfileName = ClaudeAccountProfiles.mainProfileName
    @State private var usageByProfile: [String: ClaudeAccountUsage] = [:]
    @State private var isFetchingUsage = false
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
                usageView(for: profile)

                if !profile.isMain {
                    Button {
                        renameProfile(profile)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .help("Rename profile (keeps the login — the Keychain entry moves along)")
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

    /// Limit-Anzeige pro Account: zwei ausgerichtete Gauge-Zeilen (5h-Fenster
    /// + Wochen-Limit) mit Kapsel-Balken, farbcodiertem Prozentwert und
    /// Reset-Zeit. Feste Spaltenbreiten, damit die Balken über alle
    /// Account-Zeilen hinweg eine vergleichbare Spalte bilden. Dauerhaft
    /// sichtbar (kein Hover); Cache-Stände sind als solche markiert.
    @ViewBuilder
    private func usageView(for profile: ClaudeAccountProfile) -> some View {
        if let usage = usageByProfile[profile.name] {
            VStack(alignment: .leading, spacing: 5) {
                limitGauge(label: "5h", percent: usage.fiveHourPercent, resetsAt: usage.fiveHourResetsAt)
                limitGauge(label: "wk", percent: usage.sevenDayPercent, resetsAt: usage.sevenDayResetsAt)
                if !usage.isLive {
                    Text(cacheAgeText(usage.fetchedAt))
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
        } else if profile.isLoggedIn, isFetchingUsage {
            Text("loading…")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func limitGauge(label: String, percent: Double?, resetsAt: Date?) -> some View {
        let color: Color = {
            guard let percent else { return AppTheme.textTertiary }
            if percent >= 80 { return AppTheme.statusError }
            if percent >= 50 { return AppTheme.statusAwaiting }
            return AppTheme.statusWorking
        }()

        return HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 18, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.textTertiary.opacity(0.18))
                    .frame(width: gaugeWidth, height: 5)
                if let percent {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, gaugeWidth * min(percent, 100) / 100), height: 5)
                }
            }

            Text(percent.map { "\(Int($0.rounded())) %" } ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent != nil ? color : AppTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)

            Text(resetText(resetsAt))
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 66, alignment: .leading)
        }
    }

    private var gaugeWidth: CGFloat { 72 }

    /// „→ 23:09" (5h-Fenster) bzw. „→ Sa 19:00" (Reset liegt > 24 h voraus).
    private func resetText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = resetsAt.timeIntervalSinceNow > 86_400 ? "EE HH:mm" : "HH:mm"
        return "→ \(formatter.string(from: resetsAt))"
    }

    private func cacheAgeText(_ fetchedAt: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(fetchedAt) / 60)
        return minutes < 1 ? "cache" : "cache · \(minutes) min alt"
    }

    // MARK: - Actions

    private func reload() {
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        // Statusline-Marker nachziehen (heilt auch aeltere Profile ohne Datei)
        for profile in profiles where !profile.isMain {
            profileService.writeKeychainServiceMarker(forProfile: profile.name)
        }
        fetchUsageForAllProfiles()
    }

    /// Holt die Limits ALLER eingeloggten Accounts parallel — live vom
    /// oauth/usage-Endpoint, mit Statusline-Cache als Fallback.
    private func fetchUsageForAllProfiles() {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        let loggedIn = profiles.filter(\.isLoggedIn).map(\.name)
        Task {
            var results: [String: ClaudeAccountUsage] = [:]
            await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
                for name in loggedIn {
                    group.addTask { (name, await usageFetcher.fetchUsage(forProfile: name)) }
                }
                for await (name, usage) in group {
                    if let usage { results[name] = usage }
                }
            }
            let finalResults = results
            await MainActor.run {
                usageByProfile = finalResults
                isFetchingUsage = false
            }
        }
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

    /// Rename-Dialog: neuer Name via NSAlert-Textfeld. Der Service zieht das
    /// Keychain-Item mit um (Login bleibt erhalten), danach werden die
    /// Session-Stempel im Store nachgezogen. Blockiert, solange irgendeine
    /// Session dieses Profils läuft — deren CLAUDE_CONFIG_DIR zeigt auf den
    /// alten Pfad.
    private func renameProfile(_ profile: ClaudeAccountProfile) {
        let store = AgentSessionStore()
        let runningIDs = AgentTerminalRegistry.shared.activeSessionIDs
        let hasRunningSession = store.loadWorkspace().sessions.contains {
            $0.claudeProfileName == profile.name && runningIDs.contains($0.id)
        }
        guard !hasRunningSession else {
            showFeedback("“\(profile.name)” has running sessions — stop them before renaming.", tone: .warning)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Rename account profile “\(profile.name)”"
        alert.informativeText = "The login is kept — the Keychain entry moves to the new name automatically. All chats of this profile keep working."
        let field = NSTextField(string: profile.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newName != profile.name else { return }
        do {
            try profileService.renameProfile(from: profile.name, to: newName)
            try store.renameClaudeSessionProfiles(from: profile.name, to: newName)
            usageByProfile[newName] = usageByProfile.removeValue(forKey: profile.name)
            reload()
            showFeedback("Profile renamed to “\(newName)”. Login and chats moved along.", tone: .secondary)
        } catch {
            showFeedback(error.localizedDescription, tone: .error)
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
