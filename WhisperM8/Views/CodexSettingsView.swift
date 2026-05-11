import SwiftUI

struct CodexSettingsView: View {
    @AppStorage("codexPostProcessingModel") private var selectedModelRaw = CodexPostProcessingModel.defaultModel.rawValue
    @AppStorage("codexReasoningEffort") private var reasoningEffortRaw = CodexReasoningEffort.defaultEffort.rawValue
    @AppStorage("codexVisualInputMode") private var visualInputModeRaw = CodexVisualInputMode.defaultMode.rawValue
    @State private var status = CodexConnectionStatus.unknown
    @State private var codexVersion = "Unknown"

    private var selectedModel: CodexPostProcessingModel {
        CodexPostProcessingModel.resolve(selectedModelRaw)
    }

    private var selectedReasoningEffort: CodexReasoningEffort {
        CodexReasoningEffort.resolve(reasoningEffortRaw)
    }

    private var selectedVisualInputMode: CodexVisualInputMode {
        CodexVisualInputMode.resolve(visualInputModeRaw)
    }

    private var codexLooksTooOldForGPT55: Bool {
        selectedModel == .gpt55 && codexVersion.contains("0.120.")
    }

    var body: some View {
        Form {
            Section("ChatGPT Subscription via Codex") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(status.displayText)
                        .foregroundStyle(status == .signedIn ? .green : .secondary)
                }

                HStack {
                    Button(status == .signedIn ? "Reconnect ChatGPT" : "Sign in with ChatGPT") {
                        CodexStatusProbe().openLoginInTerminal()
                    }

                    Button("Check Again") {
                        status = CodexStatusProbe().status()
                    }
                }

                Text("This uses the official Codex CLI login. It is separate from the OpenAI transcription API key. WhisperM8 never reads ChatGPT browser sessions or private tokens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Post-processing Model") {
                Picker("Model", selection: $selectedModelRaw) {
                    ForEach(CodexPostProcessingModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }

                Text(selectedModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Thinking", selection: $reasoningEffortRaw) {
                    ForEach(CodexReasoningEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort.rawValue)
                    }
                }

                Text(selectedReasoningEffort.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Codex CLI")
                    Spacer()
                    Text(codexVersion)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)

                if codexLooksTooOldForGPT55 {
                    Text("If GPT-5.5 fails with “requires a newer version of Codex”, update Codex CLI or temporarily select GPT-5.2.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Visual Input") {
                Picker("Screen clips", selection: $visualInputModeRaw) {
                    ForEach(CodexVisualInputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }

                Text(selectedVisualInputMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Current codex exec \(codexVersion) exposes --image but no --video flag. Video mode therefore passes the clip path in the prompt and keeps image frames as fallback.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section("Privacy") {
                Text("Codex post-processing will only run through an official, stable non-interactive path. If Codex is unavailable, WhisperM8 keeps working and falls back to Raw output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Codex")
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        let probe = CodexStatusProbe()
        status = probe.status()
        codexVersion = probe.version()
    }
}
