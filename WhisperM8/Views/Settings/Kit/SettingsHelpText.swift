import SwiftUI

struct SettingsHelpText: View {
    enum Tone {
        case secondary
        case warning
        case error

        var color: Color {
            switch self {
            case .secondary:
                AppTheme.textTertiary
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
        Text(text)
            .font(.system(size: 11.5))
            .lineSpacing(2)
            .foregroundStyle(tone.color)
    }
}
