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
            .help("Claude-Accounts: Usage-Limits")
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
            .help("ChatGPT/Codex: Usage-Limits")
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
                .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 66, alignment: .leading)
        }
    }

    static func resetText(_ resetsAt: Date?) -> String {
        guard let resetsAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = resetsAt.timeIntervalSinceNow > 86_400 ? "EE HH:mm" : "HH:mm"
        return "→ \(formatter.string(from: resetsAt))"
    }
}

private struct PopoverHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
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
                PopoverHeader(title: "Claude · Usage-Limits", subtitle: "Alle verbundenen Accounts")
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
                .help("Live aktualisieren — erneuert abgelaufene Tokens per Claude-CLI-Ping")
            }

            if isLoading, usageByProfile.isEmpty {
                Text("lade Limits…")
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
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if let email = profile.emailAddress {
                            Text(email)
                                .font(.system(size: 9.5))
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
                                .font(.system(size: 9.5))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                        if let problem = usage.liveFetchProblem {
                            Text(Self.problemText(problem))
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(AppTheme.statusAwaiting)
                        }
                    } else if !isLoading {
                        Text("keine Daten")
                            .font(.system(size: 10.5))
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
        if minutes < 60 { return "\(minutes) min alt" }
        return "\(minutes / 60) h alt"
    }

    private static func problemText(_ problem: ClaudeUsageFetchProblem) -> String {
        switch problem {
        case .noCredentials:
            return "Kein Login-Token — in den Account-Settings neu einloggen"
        case .loginExpired:
            return "Login abgelaufen — in den Account-Settings neu einloggen"
        case .refreshBlockedBySession:
            return "Token abgelaufen — die laufende Session erneuert ihn gleich"
        case .tokenExpired:
            return "Token abgelaufen — ↻ erneuert ihn per CLI-Ping"
        case .refreshCoolingDown(let until):
            return "Gerade gepingt — nächster Versuch ab \(AgentChatsClaudeAccountsTab.timeText(until)) Uhr"
        case .httpStatus(429):
            return "Rate-Limit von Anthropic — gleich nochmal versuchen"
        case .httpStatus(let status):
            return "Live-Abruf fehlgeschlagen (HTTP \(status))"
        case .network:
            return "Offline — letzter bekannter Stand"
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
            PopoverHeader(
                title: "ChatGPT · GPT-Backend",
                subtitle: profilesEnabled ? "Konten des GPT-Backends (Proxy-Login)" : "Verbundenes Konto (Proxy-Login)"
            )

            if isLoading, usageByProfile.isEmpty {
                Text("lade Limits…")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            let loggedIn = profiles.filter(\.isLoggedIn)
            if loggedIn.isEmpty, !isLoading {
                Text("Kein GPT-Konto angemeldet — Einstellungen → GPT-Backend.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            ForEach(loggedIn) { profile in
                accountBlock(profile)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Codex-CLI / Diktat")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary)
                if let usage = cliUsage {
                    usageRows(usage, showEmail: true)
                } else if !isLoading {
                    Text("Keine Daten — Codex nicht eingeloggt oder noch keine Session gelaufen.")
                        .font(.system(size: 10.5))
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
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                }
                if isActive, profilesEnabled {
                    Text("aktiv")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(AppTheme.statusWorking)
                }
                Spacer(minLength: 0)
                if let email = profile.emailAddress ?? usageByProfile[profile.name]?.emailAddress {
                    Text(email)
                        .font(.system(size: 9.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let usage = usageByProfile[profile.name] {
                usageRows(usage, showEmail: false)
            } else if failedProfiles.contains(profile.name) {
                Text("Limits nicht abrufbar (Token in der Datei veraltet)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AppTheme.statusAwaiting)
            } else if !isLoading {
                Text("keine Daten")
                    .font(.system(size: 10.5))
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
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(AppTheme.textTertiary.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                if let email = usage.emailAddress {
                    Text(email)
                        .font(.system(size: 9.5))
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
            Text("Gesperrt — Kontingent erschöpft")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(AppTheme.statusError)
        }
        if !usage.isLive, let capturedAt = usage.capturedAt {
            Text("Snapshot der letzten Codex-Session · \(Self.age(capturedAt))")
                .font(.system(size: 9.5))
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(minutes) min alt" }
        return "\(minutes / 60) h alt"
    }

    private func load() {
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        let service = profileService
        let targets = profiles.filter(\.isLoggedIn)
        Task {
            for profile in targets {
                let usage = await CodexUsageFetcher(
                    proxyAuthFile: service.authFileURL(forProfile: profile.name)
                ).fetchLiveUsage()
                await MainActor.run {
                    if let usage {
                        usageByProfile[profile.name] = usage
                    } else {
                        failedProfiles.insert(profile.name)
                    }
                }
            }
            let cli = await CodexUsageFetcher().fetchUsage()
            await MainActor.run {
                cliUsage = cli
                isLoading = false
            }
        }
    }
}
