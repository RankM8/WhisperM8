import AppKit
import SwiftUI
import UserNotifications

// Accounts, Context Profiles und Hooks sind mit dem IA-Umbau 2026-07-19 in
// die Sidebar-Sektion CLAUDE CODE umgezogen (eigene Seiten bzw. Tab der
// „Context & Plugins"-Seite) — hier bleibt nur noch Session-Verhalten.
enum AgentChatsSettingsPageTab: String, CaseIterable, Hashable {
    case workspace
    case notifications
    case advanced

    var title: String {
        switch self {
        case .workspace:
            return "Workspace"
        case .notifications:
            return "Notifications"
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
            subtitle: "Launch defaults, notifications, and CLI arguments for the agent workspace."
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
