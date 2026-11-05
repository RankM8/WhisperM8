import SwiftUI

/// Diagrammfarben der Statistik-Seite: die validierte Referenzpalette (Slots 1–4)
/// aus dem Entwurf, je hell und dunkel.
enum StatisticsColors {
    static let palette: [Color] = [
        Color.dynamic(light: Color(hex: "#2a78d6"), dark: Color(hex: "#3987e5")),
        Color.dynamic(light: Color(hex: "#eb6834"), dark: Color(hex: "#d95926")),
        Color.dynamic(light: Color(hex: "#1baf7a"), dark: Color(hex: "#199e70")),
        Color.dynamic(light: Color(hex: "#eda100"), dark: Color(hex: "#c98500")),
    ]

    /// Modelle jenseits der vier Farben.
    static let other = AppTheme.textTertiary

    static func model(_ model: String, order: [String]) -> Color {
        StatisticsPalette.slot(for: model, order: order).map { palette[$0] } ?? other
    }

    static let claude = palette[0]
    static let gpt = palette[2]
    static let codex = palette[3]
}

/// Umrandete Fläche wie `.card`/`.kpi` im Entwurf.
struct StatisticsCardModifier: ViewModifier {
    var filled = false
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(filled ? AppTheme.panel : AppTheme.background.opacity(0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.borderStrong, lineWidth: 1)
            )
    }
}

extension View {
    func statisticsCard(filled: Bool = false, padding: CGFloat = 14) -> some View {
        modifier(StatisticsCardModifier(filled: filled, padding: padding))
    }
}

/// Kennzahl-Kachel: Titel, großer Wert, ein bis zwei Detailzeilen.
struct StatisticsTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    var secondDetail: String? = nil
    var isIncomplete = false
    var large = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(settingsLocalized: title)
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(.system(size: large ? 24 : 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(verbatim: unit)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                if isIncomplete {
                    Text("· incomplete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let secondDetail {
                Text(verbatim: secondDetail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .statisticsCard(filled: large, padding: large ? 13 : 11)
    }
}

/// Ein Abschnitt im Teil eines Anteilsbalkens.
struct StatisticsShareSegment: Identifiable {
    let id: String
    let name: String
    let fraction: Double
    let color: Color
    /// Wert in der Legende, z. B. „78 %“.
    let valueText: String
}

/// Waagerechter Anteilsbalken mit Lücken wie im Entwurf. Sehr kleine Anteile
/// bekommen eine Mindestbreite, damit sie sichtbar bleiben.
struct StatisticsShareBar: View {
    let segments: [StatisticsShareSegment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let widths = Self.widths(for: segments.map(\.fraction), total: proxy.size.width, spacing: 2)
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: widths[safe: index] ?? 0)
                        .accessibilityLabel(Text(verbatim: "\(segment.name) \(segment.valueText)"))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Breiten mit Mindestbreite 6 pt; der Rest verteilt sich nach Anteil.
    static func widths(for fractions: [Double], total: CGFloat, spacing: CGFloat, minimum: CGFloat = 6) -> [CGFloat] {
        guard !fractions.isEmpty else { return [] }
        let available = max(0, total - spacing * CGFloat(fractions.count - 1))
        let sum = fractions.reduce(0, +)
        guard sum > 0 else { return fractions.map { _ in available / CGFloat(fractions.count) } }
        var widths = fractions.map { max(minimum, available * CGFloat($0 / sum)) }
        let overflow = widths.reduce(0, +) - available
        if overflow > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] = max(minimum, widths[largest] - overflow)
        }
        return widths
    }
}

/// Legende unter einem Anteilsbalken.
struct StatisticsLegend: View {
    let segments: [StatisticsShareSegment]

    var body: some View {
        StatisticsFlowLayout(horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(segments) { segment in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.color)
                        .frame(width: 9, height: 9)
                    Text(verbatim: segment.name)
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(verbatim: segment.valueText)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .font(.system(size: 11.5))
            }
        }
    }
}

/// Einfacher Zeilenumbruch-Layout für Legenden.
struct StatisticsFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Schmaler Füllbalken (Limits, Projekte, Fortschritt).
struct StatisticsMeter: View {
    let fraction: Double
    var color: Color = AppTheme.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.control)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Kleine Überschrift innerhalb eines Abschnitts („Was du monatlich zahlst“).
struct StatisticsCaption: View {
    let title: String

    var body: some View {
        Text(settingsLocalized: title)
            .font(.system(size: 12))
            .foregroundStyle(AppTheme.textSecondary)
    }
}

/// Spaltenkopf in Tabellen (Großbuchstaben, gedämpft).
struct StatisticsColumnHeader: View {
    let title: String

    var body: some View {
        Text(settingsLocalized: title)
            .textCase(.uppercase)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(AppTheme.textTertiary)
            .lineLimit(1)
    }
}
