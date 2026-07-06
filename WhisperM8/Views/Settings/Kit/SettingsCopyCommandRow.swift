import SwiftUI

struct SettingsCopyCommandRow: View {
    let command: String
    let caption: String
    let clipboard: ClipboardClient
    @State private var feedback: SettingsFeedbackState

    @MainActor
    init(command: String, caption: String) {
        self.init(
            command: command,
            caption: caption,
            clipboard: DefaultClipboardClient(),
            feedback: SettingsFeedbackState()
        )
    }

    init(
        command: String,
        caption: String,
        clipboard: ClipboardClient,
        feedback: SettingsFeedbackState
    ) {
        self.command = command
        self.caption = caption
        self.clipboard = clipboard
        self._feedback = State(initialValue: feedback)
    }

    var body: some View {
        // Command führt links (Mono) mit Caption darunter — wie die V3-Referenz;
        // caption doppelt als Row-Titel zu verwenden war ein Review-Befund (Phase 2).
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)
                    .textSelection(.enabled)

                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            Spacer(minLength: 12)

            Button(feedback.isActive ? "Copied" : "Copy") {
                SettingsCopyCommandAction.copy(
                    command: command,
                    clipboard: clipboard,
                    feedback: feedback
                )
            }
            .buttonStyle(SettingsButtonStyle.standard)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

enum SettingsCopyCommandAction {
    @MainActor
    static func copy(
        command: String,
        clipboard: ClipboardClient,
        feedback: SettingsFeedbackState
    ) {
        clipboard.copy(command)
        feedback.trigger()
    }
}
