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
    @State private var previewGeneration = 0
    @State private var previewTask: Task<Void, Never>?

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
                SettingsTextArea(title: "Input — raw transcript", text: $rawText, minHeight: 160)

                SettingsButtonRow(title: "Preview actions") {
                    Button("Preview") {
                        startPreview()
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
                SettingsTextArea(title: "Output — processed preview", text: $previewText, minHeight: 180)
            }
        }
        .onAppear {
            modes = OutputModeStore().enabledModes
            if !modes.contains(where: { $0.id == selectedModeID }) {
                selectedModeID = modes.first?.id ?? OutputMode.rawID
            }
        }
        .onDisappear(perform: cancelPreview)
    }

    @MainActor
    private func startPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        let inputText = rawText
        let modeID = selectedModeID
        let shouldFallbackToRaw = fallbackToRawOnProcessingError

        previewTask?.cancel()
        isProcessing = true
        errorMessage = nil
        previewTask = Task { @MainActor in
            await runPreview(
                generation: generation,
                inputText: inputText,
                modeID: modeID,
                shouldFallbackToRaw: shouldFallbackToRaw
            )
        }
    }

    @MainActor
    private func cancelPreview() {
        previewGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        isProcessing = false
    }

    @MainActor
    private func runPreview(
        generation: Int,
        inputText: String,
        modeID: String,
        shouldFallbackToRaw: Bool
    ) async {
        defer {
            if generation == previewGeneration {
                isProcessing = false
                previewTask = nil
            }
        }

        let mode = OutputMode.mode(for: modeID)
        let normalizedText = TextNormalizer.normalizeTranscriptionText(inputText)
        do {
            let output = try await PostProcessingService().process(
                rawText: normalizedText,
                mode: mode,
                language: AppPreferences.shared.language
            )
            guard generation == previewGeneration, !Task.isCancelled else { return }
            previewText = output
        } catch is CancellationError {
            return
        } catch {
            guard generation == previewGeneration, !Task.isCancelled else { return }
            if shouldFallbackToRaw {
                previewText = normalizedText
                errorMessage = "\(error.localizedDescription) Showing Raw fallback."
            } else {
                previewText = ""
                errorMessage = error.localizedDescription
            }
        }
    }
}
