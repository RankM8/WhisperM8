import SwiftUI

// Abschnitte „Limits“, „Chats“, „Diktate“ und „Git“ der Statistik-Seite.
extension StatisticsSettingsPage {
    // MARK: - Limits

    func limitsSection(_ data: StatisticsPageData) -> some View {
        let rows = data.report.limits
        return SettingsSection("Limits") {
            VStack(alignment: .leading, spacing: 8) {
                if rows.isEmpty {
                    SettingsHelpText("Limits appear as soon as the Claude Code status line or Codex has reported them once.")
                        .padding(.vertical, 6)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            StatisticsColumnHeader(title: "Account")
                            StatisticsColumnHeader(title: "5 hours")
                            StatisticsColumnHeader(title: "Week")
                            StatisticsColumnHeader(title: "History")
                        }
                        .padding(.vertical, 8)
                        ForEach(rows) { row in
                            Rectangle().fill(AppTheme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                            limitRow(row, now: data.now)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.borderStrong, lineWidth: 1)
                    )
                }
                SettingsHelpText("From the status line, without any network request. The history shows the highest weekly usage of the last 8 weeks; yellow means the limit was reached.")
            }
            .padding(.top, 8)
        }
    }

    private func limitRow(_ row: StatisticsReport.LimitRow, now: Date) -> some View {
        let current = row.current
        return GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: limitAccountName(row))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                if let plan = row.plan, !plan.isEmpty {
                    Text(verbatim: plan)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            .frame(minWidth: 130, alignment: .leading)

            if let percent = current?.fiveHourPercent {
                limitMeter(percent: percent, caption: current?.fiveHourResetsAt.map { relativeReset($0, now: now) })
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "–")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(AppTheme.textTertiary)
                    Text("no 5-hour window")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .frame(width: 150, alignment: .leading)
            }

            if let percent = current?.weekPercent {
                limitMeter(
                    percent: percent,
                    caption: current?.weekResetsAt.map {
                        String(localized: "Reset \(StatisticsFormat.weekdayTime($0, locale: locale))")
                    }
                )
            } else {
                Text(verbatim: "–")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(width: 150, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 3) {
                limitHistory(row.weeklyPeaks)
                Text(String(localized: "\(row.weeksAtLimit) of 8 weeks at limit"))
                    .font(.system(size: 11))
                    .foregroundStyle(row.weeksAtLimit > 0 ? AppTheme.statusAwaiting : AppTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func limitAccountName(_ row: StatisticsReport.LimitRow) -> String {
        if row.provider == "chatgpt" {
            let name = StatisticsAccountName.display(row.account)
            return name == "ChatGPT" ? String(localized: "ChatGPT (GPT proxy)") : name
        }
        return StatisticsAccountName.display(row.account)
    }

    private func relativeReset(_ date: Date, now: Date) -> String {
        guard date > now else { return String(localized: "resetting") }
        return String(localized: "in \(StatisticsFormat.duration(date.timeIntervalSince(now), locale: locale))")
    }

    private func limitMeter(percent: Double, caption: String?) -> some View {
        let warn = percent >= 80
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: StatisticsFormat.percentValue(percent, locale: locale))
                    .font(.system(size: 12.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(warn ? AppTheme.statusAwaiting : AppTheme.textPrimary)
                Spacer(minLength: 4)
                if let caption {
                    Text(verbatim: caption)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            StatisticsMeter(fraction: percent / 100, color: warn ? AppTheme.statusAwaiting : AppTheme.accent)
        }
        .frame(width: 150, alignment: .leading)
    }

    private func limitHistory(_ peaks: [Double?]) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(peaks.enumerated()), id: \.offset) { _, peak in
                let full = (peak ?? 0) >= 99.5
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(peak == nil
                          ? AppTheme.control
                          : (full ? AppTheme.statusAwaiting : AppTheme.accent.opacity(0.85)))
                    .frame(height: max(2, 28 * CGFloat(min(100, peak ?? 4)) / 100))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 150, height: 28, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: peaks.map { $0.map { StatisticsFormat.percentValue($0, locale: locale) } ?? "–" }.joined(separator: ", ")))
    }

    // MARK: - Chats

    func chatsSection(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let f = locale
        let perDay = Double(report.chatsStarted) / Double(max(1, report.elapsedDays))
        return SettingsSection("Chats") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        StatisticsTile(
                            title: "New chats",
                            value: StatisticsFormat.count(report.chatsStarted, locale: f),
                            detail: String(localized: "Ø \(StatisticsFormat.decimal(perDay, locale: f)) per day"),
                            large: false
                        )
                        StatisticsTile(
                            title: "Working at once",
                            value: StatisticsFormat.decimal(report.averageConcurrent, locale: f),
                            detail: String(localized: "Ø, peak \(StatisticsFormat.count(report.peakConcurrent, locale: f))"),
                            large: false
                        )
                        StatisticsTile(
                            title: "Background agents",
                            value: StatisticsFormat.count(report.chatsByKind[.background] ?? 0, locale: f),
                            detail: "claude --bg",
                            large: false
                        )
                        StatisticsTile(
                            title: "Subagents",
                            value: StatisticsFormat.count(report.subagents, locale: f),
                            detail: String(localized: "started from chats"),
                            large: false
                        )
                    }
                }

                let mix = chatMixSegments(report)
                VStack(alignment: .leading, spacing: 6) {
                    StatisticsCaption(title: "What you worked with")
                    if mix.isEmpty {
                        Text("No chats started in this period.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        StatisticsShareBar(segments: mix)
                        StatisticsLegend(segments: mix)
                    }
                }

                if !report.projects.isEmpty {
                    projectTable(report)
                }
            }
            .padding(.top, 8)
        }
    }

    /// Hintergrund-Agenten sind Claude-Chats und zählen im Mix zu Claude.
    private func chatMixSegments(_ report: StatisticsReport) -> [StatisticsShareSegment] {
        let claude = (report.chatsByKind[.claude] ?? 0) + (report.chatsByKind[.background] ?? 0)
        let parts: [(String, String, Int, Color)] = [
            ("claude", "Claude", claude, StatisticsColors.claude),
            ("gpt", String(localized: "GPT in Claude Code"), report.chatsByKind[.gpt] ?? 0, StatisticsColors.gpt),
            ("codex", "Codex", report.chatsByKind[.codex] ?? 0, StatisticsColors.codex),
        ]
        let total = parts.reduce(0) { $0 + $1.2 }
        guard total > 0 else { return [] }
        return parts.filter { $0.2 > 0 }.map { id, name, count, color in
            let fraction = Double(count) / Double(total)
            return StatisticsShareSegment(
                id: id,
                name: name,
                fraction: fraction,
                color: color,
                valueText: StatisticsFormat.percent(fraction, locale: locale)
            )
        }
    }

    private func projectTable(_ report: StatisticsReport) -> some View {
        // Die größten sechs Projekte einzeln, der Rest als „Other“.
        let shown = Array(report.projects.prefix(6))
        let rest = report.projects.dropFirst(6)
        let restEUR = rest.reduce(0) { $0 + $1.eur }
        let restChats = rest.reduce(0) { $0 + $1.chats }
        let byEuro = report.projects.contains { $0.eur > 0 }
        let maxValue = max(1e-9, shown.map { byEuro ? $0.eur : Double($0.chats) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            StatisticsColumnHeader(title: "Projects by value")
                .padding(.bottom, 6)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(shown) { project in
                    Rectangle().fill(AppTheme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    projectRow(
                        name: Text(verbatim: project.name),
                        fraction: (byEuro ? project.eur : Double(project.chats)) / maxValue,
                        eur: project.eur,
                        chats: project.chats
                    )
                }
                if !rest.isEmpty {
                    Rectangle().fill(AppTheme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    projectRow(
                        name: Text("Other"),
                        fraction: (byEuro ? restEUR : Double(restChats)) / maxValue,
                        eur: restEUR,
                        chats: restChats
                    )
                }
            }
        }
    }

    private func projectRow(name: Text, fraction: Double, eur: Double, chats: Int) -> some View {
        GridRow {
            name
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            StatisticsMeter(fraction: fraction, color: AppTheme.accent.opacity(0.85), height: 6)
                .frame(width: 180)
            Text(verbatim: StatisticsFormat.euro(eur, locale: locale))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(AppTheme.textSecondary)
                .gridColumnAlignment(.trailing)
            Text(String(localized: "\(StatisticsFormat.count(chats, locale: locale)) chats"))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(AppTheme.textSecondary)
                .gridColumnAlignment(.trailing)
        }
        .padding(.vertical, 7)
    }

    // MARK: - Diktate

    func dictationSection(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let f = locale
        let perDay = Double(report.dictations) / Double(max(1, report.elapsedDays))
        let averageSeconds = report.dictations > 0 ? report.dictationAudioSeconds / Double(report.dictations) : 0
        let saved = StatisticsFormat.typingSeconds(words: report.dictationWords)
        let totalModes = report.dictationModes.reduce(0) { $0 + $1.count }
        let topMode = report.dictationModes.first
        var modeDetail: String?
        if let topMode, totalModes > 0 {
            let share = StatisticsFormat.percent(Double(topMode.count) / Double(totalModes), locale: f)
            if report.dictationModes.count > 1 {
                let next = report.dictationModes[1]
                let nextShare = StatisticsFormat.percent(Double(next.count) / Double(totalModes), locale: f)
                modeDetail = String(localized: "\(share) · then \(next.name) \(nextShare)")
            } else {
                modeDetail = share
            }
        }
        return SettingsSection("Dictations") {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    StatisticsTile(
                        title: "Dictations",
                        value: StatisticsFormat.count(report.dictations, locale: f),
                        detail: String(localized: "Ø \(StatisticsFormat.integer(perDay, locale: f)) per day"),
                        large: false
                    )
                    StatisticsTile(
                        title: "Spoken",
                        value: String(localized: "\(StatisticsFormat.integer(report.dictationAudioSeconds / 60, locale: f)) min"),
                        detail: String(localized: "Ø \(StatisticsFormat.integer(averageSeconds, locale: f)) s per dictation"),
                        large: false
                    )
                    StatisticsTile(
                        title: "Words",
                        value: StatisticsFormat.count(report.dictationWords, locale: f),
                        detail: String(localized: "≈ \(StatisticsFormat.duration(saved, locale: f)) of typing saved"),
                        large: false
                    )
                    StatisticsTile(
                        title: "Most used mode",
                        value: topMode?.name ?? "–",
                        detail: modeDetail,
                        large: false
                    )
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Git

    func gitSection(_ data: StatisticsPageData) -> some View {
        let report = data.report
        return SettingsSection("Git") {
            VStack(alignment: .leading, spacing: 0) {
                if report.git.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Commits and pull requests per project")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("They appear after the first run. Counted are your commits in the project folders of your chats (local git log, once an hour) and, if gh is signed in, your pull requests.")
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AppTheme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            StatisticsColumnHeader(title: "Project")
                            StatisticsColumnHeader(title: "Commits").gridColumnAlignment(.trailing)
                            StatisticsColumnHeader(title: "Pull requests").gridColumnAlignment(.trailing)
                        }
                        .padding(.bottom, 7)
                        ForEach(report.git.prefix(10)) { row in
                            Rectangle().fill(AppTheme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                            GridRow {
                                Text(verbatim: row.project)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                gitNumber(row.commits)
                                gitNumber(row.pullRequests)
                            }
                            .padding(.vertical, 7)
                        }
                        Rectangle().fill(AppTheme.borderStrong).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text("Total")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            gitNumber(report.commits, emphasized: true)
                            gitNumber(report.pullRequests, emphasized: true)
                        }
                        .padding(.vertical, 7)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private func gitNumber(_ value: Int, emphasized: Bool = false) -> some View {
        Text(verbatim: StatisticsFormat.count(value, locale: locale))
            .font(.system(size: 12.5, weight: emphasized ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(emphasized ? AppTheme.textPrimary : AppTheme.textSecondary)
    }
}
