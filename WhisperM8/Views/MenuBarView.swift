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
                    Text("Aufnahme läuft...")
                }
            } else if appState.isTranscribing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                    Text("Transkribiere...")
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Bereit")
                }
            }
        }

        if let lastTranscription = appState.lastTranscription {
            Divider()
            Text("Letzte Transkription:")
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
            Text("Kein Hotkey konfiguriert")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Einstellungen...") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Beenden") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
