import SwiftUI

// Limits-Karte der Dynamic Island (R1 + ▲, Insel-Paket): alle Claude- und
// GPT-Konten mit 5-Stunden- und Wochenfenster, verbraucht wie im Popover.
// Reine Darstellung; scrollen und auffrischen macht der Ausführer.

extension ControllerIslandView {
    private static let limitsNameWidth: CGFloat = 150
    private static let limitsGaugeWidth: CGFloat = 238
    private static let limitsRowHeight: CGFloat = 32

    func limits(_ card: ControllerLimitsCard) -> some View {
        let now = Date()
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Color.clear.frame(width: Self.limitsNameWidth, height: 1)
                Text("5 h").frame(width: Self.limitsGaugeWidth, alignment: .leading)
                Text("Week").frame(width: Self.limitsGaugeWidth, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.tertiary)
            .padding(.horizontal, 8)
            .frame(height: 18)

            VStack(spacing: 0) {
                if card.hiddenAbove > 0 { moreLimits(String(localized: "↑ \(card.hiddenAbove) more")) }
                ForEach(card.visibleRows) { row in
                    if card.startsSection(row) || row.id == card.visibleRows.first?.id {
                        limitsSection(row.kind)
                    }
                    limitsRow(row, now: now)
                }
                if card.hiddenBelow > 0 { moreLimits(String(localized: "↓ \(card.hiddenBelow) more")) }
                if card.rows.isEmpty {
                    Text("No account signed in")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .frame(height: 34)
                }
            }
            .overlay(alignment: .trailing) { limitsScrollBar(card) }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            IslandFlow(spacing: 12, lineSpacing: 5) {
                if card.canScroll { footItem("L", String(localized: "stick: scroll"), round: false) }
                footItem(ControllerButton.cross.glyph,
                         card.isLoading ? String(localized: "refreshing …") : String(localized: "refresh"))
                footItem(ControllerButton.r1.glyph, String(localized: "release: close"), round: false)
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 7)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
    }

    private func limitsSection(_ kind: ControllerAccountChoice.Kind) -> some View {
        Text(verbatim: Self.sectionTitle(kind))
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(palette.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    /// Fachnamen, unübersetzt.
    private static func sectionTitle(_ kind: ControllerAccountChoice.Kind) -> String {
        switch kind {
        case .claude: return "Claude"
        case .gpt: return "GPT"
        }
    }

    private func moreLimits(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiary)
            .frame(height: 16)
    }

    private func limitsRow(_ row: ControllerAccountLimitRow, now: Date) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Text(verbatim: row.name)
                    .font(.system(size: 12.5, weight: row.isCurrentChat ? .bold : .medium))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isCurrentChat {
                    Text("this chat")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.markBorder)
                        .fixedSize()
                }
            }
            .frame(width: Self.limitsNameWidth, alignment: .leading)
            if let problem = row.problem, row.problemReplacesNumbers || !row.hasNumbers {
                // Probleme stehen in der Zeile statt der Balken (Text aus dem Popover).
                Text(verbatim: problem)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.awaiting)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.limitsGaugeWidth * 2 + 14, alignment: .leading)
            } else if !row.hasNumbers {
                Text("No data")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.tertiary)
                    .frame(width: Self.limitsGaugeWidth * 2 + 14, alignment: .leading)
            } else {
                limitsGauge(row.fiveHour, resetsAt: row.fiveHourResetsAt, now: now)
                limitsGauge(row.week, resetsAt: row.weekResetsAt, now: now)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.limitsRowHeight)
        .background {
            if row.isCurrentChat {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.mark.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.markBorder.opacity(0.55), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func limitsGauge(_ percent: Double?, resetsAt: Date?, now: Date) -> some View {
        let color = levelColor(ControllerLimitLevel(percent: percent))
        return HStack(spacing: 7) {
            ZStack(alignment: .leading) {
                Capsule().fill(palette.segmentOn).frame(width: 70, height: 5)
                if let percent {
                    Capsule().fill(color).frame(width: max(3, 70 * min(percent, 100) / 100), height: 5)
                }
            }
            Text(verbatim: Self.percentText(percent))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 38, alignment: .trailing)
            Text(verbatim: Self.resetText(resetsAt, now: now))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(width: Self.limitsGaugeWidth, alignment: .leading)
    }

    /// Schmaler Balken rechts, wenn nicht alle Konten hineinpassen.
    @ViewBuilder
    private func limitsScrollBar(_ card: ControllerLimitsCard) -> some View {
        if card.canScroll {
            GeometryReader { proxy in
                let total = CGFloat(card.rows.count)
                let height = proxy.size.height * CGFloat(card.visibleRows.count) / total
                let offset = proxy.size.height * CGFloat(card.hiddenAbove) / total
                Capsule()
                    .fill(palette.tertiary.opacity(0.6))
                    .frame(width: 3, height: height)
                    .offset(y: offset)
            }
            .frame(width: 3)
            .padding(.trailing, -4)
        }
    }

    /// „in 2 h 10 min“ unter einem Tag, sonst Wochentag und Uhrzeit.
    static func resetText(_ resetsAt: Date?, now: Date) -> String {
        switch ControllerResetStyle.of(resetsAt, now: now) {
        case .duration(let minutes)?:
            if minutes >= 60 { return String(localized: "in \(minutes / 60) h \(minutes % 60) min") }
            return String(localized: "in \(minutes) min")
        case .dayAndTime?:
            return resetsAt.map { UsageResetDateFormat.short($0, now: now) } ?? ""
        case nil:
            return ""
        }
    }
}
