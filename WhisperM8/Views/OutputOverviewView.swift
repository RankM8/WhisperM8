import AppKit
import SwiftUI

struct OutputOverviewView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.cleanID
    @State private var codexStatus = CodexConnectionStatus.unknown

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
                LastOutputPreview(title: "Report", text: appState.lastTranscriptRunReport?.title)
                LastOutputPreview(title: "Context", text: lastContextText)
                LastOutputPreview(title: "Raw", text: appState.lastRawTranscription)
                LastOutputPreview(title: "Final", text: appState.lastFinalTranscription ?? appState.lastTranscription)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
        .onAppear {
            codexStatus = CodexStatusProbe().status()
        }
    }

    private var lastContextText: String? {
        guard let bundle = appState.lastContextBundle ?? appState.lastSelectedContext.map({ TranscriptContextBundle(selectedText: $0) }),
              !bundle.isEmpty else {
            return nil
        }

        var parts: [String] = []
        if !bundle.selectedText.isEmpty {
            parts.append(bundle.selectedText.text)
        }
        if !bundle.visualContextSummary.isEmpty {
            parts.append(bundle.visualContextSummary)
        }
        return parts.joined(separator: "\n\n")
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
