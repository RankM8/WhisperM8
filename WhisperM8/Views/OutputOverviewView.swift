import AppKit
import SwiftUI

struct OutputOverviewView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.cleanID
    @State private var codexStatus = CodexConnectionStatus.unknown

    /// Springt in den History-Reiter; optional mit vorselektiertem Report.
    var onOpenHistory: (UUID?) -> Void = { _ in }

    var body: some View {
        Form {
            Section("Default Output") {
                Picker("Default Mode", selection: $defaultOutputModeID) {
                    ForEach(OutputMode.enabledBuiltInModes) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }

                Text("New recordings start with this mode. You can still switch mode while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Codex") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(codexStatus.displayText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Check Again") {
                        codexStatus = CodexStatusProbe().status()
                    }

                    Button("Set up Codex") {
                        NSWorkspace.shared.open(URL(string: "https://developers.openai.com/codex/cli")!)
                    }
                }
            }

            Section("Last Output") {
                if let report = appState.lastTranscriptRunReport {
                    LastOutputCard(report: report) {
                        onOpenHistory(report.id)
                    }
                } else if let raw = appState.lastRawTranscription, !raw.isEmpty {
                    // Fallback, falls noch kein persistierter Report vorliegt.
                    LastOutputPreview(title: "Raw", text: raw)
                    LastOutputPreview(title: "Final", text: appState.lastFinalTranscription ?? appState.lastTranscription)
                    Button("Open History") { onOpenHistory(nil) }
                } else {
                    Text("No output yet")
                        .foregroundStyle(.secondary)
                    Button("Open History") { onOpenHistory(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .onAppear {
            codexStatus = CodexStatusProbe().status()
        }
    }
}

/// Kompakte Karte für den zuletzt erzeugten Output. Zeigt Kerninfos +
/// eine gekürzte Vorschau und verlinkt in den vollständigen History-Reiter.
private struct LastOutputCard: View {
    let report: TranscriptRunReport
    var onOpenInHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.title)
                    .font(.body.weight(.semibold))
                Spacer()
                Text(report.createdAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(report.status.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(report.shortSummary)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button {
                    onOpenInHistory()
                } label: {
                    Label("Open in History", systemImage: "arrow.right")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LastOutputPreview: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text?.isEmpty == false ? text! : "No output yet")
                .lineLimit(3)
                .foregroundStyle(text == nil ? .secondary : .primary)
        }
    }
}
