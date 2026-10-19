import SwiftUI

/// Kennzeichnung für Seiten der Gruppe „Labs“ (LR-ONB-012): experimentell oder auf
/// inoffiziellem Upstream, nicht Teil des normalen Setups.
struct SettingsLabsNotice: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.statusAwaiting)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Labs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(settingsLocalized: message)
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.control)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
