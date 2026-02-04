import SwiftUI
import KeyboardShortcuts

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if appState.isRecording {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording...")
                }
            } else if appState.isTranscribing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Transcribing...")
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                }
            }
        }

        if let lastTranscription = appState.lastTranscription {
            Divider()
            Text("Last transcription:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(lastTranscription.prefix(100) + (lastTranscription.count > 100 ? "..." : ""))
                .font(.caption)
                .lineLimit(3)
        }

        if let error = appState.lastError {
            Divider()
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            Text("Hotkey: \(shortcut.description)")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No hotkey configured")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Settings...") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
