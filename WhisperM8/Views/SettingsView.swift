import SwiftUI

enum ControlCenterSection: String, CaseIterable, Identifiable {
    case api = "Transcription API"
    case codex = "Codex / ChatGPT"
    case outputOverview = "Output Overview"
    case history = "History"
    case modes = "Modes"
    case templates = "Templates"
    case testLab = "Test Lab"
    case agentChats = "Agent Chats"
    case claudeCode = "Claude Code"
    case permissions = "Permissions"
    case hotkey = "Hotkey"
    case audio = "Audio"
    case behavior = "Behavior"
    case cli = "CLI & Skill"
    case about = "About"

    var id: String { rawValue }

    var routeID: String {
        switch self {
        case .api:
            return "api"
        case .codex:
            return "codex"
        case .outputOverview:
            return "outputOverview"
        case .history:
            return "history"
        case .modes:
            return "modes"
        case .templates:
            return "templates"
        case .testLab:
            return "testLab"
        case .agentChats:
            return "agentChats"
        case .claudeCode:
            return "claudeCode"
        case .permissions:
            return "permissions"
        case .hotkey:
            return "hotkey"
        case .audio:
            return "audio"
        case .behavior:
            return "behavior"
        case .cli:
            return "cli"
        case .about:
            return "about"
        }
    }

    static func section(routeID: String) -> ControlCenterSection? {
        allCases.first { $0.routeID == routeID }
    }

    var systemImage: String {
        switch self {
        case .api:
            return "key"
        case .codex:
            return "sparkles"
        case .outputOverview:
            return "rectangle.grid.2x2"
        case .history:
            return "clock.arrow.circlepath"
        case .modes:
            return "slider.horizontal.3"
        case .templates:
            return "doc.text"
        case .testLab:
            return "testtube.2"
        case .agentChats:
            return "terminal"
        case .claudeCode:
            return "bolt.horizontal.circle"
        case .permissions:
            return "shield.checkered"
        case .hotkey:
            return "keyboard"
        case .audio:
            return "waveform"
        case .behavior:
            return "gearshape"
        case .cli:
            return "terminal.fill"
        case .about:
            return "info.circle"
        }
    }

    var groupTitle: String {
        switch self {
        case .api, .codex:
            return "Accounts"
        case .outputOverview, .history, .modes, .templates, .testLab:
            return "Output"
        case .agentChats, .claudeCode:
            return "Agents"
        case .permissions, .hotkey, .audio, .behavior, .cli, .about:
            return "App"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @StateObject private var windowRequestCenter = WindowRequestCenter.shared
    @State private var selection: ControlCenterSection? = .api
    /// Report, den die History beim Öffnen aus der Overview vorselektieren soll.
    @State private var historyPreselectID: UUID?

    var body: some View {
        NavigationSplitView {
            // Bewusst KEINE `List(selection:)`: deren NSTableView scrollte
            // beim Öffnen automatisch zur Selektion — mit kaputtem Offset
            // (Liste komplett nach oben hinausgeschoben, Leerraum darunter;
            // reproduziert 2026-07-03 mit selektiertem „About"). Ein
            // statischer VStack im ScrollView kennt kein Auto-Scrolling und
            // startet immer oben.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sidebarSection("Accounts", items: [.api, .codex])
                    sidebarSection("Output", items: [.outputOverview, .history, .modes, .templates, .testLab])
                    sidebarSection("Agents", items: [.agentChats, .claudeCode])
                    sidebarSection("App", items: [.permissions, .hotkey, .audio, .behavior, .cli, .about])
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .navigationTitle("WhisperM8")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detailView(for: selection ?? .api)
        }
        .frame(minWidth: 860, minHeight: 620)
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
              let section = ControlCenterSection.section(routeID: routeID) else {
            return
        }
        selection = section
    }

    private func sidebarSection(_ title: String, items: [ControlCenterSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(items) { section in
                sidebarRow(section)
            }
        }
    }

    private func sidebarRow(_ section: ControlCenterSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 7) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func detailView(for section: ControlCenterSection) -> some View {
        switch section {
        case .api:
            APISettingsView()
                .navigationTitle(section.rawValue)
        case .codex:
            CodexSettingsView()
        case .outputOverview:
            OutputOverviewView(onOpenHistory: { reportID in
                historyPreselectID = reportID
                selection = .history
            })
            .environment(appState)
        case .history:
            OutputHistoryView(preselectReportID: historyPreselectID)
        case .modes:
            OutputModesView()
        case .templates:
            OutputTemplatesView()
        case .testLab:
            OutputTestLabView()
        case .agentChats:
            AgentChatsAccessView()
                .navigationTitle(section.rawValue)
        case .claudeCode:
            ClaudeCodeSettingsView()
                .navigationTitle(section.rawValue)
        case .permissions:
            PermissionsSettingsView()
                .navigationTitle(section.rawValue)
        case .hotkey:
            HotkeySettingsView()
                .navigationTitle(section.rawValue)
        case .audio:
            AudioSettingsView()
                .navigationTitle(section.rawValue)
        case .behavior:
            BehaviorSettingsView()
                .navigationTitle(section.rawValue)
        case .cli:
            CLISettingsView()
                .navigationTitle(section.rawValue)
        case .about:
            AboutView()
                .navigationTitle(section.rawValue)
        }
    }
}
