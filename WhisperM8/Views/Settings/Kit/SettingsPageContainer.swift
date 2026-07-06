import SwiftUI

enum SettingsLayout {
    static let contentMaxWidth: CGFloat = 800
}

struct SettingsPageContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let scrolls: Bool
    let content: Content

    init(
        title: String,
        subtitle: String,
        scrolls: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.content = content()
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    pageBody
                }
            } else {
                pageBody
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(AppTheme.background)
    }

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageHeader
            content
        }
        .frame(maxWidth: SettingsLayout.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
