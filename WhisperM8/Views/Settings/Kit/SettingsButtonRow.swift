import SwiftUI

struct SettingsButtonRow<Actions: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let actions: Actions

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                actions
            }
        }
    }
}

enum SettingsButtonStyle: ButtonStyle {
    case standard
    case primary
    case destructive

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
    }

    private var background: Color {
        switch self {
        case .standard:
            AppTheme.control
        case .primary:
            AppTheme.accentStrong
        case .destructive:
            AppTheme.statusError
        }
    }

    private var foreground: Color {
        switch self {
        case .standard:
            AppTheme.textPrimary
        case .primary, .destructive:
            // Gefüllte Buttons brauchen in BEIDEN Modi weißen Text — textPrimary
            // wäre im Light Mode dunkel auf Indigo/Rot (Review-Befund Phase 2).
            Color.white
        }
    }

    private var border: Color {
        switch self {
        case .standard:
            AppTheme.border
        case .primary:
            AppTheme.accentStrong
        case .destructive:
            AppTheme.statusError
        }
    }
}
