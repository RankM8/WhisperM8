import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case recording
    case transcription
    case aiOutput = "ai-output"
    case context
    case agentChats = "agent-chats"
    case gptBackend = "gpt-backend"
    case claudeAccounts = "claude-accounts"
    case claudeHooks = "claude-hooks"
    case cli
    case general
    case permissions
    case about
    case output
    case voiceGate = "voice-gate"
    case jarvis

    var id: String { rawValue }

    static func page(routeID: String) -> SettingsPage? {
        SettingsRouteTarget.resolve(routeID: routeID)?.page
    }

    var title: String {
        switch self {
        case .recording:
            return String(localized: "Recording")
        case .transcription:
            return String(localized: "Transcription")
        case .aiOutput:
            return String(localized: "AI Output")
        case .context:
            return String(localized: "Context & Privacy")
        case .agentChats:
            return String(localized: "Agent Chats")
        case .gptBackend:
            return String(localized: "GPT-Backend")
        case .claudeAccounts:
            return String(localized: "Accounts")
        case .claudeHooks:
            return String(localized: "Hooks")
        case .cli:
            return String(localized: "CLI & Skills")
        case .general:
            return String(localized: "General")
        case .permissions:
            return String(localized: "Permissions")
        case .about:
            return String(localized: "About")
        case .output:
            return String(localized: "Output")
        case .voiceGate:
            return String(localized: "Codex Voice Agent")
        case .jarvis:
            return String(localized: "Jarvis & Callouts")
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
        case .claudeAccounts:
            return "person.2"
        case .claudeHooks:
            return "link"
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
        case .voiceGate:
            return "mic.slash"
        case .jarvis:
            return "text.bubble"
        }
    }

    var subtitle: String {
        switch self {
        case .recording:
            return String(localized: "Configure capture, input audio, and the dictation hotkey.")
        case .transcription:
            return String(localized: "Choose the speech-to-text provider, model, and language behavior.")
        case .aiOutput:
            return String(localized: "Connect Codex and manage post-processing modes, templates, and test runs.")
        case .context:
            return String(localized: "What WhisperM8 may capture alongside your voice — and what happens to it.")
        case .agentChats:
            return String(localized: "Configure the agent workspace and Claude Code hooks.")
        case .gptBackend:
            return String(localized: "Connect Claude Code sessions to GPT models through the local proxy.")
        case .claudeAccounts:
            return String(localized: "Claude accounts and profiles (CLAUDE_CONFIG_DIR) for multi-account sessions.")
        case .claudeHooks:
            return String(localized: "Session hooks for live status — temporary --settings, your global config stays untouched.")
        case .cli:
            return String(localized: "Command line access and installable agent skills.")
        case .general:
            return String(localized: "Profile, appearance, startup, and updates.")
        case .permissions:
            return String(localized: "System permissions required for recording and automation.")
        case .about:
            return String(localized: "Version, update, and project information.")
        case .output:
            return String(localized: "Review the latest run and archived output reports.")
        case .voiceGate:
            return String(localized: "Mute and unmute a Codex Desktop voice session with a spoken code word.")
        case .jarvis:
            return String(localized: "Experimental: Jarvis board, per-chat notes and spoken callouts.")
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var windowRequestCenter = WindowRequestCenter.shared
    @State private var selection: SettingsPage? = .recording
    @State private var aiOutputTab: AIOutputPageTab = .account
    @State private var agentChatsTab: AgentChatsSettingsPageTab = .workspace

    @AppStorage(PreferenceKeys.usageProfile) private var usageProfileRaw = AppUsageProfile.defaultProfile.rawValue
    /// Im Diktat-Profil blenden wir Agent-Chats-Seiten aus; dieser Schalter holt sie zurück.
    @State private var revealAgentPages = false

    private var usageProfile: AppUsageProfile {
        AppUsageProfile(rawValue: usageProfileRaw) ?? .defaultProfile
    }

    /// Öffnet eine Route eine ausgeblendete Seite, bleibt sie sichtbar (sonst gäbe es keine markierte Zeile).
    private var pageGroups: [SettingsPageGroup] {
        SettingsNavigation.pageGroups(for: usageProfile, revealAgentPages: revealAgentPages)
    }

    static func pageGroups(for profile: AppUsageProfile, revealAgentPages: Bool = false) -> [SettingsPageGroup] {
        SettingsNavigation.pageGroups(for: profile, revealAgentPages: revealAgentPages)
    }

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
                    if !usageProfile.wantsAgentChats {
                        revealAgentPagesButton
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
            // Ein frisch geöffnetes Fenster entsteht INNERHALB der
            // `$latestRequest`-Benachrichtigung — `@Published` meldet in
            // `willSet`, `latestRequest` hält da noch den alten Wert. Deshalb
            // die Route nach diesem Durchlauf erneut lesen. Live-Befund
            // 2026-10-08 (`whisperm8 debug open settings/transcription` landete
            // auf „Recording"); beim offenen Fenster trägt `onReceive` den
            // neuen Wert direkt als Parameter.
            DispatchQueue.main.async {
                applySettingsRoute(windowRequestCenter.latestRequest)
            }
        }
        .onReceive(windowRequestCenter.$latestRequest.compactMap { $0 }) { request in
            applySettingsRoute(request)
        }
    }

    private func applySettingsRoute(_ request: WindowRequest?) {
        guard let routeID = windowRequestCenter.settingsRouteID(for: request),
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
        if SettingsNavigation.requiresReveal(target.page, profile: usageProfile) {
            revealAgentPages = true
        }
    }

    /// Diktat-Profile sehen die Agent-Chats-Seiten nicht in der Hauptliste — hier kommen sie zurück.
    private var revealAgentPagesButton: some View {
        Button {
            revealAgentPages.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: revealAgentPages ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18)
                Text(revealAgentPages ? "Hide Agent Chats settings" : "Show Agent Chats settings")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarSection(_ group: SettingsPageGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(group.title))
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
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
        case .claudeAccounts:
            ClaudeAccountsSettingsPage()
        case .claudeHooks:
            ClaudeHooksSettingsPage()
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
        case .voiceGate:
            VoiceGateSettingsPage()
        case .jarvis:
            JarvisCalloutsSettingsPage()
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
