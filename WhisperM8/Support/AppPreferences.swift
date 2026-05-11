import Foundation

struct AppPreferences {
    static var shared = AppPreferences()

    static let defaultMaxScreenshotsPerRecording = 20
    static let maximumScreenshotsPerRecording = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateScreenshotLimitDefaultIfNeeded()
    }

    var selectedProviderRaw: String? {
        get { defaults.string(forKey: Keys.selectedProvider) }
        nonmutating set { setOptionalString(newValue, forKey: Keys.selectedProvider) }
    }

    var selectedModelRaw: String? {
        get { defaults.string(forKey: Keys.selectedModel) }
        nonmutating set { setOptionalString(newValue, forKey: Keys.selectedModel) }
    }

    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "de" }
        nonmutating set { defaults.set(newValue, forKey: Keys.language) }
    }

    var isAutoPasteEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.autoPasteEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.autoPasteEnabled) }
    }

    var isAudioDuckingEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.audioDuckingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.audioDuckingEnabled) }
    }

    var audioDuckingFactor: Double {
        get {
            let value = defaults.double(forKey: Keys.audioDuckingFactor)
            return value > 0 ? value : 0.2
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.audioDuckingFactor) }
    }

    var overlayStyleRaw: String {
        get { defaults.string(forKey: Keys.overlayStyle) ?? OverlayStyle.full.rawValue }
        nonmutating set { defaults.set(newValue, forKey: Keys.overlayStyle) }
    }

    var selectedAudioDeviceUID: String? {
        get { defaults.string(forKey: Keys.selectedAudioDeviceUID) }
        nonmutating set { setOptionalString(newValue, forKey: Keys.selectedAudioDeviceUID) }
    }

    /// Theme-Override: `system` (default, folgt macOS), `light` oder `dark`.
    /// Wird vom `ThemeManager` und einem optionalen Settings-Picker gelesen.
    var appearanceOverride: AppearanceOverride {
        get {
            let raw = defaults.string(forKey: Keys.appearanceOverride) ?? AppearanceOverride.system.rawValue
            return AppearanceOverride(rawValue: raw) ?? .system
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.appearanceOverride) }
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        nonmutating set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    var isDebugFileLoggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugFileLoggingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.debugFileLoggingEnabled) }
    }

    var defaultOutputModeID: String {
        get { defaults.string(forKey: Keys.defaultOutputModeID) ?? OutputMode.cleanID }
        nonmutating set { defaults.set(newValue, forKey: Keys.defaultOutputModeID) }
    }

    var lastSelectedOutputModeID: String {
        get { defaults.string(forKey: Keys.lastSelectedOutputModeID) ?? defaultOutputModeID }
        nonmutating set { defaults.set(newValue, forKey: Keys.lastSelectedOutputModeID) }
    }

    var fallbackToRawOnProcessingError: Bool {
        get { boolWithDefault(true, forKey: Keys.fallbackToRawOnProcessingError) }
        nonmutating set { defaults.set(newValue, forKey: Keys.fallbackToRawOnProcessingError) }
    }

    var showModePickerInMiniOverlay: Bool {
        get { boolWithDefault(true, forKey: Keys.showModePickerInMiniOverlay) }
        nonmutating set { defaults.set(newValue, forKey: Keys.showModePickerInMiniOverlay) }
    }

    var isSelectedContextCaptureEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.selectedContextCaptureEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.selectedContextCaptureEnabled) }
    }

    var isVisualContextCaptureEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.visualContextCaptureEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.visualContextCaptureEnabled) }
    }

    var maxScreenshotsPerRecording: Int {
        get {
            let value = defaults.integer(forKey: Keys.maxScreenshotsPerRecording)
            guard value > 0 else { return Self.defaultMaxScreenshotsPerRecording }
            return min(value, Self.maximumScreenshotsPerRecording)
        }
        nonmutating set {
            defaults.set(max(1, min(newValue, Self.maximumScreenshotsPerRecording)), forKey: Keys.maxScreenshotsPerRecording)
        }
    }

    var maxScreenRecordingDuration: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.maxScreenRecordingDuration)
            return value > 0 ? value : 30
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.maxScreenRecordingDuration) }
    }

    var deleteContextFilesAfterProcessing: Bool {
        get { boolWithDefault(false, forKey: Keys.deleteContextFilesAfterProcessing) }
        nonmutating set { defaults.set(newValue, forKey: Keys.deleteContextFilesAfterProcessing) }
    }

    var codexPostProcessingModelRaw: String {
        get { defaults.string(forKey: Keys.codexPostProcessingModel) ?? CodexPostProcessingModel.defaultModel.rawValue }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexPostProcessingModel) }
    }

    var codexReasoningEffortRaw: String {
        get { defaults.string(forKey: Keys.codexReasoningEffort) ?? CodexReasoningEffort.defaultEffort.rawValue }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexReasoningEffort) }
    }

    var codexVisualInputModeRaw: String {
        get { defaults.string(forKey: Keys.codexVisualInputMode) ?? CodexVisualInputMode.defaultMode.rawValue }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVisualInputMode) }
    }

    var agentDefaultProjectPath: String {
        get {
            defaults.string(forKey: Keys.agentDefaultProjectPath)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentDefaultProjectPath) }
    }

    /// Default-Provider für „Neuer Chat" in der Agent-Chats-Sidebar.
    /// Werte: "codex" oder "claude" (matched `AgentProvider.rawValue`).
    var defaultAgentProviderRaw: String {
        get { defaults.string(forKey: Keys.defaultAgentProvider) ?? "claude" }
        nonmutating set { defaults.set(newValue, forKey: Keys.defaultAgentProvider) }
    }

    /// Frei konfigurierbare zusätzliche CLI-Argumente, die an den Codex-Aufruf
    /// vorne (vor `-C <path>`/`-m <model>`/`resume`/...) angehängt werden.
    /// Beispiel: `--ask-for-approval untrusted`. Eingabe via Whitespace-getrennt.
    var codexExtraArguments: String {
        get { defaults.string(forKey: Keys.codexExtraArguments) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexExtraArguments) }
    }

    /// Frei konfigurierbare zusätzliche CLI-Argumente für Claude-Aufrufe.
    /// Beispiel: `--dangerously-skip-permissions`. Eingabe via Whitespace-getrennt.
    var claudeExtraArguments: String {
        get { defaults.string(forKey: Keys.claudeExtraArguments) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeExtraArguments) }
    }

    func objectExists(for key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    func removeObject(for key: String) {
        defaults.removeObject(forKey: key)
    }

    func double(for key: String) -> Double {
        defaults.double(forKey: key)
    }

    func set(_ value: Double, for key: String) {
        defaults.set(value, forKey: key)
    }

    private func boolWithDefault(_ defaultValue: Bool, forKey key: String) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func setOptionalString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateScreenshotLimitDefaultIfNeeded() {
        guard defaults.bool(forKey: Keys.didMigrateMaxScreenshotsPerRecordingTo20) == false else {
            return
        }

        let value = defaults.integer(forKey: Keys.maxScreenshotsPerRecording)
        if value <= 0 || value == 3 {
            defaults.set(Self.defaultMaxScreenshotsPerRecording, forKey: Keys.maxScreenshotsPerRecording)
        } else if value > Self.maximumScreenshotsPerRecording {
            defaults.set(Self.maximumScreenshotsPerRecording, forKey: Keys.maxScreenshotsPerRecording)
        }
        defaults.set(true, forKey: Keys.didMigrateMaxScreenshotsPerRecordingTo20)
    }
}

