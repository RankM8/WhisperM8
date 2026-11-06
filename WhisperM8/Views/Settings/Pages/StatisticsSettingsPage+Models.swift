import SwiftUI

// Abschnitte „Modelle & Token“ und „Geld“ der Statistik-Seite.
extension StatisticsSettingsPage {
    func modelsSection(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let segments = modelSegments(data)
        return SettingsSection("Models & tokens") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if isIncomplete {
                        Text("Incomplete while your previous chats are being imported")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    accountPicker(report)
                }
                if report.models.isEmpty {
                    Text("No tokens in this period.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.vertical, 6)
                } else {
                    StatisticsShareBar(segments: segments)
                    StatisticsLegend(segments: segments)
                    ViewThatFits(in: .horizontal) {
                        modelTable(data)
                        ScrollView(.horizontal) { modelTable(data).padding(.bottom, 8) }
                    }
                    .padding(.top, 4)
                    if report.unpricedTokens > 0 {
                        Text(String(localized: "\(StatisticsFormat.tokens(report.unpricedTokens, locale: locale)) tokens from models without a known API price are not included in the value."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(String(localized: "“Value” is what the same tokens would cost through the API, using the Anthropic and OpenAI price lists, converted at the ECB daily rate (1 $ = \(StatisticsFormat.decimal(report.usdEurRate, digits: 2, locale: locale)) €). With a subscription you do not pay it. GPT through the proxy runs on your ChatGPT plan and is not counted in the Claude accounts. Each response counts once, even if it ends up in two accounts after an account switch."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }

    private func accountPicker(_ report: StatisticsReport) -> some View {
        // Ein gewähltes Konto bleibt wählbar, auch wenn es im neuen Zeitraum keine Token hat.
        var options = report.accounts
        if let account, !options.contains(account) { options.append(account) }
        return Picker("Account", selection: $account) {
            Text("All accounts").tag(String?.none)
            ForEach(options, id: \.self) { name in
                Text(verbatim: StatisticsAccountName.display(name)).tag(String?.some(name))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func modelSegments(_ data: StatisticsPageData) -> [StatisticsShareSegment] {
        let report = data.report
        let byEuro = report.totalEUR > 0
        let total = byEuro ? report.totalEUR : Double(max(1, report.totalTokens))
        return report.models.map { row in
            let part = byEuro ? (row.eur ?? 0) : Double(row.usage.totalTokens)
            let fraction = part / total
            return StatisticsShareSegment(
                id: row.model,
                name: row.displayName,
                fraction: fraction,
                color: StatisticsColors.model(row.model, order: data.modelOrder),
                valueText: byEuro && row.eur == nil ? "–" : StatisticsFormat.percent(fraction, digits: 1, locale: locale)
            )
        }
    }

    private func modelTable(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let totals = data.tokenTotals
        let f = locale
        return Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                StatisticsColumnHeader(title: "Model").gridColumnAlignment(.leading)
                StatisticsColumnHeader(title: "Responses")
                StatisticsColumnHeader(title: "Input")
                StatisticsColumnHeader(title: "Output")
                StatisticsColumnHeader(title: "Cache write")
                StatisticsColumnHeader(title: "Cache read")
                StatisticsColumnHeader(title: "Value")
            }
            .padding(.bottom, 7)
            tableDivider(strong: false)
            ForEach(report.models) { row in
                GridRow {
                    modelCell(row, data: data)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridColumnAlignment(.leading)
                    numberCell(StatisticsFormat.count(row.usage.messages, locale: f))
                    numberCell(StatisticsFormat.tokens(row.usage.input, locale: f))
                    numberCell(StatisticsFormat.tokens(row.usage.output, locale: f))
                    numberCell(StatisticsFormat.tokens(row.usage.cacheWrite, locale: f))
                    numberCell(StatisticsFormat.tokens(row.usage.cacheRead, locale: f))
                    numberCell(row.eur.map { StatisticsFormat.euro($0, locale: f) } ?? "–", emphasized: true)
                }
                .padding(.vertical, 8)
                tableDivider(strong: false)
            }
            GridRow {
                Text("Total").gridColumnAlignment(.leading)
                numberCell(StatisticsFormat.count(totals.messages, locale: f), emphasized: true)
                numberCell(StatisticsFormat.tokens(totals.input, locale: f), emphasized: true)
                numberCell(StatisticsFormat.tokens(totals.output, locale: f), emphasized: true)
                numberCell(StatisticsFormat.tokens(totals.cacheWrite, locale: f), emphasized: true)
                numberCell(StatisticsFormat.tokens(totals.cacheRead, locale: f), emphasized: true)
                numberCell(StatisticsFormat.euro(report.totalEUR, locale: f), emphasized: true)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.top, 8)
        }
    }

    private func tableDivider(strong: Bool) -> some View {
        Rectangle()
            .fill(strong ? AppTheme.borderStrong : AppTheme.border)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    private func modelCell(_ row: StatisticsReport.ModelRow, data: StatisticsPageData) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(StatisticsColors.model(row.model, order: data.modelOrder))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Group {
                    switch data.modelSources[row.model] ?? .claudeCode {
                    case .claudeCode: Text("Claude Code")
                    case .proxy: Text("GPT via proxy, ChatGPT plan")
                    case .codex: Text("Codex CLI")
                    case .codexAndProxy: Text("Codex CLI and proxy")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .lineLimit(1)
    }

    private func numberCell(_ text: String, emphasized: Bool = false) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12.5, weight: emphasized ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(emphasized ? AppTheme.textPrimary : AppTheme.textSecondary)
            .lineLimit(1)
    }

    // MARK: - Geld

    func moneySection(_ data: StatisticsPageData) -> some View {
        let report = data.report
        let phrase = StatisticsPeriodText.phrase(for: report, locale: locale)
        return SettingsSection("Money") {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Leverage of your subscriptions \(phrase)"))
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(verbatim: report.leverage.map { StatisticsFormat.decimal($0, digits: 1, locale: locale) } ?? "–")
                            .font(.system(size: 34, weight: .heavy))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.textPrimary)
                        if report.leverage != nil {
                            Text(verbatim: "×")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        if isIncomplete {
                            Text("· incomplete")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                    }
                    Group {
                        if report.leverage != nil {
                            Text(String(localized: "\(StatisticsFormat.euro(report.totalEUR, locale: locale)) API value against \(StatisticsFormat.euro(report.subscriptionCostEUR, locale: locale)) in subscription costs (\(StatisticsFormat.euro(report.subscriptionMonthlyEUR, locale: locale)) per month, prorated for the period)."))
                        } else {
                            Text("Add the subscriptions you pay for to see how much more you get out of them.")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    StatisticsCaption(title: "What you pay per month")
                    ForEach($subscriptions) { $subscription in
                        subscriptionRow($subscription)
                    }
                    Button("Add subscription") {
                        subscriptions.append(StatisticsSubscription(
                            name: String(localized: "New subscription"),
                            count: 1,
                            monthlyEUR: 20
                        ))
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .statisticsCard()
            .padding(.top, 8)
        }
    }

    private func subscriptionRow(_ subscription: Binding<StatisticsSubscription>) -> some View {
        let id = subscription.wrappedValue.id
        let count = Binding<Int>(
            get: { subscription.wrappedValue.count },
            set: { subscription.wrappedValue.count = max(0, min(99, $0)) }
        )
        let price = Binding<Double>(
            get: { subscription.wrappedValue.monthlyEUR },
            set: { subscription.wrappedValue.monthlyEUR = max(0, $0) }
        )
        return HStack(spacing: 8) {
            TextField("Name", text: subscription.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            TextField("Count", value: count, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 44)
            Text(verbatim: "×")
                .foregroundStyle(AppTheme.textTertiary)
            TextField("Per month", value: price, format: .currency(code: "EUR").locale(locale))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 84)
            Button {
                subscriptions.removeAll { $0.id == id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove subscription")
            .accessibilityLabel(Text("Remove subscription"))
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 3)
    }
}
