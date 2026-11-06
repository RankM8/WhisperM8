import AppKit
import SwiftUI

/// Teilen-Dialog der Statistik: Vorschau-Karte plus Schalter, was sichtbar ist.
/// „Copy image“ rendert die Karte per `ImageRenderer` (sie enthält keine
/// AppKit-Controls), „Copy as Markdown“ schreibt Text. Beide Wege beanspruchen
/// ihren Schreibvorgang über die Abhängigkeiten (`ClipboardInternalWrites`).
struct StatisticsShareSheet: View {
    let data: StatisticsPageData
    let dependencies: StatisticsSettingsDependencies
    let locale: Locale
    let close: () -> Void

    @State var options = StatisticsShareOptions()
    @State private var copiedImage = SettingsFeedbackState()
    @State private var copiedText = SettingsFeedbackState()

    private var periodPhrase: String { StatisticsPeriodText.phrase(for: data.report, locale: locale) }

    private var card: StatisticsShareCard {
        StatisticsShareCard(
            periodPhrase: periodPhrase,
            items: StatisticsShareExport.items(data: data, options: options, locale: locale),
            projects: StatisticsShareExport.topProjects(data: data, options: options)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Share statistics")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Creates an image or a Markdown text you can pass on in Slack or an email.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.top, 2)
                .padding(.bottom, 14)

            HStack(alignment: .top, spacing: 18) {
                card
                    .frame(width: 330)
                VStack(alignment: .leading, spacing: 0) {
                    shareToggle("Times", isOn: $options.times)
                    shareToggle("Tokens & models", isOn: $options.tokens)
                    shareToggle("Euro amounts", isOn: $options.euros)
                    shareToggle("Project names", isOn: $options.projectNames)
                    Text("Project names are off by default so nothing about clients leaves your Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .frame(width: 230, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(SettingsButtonStyle.standard)
                    .keyboardShortcut(.cancelAction)
                Button {
                    copyMarkdown()
                } label: {
                    if copiedText.isActive { Text("Copied") } else { Text("Copy as Markdown") }
                }
                .buttonStyle(SettingsButtonStyle.standard)
                Button {
                    copyImage()
                } label: {
                    if copiedImage.isActive { Text("Copied") } else { Text("Copy image") }
                }
                .buttonStyle(SettingsButtonStyle.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 620)
        .background(AppTheme.panel)
    }

    private func shareToggle(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer()
            Toggle(isOn: isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(AppTheme.statusWorking)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.border).frame(height: 1)
        }
    }

    private func copyMarkdown() {
        let text = StatisticsShareExport.markdown(data: data, options: options, periodPhrase: periodPhrase, locale: locale)
        dependencies.copyText(text)
        copiedText.trigger()
    }

    private func copyImage() {
        let renderer = ImageRenderer(content: card.frame(width: 360))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        dependencies.copyImage(image)
        copiedImage.trigger()
    }
}

/// Die Karte selbst: feste dunkle Farben, damit das Bild in Slack in hellem
/// wie dunklem Modus gleich aussieht.
struct StatisticsShareCard: View {
    let periodPhrase: String
    let items: [StatisticsShareExport.Item]
    /// `nil`: Projektnamen ausgeblendet.
    let projects: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "WhisperM8 · \(periodPhrase)")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .medium))
                .tracking(0.8)
                .opacity(0.65)
            Text("Developer statistics")
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 2)
                .padding(.bottom, 12)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { index in
                    GridRow {
                        cell(items[index])
                        if index + 1 < items.count {
                            cell(items[index + 1])
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
            Group {
                if let projects, !projects.isEmpty {
                    Text(String(localized: "Top projects: \(projects.joined(separator: ", "))"))
                } else {
                    Text("Projects hidden")
                }
            }
            .font(.system(size: 11))
            .opacity(0.55)
            .padding(.top, 12)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(hex: "#1d2050"), Color(hex: "#121327")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func cell(_ item: StatisticsShareExport.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: item.label)
                .font(.system(size: 11))
                .opacity(0.65)
            Text(verbatim: item.value)
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
