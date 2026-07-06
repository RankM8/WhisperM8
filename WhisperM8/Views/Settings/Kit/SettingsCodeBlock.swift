import SwiftUI

struct SettingsCodeBlock: View {
    let text: String
    let minHeight: CGFloat

    init(text: String, minHeight: CGFloat = 96) {
        self.text = text
        self.minHeight = minHeight
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: minHeight)
        .background(AppTheme.control)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
    }
}
