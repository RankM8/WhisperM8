import AppKit
import SwiftUI
import UserNotifications

enum AgentChatsSettingsPageTab: String, CaseIterable, Hashable {
    case workspace
    case notifications
    case claudeAccounts
    case claudeHooks
    case advanced

    var title: String {
        switch self {
        case .workspace:
            return "Workspace"
        case .notifications:
            return "Notifications"
        case .claudeAccounts:
            return "Claude Accounts"
        case .claudeHooks:
            return "Claude Hooks"
        case .advanced:
            return "Advanced"
        }
    }
}

struct AgentChatsSettingsPage: View {
    // Binding statt @State, damit Deep-Links (alte Route claudeCode) aus
    // SettingsView den Tab auch bei offenem Fenster wechseln können.
    @Binding var selectedTab: AgentChatsSettingsPageTab

    init(selectedTab: Binding<AgentChatsSettingsPageTab>) {
        self._selectedTab = selectedTab
    }

    private let tabs = AgentChatsSettingsPageTab.allCases.map {
        SettingsTab(id: $0, title: $0.title)
    }

    var body: some View {
        SettingsPageContainer(
            title: "Agent Chats",
            subtitle: "One page for the whole agent workspace: launch defaults, notifications, Claude hooks, and CLI arguments."
        ) {
            SettingsTabs(selection: $selectedTab, tabs: tabs)
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .workspace:
            AgentChatsWorkspaceSettingsTab()
        case .notifications:
            AgentChatsNotificationsSettingsTab()
        case .claudeAccounts:
            AgentChatsClaudeAccountsTab()
        case .claudeHooks:
            AgentChatsClaudeHooksSettingsTab()
        case .advanced:
            AgentChatsAdvancedSettingsTab()
        }
    }
}

private struct AgentChatsWorkspaceSettingsTab: View {
    @AppStorage(PreferenceKeys.defaultAgentProvider) private var defaultAgentProviderRaw = "claude"
    @AppStorage(PreferenceKeys.isAutoChatRenameEnabled) private var isAutoChatRenameEnabled = true
    @AppStorage(PreferenceKeys.isAutoSummaryEnabled) private var isAutoSummaryEnabled = true

