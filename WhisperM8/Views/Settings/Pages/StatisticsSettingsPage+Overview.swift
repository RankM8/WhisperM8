import Charts
import SwiftUI

// Kennzahlen-Kacheln und Zeit-Diagramme der Statistik-Seite.
extension StatisticsSettingsPage {
    func kpiGrid(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let f = locale
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatisticsTile(
                    title: "Active time",
                    value: StatisticsFormat.duration(report.activeSeconds, locale: f),
                    detail: activeTimeDetail(report),
                    secondDetail: activeTimeComparison(report)
                )
                StatisticsTile(
                    title: "Agent time",
                    value: StatisticsFormat.duration(report.agentSeconds, locale: f),
                    detail: report.activeSeconds > 0
                        ? String(localized: "\(StatisticsFormat.multiplier(report.agentSeconds / report.activeSeconds, locale: f)) your active time")
                        : nil
                )
                StatisticsTile(
                    title: "API value",
                    value: StatisticsFormat.euro(report.totalEUR, locale: f),
                    detail: data.topModelShare.map {
                        String(localized: "of which \(StatisticsFormat.percent($0.fraction, locale: f)) \($0.name)")
                    },
                    isIncomplete: isIncomplete
                )
            }
            GridRow {
                StatisticsTile(
                    title: "Leverage",
                    value: report.leverage.map { StatisticsFormat.decimal($0, digits: 1, locale: f) } ?? "–",
                    unit: report.leverage == nil ? nil : "×",
                    detail: report.leverage == nil
                        ? String(localized: "Add a subscription under Money")
                        : String(localized: "Value ÷ subscription cost"),
                    isIncomplete: isIncomplete
                )
                StatisticsTile(
                    title: "New chats",
                    value: StatisticsFormat.count(report.chatsStarted, locale: f),
                    detail: String(localized: "Ø \(StatisticsFormat.decimal(Double(report.chatsStarted) / Double(max(1, report.elapsedDays)), locale: f)) per day · peak \(StatisticsFormat.count(report.peakConcurrent, locale: f)) at once")
                )
                StatisticsTile(
                    title: "Dictations",
                    value: StatisticsFormat.count(report.dictations, locale: f),
                    detail: String(localized: "\(StatisticsFormat.integer(report.dictationAudioSeconds / 60, locale: f)) min spoken")
                )
            }
        }
    }

    private func activeTimeDetail(_ report: StatisticsReport) -> String? {
        if report.period == .day {
            guard let previous = report.previousActiveSeconds else { return nil }
            return String(localized: "Yesterday: \(StatisticsFormat.duration(previous, locale: locale))")
        }
        guard report.activeDays > 0 else { return nil }
        let average = report.activeSeconds / Double(report.activeDays)
        return String(localized: "Ø \(StatisticsFormat.duration(average, locale: locale)) per active day")
    }

    /// Vergleich als absoluter Wert: Die laufende Woche ist noch nicht vorbei,
    /// ein Prozentvergleich mit der ganzen Vorwoche wäre schief.
    private func activeTimeComparison(_ report: StatisticsReport) -> String? {
        guard let previous = report.previousActiveSeconds else { return nil }
        let value = StatisticsFormat.duration(previous, locale: locale)
        switch report.period {
        case .week: return String(localized: "Last week: \(value)")
        case .month: return String(localized: "Last month: \(value)")
        case .day, .all: return nil
        }
    }

    // MARK: - Zeit

    func timeSection(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let unit = Self.bucketUnitText(report.period)
        let total = StatisticsFormat.duration(report.activeSeconds, locale: locale)
        let concurrent = StatisticsFormat.decimal(report.averageConcurrent, locale: locale)
        let foreground = StatisticsFormat.duration(report.foregroundSeconds, locale: locale)
        return SettingsSection("Time") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    StatisticsBarChartCard(
                        title: "Your active time",
                        subtitle: String(localized: "\(unit) · \(total) in total"),
                        buckets: report.buckets,
                        metric: .active,
                        locale: locale
                    )
                    StatisticsBarChartCard(
                        title: "Agents worked",
                        subtitle: String(localized: "\(unit) · Ø \(concurrent) chats at once"),
                        buckets: report.buckets,
                        metric: .agent,
                        locale: locale
                    )
                }
                Text(String(localized: "Active time: a WhisperM8 window is in front and you typed or clicked in the last 5 minutes. Foreground time alone: \(foreground). Agent time counts every minute in which at least one chat is working, even when you are elsewhere."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }

    static func bucketUnitText(_ period: StatisticsPeriod) -> String {
        switch period {
        case .day: return String(localized: "Per hour, today")
        case .week, .month: return String(localized: "Per day")
        case .all: return String(localized: "Per month")
        }
    }
}

