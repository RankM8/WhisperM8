import SwiftUI

enum OutputDashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case modes = "Modes"
    case templates = "Templates"
    case codex = "Codex"
    case testLab = "Test Lab"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview:
            return "rectangle.grid.2x2"
        case .modes:
            return "slider.horizontal.3"
        case .templates:
            return "doc.text"
        case .codex:
            return "sparkles"
        case .testLab:
            return "testtube.2"
        }
    }
}

struct OutputDashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: OutputDashboardSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(OutputDashboardSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection ?? .overview {
            case .overview:
                OutputOverviewView()
                    .environment(appState)
            case .modes:
                OutputModesView()
            case .templates:
                OutputTemplatesView()
            case .codex:
                CodexSettingsView()
            case .testLab:
                OutputTestLabView()
            }
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

struct OutputOverviewView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("defaultOutputModeID") private var defaultOutputModeID = OutputMode.rawID
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
                LastOutputPreview(title: "Context", text: appState.lastSelectedContext?.text)
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
}

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

                if mode.wrappedValue.usesPostProcessing {
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
        return "\(mode.shortLabel) · \(templateName)"
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

struct OutputTemplatesView: View {
    @State private var store = PostProcessingTemplateStore()
    @State private var templates = PostProcessingTemplate.builtInTemplates
    @State private var selectedTemplateID = PostProcessingTemplate.cleanID
    @State private var editableName = ""
    @State private var editableDescription = ""
    @State private var editableInstruction = ""
    @State private var errorMessage: String?

    private var selectedTemplate: PostProcessingTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                templateList
                    .frame(width: 300)

                templateEditor
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
        .navigationTitle("Templates")
        .onAppear(perform: reload)
        .onChange(of: selectedTemplateID) { _, _ in
            loadEditor()
        }
    }

    private var templateList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Templates")
                    .font(.headline)
                Spacer()
                Button {
                    createTemplate()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("Create custom template")
            }

            VStack(alignment: .leading, spacing: 14) {
                templateGroup("Built-in", templates.filter(\.isBuiltIn))
                templateGroup("Custom", templates.filter { !$0.isBuiltIn })
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func templateGroup(_ title: String, _ groupTemplates: [PostProcessingTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            if groupTemplates.isEmpty {
                Text("None yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(groupTemplates) { template in
                    Button {
                        selectedTemplateID = template.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                                .font(.body.weight(.semibold))
                            Text(template.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(template.id == selectedTemplateID ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var templateEditor: some View {
        if let selectedTemplate {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTemplate.name)
                            .font(.title3.weight(.semibold))
                        Text(selectedTemplate.isBuiltIn ? "Read-only built-in template" : "Custom template")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Duplicate") {
                        duplicate(selectedTemplate)
                    }

                    Button("Save") {
                        saveSelectedTemplate()
                    }
                    .disabled(selectedTemplate.isBuiltIn)
                }

                TextField("Name", text: $editableName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedTemplate.isBuiltIn)

                TextField("Description", text: $editableDescription)
                    .textFieldStyle(.roundedBorder)
                    .disabled(selectedTemplate.isBuiltIn)

                    Text("Placeholders: {rawTranscript}, {selectedContext}, {activeApp}, {language}, {date}")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $editableInstruction)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .frame(minHeight: 360)
                    .disabled(selectedTemplate.isBuiltIn)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        } else {
            ContentUnavailableView("No Template Selected", systemImage: "doc.text")
                .frame(maxWidth: .infinity)
        }
    }

    private func reload() {
        templates = store.templates
        if !templates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = templates.first?.id ?? PostProcessingTemplate.cleanID
        }
        loadEditor()
    }

    private func loadEditor() {
        guard let selectedTemplate else { return }
        editableName = selectedTemplate.name
        editableDescription = selectedTemplate.description
        editableInstruction = selectedTemplate.instruction
        errorMessage = nil
    }

    private func duplicate(_ template: PostProcessingTemplate) {
        do {
            let duplicated = try store.duplicate(template)
            reload()
            selectedTemplateID = duplicated.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createTemplate() {
        let now = Date()
        let template = PostProcessingTemplate(
            id: UUID().uuidString,
            name: "Custom template",
            description: "Describe what this mode should do.",
            instruction: """
            Rewrite this transcript.

            Rules:
            - Output only the final text.
            - Do not invent facts.

            Language: {language}

            Transcript:
            {rawTranscript}
            """,
            createdAt: now,
            updatedAt: now,
            isBuiltIn: false
        )

        do {
            try store.saveCustomTemplates(templates + [template])
            reload()
            selectedTemplateID = template.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSelectedTemplate() {
        guard let index = templates.firstIndex(where: { $0.id == selectedTemplateID }),
              !templates[index].isBuiltIn else {
            return
        }

        templates[index].name = editableName
        templates[index].description = editableDescription
        templates[index].instruction = editableInstruction
        templates[index].updatedAt = Date()

        do {
            try store.saveCustomTemplates(templates)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CodexSettingsView: View {
    @AppStorage("codexPostProcessingModel") private var selectedModelRaw = CodexPostProcessingModel.defaultModel.rawValue
    @AppStorage("codexReasoningEffort") private var reasoningEffortRaw = CodexReasoningEffort.defaultEffort.rawValue
    @State private var status = CodexConnectionStatus.unknown
    @State private var codexVersion = "Unknown"

    private var selectedModel: CodexPostProcessingModel {
        CodexPostProcessingModel.resolve(selectedModelRaw)
    }

    private var selectedReasoningEffort: CodexReasoningEffort {
        CodexReasoningEffort.resolve(reasoningEffortRaw)
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

struct LastOutputPreview: View {
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
