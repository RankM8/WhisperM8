import SwiftUI

/// Zwei Footer-Icons in der Agent-Chats-Sidebar (Claude + ChatGPT/Codex):
/// Klick öffnet ein Popover mit den Usage-Limits aller verbundenen Accounts.
/// Claude speist sich aus den Account-Profilen (`ClaudeAccountProfiles` +
/// Live-Fetch), Codex aus `wham/usage` mit JSONL-Snapshot-Fallback.
struct SidebarUsageButtons: View {
    @State private var showClaudePopover = false
    @State private var showCodexPopover = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showClaudePopover.toggle()
            } label: {
                // Offizielles Provider-Logo — dieselben Assets wie in
                // Sidebar-Rows und Tab-Chips (ProviderIcon).
                ProviderIcon(
                    provider: .claude,
                    size: 13,
                    tint: showClaudePopover ? AgentTheme.accent : AgentTheme.textSecondary
                )
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Claude accounts: usage limits")
            .popover(isPresented: $showClaudePopover, arrowEdge: .bottom) {
                ClaudeUsagePopoverView()
            }

            Button {
                showCodexPopover.toggle()
            } label: {
                ProviderIcon(
                    provider: .codex,
                    size: 13,
                    tint: showCodexPopover ? AgentTheme.accent : AgentTheme.textSecondary
                )
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ChatGPT/Codex: usage limits")
            .popover(isPresented: $showCodexPopover, arrowEdge: .bottom) {
                CodexUsagePopoverView()
            }
        }
    }
}

// MARK: - Gemeinsame Gauge-Zeile

/// Kompakte Limit-Zeile für die Popovers: Label · Kapsel-Balken · Prozent ·
/// Reset — dieselbe Lesart wie im Claude-Accounts-Settings-Tab.
private struct UsageGaugeLine: View {
    var label: String
    var percent: Double?
    var resetsAt: Date?
    var labelWidth: CGFloat = 40

    private var color: Color {
        guard let percent else { return AppTheme.textTertiary }
        if percent >= 80 { return AppTheme.statusError }
        if percent >= 50 { return AppTheme.statusAwaiting }
        return AppTheme.statusWorking
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.textTertiary.opacity(0.18))
                    .frame(width: 88, height: 5)
                if let percent {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, 88 * min(percent, 100) / 100), height: 5)
                }
            }

            Text(percent.map { "\(Int($0.rounded())) %" } ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent != nil ? color : AppTheme.textTertiary)
                .frame(width: 38, alignment: .trailing)

            Text(Self.resetText(resetsAt))
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 66, alignment: .leading)
        }
    }

    static func resetText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        return "→ \(UsageResetDateFormat.short(resetsAt))"
    }
}

private struct PopoverHeader: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }
}

// MARK: - Claude

private struct ClaudeUsagePopoverView: View {
    private let profileService = ClaudeAccountProfiles()
    private let fetcher = ClaudeAccountUsageFetcher()

    @State private var profiles: [ClaudeAccountProfile] = []
    @State private var activeProfileName = ClaudeAccountProfiles.mainProfileName
    @State private var usageByProfile: [String: ClaudeAccountUsage] = [:]
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                PopoverHeader(title: "Claude · Usage limits", subtitle: "All connected accounts")
                Spacer(minLength: 0)
                // Manuelles Update: einziger Weg, abgelaufene Tokens zu
                // erneuern (CLI-Ping) — onAppear bleibt passiv.
                Button {
                    update()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Live refresh — renews expired tokens via Claude CLI ping")
            }