enum PreferenceKeys {
    static let selectedProvider = "selectedProvider"
    static let selectedModel = "selectedModel"
    static let language = "language"
    static let autoPasteEnabled = "autoPasteEnabled"
    static let audioDuckingEnabled = "audioDuckingEnabled"
    static let audioDuckingFactor = "audioDuckingFactor"
    static let overlayStyle = "overlayStyle"
    static let overlayPositionX = "overlayPositionX"
    static let overlayPositionY = "overlayPositionY"
    static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
    static let onboardingCompleted = "onboardingCompleted"
    static let debugFileLoggingEnabled = "debugFileLoggingEnabled"
    static let defaultOutputModeID = "defaultOutputModeID"
    static let lastSelectedOutputModeID = "lastSelectedOutputModeID"
    static let fallbackToRawOnProcessingError = "fallbackToRawOnProcessingError"
    static let showModePickerInMiniOverlay = "showModePickerInMiniOverlay"
    static let selectedContextCaptureEnabled = "selectedContextCaptureEnabled"
    static let visualContextCaptureEnabled = "visualContextCaptureEnabled"
    static let maxScreenshotsPerRecording = "maxScreenshotsPerRecording"
    static let didMigrateMaxScreenshotsPerRecordingTo20 = "didMigrateMaxScreenshotsPerRecordingTo20"
    static let maxScreenRecordingDuration = "maxScreenRecordingDuration"
    static let deleteContextFilesAfterProcessing = "deleteContextFilesAfterProcessing"
    static let codexPostProcessingModel = "codexPostProcessingModel"
    static let codexReasoningEffort = "codexReasoningEffort"
    static let codexVisualInputMode = "codexVisualInputMode"
    static let agentDefaultProjectPath = "agentDefaultProjectPath"
    static let defaultAgentProvider = "defaultAgentProvider"
    static let codexExtraArguments = "codexExtraArguments"
    static let claudeExtraArguments = "claudeExtraArguments"
    static let appearanceOverride = "appearanceOverride"
}

private typealias Keys = PreferenceKeys
