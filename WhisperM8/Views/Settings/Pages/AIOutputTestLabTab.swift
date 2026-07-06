import AppKit
import SwiftUI

struct AIOutputTestLabTab: View {
    @AppStorage("fallbackToRawOnProcessingError") private var fallbackToRawOnProcessingError = true

    @State private var rawText = ""
    @State private var selectedModeID = OutputMode.rawID
    @State private var previewText = ""
    @State private var errorMessage: String?
    @State private var isProcessing = false
    @State private var modes = OutputModeStore().enabledModes

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Try a Mode Without Recording") {
                SettingsPickerRow(
                    title: "Mode",
                    subtitle: "Runs post-processing on typed text only. No recording starts and no selected context is captured.",
                    selection: $selectedModeID,
                    options: modes.map(\.id)
                ) { modeID in
                    Text(modes.first { $0.id == modeID }?.name ?? modeID)
                }

                SettingsRow(title: "Input — raw transcript")
                SettingsTextArea(text: $rawText, minHeight: 160)

                SettingsButtonRow(title: "Preview actions") {
                    Button("Preview") {
                        Task { await runPreview() }
                    }
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
                    .buttonStyle(SettingsButtonStyle.primary)

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(previewText, forType: .string)
                    }
                    .disabled(previewText.isEmpty)
                    .buttonStyle(SettingsButtonStyle.standard)

                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let errorMessage {
                    SettingsHelpText(errorMessage, tone: .warning)
                }

                SettingsRow(title: "Output — processed preview")
                SettingsTextArea(text: $previewText, minHeight: 180)
            }
        }
        .onAppear {
            modes = OutputModeStore().enabledModes
            if !modes.contains(where: { $0.id == selectedModeID }) {
                selectedModeID = modes.first?.id ?? OutputMode.rawID
            }
        }
    }

    @MainActor
    private func runPreview() async {
        isProcessing = true
        errorMessage = nil

        let mode = OutputMode.mode(for: selectedModeID)
        let normalizedText = TextNormalizer.normalizeTranscriptionText(rawText)
        do {
            let output = try await PostProcessingService().process(
                rawText: normalizedText,
                mode: mode,
                language: AppPreferences.shared.language
            )
            previewText = output
        } catch {
            if fallbackToRawOnProcessingError {
                previewText = normalizedText
                errorMessage = "\(error.localizedDescription) Showing Raw fallback."
            } else {
                previewText = ""
                errorMessage = error.localizedDescription
            }
        }

        isProcessing = false
    }
}
