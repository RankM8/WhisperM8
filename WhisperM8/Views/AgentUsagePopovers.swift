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
                // refreshen — onAppear bleibt passiv (Rate-Limit-Schutz).
                Button {
                    load(allowTokenRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Live aktualisieren — loggt abgelaufene Tokens neu ein")
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
            return "Token abgelaufen — mit ↻ oben aktualisieren"
        case .refreshCoolingDown(let until):
            return "Rate-Limit — Update wieder möglich ab \(AgentChatsClaudeAccountsTab.timeText(until)) Uhr"
        case .httpStatus(429):
            return "Rate-Limit von Anthropic — gleich nochmal versuchen"
        case .httpStatus(let status):
            return "Live-Abruf fehlgeschlagen (HTTP \(status))"
        case .network:
            return "Offline — letzter bekannter Stand"
        }
    }

    /// Passiv per Default — nur der ↻-Button darf abgelaufene Tokens
    /// refreshen (`allowTokenRefresh: true`), sonst Cache + Hinweis.
    private func load(allowTokenRefresh: Bool = false) {
        isLoading = true
        profiles = profileService.profiles()
        activeProfileName = profileService.activeProfileName()
        let loggedIn = profiles.filter(\.isLoggedIn).map(\.name)
        Task {
            var results: [String: ClaudeAccountUsage] = [:]
            await withTaskGroup(of: (String, ClaudeAccountUsage?).self) { group in
                for name in loggedIn {
                    group.addTask {
                        (name, await fetcher.fetchUsage(forProfile: name, allowTokenRefresh: allowTokenRefresh))
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
}

// MARK: - ChatGPT / Codex

private struct CodexUsagePopoverView: View {
    @State private var usage: CodexUsage?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PopoverHeader(title: "ChatGPT / Codex · Usage-Limits", subtitle: "Verbundener Account")

            if let usage {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if let plan = usage.planType {
                            Text(plan.capitalized)
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

                    if let primary = usage.primary {
                        UsageGaugeLine(label: primary.label, percent: primary.usedPercent, resetsAt: primary.resetsAt)
                    }
                    if let secondary = usage.secondary {
                        UsageGaugeLine(label: secondary.label, percent: secondary.usedPercent, resetsAt: secondary.resetsAt)
                    }
                    ForEach(usage.scopedLimits, id: \.name) { scoped in
                        UsageGaugeLine(label: scoped.name, percent: scoped.window.usedPercent, resetsAt: scoped.window.resetsAt, labelWidth: 88)
                    }

                    if !usage.isLive, let capturedAt = usage.capturedAt {
                        Text("Snapshot der letzten Codex-Session · \(Self.age(capturedAt))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }
            } else if isLoading {
                Text("lade Limits…")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            } else {
                Text("Keine Daten — Codex nicht eingeloggt oder noch keine Session gelaufen.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .onAppear(perform: load)
    }

    private static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(minutes) min alt" }
        return "\(minutes / 60) h alt"
    }

    private func load() {
        Task {
            let result = await CodexUsageFetcher().fetchUsage()
            await MainActor.run {
                usage = result
                isLoading = false
            }
        }
    }
}
