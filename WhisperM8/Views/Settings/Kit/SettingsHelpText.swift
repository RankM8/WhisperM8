import SwiftUI

struct SettingsHelpText: View {
    enum Tone {
        case secondary
        case warning
        case error

        var color: Color {
            switch self {
            case .secondary:
                // ≥ 4,5:1 auf dem Seitenhintergrund (LR-ONB-016).
                AppTheme.textSecondary
            case .warning:
                AppTheme.statusAwaiting
            case .error:
                AppTheme.statusError
            }
        }
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone = .secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(settingsLocalized: text)
            .font(.system(size: 11.5))
            .lineSpacing(2)
            .foregroundStyle(tone.color)
            // Linksbündig auch in Containern mit zentrierter Ausrichtung (Befund Sichtprüfung).
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
