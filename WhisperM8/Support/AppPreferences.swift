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

    /// Nutzungsprofil (Dictation-only / Enrichment / Full). Default = `.full`, damit
    /// Bestandsnutzer ohne gesetztes Profil das heutige Verhalten behalten.
    var usageProfile: AppUsageProfile {
        get {
            let raw = defaults.string(forKey: Keys.usageProfile) ?? AppUsageProfile.defaultProfile.rawValue
            return AppUsageProfile(rawValue: raw) ?? .full
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Keys.usageProfile) }
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
        get { defaults.string(forKey: Keys.overlayStyle) ?? OverlayStyle.mini.rawValue }
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

    var isDebugFileLoggingEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugFileLoggingEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.debugFileLoggingEnabled) }
    }

    var defaultOutputModeID: String {
        // Fallback bewusst Fast/raw: Erstinstallationen starten ohne Codex-Login,
        // Fast liefert sofort Ergebnisse (User-Entscheidung 2026-07-06; vorher clean).
        get { Self.remappingRetiredModeID(defaults.string(forKey: Keys.defaultOutputModeID)) ?? OutputMode.rawID }
        nonmutating set { defaults.set(newValue, forKey: Keys.defaultOutputModeID) }
    }

    var lastSelectedOutputModeID: String {
        get { Self.remappingRetiredModeID(defaults.string(forKey: Keys.lastSelectedOutputModeID)) ?? defaultOutputModeID }
        nonmutating set { defaults.set(newValue, forKey: Keys.lastSelectedOutputModeID) }
    }

    /// Lese-seitiger Remap stillgelegter Modus-IDs (Chat → Prompt, 2026-07-07):
    /// der gespeicherte Wert bleibt unangetastet (Konvention: gespeicherte Prefs
    /// werden nie still mutiert), effektiv gilt der semantisch nächste lebende Modus.
    private static func remappingRetiredModeID(_ storedID: String?) -> String? {
        guard let storedID else { return nil }
        return OutputMode.retiredBuiltInModeIDs.contains(storedID) ? OutputMode.promptID : storedID
    }

    var fallbackToRawOnProcessingError: Bool {
        get { boolWithDefault(true, forKey: Keys.fallbackToRawOnProcessingError) }
        nonmutating set { defaults.set(newValue, forKey: Keys.fallbackToRawOnProcessingError) }
    }

    var showModePickerInMiniOverlay: Bool {
        get { boolWithDefault(true, forKey: Keys.showModePickerInMiniOverlay) }
        nonmutating set { defaults.set(newValue, forKey: Keys.showModePickerInMiniOverlay) }
    }

    /// ✓-Button in der Recording-Pill: beendet die Aufnahme und transkribiert
    /// (derselbe Pfad wie der Hotkey-Stop). Abschaltbar für Hotkey-Puristen.
    var showConfirmButtonInOverlay: Bool {
        get { boolWithDefault(true, forKey: Keys.showConfirmButtonInOverlay) }
        nonmutating set { defaults.set(newValue, forKey: Keys.showConfirmButtonInOverlay) }
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

    /// Wie `codexPostProcessingModelRaw`, aber mit aufgelöstem "auto"-Sentinel
    /// (→ aktuelles Frontier-Modell). Für Stellen, die einen KONKRETEN Slug
    /// persistieren müssen (Agent-Session-Erzeugung): historische Chats sollen
    /// auf ihrem damaligen Modell bleiben, nur neue bekommen das aktuelle.
    /// Der rohe Getter bleibt für die Settings-UI ("auto" sichtbar).
    func resolvedCodexDefaultModelRaw() -> String {
        CodexModelSelection.resolveSlug(codexPostProcessingModelRaw)
    }

    var codexReasoningEffortRaw: String {
        get { defaults.string(forKey: Keys.codexReasoningEffort) ?? CodexReasoningEffort.defaultEffort.rawValue }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexReasoningEffort) }
    }

    var codexServiceTierRaw: String {
        get { defaults.string(forKey: Keys.codexServiceTier) ?? CodexServiceTier.defaultTier.rawValue }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexServiceTier) }
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
    /// Werte:
    /// - "claude" (AgentProvider.claude, Chat-Modus)
    /// - "codex" (AgentProvider.codex, Chat-Modus)
    /// - "claude-agents" (AgentProvider.claude, Agent-View-Modus via `claude agents`)
    /// Backward-kompatibel: alte Workspaces mit nur "claude"/"codex" funktionieren weiter.
    var defaultAgentProviderRaw: String {
        get { defaults.string(forKey: Keys.defaultAgentProvider) ?? "claude" }
        nonmutating set { defaults.set(newValue, forKey: Keys.defaultAgentProvider) }
    }

    /// Liefert `(provider, kind)` aus `defaultAgentProviderRaw` aufgeloest.
    /// `kind == nil` bedeutet "Default-Chat" (passt mit `AgentChatSession.kind == nil`,
    /// das via `effectiveKind` zu `.chat` resolved).
    var defaultAgentLaunchTarget: (provider: AgentProvider, kind: AgentSessionKind?) {
        switch defaultAgentProviderRaw {
        case "codex":
            return (.codex, nil)
        case "claude-agents":
            return (.claude, .agentView)
        case "claude":
            return (.claude, nil)
        default:
            return (.claude, nil)
        }
    }

    /// Aktiviert das automatische Umbenennen von neuen Chats nach dem ersten
    /// Turn-End (via `claude -p`-Subprocess). Default: an. Wenn aus: Title
    /// bleibt "Claude Chat" / "Codex Chat" bis der User selbst umbenennt.
    var isAutoChatRenameEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.isAutoChatRenameEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.isAutoChatRenameEnabled) }
    }

    /// Aktiviert automatische Chat-Zusammenfassungen (Headless-CLI nach
    /// Session-Ende + Start-Abgleich). Default: an. Manueller Refresh in der
    /// Summary-Karte funktioniert unabhängig davon.
    var isAutoSummaryEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.isAutoSummaryEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.isAutoSummaryEnabled) }
    }

    /// Steuert ob SwiftTerm Terminal-Bell-Sounds (`\a` = 0x07 von Claude/Codex
    /// bei Permission-Prompts) als macOS-System-Sound ausspielt. Default: an.
    var isTerminalBellEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.isTerminalBellEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.isTerminalBellEnabled) }
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

    /// Zentraler Kill-Switch: bei `false` werden vorhandene GPT-Stempel
    /// ignoriert und Claude startet ohne Proxy-Argumente oder Proxy-Env.
    var claudeGPTBackendEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.claudeGPTBackendEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTBackendEnabled) }
    }

    var claudeGPTBackendPort: Int {
        get {
            let value = defaults.integer(forKey: Keys.claudeGPTBackendPort)
            return value > 0 ? value : 18_765
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTBackendPort) }
    }

    var claudeGPTRouterPort: Int {
        get {
            let value = defaults.integer(forKey: Keys.claudeGPTRouterPort)
            return value > 0 ? value : 18_766
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTRouterPort) }
    }

    var claudeGPTBackendDefaultModel: String {
        get { defaults.string(forKey: Keys.claudeGPTBackendDefaultModel) ?? "gpt-5.6-sol" }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTBackendDefaultModel) }
    }

    /// Leer bedeutet bewusst: kein Override fuer native Claude-Subagents.
    var claudeGPTSubagentModel: String {
        get { defaults.string(forKey: Keys.claudeGPTSubagentModel) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTSubagentModel) }
    }

    /// Opt-in für SwiftTerms Metal-GPU-Renderer (P6, Default: aus — erst
    /// benchmarken, die CPU-Parser-Gewinne aus SwiftTerm 1.9–1.11 sind
    /// bereits ohne Metal enthalten). Einschalten:
    /// `defaults write com.whisperm8.app agentTerminalMetalEnabled -bool YES`
    var isAgentTerminalMetalRendererEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.agentTerminalMetalEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentTerminalMetalEnabled) }
    }

    /// Kill-Switch für das event-getriebene Transcript-Watching (P2). Bei
    /// Problemen ohne Rebuild zurück zum reinen 1,5-s-Polling:
    /// `defaults write com.whisperm8.app agentEventDrivenWatchEnabled -bool NO`
    var isAgentEventDrivenWatchEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.agentEventDrivenWatchEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentEventDrivenWatchEnabled) }
    }

    /// Escape-Hatch für Drag & Drop in der Agent-Chats-Sidebar. Der Mai-2026
    /// Scroll-Haenger (`.draggable` + `LazyVStack`, gefixt in 60ca683) ist
    /// durch den nicht-lazy `VStack` behoben — falls er in anderer Form
    /// wieder auftaucht, laesst sich das Drag-Feature ohne Rebuild abschalten:
    /// `defaults write com.whisperm8.app agentSidebarDragEnabled -bool NO`
    var isAgentSidebarDragEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.agentSidebarDragEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentSidebarDragEnabled) }
    }

    /// Spielt einen kurzen Ton, sobald ein Agent seinen Turn beendet
    /// (`Stop`-Hook). Default an; abschaltbar in den Einstellungen oder via
    /// `defaults write com.whisperm8.app agentStopSoundEnabled -bool NO`.
    var isAgentStopSoundEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.agentStopSoundEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentStopSoundEnabled) }
    }

    /// Name des System-Sounds für den Agent-Fertig-Ton (Dateien aus
    /// `/System/Library/Sounds`). Default „Glass" — das bisherige, fest
    /// verdrahtete Verhalten.
    var agentStopSoundName: String {
        get { defaults.string(forKey: Keys.agentStopSoundName) ?? "Glass" }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentStopSoundName) }
    }

    /// Master-Schalter für die Claude-Code-Hook-Bridge (Session-Status via
    /// `--settings`-Injection). Aus → Launch ohne Hook-Args, Status kommt nur
    /// noch aus dem Transcript-Watcher.
    var isClaudeHooksEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.claudeHooksEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeHooksEnabled) }
    }

    /// macOS-Notification, wenn ein Agent seinen Turn beendet. Bewusst auch
    /// bei App im Vordergrund (willPresent zeigt Banner).
    var isAgentStopNotificationEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.agentStopNotificationEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentStopNotificationEnabled) }
    }

    /// macOS-Notification, wenn ein Agent auf eine User-Entscheidung wartet
    /// (Permission-Dialog, Frage, Plan-Freigabe).
    var isAgentAwaitingNotificationEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.agentAwaitingNotificationEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentAwaitingNotificationEnabled) }
    }

    /// Automatischer Update-Check gegen die GitHub-Releases (Start + 24 h).
    /// Kill-Switch ohne Rebuild:
    /// `defaults write com.whisperm8.app updateCheckEnabled -bool NO`
    var isUpdateCheckEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.updateCheckEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.updateCheckEnabled) }
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
    static let usageProfile = "usageProfile"
    static let language = "language"
    static let autoPasteEnabled = "autoPasteEnabled"
    static let audioDuckingEnabled = "audioDuckingEnabled"
    static let audioDuckingFactor = "audioDuckingFactor"
    static let overlayStyle = "overlayStyle"
    static let overlayPositionX = "overlayPositionX"
    static let overlayPositionY = "overlayPositionY"
    static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
    static let debugFileLoggingEnabled = "debugFileLoggingEnabled"
    static let defaultOutputModeID = "defaultOutputModeID"
    static let lastSelectedOutputModeID = "lastSelectedOutputModeID"
    static let fallbackToRawOnProcessingError = "fallbackToRawOnProcessingError"
    static let showModePickerInMiniOverlay = "showModePickerInMiniOverlay"
    static let showConfirmButtonInOverlay = "showConfirmButtonInOverlay"
    static let selectedContextCaptureEnabled = "selectedContextCaptureEnabled"
    static let visualContextCaptureEnabled = "visualContextCaptureEnabled"
    static let maxScreenshotsPerRecording = "maxScreenshotsPerRecording"
    static let didMigrateMaxScreenshotsPerRecordingTo20 = "didMigrateMaxScreenshotsPerRecordingTo20"
    static let maxScreenRecordingDuration = "maxScreenRecordingDuration"
    static let deleteContextFilesAfterProcessing = "deleteContextFilesAfterProcessing"
    static let codexPostProcessingModel = "codexPostProcessingModel"
    static let codexReasoningEffort = "codexReasoningEffort"
    static let codexServiceTier = "codexServiceTier"
    static let codexVisualInputMode = "codexVisualInputMode"
    static let agentDefaultProjectPath = "agentDefaultProjectPath"
    static let defaultAgentProvider = "defaultAgentProvider"
    static let isAutoChatRenameEnabled = "isAutoChatRenameEnabled"
    static let isAutoSummaryEnabled = "isAutoSummaryEnabled"
    static let isTerminalBellEnabled = "isTerminalBellEnabled"
    static let codexExtraArguments = "codexExtraArguments"
    static let claudeExtraArguments = "claudeExtraArguments"
    static let claudeGPTBackendEnabled = "claudeGPTBackendEnabled"
    static let claudeGPTBackendPort = "claudeGPTBackendPort"
    static let claudeGPTRouterPort = "claudeGPTRouterPort"
    static let claudeGPTBackendDefaultModel = "claudeGPTBackendDefaultModel"
    static let claudeGPTSubagentModel = "claudeGPTSubagentModel"
    static let appearanceOverride = "appearanceOverride"
    static let agentSidebarDragEnabled = "agentSidebarDragEnabled"
    static let agentEventDrivenWatchEnabled = "agentEventDrivenWatchEnabled"
    static let agentTerminalMetalEnabled = "agentTerminalMetalEnabled"
    static let agentStopSoundEnabled = "agentStopSoundEnabled"
    static let agentStopSoundName = "agentStopSoundName"
    static let claudeHooksEnabled = "claudeHooksEnabled"
    static let agentStopNotificationEnabled = "agentStopNotificationEnabled"
    static let agentAwaitingNotificationEnabled = "agentAwaitingNotificationEnabled"
    static let updateCheckEnabled = "updateCheckEnabled"
}

private typealias Keys = PreferenceKeys
