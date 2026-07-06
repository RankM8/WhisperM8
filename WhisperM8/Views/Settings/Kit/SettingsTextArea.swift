import SwiftUI

struct SettingsTextArea: View {
    @Binding var text: String
    let minHeight: CGFloat

    init(text: Binding<String>, minHeight: CGFloat = 96) {
        self._text = text
        self.minHeight = minHeight
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(AppTheme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(AppTheme.control)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}
