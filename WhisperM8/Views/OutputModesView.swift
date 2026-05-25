import SwiftUI

struct OutputModesView: View {
    @State private var store = OutputModeStore()
    @State private var templateStore = PostProcessingTemplateStore()
    @State private var modes = OutputModeStore().modes
    @State private var templates = PostProcessingTemplateStore().templates
    @State private var selectedModeID = OutputMode.rawID
    @State private var errorMessage: String?
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.rawID
    @AppStorage("showModePickerInMiniOverlay") private var showModePickerInMiniOverlay = true
    @AppStorage("fallbackToRawOnProcessingError") private var fallbackToRawOnProcessingError = true
    @AppStorage("codexPostProcessingModel") private var globalCodexModelRaw = CodexPostProcessingModel.defaultModel.rawValue

    private var selectedModeIndex: Int? {
        modes.firstIndex { $0.id == selectedModeID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Modes")
                                .font(.headline)
                            Spacer()
                            Button {
                                addMode()
                            } label: {
                                Label("New", systemImage: "plus")
                            }
                            .labelStyle(.iconOnly)
                            .help("Create custom mode")
                        }

                        VStack(spacing: 0) {
                            ForEach($modes) { $mode in
                                Button {
                                    selectedModeID = mode.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(mode.isEnabled ? Color.green : Color.secondary.opacity(0.35))
                                            .frame(width: 8, height: 8)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mode.name)
                                                .font(.body.weight(.semibold))
                                            Text(modeSummary(mode))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Toggle("Enabled", isOn: modeEnabledBinding(for: $mode))
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.small)
                                            .disabled(!canDisable(mode))
                                            .help(modeToggleHelp(mode))

                                        if mode.id == defaultOutputModeID {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(mode.id == selectedModeID ? Color.accentColor.opacity(0.18) : Color.clear)
                                )

                                if mode.id != modes.last?.id {
                                    Divider()
                                        .padding(.leading, 30)
                                }
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(width: 280)

                    if let selectedModeIndex {
                        modeEditor(for: $modes[selectedModeIndex])
                    } else {
                        ContentUnavailableView("No Mode Selected", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Behavior")
                        .font(.headline)

                    VStack(spacing: 0) {
                        Toggle("Fallback to Raw on processing errors", isOn: $fallbackToRawOnProcessingError)
                            .padding(.vertical, 10)
                        Divider()
                        Toggle("Show mode chip in Mini overlay", isOn: $showModePickerInMiniOverlay)
                            .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .navigationTitle("Modes")
        .onAppear(perform: reload)
        .onChange(of: modes) { _, _ in
            saveModes()
        }
        .onChange(of: defaultOutputModeID) { _, _ in
            applyDefaultFlags()
        }
    }

    @ViewBuilder
    private func modeEditor(for mode: Binding<OutputMode>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.wrappedValue.name)
                        .font(.title3.weight(.semibold))
                    Text(mode.wrappedValue.kind == .custom ? "Custom mode" : "Built-in mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(mode.wrappedValue.id == defaultOutputModeID ? "Default" : "Make Default") {
                    setDefault(mode.wrappedValue.id)
                }
                .disabled(mode.wrappedValue.id == defaultOutputModeID)
            }

            VStack(spacing: 12) {
                TextField("Mode name", text: mode.name)
                TextField("Overlay label", text: mode.shortLabel)

                Toggle("Show in recording overlay and Test Lab", isOn: modeEnabledBinding(for: mode))
                    .disabled(!canDisable(mode.wrappedValue))

                Text(modeVisibilityHelp(mode.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Paste screenshots into target app", isOn: mode.pasteVisualAttachments)

                Text("When Auto-paste is enabled, captured screenshots are pasted into the target composer after the text. The message is not sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mode.wrappedValue.usesPostProcessing {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use global Codex model", isOn: useGlobalModelBinding(for: mode))

                        if mode.wrappedValue.codexModelRawOverride == nil {
                            Text("Uses Codex / ChatGPT default: \(CodexPostProcessingModel.resolve(globalCodexModelRaw).displayName).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Mode model", selection: modeModelSelection(for: mode)) {
                                ForEach(CodexPostProcessingModel.allCases) { model in
                                    Text(model.displayName).tag(model.rawValue)
                                }
                            }

                            Text(CodexPostProcessingModel.resolve(mode.wrappedValue.resolvedCodexModelRaw(defaultModelRaw: globalCodexModelRaw)).detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Picker("Selected context", selection: mode.contextPolicy) {
                        ForEach(ContextCapturePolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }

                    Text(mode.wrappedValue.contextPolicy.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Template", selection: templateSelection(for: mode)) {
                        ForEach(templates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }

                    if let template = templates.first(where: { $0.id == mode.wrappedValue.templateID }) {
                        Text(template.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Raw mode skips Codex and outputs the transcript exactly as returned by speech-to-text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                if mode.wrappedValue.kind == .custom {
                    Button("Delete Custom Mode", role: .destructive) {
                        deleteSelectedMode()
                    }
                }

                Spacer()

                Button("Reload") {
                    reload()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func templateSelection(for mode: Binding<OutputMode>) -> Binding<String> {
        Binding(
            get: { mode.wrappedValue.templateID ?? PostProcessingTemplate.cleanID },
            set: { mode.wrappedValue.templateID = $0 }
        )
    }

    private func useGlobalModelBinding(for mode: Binding<OutputMode>) -> Binding<Bool> {
        Binding(
            get: { mode.wrappedValue.codexModelRawOverride == nil },
            set: { useGlobal in
                mode.wrappedValue.codexModelRawOverride = useGlobal
                    ? nil
                    : mode.wrappedValue.resolvedCodexModelRaw(defaultModelRaw: globalCodexModelRaw)
            }
        )
    }

    private func modeModelSelection(for mode: Binding<OutputMode>) -> Binding<String> {
        Binding(
            get: { mode.wrappedValue.resolvedCodexModelRaw(defaultModelRaw: globalCodexModelRaw) },
            set: { mode.wrappedValue.codexModelRawOverride = $0 }
        )
    }

    private func modeEnabledBinding(for mode: Binding<OutputMode>) -> Binding<Bool> {
        Binding(
            get: { mode.wrappedValue.isEnabled },
            set: { newValue in
                if newValue || canDisable(mode.wrappedValue) {
                    mode.wrappedValue.isEnabled = newValue
                }
            }
        )
    }

    private func reload() {
        templates = templateStore.templates
        modes = store.modes
        if !modes.contains(where: { $0.id == selectedModeID }) {
            selectedModeID = defaultOutputModeID
        }
    }

    private func saveModes() {
        do {
            try store.saveModes(modes)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDefaultFlags() {
        for index in modes.indices {
            modes[index].isDefault = modes[index].id == defaultOutputModeID
            if modes[index].isDefault {
                modes[index].isEnabled = true
            }
        }
    }

    private func setDefault(_ id: String) {
        defaultOutputModeID = id
        selectedModeID = id
        applyDefaultFlags()
        saveModes()
    }

    private func addMode() {
        let mode = store.createCustomMode()
        modes.append(mode)
        selectedModeID = mode.id
        saveModes()
    }

    private func deleteSelectedMode() {
        guard let index = selectedModeIndex, modes[index].kind == .custom else { return }
        let removedID = modes[index].id
        modes.remove(at: index)
        if defaultOutputModeID == removedID {
            defaultOutputModeID = OutputMode.rawID
        }
        selectedModeID = modes.first?.id ?? OutputMode.rawID
        saveModes()
    }

    private func modeSummary(_ mode: OutputMode) -> String {
        if mode.kind == .raw {
            return "No post-processing"
        }
        let templateName = templates.first { $0.id == mode.templateID }?.name ?? "No template"
        let modelText: String
        if let override = mode.codexModelRawOverride, !override.isEmpty {
            modelText = CodexPostProcessingModel.resolve(override).displayName
        } else {
            modelText = "Default model"
        }
        return "\(mode.shortLabel) · \(templateName) · \(modelText)"
    }

    private func canDisable(_ mode: OutputMode) -> Bool {
        mode.id != OutputMode.rawID && mode.id != defaultOutputModeID
    }

    private func modeToggleHelp(_ mode: OutputMode) -> String {
        if mode.id == OutputMode.rawID {
            return "Raw stays available as a safe fallback."
        }
        if mode.id == defaultOutputModeID {
            return "The default mode stays visible. Pick another default before hiding it."
        }
        return mode.isEnabled ? "Hide this mode from recording." : "Show this mode while recording."
    }

    private func modeVisibilityHelp(_ mode: OutputMode) -> String {
        if mode.id == OutputMode.rawID {
            return "Raw stays visible as the fallback mode."
        }
        if mode.id == defaultOutputModeID {
            return "The current default mode stays visible. Make another mode default before hiding this one."
        }
        return mode.isEnabled
            ? "This mode appears in the recording overlay and Test Lab."
            : "This mode is hidden from the recording overlay and Test Lab."
    }
}
