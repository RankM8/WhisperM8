import SwiftUI

struct SettingsListPanelItem<ID: Hashable>: Identifiable, Hashable {
    let id: ID
    let title: String
    let subtitle: String?

    init(id: ID, title: String, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

struct SettingsListPanel<ID: Hashable>: View {
    let items: [SettingsListPanelItem<ID>]
    @Binding var selection: ID

    init(items: [SettingsListPanelItem<ID>], selection: Binding<ID>) {
        self.items = items
        self._selection = selection
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    selection = item.id
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: item.id == selection ? .semibold : .regular))
                            .foregroundStyle(item.id == selection ? AppTheme.accent : AppTheme.textPrimary)

                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(item.id == selection ? AppTheme.accentTint : AppTheme.surface.opacity(0))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 220, alignment: .topLeading)
    }
}
