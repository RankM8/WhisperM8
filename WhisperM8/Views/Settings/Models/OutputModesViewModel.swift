import Foundation
import Observation

@MainActor
@Observable
final class OutputModesViewModel {
    var modes: [OutputMode] = []
    var templates: [PostProcessingTemplate] = []
    var selectedModeID: String
    var errorMessage: String?
    var defaultOutputModeID: String

    @ObservationIgnored private let store: OutputModeStore
    @ObservationIgnored private let templateStore: PostProcessingTemplateStore

    init(
        fileURL: URL? = nil,
        templateFileURL: URL? = nil,
        selectedModeID: String = OutputMode.rawID,
        defaultOutputModeID: String = AppPreferences.shared.defaultOutputModeID
    ) {
        self.store = OutputModeStore(fileURL: fileURL)
        self.templateStore = PostProcessingTemplateStore(fileURL: templateFileURL)
        self.selectedModeID = selectedModeID
        self.defaultOutputModeID = defaultOutputModeID
        reload()
    }

    var selectedMode: OutputMode? {
        modes.first { $0.id == selectedModeID }
    }

    var selectedModeIndex: Int? {
        modes.firstIndex { $0.id == selectedModeID }
    }

    var enabledModes: [OutputMode] {
        modes.filter(\.isEnabled)
    }

    func reload() {
        templates = templateStore.templates
        modes = store.modes
        if !modes.contains(where: { $0.id == selectedModeID }) {
            selectedModeID = defaultOutputModeID
        }
    }

    func addMode() {
        let mode = store.createCustomMode()
        modes.append(mode)
        selectedModeID = mode.id
        saveModes()
    }

    func setDefault(_ id: String) {
        defaultOutputModeID = id
        AppPreferences.shared.defaultOutputModeID = id
        selectedModeID = id
        applyDefaultFlags()
        saveModes()
    }

    func deleteSelectedMode() {
        guard let index = selectedModeIndex, modes[index].kind == .custom else { return }
        let removedID = modes[index].id
        modes.remove(at: index)
        if defaultOutputModeID == removedID {
            defaultOutputModeID = OutputMode.rawID
            AppPreferences.shared.defaultOutputModeID = OutputMode.rawID
        }
        selectedModeID = modes.first?.id ?? OutputMode.rawID
        saveModes()
    }

    func setEnabled(_ isEnabled: Bool, for modeID: String) {
        updateMode(modeID) { mode in
            if isEnabled || canDisable(mode) {
                mode.isEnabled = isEnabled
            }
        }
    }

    func setName(_ name: String, for modeID: String) {
        updateMode(modeID) { $0.name = name }
    }

    func setShortLabel(_ label: String, for modeID: String) {
        updateMode(modeID) { $0.shortLabel = label }
    }

    func setPasteVisualAttachments(_ isOn: Bool, for modeID: String) {
        updateMode(modeID) { $0.pasteVisualAttachments = isOn }
    }

    func setContextPolicy(_ policy: ContextCapturePolicy, for modeID: String) {
        updateMode(modeID) { $0.contextPolicy = policy }
    }

    func setTemplateID(_ templateID: String, for modeID: String) {
        updateMode(modeID) { $0.templateID = templateID }
    }

    func setUsesGlobalModel(_ useGlobal: Bool, for modeID: String, defaultModelRaw: String) {
        updateMode(modeID) { mode in
            mode.codexModelRawOverride = useGlobal
                ? nil
                : mode.resolvedCodexModelRaw(defaultModelRaw: defaultModelRaw)
        }
    }

    func setModeModel(_ rawValue: String, for modeID: String) {
        updateMode(modeID) { $0.codexModelRawOverride = rawValue }
    }

    func setUsesGlobalReasoning(_ useGlobal: Bool, for modeID: String, defaultReasoningEffortRaw: String) {
        updateMode(modeID) { mode in
            mode.codexReasoningEffortRawOverride = useGlobal
                ? nil
                : mode.resolvedCodexReasoningEffortRaw(defaultReasoningEffortRaw: defaultReasoningEffortRaw)
        }
    }

    func setModeReasoning(_ rawValue: String, for modeID: String) {
        updateMode(modeID) { $0.codexReasoningEffortRawOverride = rawValue }
    }

    func setUsesGlobalServiceTier(_ useGlobal: Bool, for modeID: String, defaultServiceTierRaw: String) {
        updateMode(modeID) { mode in
            mode.codexServiceTierRawOverride = useGlobal
                ? nil
                : mode.resolvedCodexServiceTierRaw(defaultServiceTierRaw: defaultServiceTierRaw)
        }
    }

    func setModeServiceTier(_ rawValue: String, for modeID: String) {
        updateMode(modeID) { $0.codexServiceTierRawOverride = rawValue }
    }

    func modeSummary(_ mode: OutputMode) -> String {
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
        let speedText: String
        if let override = mode.codexServiceTierRawOverride, !override.isEmpty {
            speedText = CodexServiceTier.resolve(override).displayName
        } else {
            speedText = "Default speed"
        }
        return "\(mode.shortLabel) · \(templateName) · \(modelText) · \(speedText)"
    }

    func canDisable(_ mode: OutputMode) -> Bool {
        mode.id != OutputMode.rawID && mode.id != defaultOutputModeID
    }

    func modeToggleHelp(_ mode: OutputMode) -> String {
        if mode.id == OutputMode.rawID {
            return "Fast stays available as a safe fallback."
        }
        if mode.id == defaultOutputModeID {
            return "The default mode stays visible. Pick another default before hiding it."
        }
        return mode.isEnabled ? "Hide this mode from recording." : "Show this mode while recording."
    }

    func modeVisibilityHelp(_ mode: OutputMode) -> String {
        if mode.id == OutputMode.rawID {
            return "Fast stays visible as the fallback mode."
        }
        if mode.id == defaultOutputModeID {
            return "The current default mode stays visible. Make another mode default before hiding this one."
        }
        return mode.isEnabled
            ? "This mode appears in the recording overlay and Test Lab."
            : "This mode is hidden from the recording overlay and Test Lab."
    }

    func templateDescription(for templateID: String?) -> String? {
        templates.first { $0.id == templateID }?.description
    }

    private func updateMode(_ modeID: String, mutate: (inout OutputMode) -> Void) {
        guard let index = modes.firstIndex(where: { $0.id == modeID }) else { return }
        mutate(&modes[index])
        saveModes()
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
}
