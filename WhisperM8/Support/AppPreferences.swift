import Foundation

struct AppPreferences {
    static var shared = AppPreferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Keys.onboardingCompleted) }
        nonmutating set { defaults.set(newValue, forKey: Keys.onboardingCompleted) }
    }

    var isDebugFileLoggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugFileLoggingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.debugFileLoggingEnabled) }
    }

    var defaultOutputModeID: String {
        get { defaults.string(forKey: Keys.defaultOutputModeID) ?? OutputMode.rawID }
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
            return value > 0 ? value : 3
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.maxScreenshotsPerRecording) }
    }

    var maxScreenRecordingDuration: TimeInterval {
        get {
            let value = defaults.double(forKey: Keys.maxScreenRecordingDuration)
            return value > 0 ? value : 30
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.maxScreenRecordingDuration) }
    }

    var deleteContextFilesAfterProcessing: Bool {
        get { boolWithDefault(true, forKey: Keys.deleteContextFilesAfterProcessing) }
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
    static let maxScreenRecordingDuration = "maxScreenRecordingDuration"
    static let deleteContextFilesAfterProcessing = "deleteContextFilesAfterProcessing"
    static let codexPostProcessingModel = "codexPostProcessingModel"
    static let codexReasoningEffort = "codexReasoningEffort"
}

private typealias Keys = PreferenceKeys
