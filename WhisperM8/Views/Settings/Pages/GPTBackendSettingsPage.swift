import AppKit
import SwiftUI

struct GPTBackendSettingsPage: View {
    @AppStorage(PreferenceKeys.claudeGPTBackendEnabled) private var backendEnabled = false
    @AppStorage(PreferenceKeys.claudeGPTBackendPort) private var port = 18_765
    @AppStorage(PreferenceKeys.claudeGPTFastModeEnabled) private var fastModeEnabled = false
    @AppStorage(PreferenceKeys.claudeGPTPickerModel) private var pickerModel = ""
    @AppStorage(PreferenceKeys.claudeGPTSubagentModel) private var subagentModel = ""
    @AppStorage(PreferenceKeys.claudeGPTAutoCompactWindow) private var gptContextWindow =
        AppPreferences.claudeGPTDefaultContextWindow

    @State private var binary: ClaudeCodeProxyBinaryCandidate?
    private var binaryPath: String? { binary?.path }
    @State private var proxyReachable: Bool?
    @State private var authStatus: ClaudeCodeProxyAuthStatus = .unknown
    @State private var didRefresh = false
    @State private var isRefreshing = false
    @State private var operationError: String?
    @State private var deviceCodeInfo: ClaudeCodeProxyDeviceCodeInfo?
    @State private var isDeviceLoginRunning = false
    @State private var isSetupRunning = false
    @State private var setupProgressText: String?
    @State private var isUpdateWorking = false
    @State private var availableUpdate: String?
    @State private var updateStatusText: String?
    @State private var refreshQueued = false

    private let proxyManager = ClaudeCodeProxyManager.shared
    private var profilesEnabled: Bool { AppPreferences.shared.isGPTAccountProfilesEnabled }
    /// Vorschläge kommen aus dem Codex-Modellkatalog (`~/.codex/models_cache.json`
    /// ∪ Fallback) — neue Modelle erscheinen hier ohne App-Update. `auto` steht
    /// immer an erster Stelle und meint das jeweils neueste Modell.
    private var pickerModelSuggestions: [String] {
        ClaudeGPTModelAlias.suggestions(includeFastVariants: true)
    }
    private var subagentModelSuggestions: [String] {
        ClaudeGPTModelAlias.suggestions(includeFastVariants: true)
    }
    private var frontierModelName: String { ClaudeGPTModelAlias.frontierModel() }
    private var catalogModelSummary: String {
        ClaudeGPTModelAlias.supportedModelsSummary(
            contextWindow: ClaudeGPTModelAlias.maximumKnownSharedContextWindow
        )
    }
    private var extendedProfileModelSummary: String {
        ClaudeGPTModelAlias.supportedModelsSummary(
            contextWindow: ClaudeGPTModelAlias.maximumConfigurableContextWindow
        )
    }

