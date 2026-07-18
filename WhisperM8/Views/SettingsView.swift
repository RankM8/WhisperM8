import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case recording
    case transcription
    case aiOutput = "ai-output"
    case context
    case agentChats = "agent-chats"
    case gptBackend = "gpt-backend"
    case claudePlugins = "claude-plugins"
    case cli
    case general
    case permissions
    case about
    case output

    var id: String { rawValue }

    static func page(routeID: String) -> SettingsPage? {
        SettingsRouteTarget.resolve(routeID: routeID)?.page
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
        case .gptBackend:
            return "GPT-Backend"
        case .claudePlugins:
            return "Claude Plugins"
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
        case .gptBackend:
            return "arrow.triangle.branch"
        case .claudePlugins:
            return "puzzlepiece.extension"
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
            return "What WhisperM8 may capture alongside your voice — and what happens to it."
        case .agentChats:
            return "Configure the agent workspace and Claude Code hooks."
        case .gptBackend:
            return "Connect Claude Code sessions to GPT models through the local proxy."
        case .claudePlugins:
            return "Manage Claude Code plugins and marketplaces with projected token costs."
        case .cli:
            return "Command line access and installable agent skills."
        case .general:
            return "Profile, appearance, startup, and updates."
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

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var windowRequestCenter = WindowRequestCenter.shared
    @State private var selection: SettingsPage? = .recording
    @State private var aiOutputTab: AIOutputPageTab = .account
    @State private var agentChatsTab: AgentChatsSettingsPageTab = .workspace

    private let pageGroups: [SettingsPageGroup] = [
        SettingsPageGroup(title: "Dictation", pages: [.recording, .transcription, .aiOutput, .context]),
        SettingsPageGroup(title: "Agents", pages: [.agentChats, .gptBackend, .claudePlugins, .cli]),
        SettingsPageGroup(title: "App", pages: [.general, .permissions, .about]),
        SettingsPageGroup(title: "Workspace", pages: [.output])
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
            detailView(for: selection ?? .recording)
        }
        .frame(minWidth: 920, minHeight: 620)
        // Bewusst KEIN Auto-Öffnen des Agent-Chat-Hubs bei Sidebar-Auswahl mehr:
        // die Seite „Agent Chats" ist eine normale Settings-Seite; in den Hub
        // führt ausschließlich der explizite „Open Agent Chats"-Button.
        .onAppear {
            applySettingsRoute(windowRequestCenter.latestRequest)
        }
        .onReceive(windowRequestCenter.$latestRequest.compactMap { $0 }) { request in
            applySettingsRoute(request)
        }
    }

    private func applySettingsRoute(_ request: WindowRequest?) {
        guard let routeID = request?.settingsSectionID,
              let target = SettingsRouteTarget.resolve(routeID: routeID) else {
            return
        }

        if let aiOutputTab = target.aiOutputTab {
            self.aiOutputTab = aiOutputTab
        }
        if let agentChatsTab = target.agentChatsTab {
            self.agentChatsTab = agentChatsTab
        }
        selection = target.page
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
            // Phase 9b: migrierte V3-Seite (A4 Status-Zeile, A5 Remove Key,
            // A6 Preisstand, A7 Language-Wirkungshinweis).
            TranscriptionSettingsPage()
        case .aiOutput:
            aiOutputPage(page)
        case .context:
            // Phase 7: migrierte V3-Seite (Kontext-Teile der alten Behavior-Seite, A3).
            ContextPrivacySettingsPage()
        case .agentChats:
            agentChatsPage(page)
        case .gptBackend:
            GPTBackendSettingsPage()
        case .claudePlugins:
            ClaudePluginsSettingsPage()
        case .cli:
            // Phase 9b: migrierte V3-Seite (Inhalte 1:1, Kit-Optik, CopyCommandRows).
            CLISkillsSettingsPage()
        case .general:
            // Phase 7: migrierte V3-Seite (Profil/Theme/Login der alten Behavior-Seite,
            // A20/A21) — löst die frühere Sammelseite „Behavior" vollständig ab.
            GeneralSettingsPage()
        case .permissions:
            // Phase 8: migrierte V3-Seite (Header-Fix A22, cancellable Polling).
            PermissionsSettingsPage()
        case .about:
            // Phase 8: migrierte V3-Seite (Last-checked A23, sicherer Hersteller-Link).
            AboutSettingsPage()
        case .output:
            outputPage(page)
        }
    }

    private var recordingPage: some View {
        // Phase 4: erste fertig migrierte V3-Seite — ersetzt Hotkey- + Audio-View
        // und übernimmt die Recording-Teile der alten Behavior-Seite (A2, A29).
        RecordingSettingsPage()
    }

    private func aiOutputPage(_ page: SettingsPage) -> some View {
        // Phase 5: migrierte V3-Seite mit eigenen Tabs; Binding hält Deep-Links
        // (alte Routen modes/templates/testLab) funktionsfähig.
        AIOutputSettingsPage(selectedTab: $aiOutputTab)
    }


    private func agentChatsPage(_ page: SettingsPage) -> some View {
        // Phase 6: migrierte V3-Seite (vereint alte Agent-Chats- + Claude-Code-Seite,
        // A17/A18/A30, F6/F7); Binding hält den claudeCode-Deep-Link funktionsfähig.
        AgentChatsSettingsPage(selectedTab: $agentChatsTab)
    }

    private func outputPage(_ page: SettingsPage) -> some View {
        // Phase 9: fusionierte Workspace-Seite (Overview + History, A24–A27);
        // Latest kommt aus dem persistierten Store (A25), Delete mit Bestätigung (A26).
        OutputWorkspacePage()
            .environment(appState)
    }

}
