import SwiftUI

struct SettingsStatusRow<Actions: View>: View {
    let title: String
    let subtitle: String?
    let tone: SettingsStatusTone
    let detail: String
    @ViewBuilder let actions: Actions

    init(
        title: String,
        subtitle: String? = nil,
        tone: SettingsStatusTone,
        detail: String,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.detail = detail
        self.actions = actions()
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(tone.color)
                        .frame(width: 8, height: 8)

                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                actions
            }
        }
    }
}