    var body: some View {
        SettingsPageContainer(
            title: "GPT-Backend",
            subtitle: "Use Claude Code with GPT models through the local claude-code-proxy."
        ) {
            SettingsLabsNotice("Unofficial upstream: Claude Code talks to GPT models through a local proxy. It can break whenever the upstream changes. Off by default.")

            SettingsSection("Activation") {
                SettingsToggleRow(
                    title: "Enable GPT-Backend",
                    subtitle: "Off: all Claude chats behave as before and connect directly to Anthropic. GPT stamps on existing sessions are ignored.",
                    isOn: $backendEnabled
                )
            }

            if backendEnabled {
                if setupNeeded {
                    setupSection
                }

                statusSection

                // Device-Code-Anzeige nur fuer den Login, den die gefuehrte
                // Einrichtung selbst gestartet hat, oder — bei ausgeschalteten
                // Konto-Profilen — als klassischer Login-Einstieg. Genau EINE
                // Entscheidung, sonst erschien die Sektion im Login-Moment doppelt.
                let showsLegacyLogin = !profilesEnabled && authStatus == .notAuthenticated
                if isDeviceLoginRunning || deviceCodeInfo != nil || showsLegacyLogin {
                    deviceLoginSection
                }

                if profilesEnabled {
                    GPTAccountsSection(onAccountsChanged: { refreshStatus() })
                }
            }

            configurationSection
                .disabled(!backendEnabled)
                .opacity(backendEnabled ? 1 : 0.55)

            SettingsSection("Actions") {
                SettingsButtonRow(
                    title: "Manage proxy",
                    subtitle: "Stopping only ends proxy processes started by WhisperM8 itself — the main proxy and the instances of the additional accounts."
                ) {
                    Button("Stop proxy") {
                        proxyManager.stopIfSelfStarted()
                        refreshStatus()
                    }
                    .buttonStyle(SettingsButtonStyle.destructive)

                    Button {
                        refreshStatus()
                    } label: {
                        isRefreshing ? Text("Checking…") : Text("Check again")
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(!backendEnabled || isRefreshing)
                }

                SettingsButtonRow(
                    title: "Proxy binary",
                    subtitle: binaryManagementSubtitle
                ) {
                    if let availableUpdate {
                        Button {
                            installBinaryUpdate(availableUpdate)
                        } label: {
                            isUpdateWorking ? Text("Installing…") : Text("Update to v\(availableUpdate)")
                        }
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(isUpdateWorking)
                    }

                    Button {
                        checkForBinaryUpdate()
                    } label: {
                        isUpdateWorking && availableUpdate == nil ? Text("Checking…") : Text("Check for update")
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(!backendEnabled || isUpdateWorking)
                }

                if let updateStatusText {
                    SettingsHelpText(updateStatusText)
                }
            }
        }
        .task(id: backendEnabled) {
            if backendEnabled {
                // Aktivierung = sofort betriebsbereit machen: Binary prüfen,
                // Proxy + Router hochfahren, Auth-Status ermitteln. Der
                // Device-Code-Login bleibt ein bewusster Klick (Browser-Flow).
                runFullSetup(startLoginIfNeeded: false)
            } else {
                clearStatus()
            }
            // Verwaltete `gpt`-Agent-Definition folgt dem Backend-Zustand:
            // aktiv → anlegen/aktualisieren, deaktiviert → entfernen.
            syncAgentDefinition()
        }
        .onChange(of: pickerModel) { _, _ in
            syncAgentDefinition()
        }
        .onChange(of: fastModeEnabled) { _, _ in
            syncAgentDefinition()
        }
        .onChange(of: gptContextWindow) { _, _ in
            syncAgentDefinition()
        }
    }

    /// Setup unvollständig, sobald ein Baustein fehlt — erst dann zeigt die
    /// Seite die geführte Einrichtung. Vor dem ersten Refresh (didRefresh
    /// false) bleibt sie versteckt, um Flackern beim Öffnen zu vermeiden.
    private var setupNeeded: Bool {
        guard didRefresh else { return isSetupRunning }
        if binaryPath == nil { return true }
        if proxyReachable != true { return true }
        if case .authenticated = authStatus { return false }
        return true
    }

    private var setupSection: some View {
        SettingsSection("Setup") {
            SettingsButtonRow(
                title: "Guided setup",
                subtitle: String(localized: "Runs all steps in order: check the binary (if it is missing, WhisperM8 downloads v\(ClaudeCodeProxyBinaryInstaller.knownGoodVersion) from the GitHub release, checksum-verified) → start proxy & router → ChatGPT login (device code, opens the code display below).")
            ) {
                Button {
                    runFullSetup(startLoginIfNeeded: true)
                } label: {
                    isSetupRunning ? Text("Running…") : Text("Set up everything now")
                }
                .buttonStyle(SettingsButtonStyle.primary)
                // Auch ein Login aus der Kontoliste sperrt: der Manager erlaubt
                // nur einen Device-Login und beendet den laufenden sonst.
                .disabled(isSetupRunning || isDeviceLoginRunning || proxyManager.isDeviceLoginRunning)
            }

            if let setupProgressText {
                SettingsHelpText(setupProgressText)
            }
        }
    }

    private var statusSection: some View {
        SettingsSection("Status") {
            SettingsStatusRow(
                title: "Binary",
                subtitle: binaryStatusSubtitle,
                tone: binaryStatusTone,
                detail: binaryStatusDetail
            )

            SettingsStatusRow(
                title: "Process",
                tone: proxyReachable.map { $0 ? .ok : .warn } ?? .off,
                detail: processStatusText
            ) {
                if proxyReachable != true {
                    Button("Start proxy") {
                        startProxy()
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                    .disabled(binaryPath == nil || isRefreshing)
                }
            }

            SettingsStatusRow(
                title: "Authentication",
                tone: authStatusTone,
                detail: authStatusText
            )

            if let operationError {
                SettingsHelpText(operationError, tone: .error)
            }
        }
    }

    private var deviceLoginSection: some View {
        SettingsSection("ChatGPT account") {
            SettingsButtonRow(
                title: "Device-code login",
                subtitle: "“Device code authorization” must be enabled in the ChatGPT security settings."
            ) {
                Button {
                    startDeviceLogin()
                } label: {
                    isDeviceLoginRunning ? Text("Login running…") : Text("Connect ChatGPT account")
                }
                .buttonStyle(SettingsButtonStyle.primary)
                // Auch während des geführten Setups gesperrt: dessen
                // Abschluss startet den Login ggf. selbst — ein zweiter
                // Start würde den angezeigten Gerätecode invalidieren.
                .disabled(isDeviceLoginRunning || isSetupRunning)
            }

            if let deviceCodeInfo {
                SettingsRow(title: "URL", subtitle: "Open it in the browser and enter the displayed code there.") {
                    if let url = URL(string: deviceCodeInfo.visitURL) {
                        Link(deviceCodeInfo.visitURL, destination: url)
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text(settingsLocalized: deviceCodeInfo.visitURL)
                            .textSelection(.enabled)
                    }
                }

                SettingsRow(title: "Device code") {
                    HStack(spacing: 10) {
                        Text(settingsLocalized: deviceCodeInfo.code)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)

                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(deviceCodeInfo.code, forType: .string)
                        }
                        .buttonStyle(SettingsButtonStyle.standard)
                    }
                }
            }
        }
    }

    private var configurationSection: some View {
        SettingsSection("Configuration") {
            SettingsRow(title: "Port", subtitle: "Local port of the claude-code-proxy (default: 18765, allowed 1024–65535).") {
                TextField("18765", value: $port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                    .onChange(of: port) { _, newValue in
                        // Zulässig 1024…65535 — Profilports liegen oberhalb (LR-GPT-003).
                        let clamped = min(max(newValue, ClaudeCodeProxyManager.minPort), ClaudeCodeProxyManager.maxPort)
                        if clamped != newValue { port = clamped }
                    }
            }

            SettingsToggleRow(
                title: "Fast mode (priority tier)",
                subtitle: "Priority tier of the Codex backend: much faster (1.5× to 2× according to the catalog), but uses considerably more ChatGPT credits. Applies to newly started chats including subagents — not to background agents (claude --bg). These take precedence: your own --model in the Claude extra arguments, an explicit ‘-fast’ in the model name, and a global proxy configuration.",
                isOn: $fastModeEnabled
            )

            editableModelRow(
                title: "GPT model",
                subtitle: String(localized: "The GPT model for the /model picker, for “New GPT chat” and for GPT subagents (agent type “gpt”). Which model a new chat uses is decided by Claude Code itself: choose /model in a chat and save it as the default with Enter — GPT or Claude. Empty, ‘auto’ or unknown = latest model (currently \(frontierModelName)). Any backend model of the Codex catalog is allowed (currently: \(catalogModelSummary)); models with a priority tier optionally with ‘-fast’. Older and unknown GPT IDs are clearly rejected by the router. New models also need a claude-code-proxy that knows them."),
                placeholder: String(localized: "Empty = automatic"),
                text: $pickerModel,
                suggestions: pickerModelSuggestions
            )

            editableModelRow(
                title: "Subagent model (CLAUDE_CODE_SUBAGENT_MODEL)",
                subtitle: String(localized: "Forced override for ALL native subagents. Any backend model of the Codex catalog is allowed, optionally with ‘-fast’; ‘auto’ = latest model (currently \(frontierModelName)); unknown values safely fall back to the latest model. Recommendation: leave empty and let GPT subagents be chosen via the agent type “gpt”."),
                placeholder: String(localized: "Empty = off (recommended)"),
                text: $subagentModel,
                suggestions: subagentModelSuggestions
            )

            SettingsRow(
                title: "GPT context profile",
                subtitle: gptContextProfileSubtitle
            ) {
                Picker("GPT context profile", selection: gptContextWindowSelection) {
                    ForEach(ClaudeGPTContextProfile.allCases) { profile in
                        Text(settingsLocalized: profile.title).tag(profile.rawValue)
                    }
                    if ClaudeGPTContextProfile.matching(contextWindow: effectiveGPTContextWindow) == nil {
                        Text("Custom — \(effectiveGPTContextWindow)")
                            .tag(effectiveGPTContextWindow)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private var effectiveGPTContextWindow: Int {
        AppPreferences.normalizedClaudeGPTContextWindow(gptContextWindow)
    }

    private var gptContextWindowSelection: Binding<Int> {
        Binding(
            get: { effectiveGPTContextWindow },
            set: { gptContextWindow = $0 }
        )
    }

    private func syncAgentDefinition() {
        // Bewusst ueber die Preferences statt der @AppStorage-Snapshots:
        // syncFromPreferences liest unter dem Sync-Lock den frischesten
        // Stand und kann so keinen parallelen Start-Sync zurueckrollen.
        ClaudeGPTAgentDefinitionInstaller().syncFromPreferences()
    }

    private func editableModelRow(
        title: String,
        subtitle: String,
        placeholder: String,
        text: Binding<String>,
        suggestions: [String]
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(width: 260)

                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                text.wrappedValue = suggestion
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Model suggestions")
                }
            }
        }
    }

    private var gptContextProfileSubtitle: String {
        switch ClaudeGPTContextProfile.matching(contextWindow: effectiveGPTContextWindow) {
        case .some(.standard):
            return String(localized: "Safe default for all approved GPT models. In our experience Claude Code compacts at roughly \(ClaudeGPTContextProfile.standard.expectedAutoCompactTokens / 1_000)k; native 1M models are left untouched.")
        case .some(.extended900K):
            return String(localized: "Opt-in via Codex subscription/OAuth (1M rollout of the Codex backend): 900k raw profile, auto-compact expected around \(ClaudeGPTContextProfile.extended900K.expectedAutoCompactTokens / 1_000)k. Applies to the 1M class according to the Codex catalog (currently: \(extendedProfileModelSummary)); direct measurements 2026-08-18 and 2026-09-06: 903k–913k accepted, ~924k rejected. In this profile other models drop out of the picker, so fresh starts fall back to the latest model. May use up ChatGPT credits faster — switch back to Standard on upstream overflow.")
        case .none:
            return "Existing custom value. For a clearly tested configuration choose Standard 272k or the extended 900k profile."
        }
    }

    private var processStatusText: String {
        switch proxyReachable {
        case true:
            return String(localized: "Reachable on port \(String(port))")
        case false:
            return String(localized: "Not reachable on port \(String(port))")
        case nil:
            return "Checking…"
        }
    }

    private var authStatusText: String {
        switch authStatus {
        case .authenticated(let account, let expires):
            return String(localized: "Signed in: \(account), expires: \(expires)")
        case .notAuthenticated:
            return "Not signed in"
        case .unknown:
            return didRefresh ? "Unknown" : "Checking…"
        }
    }

    private var authStatusTone: SettingsStatusTone {
        switch authStatus {
        case .authenticated:
            return .ok
        case .notAuthenticated:
            return .warn
        case .unknown:
            return .off
        }
    }

    private var binaryManagementSubtitle: String {
        let installer = ClaudeCodeProxyBinaryInstaller()
        if let managed = installer.installedManagedVersion() {
            return String(localized: "Managed by WhisperM8: v\(managed) (\(installer.binaryURL.path)), automatically raised to the latest upstream release on app start. A PATH binary would take precedence if it is at least v\(ClaudeCodeProxyBinaryInstaller.minimumVersion).")
        }
        return String(localized: "No managed binary — the PATH installation counts as long as it is at least v\(ClaudeCodeProxyBinaryInstaller.minimumVersion). “Check for update” compares against the latest GitHub release.")
    }

    private var binaryStatusDetail: String {
        guard let binary else { return didRefresh ? "Missing" : "Checking…" }
        return String(localized: "Found: \(binary.path) (v\(binary.version ?? String(localized: "unknown")), \(binary.sourceLabel))")
    }

    private var binaryStatusTone: SettingsStatusTone {
        guard didRefresh else { return .off }
        guard let binary else { return .error }
        return binary.meetsMinimumVersion ? .ok : .warn
    }

    /// Ein Binary unter der Mindestversion kennt nur ältere Modelle; WhisperM8
    /// bietet ohnehin nur an, was der laufende Proxy unter `/v1/models` meldet.
    private var binaryStatusSubtitle: String? {
        guard didRefresh else { return nil }
        guard let binary else {
            return String(localized: "“Set up everything now” downloads it automatically; alternatively, put it into the PATH manually from the GitHub release \(ClaudeCodeProxyBinaryInstaller.repository).")
        }
        guard !binary.meetsMinimumVersion else { return nil }
        var text = String(localized: "This version is older than v\(ClaudeCodeProxyBinaryInstaller.minimumVersion) and does not know newer Codex models. “Set up everything now” installs the managed binary, which then takes precedence.")
        if let installError = proxyManager.lastManagedInstallError {
            text += String(localized: " Last automatic attempt: \(installError)")
        }
        return text
    }

    private func checkForBinaryUpdate() {
        guard !isUpdateWorking, !isSetupRunning else { return }
        isUpdateWorking = true
        updateStatusText = nil
        availableUpdate = nil

        Task {
            defer { isUpdateWorking = false }
            let installer = ClaudeCodeProxyBinaryInstaller()
            do {
                let latest = try await installer.latestVersion()
                let baseline = installer.installedManagedVersion()
                    ?? ClaudeCodeProxyBinaryInstaller.knownGoodVersion
                // Nur echte Upgrades anbieten — ein zurückgezogenes Release
                // (latest < baseline) darf keinen Downgrade auslösen.
                if ClaudeCodeProxyBinaryInstaller.isVersion(latest, newerThan: baseline) {
                    availableUpdate = latest
                    updateStatusText = String(localized: "Newer version available (installed/tested: v\(baseline)). The update is verified against the release checksum.")
                } else {
                    updateStatusText = String(localized: "Up to date: v\(baseline) (latest release: v\(latest)).")
                }
            } catch {
                updateStatusText = error.localizedDescription
            }
        }
    }

    private func installBinaryUpdate(_ version: String) {
        // Gegensperre zum Setup-Wizard: nie zwei Installationen parallel
        // auf dasselbe Binary (zusätzlich prozessweit via installLock).
        guard !isUpdateWorking, !isSetupRunning else { return }
        isUpdateWorking = true
        updateStatusText = nil

        Task {
            defer { isUpdateWorking = false }
            do {
                let url = try await ClaudeCodeProxyBinaryInstaller().install(version: version)
                availableUpdate = nil
                updateStatusText = String(localized: "v\(version) installed: \(url.path). A running proxy uses the update after “Stop proxy” + restart.")
                refreshStatus()
            } catch {
                updateStatusText = error.localizedDescription
            }
        }
    }

    /// Ein-Klick-Einrichtung: läuft den `GPTBackendSetupRunner` sequenziell
    /// durch und spiegelt jeden Schritt in `setupProgressText`. Fehlt am Ende
    /// nur der Login, startet `startLoginIfNeeded` direkt den
    /// Device-Code-Flow (Code + URL erscheinen in der Login-Sektion).
    private func runFullSetup(startLoginIfNeeded: Bool) {
        // Setup und Binary-Update schließen sich gegenseitig aus — beide
        // können sonst parallel dasselbe Binary installieren.
        guard backendEnabled, !isSetupRunning, !isUpdateWorking else { return }
        isSetupRunning = true
        operationError = nil
        setupProgressText = nil
        let selectedPort = port
        let runner = GPTBackendSetupRunner()

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                await runner.run(port: selectedPort) { step, state in
                    let text: String?
                    switch state {
                    case .running:
                        text = "\(step.title)…"
                    case .failed(let message):
                        text = "\(step.title): \(message)"
                    case .ok, .pending:
                        text = nil
                    }
                    if let text {
                        Task { @MainActor in setupProgressText = text }
                    }
                }
            }.value

            isSetupRunning = false
            // Toggle wurde während des Laufs deaktiviert: der Lauf hat den
            // Proxy ggf. trotzdem gestartet — sauber zurückbauen und keinen
            // Login/Status mehr anfassen (Review-Befund 2026-07-19).
            guard backendEnabled else {
                setupProgressText = nil
                proxyManager.stopIfSelfStarted()
                clearStatus()
                return
            }
            switch outcome {
            case .ready:
                setupProgressText = nil
            case .needsDeviceLogin:
                setupProgressText = nil
                // Nie einen bereits laufenden Login-Flow ersetzen — das
                // würde den angezeigten Gerätecode invalidieren.
                if startLoginIfNeeded, !isDeviceLoginRunning {
                    startDeviceLogin()
                }
            case .failed:
                // Detailtext steht bereits in setupProgressText.
                break
            }
            refreshStatus()
        }
    }

    private func refreshStatus() {
        guard backendEnabled else { return }
        // Läuft bereits ein Refresh, wird EIN weiterer vorgemerkt statt
        // verworfen: Der laufende hat seinen Snapshot womöglich VOR einer
        // gerade abgeschlossenen Zustandsänderung (Proxy-Start) gezogen und
        // würde sonst veraltet „nicht erreichbar" stehen lassen.
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true
        operationError = nil
        let checkedPort = port
        let manager = proxyManager

        Task {
            // Mit Konto-Profilen zaehlt der Status des AKTIVEN Kontos — sonst
            // meldete die Seite „Nicht angemeldet" und bot die Einrichtung an,
            // waehrend die Kontoliste darunter ein angemeldetes, aktives ai zeigt.
            let statusProfile: String? = profilesEnabled
                ? GPTAccountProfiles().activeProfileNameOrNil()
                : nil
            let snapshot = await Task.detached(priority: .userInitiated) {
                (
                    manager.resolvedBinary(),
                    manager.isReachable(port: checkedPort),
                    manager.authStatus(profile: statusProfile)
                )
            }.value
            binary = snapshot.0
            proxyReachable = snapshot.1
            authStatus = snapshot.2
            didRefresh = true
            isRefreshing = false
            if refreshQueued {
                refreshQueued = false
                refreshStatus()
            }
        }
    }

    private func startProxy() {
        guard !isRefreshing else { return }
        isRefreshing = true
        operationError = nil
        let selectedPort = port
        let manager = proxyManager

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                manager.ensureRunning(port: selectedPort)
            }.value
            if case .failure(let error) = result {
                operationError = error.localizedDescription
            }
            isRefreshing = false
            refreshStatus()
        }
    }

    private func startDeviceLogin() {
        operationError = nil
        deviceCodeInfo = nil
        isDeviceLoginRunning = true

        let result = proxyManager.startDeviceLogin(
            onCodeInfo: { info in
                Task { @MainActor in
                    deviceCodeInfo = info
                }
            },
            onCompletion: { exitCode in
                Task { @MainActor in
                    isDeviceLoginRunning = false
                    if exitCode != 0 {
                        operationError = String(localized: "Device-code login ended with status \(exitCode).")
                    }
                    refreshStatus()
                }
            }
        )

        if case .failure(let error) = result {
            isDeviceLoginRunning = false
            operationError = error.localizedDescription
        }
    }

    private func clearStatus() {
        binary = nil
        proxyReachable = nil
        authStatus = .unknown
        didRefresh = false
        isRefreshing = false
        operationError = nil
        deviceCodeInfo = nil
    }
}