    @State private var defaultProjectPath = AppPreferences.shared.agentDefaultProjectPath
    @State private var folderFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Workspace") {
                SettingsButtonRow(
                    title: "Agent Chats",
                    subtitle: "Open the Codex and Claude session hub."
                ) {
                    Button("Open Agent Chats") {
                        WindowRequestCenter.shared.request(.agentChats)
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                }

                SettingsPickerRow(
                    title: "New chat starts with",
                    subtitle: "Claude Agents opens the multi-session dashboard view instead of a single chat.",
                    selection: $defaultAgentProviderRaw,
                    options: ["claude", "claude-agents", "codex"]
                ) { rawValue in
                    Text(providerLabel(for: rawValue))
                }

                SettingsButtonRow(
                    title: "Default project folder",
                    subtitle: "New chats start from this folder. Project actions still update this path when you open or select a project."
                ) {
                    Text(defaultProjectPath)
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 260, alignment: .trailing)
                        .textSelection(.enabled)

                    Button("Choose…") {
                        chooseDefaultProjectFolder()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }

                if let folderFeedback {
                    SettingsHelpText(folderFeedback, tone: .warning)
                }

                SettingsToggleRow(
                    title: "Rename chats automatically",
                    subtitle: "Generates a title after the first completed turn.",
                    isOn: $isAutoChatRenameEnabled
                )

                SettingsToggleRow(
                    title: "Summarize chats automatically",
                    subtitle: "Creates timeline summaries per session after chat activity completes.",
                    isOn: $isAutoSummaryEnabled
                )
            }
        }
        .onAppear {
            defaultProjectPath = AppPreferences.shared.agentDefaultProjectPath
        }
    }

    private func providerLabel(for rawValue: String) -> String {
        switch rawValue {
        case "claude":
            return "Claude Code"
        case "claude-agents":
            return "Claude Agents"
        case "codex":
            return "Codex"
        default:
            return rawValue
        }
    }

    private func chooseDefaultProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"

        if isExistingDirectory(defaultProjectPath) {
            panel.directoryURL = URL(fileURLWithPath: defaultProjectPath, isDirectory: true)
        }

        guard panel.runModal() == .OK,
              let selectedPath = panel.url?.path.trimmingCharacters(in: .whitespacesAndNewlines),
              isExistingDirectory(selectedPath) else {
            // Report-B-Risiko: leere oder ungueltige Picker-Ergebnisse duerfen
            // den letzten funktionierenden Projektpfad nie ueberschreiben.
            folderFeedback = "Folder was not saved because the selection is empty or invalid."
            return
        }

        AppPreferences.shared.agentDefaultProjectPath = selectedPath
        defaultProjectPath = selectedPath
        folderFeedback = nil
    }

    private func isExistingDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct AgentChatsNotificationsSettingsTab: View {
    @AppStorage(PreferenceKeys.agentStopNotificationEnabled) private var stopNotificationEnabled = true
    @AppStorage(PreferenceKeys.agentAwaitingNotificationEnabled) private var awaitingNotificationEnabled = true
    @AppStorage(PreferenceKeys.agentStopSoundEnabled) private var stopSoundEnabled = true
    @AppStorage(PreferenceKeys.agentStopSoundName) private var stopSoundName = SystemSoundCatalog.fallbackSoundName
    @AppStorage(PreferenceKeys.isTerminalBellEnabled) private var isTerminalBellEnabled = true

    @State private var notificationAuthStatus: UNAuthorizationStatus?
    @State private var availableSounds: [String] = []
    @State private var notificationFeedback: SettingsFeedbackState
    @State private var notificationFeedbackMessage: NotificationFeedback?

    @MainActor
    init() {
        self._notificationFeedback = State(initialValue: SettingsFeedbackState(duration: .milliseconds(2500)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Notifications & Sounds") {
                SettingsToggleRow(
                    title: "When an agent finishes",
                    subtitle: "Banner also shows while WhisperM8 is frontmost; clicking opens the chat.",
                    isOn: $stopNotificationEnabled
                )

                SettingsToggleRow(
                    title: "On questions (permission, question, plan approval)",
                    subtitle: "Deliberately silent — notification only.",
                    isOn: $awaitingNotificationEnabled
                )

                completionSoundRow

                SettingsButtonRow(title: "Test notification") {
                    Button("Send test notification") {
                        sendTestNotification()
                    }
                    .buttonStyle(SettingsButtonStyle.standard)
                }

                notificationPermissionRow

                if let notificationFeedbackMessage, notificationFeedback.isActive {
                    SettingsHelpText(notificationFeedbackMessage.message, tone: notificationFeedbackMessage.tone)
                }
            }

            SettingsSection("Terminal") {
                SettingsToggleRow(
                    title: "Allow terminal sounds",
                    subtitle: "The terminal bell inside chat views — a different event than the completion sound above (TUI bell vs. stop hook).",
                    isOn: $isTerminalBellEnabled
                )
            }
        }
        .onAppear(perform: refresh)
    }

    private var completionSoundRow: some View {
        SettingsRow(
            title: "Completion sound",
            subtitle: "Plays on the stop hook when an agent finishes. Question notifications stay silent."
        ) {
            HStack(spacing: 8) {
                Toggle("", isOn: $stopSoundEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(AppTheme.statusWorking)

                Picker("", selection: $stopSoundName) {
                    ForEach(soundChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .disabled(!stopSoundEnabled)
                .onChange(of: stopSoundName) { _, newValue in
                    SystemSoundCatalog.play(newValue)
                }

                Button {
                    SystemSoundCatalog.play(stopSoundName)
                } label: {
                    Image(systemName: "play.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!stopSoundEnabled)
                .help("Play sound")
                .accessibilityLabel(Text("Play completion sound"))
            }
        }
    }

    private var notificationPermissionRow: some View {
        SettingsStatusRow(
            title: "macOS notification permission",
            subtitle: notificationPermissionSubtitle,
            tone: notificationPermissionTone,
            detail: notificationPermissionDetail
        ) {
            if notificationAuthStatus == .denied {
                Button("Open System Settings") {
                    openNotificationSystemSettings()
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }
        }
    }

    private var soundChoices: [String] {
        if availableSounds.isEmpty {
            return [stopSoundName]
        }

        return availableSounds.contains(stopSoundName)
            ? availableSounds
            : [stopSoundName] + availableSounds
    }

    private var notificationPermissionDetail: String {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            return "Allowed"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not requested"
        case .none:
            return "Checking..."
        @unknown default:
            return "Unknown"
        }
    }

    private var notificationPermissionSubtitle: String {
        switch notificationAuthStatus {
        case .denied:
            return "WhisperM8 cannot show agent notifications until macOS allows them."
        case .notDetermined:
            return "Send a test notification or allow notifications when macOS asks."
        case .authorized, .provisional, .ephemeral:
            return "Agent notifications can be delivered by macOS."
        case .none:
            return "Checking the current macOS notification status."
        @unknown default:
            return "macOS returned an unknown notification status."
        }
    }

    private var notificationPermissionTone: SettingsStatusTone {
        switch notificationAuthStatus {
        case .authorized, .provisional, .ephemeral:
            return .ok
        case .denied, .notDetermined:
            return .warn
        case .none:
            return .off
        @unknown default:
            return .warn
        }
    }

    private func refresh() {
        availableSounds = SystemSoundCatalog.availableSoundNames()
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationAuthStatus = settings.authorizationStatus
        }
    }

    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Statusmaschine-Chat"
        content.subtitle = "WhisperM8 Test"
        content.body = "Agent ist fertig und wartet auf dich."

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                if let error {
                    showNotificationFeedback(NotificationFeedback(
                        message: "Notification failed: \(error.localizedDescription)",
                        tone: .error
                    ))
                } else {
                    showNotificationFeedback(NotificationFeedback(message: "Sent", tone: .secondary))
                    refresh()
                }
            }
        }
    }

    private func openNotificationSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showNotificationFeedback(_ feedback: NotificationFeedback) {
        notificationFeedbackMessage = feedback
        notificationFeedback.trigger()
    }
}

private struct NotificationFeedback {
    let message: String
    let tone: SettingsHelpText.Tone
}

private struct AgentChatsClaudeHooksSettingsTab: View {
    @AppStorage(PreferenceKeys.claudeHooksEnabled) private var hooksEnabled = true

    @State private var externalHookFindings: [ExternalClaudeHooksInspector.Finding] = []
    @State private var isExplainerExpanded = false
    @State private var isHookPreviewExpanded = false
    @State private var hookSettingsPreview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Claude Code Hooks") {
                SettingsStatusRow(
                    title: hooksEnabled ? "Session hooks active" : "Session hooks disabled",
                    subtitle: hooksEnabled
                        ? "Claude chats start with a temporary hook configuration. Status, questions, and turn completion arrive in real time; your global ~/.claude/settings.json stays untouched."
                        : "Chats start without the hook bridge. Status comes only from the transcript, with coarser detection, no question detection, and no notifications.",
                    tone: hooksEnabled ? .ok : .off,
                    detail: hooksEnabled ? "Live status via session hooks" : "Transcript fallback"
                )

                SettingsToggleRow(
                    title: "Use session hooks",
                    subtitle: "Launches Claude with a temporary --settings file for live status. Your global ~/.claude/settings.json is never touched. Running sessions need a restart to pick up changes.",
                    isOn: $hooksEnabled
                )

                statusLegendRow

                if !externalHookFindings.isEmpty {
                    externalHooksSection
                }

                DisclosureGroup("How does it work?", isExpanded: $isExplainerExpanded) {
                    SettingsHelpText("WhisperM8 starts Claude with `claude --settings <file>`. Each hook appends its event to a session file watched by the app. Global and project settings stay untouched; Claude merges the temporary settings additively.")
                        .padding(.vertical, 8)
                }

                DisclosureGroup("Hook settings preview", isExpanded: $isHookPreviewExpanded) {
                    SettingsCodeBlock(text: hookSettingsPreview, minHeight: 220)
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private var statusLegendRow: some View {
        SettingsRow(
            title: "Live status legend",
            subtitle: "The same states shown in the Agent Chats sidebar."
        ) {
            HStack(spacing: 14) {
                legendItem(color: AppTheme.statusWorking, label: "working")
                legendItem(color: AppTheme.statusAwaiting, label: "awaiting")
                legendItem(color: AppTheme.textTertiary, label: "idle")
            }
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private var externalHooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsStatusRow(
                title: "External Claude hooks detected",
                subtitle: "External hooks can cause duplicate notifications. WhisperM8 never changes ~/.claude/.",
                tone: .warn,
                detail: "\(externalHookFindings.count) found"
            )

            VStack(alignment: .leading, spacing: 8) {
                ForEach(externalHookFindings) { finding in
                    externalHookFindingRow(finding)
                }
            }
            .padding(.top, 2)
        }
    }

    private func externalHookFindingRow(_ finding: ExternalClaudeHooksInspector.Finding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(finding.eventName)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("matcher: \(finding.matcher ?? "none")")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer(minLength: 8)

                Text(finding.source)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            Text(finding.commandPreview)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }

    private func refresh() {
        externalHookFindings = ExternalClaudeHooksInspector.inspectUserSettings()
        if hookSettingsPreview.isEmpty {
            let examplePath = "~/Library/Application Support/WhisperM8/claude-session-events/<session>.jsonl"
            if let data = try? ClaudeHookSettingsBuilder.serializedSettings(eventFilePath: examplePath),
               let json = String(data: data, encoding: .utf8) {
                hookSettingsPreview = json
            }
        }
    }
}

private struct AgentChatsAdvancedSettingsTab: View {
    @AppStorage(PreferenceKeys.claudeExtraArguments) private var claudeExtraArguments = ""
    @AppStorage(PreferenceKeys.codexExtraArguments) private var codexExtraArguments = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Advanced") {
                cliArgumentsField(
                    title: "Claude CLI · extra arguments",
                    subtitle: "Prepended to each `claude` launch, including resumed sessions. Whitespace-separated; quotes are supported for arguments with spaces.",
                    placeholder: "e.g. --dangerously-skip-permissions",
                    binary: "claude",
                    text: $claudeExtraArguments
                )

                commandPreviewRow(binary: "claude", extraArguments: claudeExtraArguments)

                cliArgumentsField(
                    title: "Codex CLI · extra arguments",
                    subtitle: "Prepended to each `codex` launch before `-C`, `-m`, and resume arguments. Whitespace-separated; quotes are supported.",
                    placeholder: "e.g. --ask-for-approval untrusted",
                    binary: "codex",
                    text: $codexExtraArguments
                )

                commandPreviewRow(binary: "codex", extraArguments: codexExtraArguments)
            }
        }
    }

    private func cliArgumentsField(
        title: String,
        subtitle: String,
        placeholder: String,
        binary: String,
        text: Binding<String>
    ) -> some View {
        SettingsRow(title: title, subtitle: subtitle) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .frame(width: 360)
                .help("\(binary) extra arguments")
        }
    }

    private func commandPreviewRow(binary: String, extraArguments: String) -> some View {
        SettingsRow(title: "Command preview") {
            Text(AgentCLIArgumentsPreview.preview(binary: binary, extraArguments: extraArguments))
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 520, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}
