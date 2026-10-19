import AppKit
import SwiftUI

/// Sektionen „ChatGPT-Konten (GPT-Backend)" + „Konto hinzufügen" auf der
/// GPT-Backend-Seite — dasselbe Bedienmodell wie der Tab „Claude Accounts":
/// Radio-Auswahl des aktiven Kontos für neue Chats, Identität + Wochen-
/// Gauge pro Konto, ⋯-Menü für Anmelden/Abmelden/Entfernen. Die Konten sind
/// Proxy-Logins (`~/.gpt-profiles/<name>`, `CCP_CONFIG_DIR`) — bewusst
/// sichtbar getrennt vom `codex login` der Codex-CLI (Befund 2026-09-16:
/// beide wurden verwechselt). Plan: docs/plans/gpt-account-switcher.md, E5.
struct GPTAccountsSection: View {
    /// Wird nach Login/Logout/Entfernen gerufen, damit die Seite ihren
    /// Status (Zeile „Authentifizierung", Einrichtung) nachzieht.
    var onAccountsChanged: () -> Void = {}

    private let profileService = GPTAccountProfiles()
    private let proxyManager = ClaudeCodeProxyManager.shared

    @State private var profiles: [GPTAccountProfile] = []
    @State private var activeProfileName = GPTAccountProfiles.mainProfileName
    @State private var usageByProfile: [String: CodexUsage] = [:]
    @State private var usageProblemByProfile: [String: String] = [:]
    @State private var runningPorts: [String: Int] = [:]
    @State private var isFetchingUsage = false
    @State private var newProfileName = ""
    @State private var feedback: String?
    @State private var feedbackTone: SettingsHelpText.Tone = .secondary
    @State private var loginProfileName: String?
    @State private var deviceCodeInfo: ClaudeCodeProxyDeviceCodeInfo?
    @State private var isDeviceLoginRunning = false
    @State private var isBusy = false

