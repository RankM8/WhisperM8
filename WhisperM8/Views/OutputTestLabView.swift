import AppKit
import SwiftUI

struct OutputTestLabView: View {
    @AppStorage("fallbackToRawOnProcessingError") private var fallbackToRawOnProcessingError = true
    @State private var rawText = ""
    @State private var selectedModeID = OutputMode.rawID
    @State private var previewText = ""
    @State private var errorMessage: String?
    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $selectedModeID) {
                ForEach(OutputMode.enabledBuiltInModes) { mode in
                    Text(mode.name).tag(mode.id)
                }
            }
            .pickerStyle(.segmented)

            TextEditor(text: $rawText)
                .font(.body)
                .border(Color.secondary.opacity(0.25))
                .frame(minHeight: 160)

            HStack {
                Button("Preview") {
                    Task {
                        await runPreview()
                    }
                }
                .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previewText, forType: .string)
                }
                .disabled(previewText.isEmpty)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextEditor(text: $previewText)
                .font(.body)
                .border(Color.secondary.opacity(0.25))
                .frame(minHeight: 180)
        }
        .padding()
        .navigationTitle("Test Lab")
    }

    @MainActor
    private func runPreview() async {
        isProcessing = true
        errorMessage = nil

        let mode = OutputMode.mode(for: selectedModeID)
        do {
            let output = try await PostProcessingService().process(
                rawText: TextNormalizer.normalizeTranscriptionText(rawText),
                mode: mode,
                language: AppPreferences.shared.language
            )
            previewText = output
        } catch {
            if fallbackToRawOnProcessingError {
                previewText = TextNormalizer.normalizeTranscriptionText(rawText)
                errorMessage = "\(error.localizedDescription) Showing Raw fallback."
            } else {
                previewText = ""
                errorMessage = error.localizedDescription
            }
        }

        isProcessing = false
    }
}
