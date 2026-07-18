import AppKit
import SwiftUI

struct GPTBackendSettingsPage: View {
    @AppStorage(PreferenceKeys.claudeGPTBackendEnabled) private var backendEnabled = false
    @AppStorage(PreferenceKeys.claudeGPTBackendPort) private var port = 18_765
    @AppStorage(PreferenceKeys.claudeGPTBackendDefaultModel) private var defaultModel = "gpt-5.6-sol"
    @AppStorage(PreferenceKeys.claudeGPTSubagentModel) private var subagentModel = ""

    @State private var binaryPath: String?
    @State private var proxyReachable: Bool?
    @State private var authStatus: ClaudeCodeProxyAuthStatus = .unknown
    @State private var didRefresh = false
    @State private var isRefreshing = false
    @State private var operationError: String?
    @State private var deviceCodeInfo: ClaudeCodeProxyDeviceCodeInfo?
    @State private var isDeviceLoginRunning = false

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
            }
        }
        .task(id: backendEnabled) {
            if backendEnabled {
                refreshStatus()
            } else {
                clearStatus()
            }
        }
    }

    private var statusSection: some View {
        SettingsSection("Status") {
            SettingsStatusRow(
                title: "Binary",
                subtitle: didRefresh && binaryPath == nil
                    ? "Installieren mit `brew install` oder aus dem GitHub-Release raine/claude-code-proxy."
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
                .disabled(isDeviceLoginRunning)
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
                subtitle: "Frei editierbar; die Liste enthält nur Vorschläge.",
                placeholder: "gpt-5.6-sol",
                text: $defaultModel,
                offersSuggestions: true
            )

            editableModelRow(
                title: "Subagent-Modell (CLAUDE_CODE_SUBAGENT_MODEL)",
                subtitle: "Leer bedeutet: kein Override für native Subagents und Workflows.",
                placeholder: "Leer = aus",
                text: $subagentModel,
                offersSuggestions: true
            )
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

    private func refreshStatus() {
        guard backendEnabled, !isRefreshing else { return }
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
