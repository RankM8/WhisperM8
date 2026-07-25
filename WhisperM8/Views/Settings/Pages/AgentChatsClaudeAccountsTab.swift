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
    /// Profile mit laufendem Einzel-Update (⋯-Menü → „Update usage").
    @State private var refreshingProfiles: Set<String> = []
    /// Tickt, damit die globale Sperre nach Ablauf von selbst wieder freigibt.
    @State private var tick = Date()

    /// Ende der prozessweiten Sperre nach dem letzten Token-Refresh.
    private var cooldownEnd: Date? {
        ClaudeTokenRefreshThrottle.shared.globalCooldownEnd(now: tick)
    }
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

            // Bewusst kein „alle aktualisieren": Anthropic drosselt den
            // OAuth-Token-Endpoint so hart, dass ein einziger Sammelklick
            // sämtliche Accounts in die Sperre laufen lassen kann. Aktualisiert
            // wird gezielt pro Account über das ⋯-Menü.
            SettingsHelpText(
                cooldownEnd.map {
                    "Usage-Updates gesperrt bis \(Self.timeText($0)) Uhr — Anthropic drosselt Token-Refreshes hart. Danach über das ⋯-Menü einzeln aktualisieren."
                } ?? "Limits werden beim Öffnen aus dem Cache geladen. Für einen Live-Stand einen einzelnen Account über sein ⋯-Menü aktualisieren — nie alle auf einmal.",
                tone: cooldownEnd == nil ? .secondary : .warning
            )
        }
        .onAppear { reload() }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    // MARK: - Rows

    /// Dashboard-Zeile: Radio-Auswahl (Klick = aktiv) · Identitäts-Spalte
    /// fester Breite · Gauge-Spalte (fluchtet dadurch über alle Zeilen) ·
    /// ⋯-Menü für die seltenen Verwaltungs-Aktionen. Die Daten tragen die
    /// Seite, destruktive Buttons dominieren sie nicht mehr.
    @ViewBuilder
    private func profileRow(_ profile: ClaudeAccountProfile) -> some View {
        let isActive = profile.name == activeProfileName

        HStack(alignment: .top, spacing: 14) {
            radioButton(for: profile, isActive: isActive)
                .padding(.top, 2)

            identityColumn(for: profile, isActive: isActive)
                .frame(width: 230, alignment: .leading)

            gaugeColumn(for: profile)
                .frame(minWidth: 215, alignment: .leading)

            Spacer(minLength: 8)

            manageMenu(for: profile, isActive: isActive)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
                .frame(height: 1)
        }
    }

    /// Radio-Indikator: gefüllt = aktiver Account, Klick macht den Account
    /// aktiv. Ersetzt den „Set Active"-Button — Auswahl ist EIN Klick.
    private func radioButton(for profile: ClaudeAccountProfile, isActive: Bool) -> some View {
        Button {
            guard !isActive else { return }
            setActive(profile)
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(
                        isActive ? AppTheme.statusWorking : AppTheme.textTertiary.opacity(0.55),
                        lineWidth: 1.5
                    )
                    .frame(width: 15, height: 15)
                if isActive {
                    Circle()
                        .fill(AppTheme.statusWorking)
                        .frame(width: 7, height: 7)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!profile.isLoggedIn)
        .help(isActive
            ? "Active account for new Claude chats"
            : profile.isLoggedIn
                ? "Use this account for new Claude chats"
                : "Log in first (⋯ menu)")
    }

    private func identityColumn(for profile: ClaudeAccountProfile, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(profile.name)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AppTheme.statusWorking : AppTheme.textPrimary)

                if let plan = profile.planDisplayName {
                    Text(plan)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                }

                if profile.isMain {
                    Text("main")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(Capsule().strokeBorder(AppTheme.border, lineWidth: 1))
                }
            }

            if let email = profile.emailAddress {
                Text(email)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Org nur wenn sie mehr sagt als „<email>'s Organization"
                if let org = profile.organizationName, !org.isEmpty,
                   !org.hasSuffix("'s Organization"), !org.hasSuffix("’s Organization") {
                    Text(org)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Not logged in")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            }
        }
    }

    /// Gauge-Spalte; für nicht eingeloggte Profile sitzt hier der sichtbare
    /// Login-Einstieg (die einzige Aktion, die ein frisches Profil braucht).
    @ViewBuilder
    private func gaugeColumn(for profile: ClaudeAccountProfile) -> some View {
        if profile.isLoggedIn {
            usageView(for: profile)
        } else {
            Button("Log in…") {
                openLoginTerminal(for: profile)
            }
            .buttonStyle(SettingsButtonStyle.standard)
            .help("Opens Terminal with this profile — complete the one-time browser login there.")
        }
    }

    /// Login des Profils nicht mehr nutzbar (Token abgelaufen und Refresh
    /// fehlgeschlagen, oder Keychain-Item weg) → „Log in…" wieder anbieten.
    private func needsRelogin(_ profile: ClaudeAccountProfile) -> Bool {
        switch usageByProfile[profile.name]?.liveFetchProblem {
        case .loginExpired, .noCredentials: return true
        default: return false
        }
    }

    /// ⋯-Menü: dauerhaft sichtbar (kein Hover-only), bündelt die seltenen
    /// Verwaltungs-Aktionen. Destruktives nur hier, nie als Flächen-Button.
    private func manageMenu(for profile: ClaudeAccountProfile, isActive: Bool) -> some View {
        Menu {
            if profile.isLoggedIn {
                // Einzel-Update statt „alle": Anthropics Token-Endpoint ist pro
                // Account streng gedrosselt, ein Sammellauf verbrennt im
                // Fehlerfall das Budget aller Accounts.
                Button(cooldownEnd.map { "Update usage (ab \(Self.timeText($0)) Uhr)" } ?? "Update usage") {
                    refreshSingle(profile.name)
                }
                .disabled(refreshingProfiles.contains(profile.name) || cooldownEnd != nil)
            }
            if !profile.isLoggedIn || needsRelogin(profile) {
                Button("Log in…") { openLoginTerminal(for: profile) }
            }
            if !profile.isMain {
                Divider()
                Button("Rename…") { renameProfile(profile) }
                Button("Remove…", role: .destructive) { removeProfile(profile) }
                    .disabled(isActive)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(profile.isMain ? "Update usage" : "Update usage, rename, log in, remove")
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
                if usage.hasLimitData {
                    limitGauge(label: "5h", percent: usage.fiveHourPercent, resetsAt: usage.fiveHourResetsAt)
                    limitGauge(label: "wk", percent: usage.sevenDayPercent, resetsAt: usage.sevenDayResetsAt)
                    if let modelPercent = usage.modelWeeklyPercent {
                        limitGauge(
                            label: usage.modelWeeklyLabel ?? "model",
                            percent: modelPercent,
                            resetsAt: usage.modelWeeklyResetsAt
                        )
                    }
                }
                if !usage.isLive, usage.hasLimitData {
                    Text(cacheAgeText(usage.fetchedAt))
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                if let problem = usage.liveFetchProblem {
                    Text(Self.problemText(problem))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.statusAwaiting)
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
                .lineLimit(1)
                .frame(width: 34, alignment: .leading)

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

    /// Warum kein Live-Stand geholt werden konnte — sichtbar statt still auf
    /// den Cache zurückzufallen (sonst wirkt „cache · 3320 min alt" wie ein
    /// Anzeigefehler, obwohl der Login des Accounts abgelaufen ist).
    static func problemText(_ problem: ClaudeUsageFetchProblem) -> String {
        switch problem {
        case .noCredentials:
            return "no login token in Keychain — log in again (⋯ menu)"
        case .loginExpired:
            return "login expired — re-login via ⋯ → Log in…"
        case .refreshBlockedBySession:
            return "token expired — the running session refreshes it, retry shortly"
        case .tokenExpired:
            return "token expired — press “Update” below to fetch fresh limits"
        case .refreshCoolingDown(let until):
            return "rate-limited — next update possible at \(timeText(until))"
        case .httpStatus(429):
            return "rate-limited by Anthropic — try again in a few minutes"
        case .httpStatus(let status):
            return "live fetch failed (HTTP \(status))"
        case .network:
            return "offline — showing last known state"
        }
    }

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Actions

    /// Immer passiv — Reloads (onAppear, nach Account-Aktionen) treffen den
    /// streng gedrosselten OAuth-Token-Endpoint nie. Tokens erneuert nur der
    /// gezielte Einzel-Update im ⋯-Menü.
    private func reload() {
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        // Statusline-Marker nachziehen (heilt auch aeltere Profile ohne Datei)
        for profile in profiles where !profile.isMain {
            profileService.writeKeychainServiceMarker(forProfile: profile.name)
        }
        fetchUsageForAllProfiles()
    }

    /// Holt die Limits aller eingeloggten Accounts aus dem Cache bzw. live mit
    /// dem vorhandenen Token. Darf parallel laufen: gedrosselt ist der
    /// Token-Endpoint, nicht dieser Abruf.
    private func fetchUsageForAllProfiles() {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        let loggedIn = profiles.filter(\.isLoggedIn).map(\.name)
        Task {
            var results: [String: ClaudeAccountUsage] = [:]
            await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
                for name in loggedIn {
                    group.addTask {
                        (name, await usageFetcher.fetchUsage(forProfile: name, allowTokenRefresh: false))
                    }
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

    /// Aktualisiert genau einen Account.
    private func refreshSingle(_ name: String) {
        guard !refreshingProfiles.contains(name) else { return }
        refreshingProfiles.insert(name)
        Task {
            let usage = await usageFetcher.fetchUsage(forProfile: name, allowTokenRefresh: true)
            await MainActor.run {
                if let usage { usageByProfile[name] = usage }
                refreshingProfiles.remove(name)
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
        alert.informativeText = "Moves \(profile.configDir.path) — including its chat history — to the Trash, so you can restore it if needed. The Keychain login entry is kept — remove it via Keychain Access if you want it gone. Sessions that ran under this profile can no longer be resumed while the folder is in the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            // Papierkorb statt endgültigem Löschen (Review-Befund 2026-07-13):
            // im Config-Dir liegt unter projects/ die komplette Chat-Historie
            // des Accounts — ein Fehlklick darf sie nicht unwiederbringlich
            // vernichten.
            try FileManager.default.trashItem(at: profile.configDir, resultingItemURL: nil)
            reload()
            showFeedback("Profile “\(profile.name)” moved to Trash.", tone: .secondary)
        } catch {
            showFeedback("Could not remove profile: \(error.localizedDescription)", tone: .error)
        }
    }

    private func showFeedback(_ message: String, tone: SettingsHelpText.Tone) {
        feedback = message
        feedbackTone = tone
    }
}
