import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case recording
    case transcription
    case aiOutput = "ai-output"
    case context
    case agentChats = "agent-chats"
    case cli
    case general
    case permissions
    case about
    case output

    var id: String { rawValue }

    static func page(routeID: String) -> SettingsPage? {
        if let page = SettingsPage(rawValue: routeID) {
            return page
        }

        switch routeID {
        case "api":
            return .transcription
        case "codex", "modes", "templates", "testLab":
            return .aiOutput
        case "outputOverview", "history":
            return .output
        case "agentChats", "claudeCode":
            return .agentChats
        case "permissions":
            return .permissions
        case "hotkey", "audio":
            return .recording
        case "behavior":
            return .general
        case "cli":
            return .cli
        case "about":
            return .about
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .recording:
            return "Recording"
        case .transcription:
            return "Transcription"
        case .aiOutput:
            return "AI Output"
        case .context:
            return "Context & Privacy"
        case .agentChats:
            return "Agent Chats"
        case .cli:
            return "CLI & Skills"
        case .general:
            return "General"
        case .permissions:
            return "Permissions"
        case .about:
            return "About"
        case .output:
            return "Output"
        }
    }

    var systemImage: String {
        switch self {
        case .recording:
            return "mic"
        case .transcription:
            return "waveform"
        case .aiOutput:
            return "sparkles"
        case .context:
            return "magnifyingglass"
        case .agentChats:
            return "terminal"
        case .cli:
            return "chevron.left.forwardslash.chevron.right"
        case .general:
            return "gearshape"
        case .permissions:
            return "lock.shield"
        case .about:
            return "info.circle"
        case .output:
            return "doc.text"
        }
    }

    var subtitle: String {
        switch self {
        case .recording:
            return "Configure capture, input audio, and the dictation hotkey."
        case .transcription:
            return "Choose the speech-to-text provider, model, and language behavior."
        case .aiOutput:
            return "Connect Codex and manage post-processing modes, templates, and test runs."
        case .context:
            return "Review context and privacy controls while pages are migrated."
        case .agentChats:
            return "Configure the agent workspace and Claude Code hooks."
        case .cli:
            return "Command line access and installable agent skills."
        case .general:
            return "App behavior and appearance while pages are migrated."
        case .permissions:
            return "System permissions required for recording and automation."
        case .about:
            return "Version, update, and project information."
        case .output:
            return "Review the latest run and archived output reports."
        }
    }
}

private struct SettingsPageGroup: Identifiable {
    let title: String
    let pages: [SettingsPage]

    var id: String { title }
}

private enum AIOutputSettingsTab: String, Hashable {
    case account
    case modes
    case templates
    case testLab
}

private enum AgentChatsSettingsTab: String, Hashable {
    case workspace
    case claudeHooks
}

private enum OutputSettingsTab: String, Hashable {
    case latest
    case archive
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var windowRequestCenter = WindowRequestCenter.shared
    @State private var selection: SettingsPage? = .transcription
    @State private var aiOutputTab: AIOutputSettingsTab = .account
    @State private var agentChatsTab: AgentChatsSettingsTab = .workspace
    @State private var outputTab: OutputSettingsTab = .latest
    /// Report, den die History beim Öffnen aus der Overview vorselektieren soll.
    @State private var historyPreselectID: UUID?

    private let pageGroups: [SettingsPageGroup] = [
        SettingsPageGroup(title: "Dictation", pages: [.recording, .transcription, .aiOutput, .context]),
        SettingsPageGroup(title: "Agents", pages: [.agentChats, .cli]),
        SettingsPageGroup(title: "App", pages: [.general, .permissions, .about]),
        SettingsPageGroup(title: "Workspace", pages: [.output])
    ]

    private let aiOutputTabs = [
        SettingsTab(id: AIOutputSettingsTab.account, title: "Account"),
        SettingsTab(id: AIOutputSettingsTab.modes, title: "Modes"),
        SettingsTab(id: AIOutputSettingsTab.templates, title: "Templates"),
        SettingsTab(id: AIOutputSettingsTab.testLab, title: "Test Lab")
    ]

    private let agentChatsTabs = [
        SettingsTab(id: AgentChatsSettingsTab.workspace, title: "Workspace"),
        SettingsTab(id: AgentChatsSettingsTab.claudeHooks, title: "Claude Hooks")
    ]

    private let outputTabs = [
        SettingsTab(id: OutputSettingsTab.latest, title: "Latest"),
        SettingsTab(id: OutputSettingsTab.archive, title: "Archive")
    ]