/// Achsenteilung der Zeit-Diagramme: höchstens vier Stufen, glatte Werte.
enum StatisticsChartScale {
    /// `maxValue` in der Anzeigeeinheit (Minuten oder Stunden).
    static func ticks(maxValue: Double, steps: [Double]) -> (top: Double, step: Double) {
        let fallback = steps.last ?? 1
        guard maxValue > 0 else { return (steps.first ?? 1, steps.first ?? 1) }
        let step = steps.first { maxValue / $0 <= 4 } ?? fallback * (maxValue / fallback / 4).rounded(.up)
        return (max(step, (maxValue / step).rounded(.up) * step), step)
    }
}

/// Ein Balkendiagramm (aktive Zeit oder Agenten-Zeit) mit eigener Auswahl.
/// Die Auswahl ist Zusatz: Summe und Durchschnitt stehen ohnehin darüber, es
/// braucht also kein Hovern, um die Werte zu sehen.
struct StatisticsBarChartCard: View {
    enum Metric {
        case active
        case agent
    }

    let title: String
    let subtitle: String
    let buckets: [StatisticsReport.Bucket]
    let metric: Metric
    let locale: Locale

    @State private var selectedKey: String?

    private func seconds(_ bucket: StatisticsReport.Bucket) -> Double {
        metric == .active ? bucket.activeSeconds : bucket.agentSeconds
    }

    private static func key(_ bucket: StatisticsReport.Bucket) -> String { "\(bucket.id)" }

    var body: some View {
        // Achse einmal je Auswertung festlegen: unter 90 Minuten Spitze in
        // Minuten, sonst in Stunden.
        let maxSeconds = buckets.map(seconds).max() ?? 0
        let usesHours = maxSeconds >= 5400
        let divisor: Double = usesHours ? 3600 : 60
        let scale = StatisticsChartScale.ticks(
            maxValue: maxSeconds / divisor,
            steps: usesHours ? [1, 2, 3, 4, 5, 10, 20, 25, 50, 100, 200, 250, 500] : [15, 30, 60]
        )
        let ticks = Array(stride(from: 0, through: scale.top, by: scale.step))
        let labeled = buckets.filter { !$0.label.isEmpty }.map(Self.key)
        let selected = selectedKey.flatMap { key in buckets.first { Self.key($0) == key } }

        VStack(alignment: .leading, spacing: 2) {
            Text(settingsLocalized: title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Group {
                if let selected {
                    Text(verbatim: selectionText(selected))
                        .foregroundStyle(AppTheme.textPrimary)
                } else {
                    Text(verbatim: subtitle)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.bottom, 6)

            Chart {
                ForEach(buckets) { bucket in
                    if bucket.isFuture {
                        RectangleMark(
                            x: .value("Slot", Self.key(bucket)),
                            yStart: .value("Value", 0),
                            yEnd: .value("Value", scale.top * 0.025),
                            width: .ratio(0.7)
                        )
                        .foregroundStyle(AppTheme.textTertiary.opacity(0.35))
                    } else {
                        BarMark(
                            x: .value("Slot", Self.key(bucket)),
                            y: .value("Value", seconds(bucket) / divisor),
                            width: .ratio(0.7)
                        )
                        .foregroundStyle(
                            selectedKey == nil || selectedKey == Self.key(bucket)
                                ? AppTheme.accent
                                : AppTheme.accent.opacity(0.4)
                        )
                        .cornerRadius(3)
                    }
                }
            }
            .chartYScale(domain: 0...scale.top)
            .chartXSelection(value: $selectedKey)
            .chartXAxis {
                AxisMarks(values: labeled) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(verbatim: buckets.first { Self.key($0) == key }?.label ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: ticks) { value in
                    AxisGridLine().foregroundStyle(AppTheme.border)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(verbatim: tickLabel(number, hours: usesHours))
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                    }
                }
            }
            .frame(height: 140)
            .accessibilityLabel(Text(settingsLocalized: title))
        }
        .statisticsCard()
    }

    private func tickLabel(_ value: Double, hours: Bool) -> String {
        hours ? StatisticsFormat.integer(value, locale: locale) + "h" : StatisticsFormat.integer(value, locale: locale) + "m"
    }

    private func selectionText(_ bucket: StatisticsReport.Bucket) -> String {
        let value = bucket.isFuture
            ? String(localized: "no data yet")
            : StatisticsFormat.duration(seconds(bucket), locale: locale)
        return "\(bucket.detail) · \(value)"
    }
}
