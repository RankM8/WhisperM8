import SwiftUI

struct AIOutputAccountTab: View {
    @AppStorage("codexPostProcessingModel") private var selectedModelRaw = CodexPostProcessingModel.defaultModel.rawValue
    @AppStorage("codexReasoningEffort") private var reasoningEffortRaw = CodexReasoningEffort.defaultEffort.rawValue
    @AppStorage("codexServiceTier") private var serviceTierRaw = CodexServiceTier.defaultTier.rawValue
    @AppStorage("codexVisualInputMode") private var visualInputModeRaw = CodexVisualInputMode.defaultMode.rawValue
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.rawID
    @AppStorage("fallbackToRawOnProcessingError") private var fallbackToRawOnProcessingError = true

    @State private var connectionModel = CodexConnectionModel()
    @State private var enabledModes = OutputModeStore().enabledModes

    private var selectedModel: CodexPostProcessingModel {
        CodexPostProcessingModel.resolve(selectedModelRaw)
    }

    private var selectedReasoningEffort: CodexReasoningEffort {
        CodexReasoningEffort.resolve(reasoningEffortRaw)
    }

    private var selectedServiceTier: CodexServiceTier {
        CodexServiceTier.resolve(serviceTierRaw)
    }

    private var selectedVisualInputMode: CodexVisualInputMode {
        CodexVisualInputMode.resolve(visualInputModeRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("ChatGPT") {
                SettingsStatusRow(
                    title: "ChatGPT via Codex CLI",
                    subtitle: "Uses the official Codex CLI login. This is separate from the OpenAI transcription API key.",
                    tone: connectionModel.statusTone,
                    detail: connectionModel.status.displayText
                ) {
                    Button(connectionModel.status == .signedIn ? "Reconnect" : "Sign In") {
                        CodexStatusProbe().openLoginInTerminal()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)

                    Button("Check Again") {
                        Task { await connectionModel.refresh() }
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                }

                SettingsRow(
                    title: "Codex CLI",
                    subtitle: "Version used for non-interactive post-processing."
                ) {
                    Text(connectionModel.codexVersion)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }

                if connectionModel.shouldWarnAboutGPT55(selectedModelRaw: selectedModelRaw) {
                    SettingsHelpText(
                        "If GPT-5.5 fails with \"requires a newer version of Codex\", update Codex CLI or temporarily select GPT-5.2.",
                        tone: .warning
                    )
                }
            }

            SettingsSection("Post-processing Defaults") {
                SettingsPickerRow(
                    title: "Model",
                    subtitle: "\(selectedModel.detail) Modes can override this value in the Modes tab. New Codex agent chats also start from this default.",
                    selection: $selectedModelRaw,
                    options: CodexPostProcessingModel.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(CodexPostProcessingModel.resolve(rawValue).displayName)
                }

                SettingsPickerRow(
                    title: "Thinking",
                    subtitle: "\(selectedReasoningEffort.detail) Modes can override this value; new Codex agent chats also use it when created.",
                    selection: $reasoningEffortRaw,
                    options: CodexReasoningEffort.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(CodexReasoningEffort.resolve(rawValue).displayName)
                }

                SettingsPickerRow(
                    title: "Speed",
                    subtitle: "\(selectedServiceTier.detail) Modes can override speed separately when they need different routing.",
                    selection: $serviceTierRaw,
                    options: CodexServiceTier.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(CodexServiceTier.resolve(rawValue).displayName)
                }
            }

            SettingsSection("Visual Input") {
                SettingsPickerRow(
                    title: "Screen clips",
                    subtitle: selectedVisualInputMode.detail,
                    selection: $visualInputModeRaw,
                    options: CodexVisualInputMode.allCases.map(\.rawValue)
                ) { rawValue in
                    Text(visualInputLabel(for: rawValue))
                }

                SettingsHelpText(
                    "Codex receives extracted frames as images today. Direct video upload is not exposed by codex exec; Video keeps clip paths in the prompt and sends frames as fallback.",
                    tone: .warning
                )
            }

            SettingsSection("Output & Fallback") {
                SettingsPickerRow(
                    title: "Default Mode",
                    subtitle: "New recordings start here. If the stored mode was deleted, recordings fall back to Fast (raw) at runtime.",
                    selection: $defaultOutputModeID,
                    options: enabledModes.map(\.id)
                ) { modeID in
                    Text(modeName(for: modeID))
                }

                SettingsToggleRow(
                    title: "Fall back to Fast on processing errors",
                    subtitle: "If Codex fails, WhisperM8 delivers the raw transcript instead.",
                    isOn: $fallbackToRawOnProcessingError
                )

                SettingsHelpText("Privacy controls for captured context live in Context & Privacy. AI Output only sends what those settings allow.")
            }
        }
        .task {
            await connectionModel.refresh()
            enabledModes = OutputModeStore().enabledModes
        }
    }

    private func visualInputLabel(for rawValue: String) -> String {
        let mode = CodexVisualInputMode.resolve(rawValue)
        switch mode {
        case .auto:
            return "Auto (frames today)"
        case .frames:
            return "Frames"
        case .video:
            return "Video (frames fallback)"
        }
    }

    private func modeName(for id: String) -> String {
        enabledModes.first { $0.id == id }?.name ?? id
    }
}
