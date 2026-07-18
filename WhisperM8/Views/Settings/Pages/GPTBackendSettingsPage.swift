import AppKit
import SwiftUI

struct GPTBackendSettingsPage: View {
    @AppStorage(PreferenceKeys.claudeGPTBackendEnabled) private var backendEnabled = false
    @AppStorage(PreferenceKeys.claudeGPTBackendPort) private var port = 18_765
    @AppStorage(PreferenceKeys.claudeGPTBackendDefaultModel) private var defaultModel = ""
    @AppStorage(PreferenceKeys.claudeGPTSubagentModel) private var subagentModel = ""
    @AppStorage(PreferenceKeys.claudeGPTAutoCompactWindow) private var autoCompactWindow =
        AppPreferences.claudeGPTDefaultAutoCompactWindow

    @State private var binaryPath: String?
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
    private let modelSuggestions = ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra"]

    var body: some View {
        SettingsPageContainer(
            title: "GPT-Backend",
            subtitle: "Claude Code mit GPT-Modellen über den lokalen claude-code-proxy verwenden."
        ) {
            SettingsSection("Aktivierung") {
                SettingsToggleRow(
                    title: "GPT-Backend aktivieren",
                    subtitle: "Aus: Alle Claude-Chats verhalten sich wie bisher und verbinden sich direkt mit Anthropic. GPT-Stempel vorhandener Sessions werden ignoriert.",
                    isOn: $backendEnabled
                )
            }

            if backendEnabled {
                if setupNeeded {
                    setupSection
                }

                statusSection

                if authStatus == .notAuthenticated {
                    deviceLoginSection
                }
            }

            configurationSection
                .disabled(!backendEnabled)
                .opacity(backendEnabled ? 1 : 0.55)

            SettingsSection("Aktionen") {
                SettingsButtonRow(
                    title: "Proxy verwalten",
                    subtitle: "Stoppen beendet nur einen von WhisperM8 selbst gestarteten Proxy."
                ) {
                    Button("Proxy stoppen") {
                        proxyManager.stopIfSelfStarted()
                        refreshStatus()
                    }
                    .buttonStyle(SettingsButtonStyle.destructive)

                    Button(isRefreshing ? "Prüfe…" : "Neu prüfen") {
                        refreshStatus()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                    .disabled(!backendEnabled || isRefreshing)
                }

                SettingsButtonRow(
                    title: "Proxy-Binary",
                    subtitle: binaryManagementSubtitle
                ) {
                    if let availableUpdate {
                        Button(isUpdateWorking ? "Installiere…" : "Update auf v\(availableUpdate)") {
                            installBinaryUpdate(availableUpdate)
                        }
                        .buttonStyle(SettingsButtonStyle.primary)
                        .disabled(isUpdateWorking)
                    }

                    Button(isUpdateWorking && availableUpdate == nil ? "Prüfe…" : "Nach Update suchen") {
                        checkForBinaryUpdate()
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
            ClaudeGPTAgentDefinitionInstaller().sync(
                backendEnabled: backendEnabled,
                model: defaultModel
            )
        }
        .onChange(of: defaultModel) { _, newModel in
            guard backendEnabled else { return }
            ClaudeGPTAgentDefinitionInstaller().sync(
                backendEnabled: true,
                model: newModel
            )
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
        SettingsSection("Einrichtung") {
            SettingsButtonRow(
                title: "Geführte Einrichtung",
                subtitle: "Führt alle Schritte nacheinander aus: Binary prüfen (fehlt es, lädt WhisperM8 v\(ClaudeCodeProxyBinaryInstaller.knownGoodVersion) checksummen-verifiziert aus dem GitHub-Release) → Proxy & Router starten → ChatGPT-Login (Device-Code, öffnet die Code-Anzeige unten)."
            ) {
                Button(isSetupRunning ? "Läuft…" : "Jetzt komplett einrichten") {
                    runFullSetup(startLoginIfNeeded: true)
                }
                .buttonStyle(SettingsButtonStyle.primary)
                .disabled(isSetupRunning || isDeviceLoginRunning)
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
                subtitle: didRefresh && binaryPath == nil
                    ? "„Jetzt komplett einrichten“ lädt es automatisch; alternativ manuell aus dem GitHub-Release raine/claude-code-proxy in den PATH."
                    : nil,
                tone: didRefresh ? (binaryPath == nil ? .error : .ok) : .off,
                detail: binaryPath.map { "Gefunden: \($0)" } ?? (didRefresh ? "Fehlt" : "Wird geprüft…")
            )

            SettingsStatusRow(
                title: "Prozess",
                tone: proxyReachable.map { $0 ? .ok : .warn } ?? .off,
                detail: processStatusText
            ) {
                if proxyReachable != true {
                    Button("Proxy starten") {
                        startProxy()
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                    .disabled(binaryPath == nil || isRefreshing)
                }
            }

            SettingsStatusRow(
                title: "Authentifizierung",
                tone: authStatusTone,
                detail: authStatusText
            )

            if let operationError {
                SettingsHelpText(operationError, tone: .error)
            }
        }
    }

    private var deviceLoginSection: some View {
        SettingsSection("ChatGPT-Konto") {
            SettingsButtonRow(
                title: "Device-Code-Login",
                subtitle: "In den ChatGPT-Sicherheitseinstellungen muss „Autorisierung per Gerätecode“ aktiviert sein."
            ) {
                Button(isDeviceLoginRunning ? "Login läuft…" : "Mit ChatGPT-Konto verbinden") {
                    startDeviceLogin()
                }
                .buttonStyle(SettingsButtonStyle.primary)
                // Auch während des geführten Setups gesperrt: dessen
                // Abschluss startet den Login ggf. selbst — ein zweiter
                // Start würde den angezeigten Gerätecode invalidieren.
                .disabled(isDeviceLoginRunning || isSetupRunning)
            }

            if let deviceCodeInfo {
                SettingsRow(title: "URL", subtitle: "Im Browser öffnen und dort den angezeigten Code eingeben.") {
                    if let url = URL(string: deviceCodeInfo.visitURL) {
                        Link(deviceCodeInfo.visitURL, destination: url)
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text(deviceCodeInfo.visitURL)
                            .textSelection(.enabled)
                    }
                }

                SettingsRow(title: "Gerätecode") {
                    HStack(spacing: 10) {
                        Text(deviceCodeInfo.code)
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                            .textSelection(.enabled)

                        Button("Code kopieren") {
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
        SettingsSection("Konfiguration") {
            SettingsRow(title: "Port", subtitle: "Lokaler Port des claude-code-proxy (Standard: 18765).") {
                TextField("18765", value: $port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }

            editableModelRow(
                title: "Standard-Modell für neue Claude-Chats",
                subtitle: "Leer = neue Chats starten wie gewohnt mit Claude; GPT nur, wenn hier ein Modell steht. Frei editierbar; die Liste enthält nur Vorschläge.",
                placeholder: "Leer = Claude (Standard)",
                text: $defaultModel,
                offersSuggestions: true
            )

            editableModelRow(
                title: "Subagent-Modell (CLAUDE_CODE_SUBAGENT_MODEL)",
                subtitle: "Zwangs-Override: erzwingt dieses Modell für ALLE nativen Subagents. Empfehlung: leer lassen — GPT-Subagents stehen ohnehin über den Agent-Typ »gpt« bereit, den Claude pro Aufgabe wählen kann.",
                placeholder: "Leer = aus (empfohlen)",
                text: $subagentModel,
                offersSuggestions: true
            )

            SettingsRow(
                title: "Kontextfenster (CLAUDE_CODE_AUTO_COMPACT_WINDOW)",
                subtitle: "Reales Token-Fenster der GPT-Modelle für GPT-Sessions; steuert Auto-Kompaktierung und Kontext-Anzeige. 272000 = ChatGPT-Limit für GPT-5.6 (serverseitig, nicht erhöhbar)."
            ) {
                TextField(
                    String(AppPreferences.claudeGPTDefaultAutoCompactWindow),
                    value: $autoCompactWindow,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
            }
        }
    }

    private func editableModelRow(
        title: String,
        subtitle: String,
        placeholder: String,
        text: Binding<String>,
        offersSuggestions: Bool
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 6) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(width: 260)

                if offersSuggestions {
                    Menu {
                        ForEach(modelSuggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                text.wrappedValue = suggestion
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Modellvorschläge")
                }
            }
        }
    }

    private var processStatusText: String {
        switch proxyReachable {
        case true:
            return "Erreichbar auf Port \(port)"
        case false:
            return "Nicht erreichbar auf Port \(port)"
        case nil:
            return "Wird geprüft…"
        }
    }

    private var authStatusText: String {
        switch authStatus {
        case .authenticated(let account, let expires):
            return "Angemeldet: \(account), Ablauf: \(expires)"
        case .notAuthenticated:
            return "Nicht angemeldet"
        case .unknown:
            return didRefresh ? "Unbekannt" : "Wird geprüft…"
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
            return "Verwaltet von WhisperM8: v\(managed) (\(installer.binaryURL.path)). Ein PATH-Binary hätte Vorrang."
        }
        return "Kein verwaltetes Binary — es zählt die PATH-Installation. „Nach Update suchen“ vergleicht mit dem neuesten GitHub-Release."
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
                    updateStatusText = "Neuere Version verfügbar (installiert/getestet: v\(baseline)). Update wird gegen die Release-Checksumme verifiziert."
                } else {
                    updateStatusText = "Aktuell: v\(baseline) (neuestes Release: v\(latest))."
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
                updateStatusText = "v\(version) installiert: \(url.path). Ein laufender Proxy nutzt das Update nach „Proxy stoppen“ + Neustart."
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
            let snapshot = await Task.detached(priority: .userInitiated) {
                (
                    manager.resolvedBinaryPath(),
                    manager.isReachable(port: checkedPort),
                    manager.authStatus()
                )
            }.value
            binaryPath = snapshot.0
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
                        operationError = "Device-Code-Login wurde mit Status \(exitCode) beendet."
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
        binaryPath = nil
        proxyReachable = nil
        authStatus = .unknown
        didRefresh = false
        isRefreshing = false
        operationError = nil
        deviceCodeInfo = nil
    }
}