    var body: some View {
        Group {
            SettingsSection("ChatGPT accounts (GPT-Backend)") {
                ForEach(profiles) { profile in
                    profileRow(profile)
                }

                if let deviceCodeInfo, let loginProfileName {
                    deviceCodeRows(deviceCodeInfo, profileName: loginProfileName)
                }

                SettingsHelpText("The active account applies to newly started Claude chats (also for a later /model switch to GPT). Running chats keep their account; existing chats can be switched in the context menu. Background agents (claude --bg) always use the main account. These accounts are the proxy logins of the GPT-Backend — the Codex CLI, dictation and the ChatGPT app use their own “codex login”.")

                if let feedback {
                    SettingsHelpText(feedback, tone: feedbackTone)
                }
            }

            SettingsSection("Add account") {
                SettingsRow(
                    title: "New account profile",
                    subtitle: "Creates a separate proxy login (CCP_CONFIG_DIR) that stays signed in permanently. The login runs via device code in the browser — sign in there with the ChatGPT account you want; if another account is already active in the browser, use an incognito window."
                ) {
                    HStack(spacing: 8) {
                        TextField("e.g. ai", text: $newProfileName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(width: 160)

                        Button("Create & sign in…") {
                            createProfileAndLogin()
                        }
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(
                            loginInProgress
                                || !GPTAccountProfiles.isValidProfileName(
                                    newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                        )
                    }
                }

                SettingsButtonRow(
                    title: "Refresh limits",
                    subtitle: "Queries the weekly limits of all signed-in accounts live."
                ) {
                    Button {
                        fetchUsage()
                    } label: {
                        isFetchingUsage ? Text("Loading…") : Text("Refresh")
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(isFetchingUsage)
                }
            }
        }
        .onAppear { reload() }
    }

    /// Login laeuft — egal, ob aus dieser Sektion oder von der gefuehrten
    /// Einrichtung gestartet: der Manager erlaubt nur einen Device-Login und
    /// wuerde einen laufenden sonst kommentarlos beenden.
    private var loginInProgress: Bool {
        isDeviceLoginRunning || proxyManager.isDeviceLoginRunning
    }

    // MARK: - Zeilen

    @ViewBuilder
    private func profileRow(_ profile: GPTAccountProfile) -> some View {
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

    private func radioButton(for profile: GPTAccountProfile, isActive: Bool) -> some View {
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
        .disabled(!profile.isLoggedIn || isBusy || loginInProgress)
        .help(isActive
            ? Text("Active account for new GPT chats")
            : profile.isLoggedIn
                ? Text("Use this account for new GPT chats")
                : Text("Sign in first (⋯ menu)"))
    }

    private func identityColumn(for profile: GPTAccountProfile, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(settingsLocalized: profile.name)
                    .font(.system(size: 13.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AppTheme.statusWorking : AppTheme.textPrimary)

                if let plan = profile.planDisplayName ?? usageByProfile[profile.name]?.planType
                    .flatMap(GPTAccountProfiles.planDisplayName) {
                    Text(settingsLocalized: plan)
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

            if profile.isLoggedIn {
                if let email = profile.emailAddress ?? usageByProfile[profile.name]?.emailAddress {
                    Text(settingsLocalized: email)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let accountID = profile.accountID {
                    Text("Account …\(String(accountID.suffix(8)))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                if let port = runningPorts[profile.name] {
                    // verbatim: SwiftUI formatiert interpolierte Ints sonst mit
                    // Tausendertrennzeichen („18'775").
                    Text(verbatim: String(localized: "Proxy instance on port \(String(port))"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            } else if loginProfileName == profile.name, loginInProgress {
                Text("Login running…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            } else {
                Text("Not signed in")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            }
        }
    }

    @ViewBuilder
    private func gaugeColumn(for profile: GPTAccountProfile) -> some View {
        if profile.isLoggedIn {
            usageView(for: profile)
        } else {
            Button {
                startLogin(for: profile)
            } label: {
                loginProfileName == profile.name && loginInProgress ? Text("Login running…") : Text("Sign in…")
            }
            .buttonStyle(SettingsButtonStyle.standard)
            .disabled(loginInProgress)
            .help("Opens the device-code login for this profile — sign in in the browser with the ChatGPT account you want, in an incognito window if needed.")
        }
    }

    @ViewBuilder
    private func usageView(for profile: GPTAccountProfile) -> some View {
        if let usage = usageByProfile[profile.name] {
            VStack(alignment: .leading, spacing: 5) {
                if let primary = usage.primary {
                    limitGauge(label: primary.label, percent: primary.usedPercent, resetsAt: primary.resetsAt)
                }
                if let secondary = usage.secondary {
                    limitGauge(label: secondary.label, percent: secondary.usedPercent, resetsAt: secondary.resetsAt)
                }
                ForEach(usage.scopedLimits, id: \.name) { scoped in
                    limitGauge(
                        label: scoped.name,
                        percent: scoped.window.usedPercent,
                        resetsAt: scoped.window.resetsAt,
                        labelWidth: 88
                    )
                }
                if usage.isLimitReached {
                    Text("Locked — quota exhausted\(Self.untilText(Self.lockedUntil(usage)))")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(AppTheme.statusError)
                }
            }
        } else if let problem = usageProblemByProfile[profile.name] {
            Text(settingsLocalized: problem)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.statusAwaiting)
                .frame(maxWidth: 260, alignment: .leading)
        } else if isFetchingUsage {
            Text("loading…")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Reset des Fensters, das die Sperre verursacht: das spaeteste Reset
    /// unter allen vollen Fenstern. `primary` ist nicht zwingend die Woche —
    /// bei einem gesperrten Konto war bisher immer das Wochenlimit voll.
    static func lockedUntil(_ usage: CodexUsage) -> Date? {
        var windows = [usage.primary, usage.secondary].compactMap { $0 }
        windows.append(contentsOf: usage.scopedLimits.map(\.window))
        let full = windows.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt)
        return full.max() ?? windows.compactMap(\.resetsAt).max()
    }

    private func limitGauge(label: String, percent: Double?, resetsAt: Date?, labelWidth: CGFloat = 34) -> some View {
        let color: Color = {
            guard let percent else { return AppTheme.textTertiary }
            if percent >= 80 { return AppTheme.statusError }
            if percent >= 50 { return AppTheme.statusAwaiting }
            return AppTheme.statusWorking
        }()

        return HStack(spacing: 7) {
            Text(settingsLocalized: label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.textTertiary.opacity(0.18))
                    .frame(width: 72, height: 5)
                if let percent {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, 72 * min(percent, 100) / 100), height: 5)
                }
            }

            Text(settingsLocalized: percent.map { "\(Int($0.rounded())) %" } ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent != nil ? color : AppTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)

            Text(settingsLocalized: Self.resetText(resetsAt))
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 66, alignment: .leading)
        }
    }

    @ViewBuilder
    private func manageMenu(for profile: GPTAccountProfile, isActive: Bool) -> some View {
        Menu {
            Button { startLogin(for: profile) } label: { profile.isLoggedIn ? Text("Sign in again…") : Text("Sign in…") }
                .disabled(loginInProgress)
            if profile.isLoggedIn {
                Button("Sign out…") { logout(profile) }
                    .disabled(isBusy || loginInProgress)
            }
            if !profile.isMain, profile.isLoggedIn {
                Button("Make main account…") { promoteToMain(profile) }
                    .disabled(isBusy || loginInProgress)
            }
            if !profile.isMain {
                Divider()
                Button("Remove…", role: .destructive) { removeProfile(profile) }
                    .disabled(isActive || isBusy || loginInProgress)
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
        .help(profile.isMain ? Text("Sign in, sign out") : Text("Make main account, sign in, sign out, remove"))
    }

    @ViewBuilder
    private func deviceCodeRows(_ info: ClaudeCodeProxyDeviceCodeInfo, profileName: String) -> some View {
        SettingsRow(
            title: String(localized: "Login for “\(profileName)”"),
            subtitle: "Open the URL in the browser, sign in there with the ChatGPT account you want and enter the code. If another account is active in the browser, use an incognito window."
        ) {
            if let url = URL(string: info.visitURL) {
                Link(info.visitURL, destination: url)
                    .font(.system(size: 13, weight: .medium))
            } else {
                Text(settingsLocalized: info.visitURL).textSelection(.enabled)
            }
        }

        SettingsRow(title: "Device code") {
            HStack(spacing: 10) {
                Text(settingsLocalized: info.code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)
                    .textSelection(.enabled)

                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.code, forType: .string)
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }
        }
    }

    // MARK: - Laden

    private func reload() {
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        runningPorts = proxyManager.runningProfileInstances()
        fetchUsage()
    }

    /// Live-Limits je angemeldetem Konto aus dem jeweiligen Proxy-Store,
    /// parallel (ein Konto im 6-s-Timeout haelt die anderen nicht auf).
    /// Ein 401 heisst hier meist: der Datei-Token ist veraltet — die Instanz
    /// arbeitet trotzdem, nur die Anzeige fehlt.
    private func fetchUsage() {
        guard !isFetchingUsage else { return }
        isFetchingUsage = true
        let targets = profiles.filter(\.isLoggedIn)
        let service = profileService
        Task {
            let results = await withTaskGroup(of: (GPTAccountProfile, CodexUsage?).self) { group in
                for profile in targets {
                    group.addTask {
                        let usage = await CodexUsageFetcher(
                            proxyAuthFile: service.authFileURL(forProfile: profile.name)
                        ).fetchLiveUsage()
                        return (profile, usage)
                    }
                }
                var collected: [(GPTAccountProfile, CodexUsage?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            await MainActor.run {
                for (profile, usage) in results {
                    if let usage {
                        usageByProfile[profile.name] = usage
                        usageProblemByProfile[profile.name] = nil
                        if let accountID = profile.accountID {
                            try? service.writeAccountInfo(
                                GPTAccountInfo(
                                    accountID: accountID,
                                    emailAddress: usage.emailAddress,
                                    planType: usage.planType,
                                    fetchedAt: Date()
                                ),
                                forProfile: profile.name
                            )
                        }
                    } else {
                        usageByProfile[profile.name] = nil
                        usageProblemByProfile[profile.name] =
                            "Limits unavailable — token in the file is outdated. The instance keeps running; to show them, use “Sign in again…” (⋯)."
                    }
                }
                profiles = service.profiles()
                isFetchingUsage = false
            }
        }
    }

    // MARK: - Aktionen

    private func setActive(_ profile: GPTAccountProfile) {
        do {
            try profileService.setActiveProfile(profile.name)
            activeProfileName = profile.name
            showFeedback(String(localized: "New GPT chats now run through “\(profile.name)”. Running chats stay unchanged."), tone: .secondary)
        } catch {
            showFeedback(String(localized: "Could not activate account: \(error.localizedDescription)"), tone: .error)
            return
        }
        onAccountsChanged()
        guard !profile.isMain else { return }
        // Instanz vorab hochfahren, damit der erste Chat nicht in den 503-Retry laeuft.
        let manager = proxyManager
        Task.detached(priority: .userInitiated) {
            let result = manager.ensureRunning(profile: profile.name)
            await MainActor.run {
                runningPorts = manager.runningProfileInstances()
                if case .failure(let error) = result {
                    showFeedback(String(localized: "Proxy instance for “\(profile.name)” could not start: \(error.localizedDescription)"), tone: .error)
                }
            }
        }
    }

    private func createProfileAndLogin() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let profile = try profileService.createProfile(named: name)
            newProfileName = ""
            profiles = profileService.profiles()
            startLogin(for: profile)
        } catch {
            showFeedback(error.localizedDescription, tone: .error)
        }
    }

    private func startLogin(for profile: GPTAccountProfile) {
        guard !loginInProgress else {
            showFeedback("A login is already running — please finish it first.", tone: .warning)
            return
        }
        feedback = nil
        deviceCodeInfo = nil
        loginProfileName = profile.name
        isDeviceLoginRunning = true
        let others = profiles.filter { $0.name != profile.name }
        let service = profileService

        let result = proxyManager.startDeviceLogin(
            profile: profile.isMain ? nil : profile.name,
            onCodeInfo: { info in
                Task { @MainActor in deviceCodeInfo = info }
            },
            onCompletion: { exitCode in
                Task { @MainActor in
                    isDeviceLoginRunning = false
                    deviceCodeInfo = nil
                    loginProfileName = nil
                    if exitCode != 0 {
                        showFeedback(String(localized: "Login for “\(profile.name)” ended with status \(exitCode)."), tone: .error)
                    } else if let newAccountID = service.storedAccountID(forProfile: profile.name) {
                        if let duplicate = others.first(where: { $0.accountID == newAccountID }) {
                            showFeedback(String(localized: "Warning: this ChatGPT account is already connected as “\(duplicate.name)”. The browser was probably signed in to the other account — for a second account, repeat the login in an incognito window (⋯ → Sign in again…)."), tone: .warning)
                        } else {
                            showFeedback(String(localized: "“\(profile.name)” is signed in."), tone: .secondary)
                        }
                        if !profile.isMain {
                            // Laufende Instanz benutzt den alten Grant im Speicher —
                            // beim naechsten Chat startet sie mit dem neuen.
                            proxyManager.stopInstance(profile: profile.name)
                        }
                    } else {
                        showFeedback(String(localized: "Login for “\(profile.name)” finished, but no credentials were found."), tone: .error)
                    }
                    reload()
                    onAccountsChanged()
                }
            }
        )
        if case .failure(let error) = result {
            isDeviceLoginRunning = false
            loginProfileName = nil
            showFeedback(error.localizedDescription, tone: .error)
        }
    }

    private func logout(_ profile: GPTAccountProfile) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Sign out GPT account “\(profile.name)”?")
        alert.informativeText = profile.isMain
            ? String(localized: "The main account’s proxy login will be deleted. Chats on the main account then start without the GPT-Backend until you sign in again.")
            : String(localized: "This profile’s proxy login will be deleted and its instance stopped. Chats on this account run through the main account on their next start until you sign in again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Sign out"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isBusy = true
        let manager = proxyManager
        Task.detached(priority: .userInitiated) {
            let result = manager.logout(profile: profile.isMain ? nil : profile.name)
            await MainActor.run {
                isBusy = false
                switch result {
                case .success:
                    if activeProfileName == profile.name, !profile.isMain {
                        try? profileService.setActiveProfile(GPTAccountProfiles.mainProfileName)
                    }
                    usageByProfile[profile.name] = nil
                    usageProblemByProfile[profile.name] = nil
                    showFeedback(String(localized: "“\(profile.name)” is signed out."), tone: .secondary)
                case .failure(let error):
                    showFeedback(String(localized: "Sign-out failed: \(error.localizedDescription)"), tone: .error)
                }
                reload()
                onAccountsChanged()
            }
        }
    }

    /// „Zum Hauptkonto machen": der Grant des Profils ersetzt den des
    /// Default-Stores, das Profil verschwindet, seine Chats laufen ueber main
    /// weiter (laufende per Router-Umleitung, gestoppte per Stempel). Der
    /// main-Proxy startet dafuer kurz neu.
    private func promoteToMain(_ profile: GPTAccountProfile) {
        let main = profiles.first(where: \.isMain)
        let oldMain = (main?.emailAddress ?? usageByProfile[GPTAccountProfiles.mainProfileName]?.emailAddress)
            .map { " (\($0))" } ?? ""
        let newAccount = (profile.emailAddress ?? usageByProfile[profile.name]?.emailAddress)
            .map { " (\($0))" } ?? ""
        let alert = NSAlert()
        alert.messageText = String(localized: "Make “\(profile.name)” the main account?")
        alert.informativeText = String(localized: "The proxy login of “\(profile.name)”\(newAccount) replaces that of the main account\(oldMain), which is signed out in the process — sign in again under “Add account” if needed.")
            + "\n\n"
            + String(localized: "Chats on “\(profile.name)” then continue through the main account, and the profile disappears. The main account’s proxy restarts briefly for this.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Make main account"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isBusy = true
        let manager = proxyManager
        let service = profileService
        let name = profile.name
        Task.detached(priority: .userInitiated) {
            let result = manager.replaceMainGrant(withProfile: name) {
                try service.promoteToMain(name)
            }
            await MainActor.run {
                isBusy = false
                // Stempel auch bei gescheitertem main-Neustart umziehen, sobald
                // das Profil weg ist — die Dateien sind dann schon getauscht.
                let promoted = !FileManager.default.fileExists(
                    atPath: service.configDir(forProfile: name).path
                )
                if promoted {
                    let store = AgentSessionStore()
                    let stamped = store.loadWorkspace().sessions
                        .filter { $0.gptProfileName == name }
                        .map(\.id)
                    if !stamped.isEmpty {
                        try? store.setGPTSessionProfile(ids: stamped, profileName: nil)
                    }
                    usageByProfile[GPTAccountProfiles.mainProfileName] = usageByProfile.removeValue(forKey: name)
                    usageProblemByProfile[name] = nil
                }
                switch result {
                case .success:
                    showFeedback(String(localized: "“\(name)” is now the main account."), tone: .secondary)
                case .failure(let error) where promoted:
                    showFeedback(String(localized: "“\(name)” is now the main account, but the proxy did not restart: \(error.localizedDescription)"), tone: .warning)
                case .failure(let error):
                    showFeedback(error.localizedDescription, tone: .error)
                }
                reload()
                onAccountsChanged()
            }
        }
    }

    private func removeProfile(_ profile: GPTAccountProfile) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove GPT account “\(profile.name)”?")
        alert.informativeText = String(localized: "This profile’s proxy login will be deleted and its instance stopped. Chats stamped with this account are switched to the main account.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if loginProfileName == profile.name {
            proxyManager.cancelDeviceLogin()
        }
        proxyManager.stopInstance(profile: profile.name)
        // Stempel mitziehen: sonst zeigte das Kontextmenue ein Konto, das es
        // nicht mehr gibt, und der Alert-Text stimmte nicht.
        let store = AgentSessionStore()
        let stamped = store.loadWorkspace().sessions
            .filter { $0.gptProfileName == profile.name }
            .map(\.id)
        if !stamped.isEmpty {
            try? store.setGPTSessionProfile(ids: stamped, profileName: nil)
        }
        do {
            try profileService.removeProfile(named: profile.name)
            usageByProfile[profile.name] = nil
            usageProblemByProfile[profile.name] = nil
            showFeedback(String(localized: "“\(profile.name)” was removed."), tone: .secondary)
        } catch {
            showFeedback(error.localizedDescription, tone: .error)
        }
        reload()
        onAccountsChanged()
    }

    private func showFeedback(_ text: String, tone: SettingsHelpText.Tone) {
        feedback = text
        feedbackTone = tone
    }

    // MARK: - Formatierung

    private static func resetText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = resetsAt.timeIntervalSinceNow > 86_400 ? "EE HH:mm" : "HH:mm"
        return "→ \(formatter.string(from: resetsAt))"
    }

    private static func untilText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = resetsAt.timeIntervalSinceNow > 86_400 ? "EE dd.MM. HH:mm" : "HH:mm"
        return String(localized: " · free from \(formatter.string(from: resetsAt))")
    }
}
