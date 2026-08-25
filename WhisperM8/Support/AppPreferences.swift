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

    /// Kanonisches GPT-Standardmodell (immer mit High-Effort gedacht) —
    /// Fallback fuer die /model-Picker-Option und die verwaltete
    /// Agent-Definition, wenn kein eigenes Standard-Modell konfiguriert ist.
    static let claudeGPTCanonicalModel = "gpt-5.6-sol"

    var claudeGPTBackendDefaultModel: String {
        // Leer = kein GPT-Stempel: neue Claude-Chats starten mit den
        // Claude-Modellen; GPT nur, wenn hier explizit ein Modell steht.
        get { defaults.string(forKey: Keys.claudeGPTBackendDefaultModel) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTBackendDefaultModel) }
    }

    /// Belegt den einen Custom-Eintrag im Claude-Code-`/model`-Picker.
    /// Leer behaelt die automatische Ableitung aus Standard-/Canonical-Modell.
    var claudeGPTPickerModel: String {
        get { defaults.string(forKey: Keys.claudeGPTPickerModel) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTPickerModel) }
    }

    /// Aktiviert den Priority-Tier fuer GPT-Modelle ueber den `-fast`-Alias.
    /// Default bewusst aus; Fast muss wegen der hoeheren Kosten explizit aktiviert werden.
    var claudeGPTFastModeEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.claudeGPTFastModeEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTFastModeEnabled) }
    }

    /// Leer bedeutet bewusst: kein Override fuer native Claude-Subagents.
    var claudeGPTSubagentModel: String {
        get { defaults.string(forKey: Keys.claudeGPTSubagentModel) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Keys.claudeGPTSubagentModel) }
    }

    /// Konservatives Standardprofil aller freigegebenen GPT-Modelle. Ein
    /// erweitertes 900k-Profil ist für GPT-5.6 Sol/Terra/Luna und GPT-5.4
    /// verfügbar und bleibt Opt-in. Bei aktivem MixRouter wird der Wert als
    /// `CLAUDE_CODE_MAX_CONTEXT_TOKENS` gesetzt; der prozessweite Auto-Compact-
    /// Deckel bleibt getrennt bei 1M, damit native 1M-Modelle unberührt bleiben.
    static let claudeGPTDefaultContextWindow =
        ClaudeGPTContextProfile.standard.rawValue

    /// Persistierbare Grenzen. Werte bis 272k bleiben als historische Custom-
    /// Profile gültig; oberhalb davon ist ausschließlich das exakte 900k-Profil
    /// ein Opt-in. Der historische 372k-Opt-in (Sol-Experiment bis 2026-08-18)
    /// migriert beim Lesen auf 900k — wer das Experiment gewählt hatte, wollte
    /// das größte verifizierte Fenster. Der Key behält aus Kompatibilitätsgründen
    /// seinen historischen `claudeGPTAutoCompactWindow`-Namen.
    static let claudeGPTContextWindowRange =
        10_000...ClaudeGPTModelAlias.maximumConfigurableContextWindow

    private static let legacyExperimentalSol372K = 372_000

    static func normalizedClaudeGPTContextWindow(_ value: Int) -> Int {
        guard value > 0 else { return claudeGPTDefaultContextWindow }
        if value == ClaudeGPTContextProfile.extended900K.rawValue
            || value == legacyExperimentalSol372K {
            return ClaudeGPTContextProfile.extended900K.rawValue
        }
        return min(
            max(value, claudeGPTContextWindowRange.lowerBound),
            ClaudeGPTModelAlias.maximumKnownSharedContextWindow
        )
    }

    var claudeGPTContextWindow: Int {
        get {
            Self.normalizedClaudeGPTContextWindow(
                defaults.integer(forKey: Keys.claudeGPTAutoCompactWindow)
            )
        }
        nonmutating set {
            defaults.set(
                Self.normalizedClaudeGPTContextWindow(newValue),
                forKey: Keys.claudeGPTAutoCompactWindow
            )
        }
    }

    /// SwiftTerms Metal-GPU-Renderer — **Opt-in, Default aus**.
    ///
    /// Die Sicherheitsgründe von früher sind mit SwiftTerm 1.15 weg: der
    /// Renderer brach in einer gepackten .app beim Laden der Shader den ganzen
    /// Prozess ab (#593) und sein Buffer-Pool wuchs bei stetig wechselndem
    /// Inhalt unbegrenzt (#598). Beides behoben, der Rückfall auf die
    /// CPU-Darstellung ist ein sauberer `throw`.
    ///
    /// Trotzdem aus, aus einem anderen Grund: **das Schriftbild leidet
    /// sichtbar** (Feldtest 01.08.2026 — „low resolution"). Nicht die
    /// Auflösung, die stimmt (`scaledFontFor(font:scale:)` rastert in
    /// Retina-Größe), sondern vermutlich das auf transparentem Grund
    /// rasternde Font-Smoothing (`_fontSmoothing = true`) und die
    /// Pixel-Rundung der Glyph-Positionen (`alignToPixel`). Der Gewinn ist
    /// dagegen unbelegt — es gibt bis heute keine A/B-Messung.
    ///
    /// Etwas Sichtbares gegen etwas Unbelegtes zu tauschen ist ein schlechter
    /// Handel; Metal kommt zurück, wenn das Messgerüst (Paket A4) einen
    /// Gewinn zeigt UND die Darstellung stimmt. Einschalten zum Vergleichen:
    /// `defaults write com.whisperm8.app agentTerminalMetalEnabled -bool YES`
    /// (wirkt nach App-Neustart, der Wert wird einmal pro Prozess gelesen).
    var isAgentTerminalMetalRendererEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.agentTerminalMetalEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentTerminalMetalEnabled) }
    }

    /// Zeilen Scrollback pro Agent-Terminal — Default 5 000 statt SwiftTerms
    /// 500. Begründung, Messwerte und die Grenzen stehen in
    /// `TerminalScrollbackPolicy`; kurz: bei vollem Ringpuffer senkt jede neue
    /// Ausgabezeile die Leseposition um 1, mit 500 Zeilen schob ein
    /// arbeitender Agent den lesenden Nutzer nach ~200 Zeilen Output an den
    /// oberen Anschlag. Anpassen mit
    /// `defaults write com.whisperm8.app agentTerminalScrollbackLines -int 20000`
    /// (wirkt für neu geöffnete Chats).
    var agentTerminalScrollbackLines: Int {
        get {
            let raw = defaults.object(forKey: Keys.agentTerminalScrollbackLines) as? Int
            return TerminalScrollbackPolicy.resolve(configured: raw)
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentTerminalScrollbackLines) }
    }

    /// Detail-Messung für Performance-Untersuchungen — **Opt-in, Default aus**.
    ///
    /// Aus heißt nicht „keine Messung": die Stufe-1-Messpunkte
    /// (`PerfBudgets`, Tier `.always`) laufen immer mit. Sie sitzen
    /// ausschließlich an seltenen Ereignissen — Klick, Fensterwechsel,
    /// Speichervorgang, gebündelter Terminal-Flush — und kosten damit unter
    /// 0,01 % CPU. Genau sie liefern im Alltag die
    /// `perf_budget_exceeded`-Warnungen.
    ///
    /// Diese Preference schaltet Stufe 2 dazu: dichtere Messpunkte und die
    /// periodische Zähler-Ausgabe für eine Baseline-Aufnahme. Gemessen
    /// (01.08.2026, M-Serie) kostet **ein** os_signpost-Intervall ~686 ns —
    /// auch ohne laufendes Instruments, denn `OSSignposter.isEnabled` ist auf
    /// macOS immer `true`. Bei ein paar hundert Ereignissen pro Sekunde ist
    /// das nichts, bei zehntausenden wären es Prozente. Deshalb die Trennung.
    ///
    /// `defaults write com.whisperm8.app agentPerfDetailEnabled -bool YES`
    /// (wirkt nach App-Neustart, wird einmal pro Prozess gelesen).
    var isAgentPerfDetailEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.agentPerfDetailEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentPerfDetailEnabled) }
    }

    /// Kill-Switch für das event-getriebene Transcript-Watching (P2). Bei
    /// Problemen ohne Rebuild zurück zum reinen 1,5-s-Polling:
    /// `defaults write com.whisperm8.app agentEventDrivenWatchEnabled -bool NO`
    /// Verdichtet das Grid beim Entfernen eines Chats: die uebrigen ruecken
    /// nach, die Stufe faellt auf die kleinste passende. Aus heisst: das Loch
    /// bleibt stehen und die Stufe auch — die feste Position ueberlebt dann
    /// jedes Entfernen.
    /// `defaults write com.whisperm8.app gridAutoCompactEnabled -bool NO`
    var isGridAutoCompactEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.gridAutoCompactEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.gridAutoCompactEnabled) }
    }

    /// Send-Guard der Hook-Bridge: `UserPromptSubmit`-Hook blockt die
    /// Wiedervorlage zugestellter `[via whisperm8 chats]`-Prompts (die CLI
    /// legt sie nach ESC-Abbruch selbst in den Composer zurück — Vorfall
    /// 2026-08-17). Aus = Settings ohne Guard-Eintrag; wirkt für NEU
    /// gestartete Sessions.
    /// `defaults write com.whisperm8.app chatsPromptGuardEnabled -bool NO`
    var isChatsPromptGuardEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.chatsPromptGuardEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.chatsPromptGuardEnabled) }
    }

    var isAgentEventDrivenWatchEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.agentEventDrivenWatchEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentEventDrivenWatchEnabled) }
    }

    /// Kill-Switch fuer den Account-Default neuer Claude-Chats: an heisst,
    /// eine neue Session ohne ausdrueckliche Profilangabe uebernimmt das in
    /// den Einstellungen aktive Account-Profil. Aus stellt das alte Verhalten
    /// her (alles Neue startet im Haupt-Account). Eine AUSDRUECKLICHE Angabe
    /// (`chats new --account`) bleibt in beiden Stellungen wirksam.
    /// `defaults write com.whisperm8.app chatsNewProfileDefaultEnabled -bool NO`
    var isChatsNewProfileDefaultEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.chatsNewProfileDefaultEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.chatsNewProfileDefaultEnabled) }
    }

    /// Kill-Switch fuer den Mehrfach-Kontowechsel (Auswahl → anderer Account).
    /// Aus blendet nur die Bulk-Aktion aus; der Einzel-Umzug bleibt nutzbar.
    /// `defaults write com.whisperm8.app accountBulkMoveEnabled -bool NO`
    var isAccountBulkMoveEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.accountBulkMoveEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.accountBulkMoveEnabled) }
    }

    /// Kill-Switch für die Retention der CLI-Subagent-Spiegel. Aus heißt: die
    /// verwaisten Einträge bleiben für immer in der Sidebar stehen (der
    /// Zustand vor 2026-08-01):
    /// `defaults write com.whisperm8.app subagentJobRetentionEnabled -bool NO`
    var isSubagentJobRetentionEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.subagentJobRetentionEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.subagentJobRetentionEnabled) }
    }

    /// Aufbewahrungsdauer abgeschlossener Subagent-Jobs in Tagen. 0 oder
    /// negativ = Default (7). Anpassbar ohne Rebuild:
    /// `defaults write com.whisperm8.app subagentJobRetentionDays -int 30`
    var subagentJobRetentionMaxAge: TimeInterval {
        let days = defaults.integer(forKey: Keys.subagentJobRetentionDays)
        guard days > 0 else { return SubagentJobRetentionPolicy.defaultMaxAge }
        return TimeInterval(days) * 24 * 60 * 60
    }

    /// Einmalige Altlasten-Bereinigung: Vor Einführung der Retention
    /// (2026-08-01) sammelten sich Jahrgänge verwaister Subagent-Spiegel an,
    /// die auch die Frist nicht mehr rechtfertigt — der erste Lauf räumt
    /// deshalb ALLE verwaisten Einträge ab, unabhängig vom Alter. Danach
    /// gilt die normale Frist. Erneut auslösen:
    /// `defaults delete com.whisperm8.app subagentJobRetentionInitialPurgeDone`
    var hasCompletedSubagentRetentionInitialPurge: Bool {
        get { defaults.bool(forKey: Keys.subagentJobRetentionInitialPurgeDone) }
        nonmutating set { defaults.set(newValue, forKey: Keys.subagentJobRetentionInitialPurgeDone) }
    }

    // MARK: - Voice Gate (Codewort-Steuerung der Codex-Sprachsitzung)

    /// Opt-in, Default AUS. Schaltet den mithoerenden On-Device-Listener frei:
    /// `defaults write com.whisperm8.app codexVoiceGateEnabled -bool YES`
    var isCodexVoiceGateEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.codexVoiceGateEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateEnabled) }
    }

    /// Trockenlauf, Default AN. In Phase 1 existiert ohnehin kein Code, der
    /// eine Taste drueckt — das Flag ist die Absicherung fuer Phase 2:
    /// `defaults write com.whisperm8.app codexVoiceGateDryRun -bool NO`
    var isCodexVoiceGateDryRun: Bool {
        get { boolWithDefault(true, forKey: Keys.codexVoiceGateDryRun) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateDryRun) }
    }

    /// Kurzer Ton, wenn das Codewort greift. Im Trockenlauf wichtig: nur so
    /// faellt im Moment des Geschehens auf, dass es ausgeloest haette.
    var isCodexVoiceGateSoundEnabled: Bool {
        get { boolWithDefault(true, forKey: Keys.codexVoiceGateSoundEnabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateSoundEnabled) }
    }

    var codexVoiceGateSoundName: String {
        get { defaults.string(forKey: Keys.codexVoiceGateSoundName) ?? "Tink" }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateSoundName) }
    }

    /// Traegerwort. Leer oder nur Leerzeichen faellt auf den Default zurueck —
    /// ein leeres Vokabular wuerde entweder nie oder staendig ausloesen.
    var codexVoiceGateCarrier: String {
        get { nonEmpty(Keys.codexVoiceGateCarrier, default: VoiceGateVocabulary.default.carrier) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateCarrier) }
    }

    var codexVoiceGateMuteWord: String {
        get { nonEmpty(Keys.codexVoiceGateMuteWord, default: VoiceGateVocabulary.default.muteCommand) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateMuteWord) }
    }

    var codexVoiceGateUnmuteWord: String {
        get { nonEmpty(Keys.codexVoiceGateUnmuteWord, default: VoiceGateVocabulary.default.unmuteCommand) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateUnmuteWord) }
    }

    /// Schreibt die ERKANNTEN WÖRTER ins Log — nur zur Fehlersuche, Default aus.
    /// Ohne das ist bei „mein Codewort greift nicht" nicht unterscheidbar, ob
    /// der Erkenner etwas anderes verstanden hat oder die Regel zuschlug.
    var isCodexVoiceGateVerboseLoggingEnabled: Bool {
        get { boolWithDefault(false, forKey: Keys.codexVoiceGateVerboseLogging) }
        nonmutating set { defaults.set(newValue, forKey: Keys.codexVoiceGateVerboseLogging) }
    }

    private func nonEmpty(_ key: String, default fallback: String) -> String {
        let raw = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallback : raw
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
    static let claudeGPTPickerModel = "claudeGPTPickerModel"
    static let claudeGPTFastModeEnabled = "claudeGPTFastModeEnabled"
    static let claudeGPTSubagentModel = "claudeGPTSubagentModel"
    static let claudeGPTAutoCompactWindow = "claudeGPTAutoCompactWindow"
    static let appearanceOverride = "appearanceOverride"
    static let agentSidebarDragEnabled = "agentSidebarDragEnabled"
    static let agentTabGroupingEnabled = "agentTabGroupingEnabled"
    static let agentEventDrivenWatchEnabled = "agentEventDrivenWatchEnabled"
    static let gridAutoCompactEnabled = "gridAutoCompactEnabled"
    static let chatsPromptGuardEnabled = "chatsPromptGuardEnabled"
    static let chatsNewProfileDefaultEnabled = "chatsNewProfileDefaultEnabled"
    static let accountBulkMoveEnabled = "accountBulkMoveEnabled"
    static let subagentJobRetentionEnabled = "subagentJobRetentionEnabled"
    static let subagentJobRetentionDays = "subagentJobRetentionDays"
    static let subagentJobRetentionInitialPurgeDone = "subagentJobRetentionInitialPurgeDone"
    static let agentTerminalMetalEnabled = "agentTerminalMetalEnabled"
    static let agentTerminalScrollbackLines = "agentTerminalScrollbackLines"
    static let agentPerfDetailEnabled = "agentPerfDetailEnabled"
    static let agentStopSoundEnabled = "agentStopSoundEnabled"
    static let agentStopSoundName = "agentStopSoundName"
    static let claudeHooksEnabled = "claudeHooksEnabled"
    static let agentStopNotificationEnabled = "agentStopNotificationEnabled"
    static let agentAwaitingNotificationEnabled = "agentAwaitingNotificationEnabled"
    static let updateCheckEnabled = "updateCheckEnabled"
    static let codexVoiceGateEnabled = "codexVoiceGateEnabled"
    static let codexVoiceGateDryRun = "codexVoiceGateDryRun"
    static let codexVoiceGateSoundEnabled = "codexVoiceGateSoundEnabled"
    static let codexVoiceGateSoundName = "codexVoiceGateSoundName"
    static let codexVoiceGateCarrier = "codexVoiceGateCarrier"
    static let codexVoiceGateMuteWord = "codexVoiceGateMuteWord"
    static let codexVoiceGateUnmuteWord = "codexVoiceGateUnmuteWord"
    static let codexVoiceGateVerboseLogging = "codexVoiceGateVerboseLogging"
}

private typealias Keys = PreferenceKeys
