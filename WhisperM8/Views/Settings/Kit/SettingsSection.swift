import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(1.45)
                    .foregroundStyle(AppTheme.accent)

                LinearGradient(
                    colors: [AppTheme.accentTint, AppTheme.accentTint.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
            }

            VStack(spacing: 0) {
                content
            }
        }
    }
}