            if isLoading, usageByProfile.isEmpty {
                Text("Loading limits…")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            ForEach(profiles.filter(\.isLoggedIn)) { profile in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.system(size: 11.5, weight: profile.name == activeProfileName ? .semibold : .medium))
                            .foregroundStyle(profile.name == activeProfileName ? AppTheme.statusWorking : AppTheme.textPrimary)
                        if let plan = profile.planDisplayName {
                            Text(plan)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if let email = profile.emailAddress {
                            Text(email)
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if let usage = usageByProfile[profile.name] {
                        if usage.hasLimitData {
                            UsageGaugeLine(label: "5h", percent: usage.fiveHourPercent, resetsAt: usage.fiveHourResetsAt)
                            UsageGaugeLine(label: "wk", percent: usage.sevenDayPercent, resetsAt: usage.sevenDayResetsAt)
                            if let model = usage.modelWeeklyPercent {
                                UsageGaugeLine(
                                    label: usage.modelWeeklyLabel ?? "model",
                                    percent: model,
                                    resetsAt: usage.modelWeeklyResetsAt
                                )
                            }
                        }
                        if !usage.isLive, usage.hasLimitData {
                            Text("Cache · \(Self.age(usage.fetchedAt))")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                        if let problem = usage.liveFetchProblem {
                            Text(Self.problemText(problem))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.statusAwaiting)
                        }
                    } else if !isLoading {
                        Text("No data")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .onAppear { load() }
    }

    private static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return String(localized: "\(minutes) min old") }
        return String(localized: "\(minutes / 60) h old")
    }

    private static func problemText(_ problem: ClaudeUsageFetchProblem) -> String {
        switch problem {
        case .noCredentials:
            return String(localized: "No login token — sign in again in the account settings")
        case .loginExpired:
            return String(localized: "Login expired — sign in again in the account settings")
        case .refreshBlockedBySession:
            return String(localized: "Token expired — the running session will renew it shortly")
        case .tokenExpired:
            return String(localized: "Token expired — ↻ renews it via CLI ping")
        case .refreshCoolingDown(let until):
            return String(localized: "Just pinged — next attempt from \(AgentChatsClaudeAccountsTab.timeText(until))")
        case .httpStatus(429):
            return String(localized: "Rate limit from Anthropic — try again shortly")
        case .httpStatus(let status):
            return String(localized: "Live fetch failed (HTTP \(status))")
        case .network:
            return String(localized: "Offline — last known state")
        }
    }

    /// Passiv (onAppear): nur lesen, nie Tokens anfassen.
    private func load() {
        isLoading = true
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        let loggedIn = profiles.filter(\.isLoggedIn).map(\.name)
        Task {
            var results: [String: ClaudeAccountUsage] = [:]
            await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
                for name in loggedIn {
                    group.addTask {
                        (name, await fetcher.fetchUsage(forProfile: name))
                    }
                }
                for await (name, usage) in group {
                    if let usage { results[name] = usage }
                }
            }
            let finalResults = results
            await MainActor.run {
                usageByProfile = finalResults
                isLoading = false
            }
        }
    }

    /// ↻-Button: gemeinsamer Update-Flow mit dem Accounts-Tab — abgelaufene
    /// Tokens werden seriell per CLI-Ping erneuert, Zeilen aktualisieren
    /// einzeln.
    private func update() {
        guard !isLoading else { return }
        isLoading = true
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        let loggedIn = profiles.filter(\.isLoggedIn).map(\.name)
        Task {
            _ = await ClaudeUsageUpdateFlow.run(profileNames: loggedIn) { name, usage in
                usageByProfile[name] = usage
            }
            await MainActor.run { isLoading = false }
        }
    }
}

// MARK: - ChatGPT / Codex

/// Zwei Bloecke: die Konten des GPT-Backends (Proxy-Logins, je eigener
/// Store — das sind die Konten, die GPT-Chats tatsaechlich belasten) und
/// darunter das Konto der Codex-CLI (`~/.codex/auth.json`: Diktat,
/// `whisperm8 agent`, ChatGPT-App). Die Trennung ist Absicht: am 16.09.2026
/// zeigte das Popover das frisch umgeloggte CLI-Konto mit freiem Kontingent,
/// waehrend jede GPT-Session weiter gegen das gesperrte Proxy-Konto lief.
/// Welche GPT-Backend-Konten das Popover zeigt und live abfragt (pur, testbar).
/// Ausgeschaltetes Backend = keine Proxy-Konten und keine authentisierten
/// Abrufe bei chatgpt.com, auch wenn auf Disk noch ein alter Login liegt
/// (LR-GPT-007). Das Codex-CLI-Konto fragt das Popover unabhängig davon ab.
enum CodexUsagePopoverTargets {
    static func displayedProfiles(
        backendEnabled: Bool,
        profilesEnabled: Bool,
        all: () -> [GPTAccountProfile],
        main: () -> GPTAccountProfile
    ) -> [GPTAccountProfile] {
        guard backendEnabled else { return [] }
        // Kill-Switch aus → nur das Hauptkonto, sonst listete das Popover
        // Zusatzkonten, die kein Chat nutzen kann.
        return profilesEnabled ? all() : [main()]
    }

    static func fetchTargets(_ profiles: [GPTAccountProfile]) -> [GPTAccountProfile] {
        profiles.filter(\.isLoggedIn)
    }
}

private struct CodexUsagePopoverView: View {
    private let profileService = GPTAccountProfiles()