    var body: some View {
        NavigationSplitView {
            // Bewusst KEINE `List(selection:)`: deren NSTableView scrollte
            // beim Öffnen automatisch zur Selektion und konnte dadurch mit
            // fehlerhaftem Offset starten. Der statische Stack bleibt stabil.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(pageGroups) { group in
                        sidebarSection(group)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.sidebar)
            .navigationTitle("WhisperM8")
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        } detail: {
            detailView(for: selection ?? .transcription)
        }
        .frame(minWidth: 920, minHeight: 620)
        .onChange(of: selection) { _, newSelection in
            if newSelection == .agentChats {
                WindowRequestCenter.shared.request(.agentChats)
            }
        }
        .onAppear {
            applySettingsRoute(windowRequestCenter.latestRequest)
        }
        .onReceive(windowRequestCenter.$latestRequest.compactMap { $0 }) { request in
            applySettingsRoute(request)
        }
    }

    private func applySettingsRoute(_ request: WindowRequest?) {
        guard let routeID = request?.settingsSectionID,
              let page = SettingsPage.page(routeID: routeID) else {
            return
        }

        applyTabAlias(routeID: routeID)
        selection = page
    }

    private func applyTabAlias(routeID: String) {
        // Alte Deep-Links sollen nach dem Strangler-Umbau weiter im passenden Tab landen.
        switch routeID {
        case "codex", SettingsPage.aiOutput.rawValue:
            aiOutputTab = .account
        case "modes":
            aiOutputTab = .modes
        case "templates":
            aiOutputTab = .templates
        case "testLab":
            aiOutputTab = .testLab
        case "agentChats", SettingsPage.agentChats.rawValue:
            agentChatsTab = .workspace
        case "claudeCode":
            agentChatsTab = .claudeHooks
        case "outputOverview", SettingsPage.output.rawValue:
            outputTab = .latest
        case "history":
            outputTab = .archive
        default:
            break
        }
    }

    private func sidebarSection(_ group: SettingsPageGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(AppTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)

            ForEach(group.pages) { page in
                sidebarRow(page)
            }
        }
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        let isSelected = selection == page

        return Button {
            selection = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textSecondary)
                    .frame(width: 18)

                Text(page.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? AppTheme.accentTint : AppTheme.sidebar.opacity(0))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailView(for page: SettingsPage) -> some View {
        switch page {
        case .recording:
            recordingPage
        case .transcription:
            settingsPage(page) {
                APISettingsView()
            }
        case .aiOutput:
            aiOutputPage(page)
        case .context:
            contextPage(page)
        case .agentChats:
            agentChatsPage(page)
        case .cli:
            settingsPage(page) {
                CLISettingsView()
            }
        case .general:
            settingsPage(page) {
                BehaviorSettingsView()
            }
        case .permissions:
            settingsPage(page) {
                PermissionsSettingsView()
            }
        case .about:
            settingsPage(page) {
                AboutView()
            }
        case .output:
            outputPage(page)
        }
    }

    private var recordingPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader(.recording)
                HotkeySettingsView()
                AudioSettingsView()
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.background)
    }

    private func aiOutputPage(_ page: SettingsPage) -> some View {
        settingsPage(page) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsTabs(selection: $aiOutputTab, tabs: aiOutputTabs)
                    .padding(.horizontal, 32)

                Group {
                    switch aiOutputTab {
                    case .account:
                        CodexSettingsView()
                    case .modes:
                        OutputModesView()
                    case .templates:
                        OutputTemplatesView()
                    case .testLab:
                        OutputTestLabView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func contextPage(_ page: SettingsPage) -> some View {
        settingsPage(page) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsHelpText("Context & privacy controls are temporarily on General while pages are migrated.")
                    .padding(.horizontal, 32)
                    .padding(.top, 2)
                Spacer(minLength: 0)
            }
        }
    }

    private func agentChatsPage(_ page: SettingsPage) -> some View {
        settingsPage(page) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsTabs(selection: $agentChatsTab, tabs: agentChatsTabs)
                    .padding(.horizontal, 32)

                Group {
                    switch agentChatsTab {
                    case .workspace:
                        AgentChatsAccessView()
                    case .claudeHooks:
                        ClaudeCodeSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func outputPage(_ page: SettingsPage) -> some View {
        settingsPage(page) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsTabs(selection: $outputTab, tabs: outputTabs)
                    .padding(.horizontal, 32)

                Group {
                    switch outputTab {
                    case .latest:
                        OutputOverviewView(onOpenHistory: { reportID in
                            historyPreselectID = reportID
                            outputTab = .archive
                        })
                        .environment(appState)
                    case .archive:
                        OutputHistoryView(preselectReportID: historyPreselectID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func settingsPage<Content: View>(
        _ page: SettingsPage,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(page)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 14)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppTheme.background)
    }

    private func pageHeader(_ page: SettingsPage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(page.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppTheme.textPrimary)

            Text(page.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
