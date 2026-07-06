import SwiftUI

struct AIOutputModesTab: View {
    @AppStorage("codexPostProcessingModel") private var globalCodexModelRaw = CodexPostProcessingModel.defaultModel.rawValue
    @AppStorage("codexReasoningEffort") private var globalReasoningEffortRaw = CodexReasoningEffort.defaultEffort.rawValue
    @AppStorage("codexServiceTier") private var globalServiceTierRaw = CodexServiceTier.defaultTier.rawValue

    @State private var model = OutputModesViewModel()
    @State private var isConfirmingDelete = false

    let onEditTemplate: (String) -> Void

    init(onEditTemplate: @escaping (String) -> Void = { _ in }) {
        self.onEditTemplate = onEditTemplate
    }

    private var enrichmentAvailable: Bool {
        AppPreferences.shared.usageProfile.wantsCodexEnrichment
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            modeList
                .frame(width: 280, alignment: .topLeading)

            modeEditor
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { model.reload() }
        .confirmationDialog("Delete custom mode?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteSelectedMode()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the custom mode from OutputModes.json.")
        }
    }

    private var modeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Modes")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Button {
                    model.addMode()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Create custom mode")
                .buttonStyle(SettingsButtonStyle.standard)
            }

            if !enrichmentAvailable {
                lockedBanner
            }

            VStack(spacing: 2) {
                ForEach(model.modes) { mode in
                    modeRow(mode)
                }
            }
            .padding(8)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
        }
    }

    private var lockedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(AppTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI enrichment is off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text("Clean, Email, Slack and other modes need Codex. Switch to an enrichment profile in Behavior to unlock them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(AppTheme.control)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func modeRow(_ mode: OutputMode) -> some View {
        let isLocked = !enrichmentAvailable && mode.isCodexDependent
        return Button {
            model.selectedModeID = mode.id
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(indicatorColor(for: mode, isLocked: isLocked))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.name)
                        .font(.system(size: 13, weight: mode.id == model.selectedModeID ? .semibold : .regular))
                        .foregroundStyle(mode.id == model.selectedModeID ? AppTheme.accent : AppTheme.textPrimary)
                    Text(isLocked ? "Needs AI enrichment (Codex)" : model.modeSummary(mode))
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textTertiary)
                } else {
                    Toggle("Enabled", isOn: enabledBinding(for: mode.id))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!model.canDisable(mode))
                        .help(model.modeToggleHelp(mode))
                }

                if mode.id == model.defaultOutputModeID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.statusWorking)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(mode.id == model.selectedModeID ? AppTheme.accentTint : AppTheme.surface.opacity(0))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isLocked ? 0.58 : 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var modeEditor: some View {
        if let mode = model.selectedMode {
            VStack(alignment: .leading, spacing: 18) {
                editorHeader(mode)

                SettingsSection("Identity") {
                    SettingsRow(title: "Name") {
                        TextField("Mode name", text: textBinding(for: mode.id, get: \.name, set: model.setName))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }

                    SettingsRow(title: "Overlay label") {
                        TextField("Overlay label", text: textBinding(for: mode.id, get: \.shortLabel, set: model.setShortLabel))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    SettingsToggleRow(
                        title: "Show in recording overlay and Test Lab",
                        subtitle: model.modeVisibilityHelp(mode),
                        isOn: enabledBinding(for: mode.id)
                    )

                    SettingsToggleRow(
                        title: "Paste screenshots into target app",
                        subtitle: "When Auto-paste is enabled, captured screenshots are pasted into the target composer after the text. The message is not sent.",
                        isOn: pasteBinding(for: mode.id)
                    )
                }

                if mode.usesPostProcessing {
                    SettingsSection("Codex Overrides") {
                        SettingsToggleRow(
                            title: "Use global Codex model",
                            subtitle: mode.codexModelRawOverride == nil ? "Uses Account default: \(CodexPostProcessingModel.resolve(globalCodexModelRaw).displayName)." : nil,
                            isOn: useGlobalModelBinding(for: mode.id)
                        )

                        if mode.codexModelRawOverride != nil {
                            SettingsPickerRow(
                                title: "Mode model",
                                subtitle: CodexPostProcessingModel.resolve(mode.resolvedCodexModelRaw(defaultModelRaw: globalCodexModelRaw)).detail,
                                selection: modeModelBinding(for: mode.id),
                                options: CodexPostProcessingModel.allCases.map(\.rawValue)
                            ) { rawValue in
                                Text(CodexPostProcessingModel.resolve(rawValue).displayName)
                            }
                        }

                        SettingsToggleRow(
                            title: "Use global Thinking level",
                            subtitle: mode.codexReasoningEffortRawOverride == nil ? "Uses Account default: \(CodexReasoningEffort.resolve(globalReasoningEffortRaw).displayName)." : nil,
                            isOn: useGlobalReasoningBinding(for: mode.id)
                        )

                        if mode.codexReasoningEffortRawOverride != nil {
                            SettingsPickerRow(
                                title: "Thinking level",
                                subtitle: CodexReasoningEffort.resolve(mode.resolvedCodexReasoningEffortRaw(defaultReasoningEffortRaw: globalReasoningEffortRaw)).detail,
                                selection: modeReasoningBinding(for: mode.id),
                                options: CodexReasoningEffort.allCases.map(\.rawValue)
                            ) { rawValue in
                                Text(CodexReasoningEffort.resolve(rawValue).displayName)
                            }
                        }

                        SettingsToggleRow(
                            title: "Use global Fast mode",
                            subtitle: mode.codexServiceTierRawOverride == nil ? "Uses Account default: \(CodexServiceTier.resolve(globalServiceTierRaw).displayName)." : nil,
                            isOn: useGlobalServiceTierBinding(for: mode.id)
                        )

                        if mode.codexServiceTierRawOverride != nil {
                            SettingsPickerRow(
                                title: "Speed",
                                subtitle: CodexServiceTier.resolve(mode.resolvedCodexServiceTierRaw(defaultServiceTierRaw: globalServiceTierRaw)).detail,
                                selection: modeServiceTierBinding(for: mode.id),
                                options: CodexServiceTier.allCases.map(\.rawValue)
                            ) { rawValue in
                                Text(CodexServiceTier.resolve(rawValue).displayName)
                            }
                        }
                    }

                    SettingsSection("Context & Template") {
                        SettingsPickerRow(
                            title: "Selected context",
                            subtitle: mode.contextPolicy.detail,
                            selection: contextPolicyBinding(for: mode.id),
                            options: ContextCapturePolicy.allCases
                        ) { policy in
                            Text(policy.displayName)
                        }

                        SettingsPickerRow(
                            title: "Template",
                            subtitle: model.templateDescription(for: mode.templateID) ?? "Template not found.",
                            selection: templateBinding(for: mode.id),
                            options: model.templates.map(\.id)
                        ) { templateID in
                            Text(model.templates.first { $0.id == templateID }?.name ?? templateID)
                        }

                        SettingsButtonRow(
                            title: "Edit template",
                            subtitle: "Template contents are edited on the Templates tab."
                        ) {
                            Button("Edit →") {
                                onEditTemplate(mode.templateID ?? PostProcessingTemplate.cleanID)
                            }
                            .buttonStyle(SettingsButtonStyle.standard)
                        }
                    }
                } else {
                    SettingsHelpText("Fast mode skips Codex and outputs the transcript exactly as returned by speech-to-text.")
                }

                SettingsSection("Actions") {
                    SettingsButtonRow(title: "Mode actions") {
                        if mode.kind == .custom {
                            Button("Delete") {
                                isConfirmingDelete = true
                            }
                            .buttonStyle(SettingsButtonStyle.destructive)
                        }

                        Button("Reload") {
                            model.reload()
                        }
                        .buttonStyle(SettingsButtonStyle.standard)
                    }
                }

                if let errorMessage = model.errorMessage {
                    SettingsHelpText(errorMessage, tone: .error)
                }
            }
        } else {
            ContentUnavailableView("No Mode Selected", systemImage: "slider.horizontal.3")
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func editorHeader(_ mode: OutputMode) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(mode.kind == .custom ? "Custom mode" : "Built-in mode")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            Spacer()

            Button(mode.id == model.defaultOutputModeID ? "Default" : "Make Default") {
                model.setDefault(mode.id)
            }
            .disabled(mode.id == model.defaultOutputModeID)
            .buttonStyle(SettingsButtonStyle.primary)
        }
    }

    private func indicatorColor(for mode: OutputMode, isLocked: Bool) -> Color {
        if isLocked { return AppTheme.textTertiary }
        return mode.isEnabled ? AppTheme.statusWorking : AppTheme.textTertiary
    }

    private func textBinding(
        for modeID: String,
        get: @escaping (OutputMode) -> String,
        set: @escaping (String, String) -> Void
    ) -> Binding<String> {
        Binding(
            get: { model.modes.first { $0.id == modeID }.map(get) ?? "" },
            set: { set($0, modeID) }
        )
    }

    private func enabledBinding(for modeID: String) -> Binding<Bool> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.isEnabled ?? false },
            set: { model.setEnabled($0, for: modeID) }
        )
    }

    private func pasteBinding(for modeID: String) -> Binding<Bool> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.pasteVisualAttachments ?? false },
            set: { model.setPasteVisualAttachments($0, for: modeID) }
        )
    }

    private func contextPolicyBinding(for modeID: String) -> Binding<ContextCapturePolicy> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.contextPolicy ?? .off },
            set: { model.setContextPolicy($0, for: modeID) }
        )
    }

    private func templateBinding(for modeID: String) -> Binding<String> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.templateID ?? PostProcessingTemplate.cleanID },
            set: { model.setTemplateID($0, for: modeID) }
        )
    }

    private func useGlobalModelBinding(for modeID: String) -> Binding<Bool> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.codexModelRawOverride == nil },
            set: { model.setUsesGlobalModel($0, for: modeID, defaultModelRaw: globalCodexModelRaw) }
        )
    }

    private func modeModelBinding(for modeID: String) -> Binding<String> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.resolvedCodexModelRaw(defaultModelRaw: globalCodexModelRaw) ?? globalCodexModelRaw },
            set: { model.setModeModel($0, for: modeID) }
        )
    }

    private func useGlobalReasoningBinding(for modeID: String) -> Binding<Bool> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.codexReasoningEffortRawOverride == nil },
            set: { model.setUsesGlobalReasoning($0, for: modeID, defaultReasoningEffortRaw: globalReasoningEffortRaw) }
        )
    }

    private func modeReasoningBinding(for modeID: String) -> Binding<String> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.resolvedCodexReasoningEffortRaw(defaultReasoningEffortRaw: globalReasoningEffortRaw) ?? globalReasoningEffortRaw },
            set: { model.setModeReasoning($0, for: modeID) }
        )
    }

    private func useGlobalServiceTierBinding(for modeID: String) -> Binding<Bool> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.codexServiceTierRawOverride == nil },
            set: { model.setUsesGlobalServiceTier($0, for: modeID, defaultServiceTierRaw: globalServiceTierRaw) }
        )
    }

    private func modeServiceTierBinding(for modeID: String) -> Binding<String> {
        Binding(
            get: { model.modes.first { $0.id == modeID }?.resolvedCodexServiceTierRaw(defaultServiceTierRaw: globalServiceTierRaw) ?? globalServiceTierRaw },
            set: { model.setModeServiceTier($0, for: modeID) }
        )
    }
}