    @State private var profiles: [GPTAccountProfile] = []
    @State private var activeProfileName = GPTAccountProfiles.mainProfileName
    @State private var usageByProfile: [String: CodexUsage] = [:]
    @State private var failedProfiles: Set<String> = []
    @State private var cliUsage: CodexUsage?
    @State private var isLoading = true

    private var profilesEnabled: Bool { AppPreferences.shared.isGPTAccountProfilesEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                PopoverHeader(
                    title: "ChatGPT · GPT Backend",
                    subtitle: profilesEnabled ? "Accounts of the GPT backend (proxy login)" : "Connected account (proxy login)"
                )
                Spacer(minLength: 0)
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Fetch limits again")
            }

            if isLoading, usageByProfile.isEmpty {
                Text("Loading limits…")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            let loggedIn = profiles.filter(\.isLoggedIn)
            if loggedIn.isEmpty, !isLoading {
                Text("No GPT account signed in — Settings → GPT Backend.")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            ForEach(loggedIn) { profile in
                accountBlock(profile)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Codex CLI / dictation")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                if let usage = cliUsage {
                    usageRows(usage, showEmail: true)
                } else if !isLoading {
                    Text("No data — Codex is not signed in or no session has run yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func accountBlock(_ profile: GPTAccountProfile) -> some View {
        let isActive = profile.name == activeProfileName
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(profile.name)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? AppTheme.statusWorking : AppTheme.textPrimary)
                if let plan = profile.planDisplayName
                    ?? usageByProfile[profile.name]?.planType.flatMap(GPTAccountProfiles.planDisplayName) {
                    Text(plan)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                }
                if isActive, profilesEnabled {
                    Text("active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.statusWorking)
                }
                Spacer(minLength: 0)
                if let email = profile.emailAddress ?? usageByProfile[profile.name]?.emailAddress {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let usage = usageByProfile[profile.name] {
                usageRows(usage, showEmail: false)
            } else if failedProfiles.contains(profile.name) {
                Text("Limits unavailable (token in the file is stale)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            } else if !isLoading {
                Text("No data")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func usageRows(_ usage: CodexUsage, showEmail: Bool) -> some View {
        if showEmail {
            HStack(spacing: 6) {
                if let plan = GPTAccountProfiles.planDisplayName(usage.planType) {
                    Text(plan)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                if let email = usage.emailAddress {
                    Text(email)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        if let primary = usage.primary {
            UsageGaugeLine(label: primary.label, percent: primary.usedPercent, resetsAt: primary.resetsAt)
        }
        if let secondary = usage.secondary {
            UsageGaugeLine(label: secondary.label, percent: secondary.usedPercent, resetsAt: secondary.resetsAt)
        }
        ForEach(usage.scopedLimits, id: \.name) { scoped in
            UsageGaugeLine(label: scoped.name, percent: scoped.window.usedPercent, resetsAt: scoped.window.resetsAt, labelWidth: 88)
        }
        if usage.isLimitReached {
            Text("Blocked — quota exhausted")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.statusError)
        }
        if !usage.isLive, let capturedAt = usage.capturedAt {
            Text("Snapshot of the last Codex session · \(Self.age(capturedAt))")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return String(localized: "\(minutes) min old") }
        return String(localized: "\(minutes / 60) h old")
    }

    private func load() {
        profiles = CodexUsagePopoverTargets.displayedProfiles(
            backendEnabled: AppPreferences.shared.claudeGPTBackendEnabled,
            profilesEnabled: profilesEnabled,
            all: { profileService.profiles() },
            main: { profileService.profile(named: GPTAccountProfiles.mainProfileName) }
        )
        activeProfileName = profileService.activeProfileName()
        isLoading = true
        failedProfiles = []
        let service = profileService
        let targets = CodexUsagePopoverTargets.fetchTargets(profiles)
        Task {
            // Parallel: ein Konto im Timeout (6 s) darf die anderen nicht aufhalten.
            let results = await withTaskGroup(of: (String, CodexUsage?).self) { group in
                for profile in targets {
                    group.addTask {
                        let usage = await CodexUsageFetcher(
                            proxyAuthFile: service.authFileURL(forProfile: profile.name)
                        ).fetchLiveUsage()
                        return (profile.name, usage)
                    }
                }
                var collected: [(String, CodexUsage?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            let cli = await CodexUsageFetcher().fetchUsage()
            await MainActor.run {
                for (name, usage) in results {
                    if let usage {
                        usageByProfile[name] = usage
                    } else {
                        usageByProfile[name] = nil
                        failedProfiles.insert(name)
                    }
                }
                cliUsage = cli
                isLoading = false
            }
        }
    }
}
