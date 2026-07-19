import SwiftUI

/// Settings-Tab fuer die Context-Profile: benannte Presets, die MCP-Denies,
/// Plugin-Aktivierung und Env-Vars buendeln und beim Claude-Launch als
/// session-scoped `--settings`-Overlay wirken (siehe
/// `ClaudeContextSettingsBuilder`). Listen werden als eine-Zeile-pro-Eintrag
/// editiert — die Kopplung an den Plugin-Manager (Checkboxen statt Freitext)
/// kommt in Ausbaustufe B4.
struct AgentChatsContextProfilesTab: View {
    @State private var profileStore = ClaudeContextProfileStore.shared
    @State private var selectedProfileID: UUID?
    /// B4-Kopplung: installierte Plugins + deren MCP-Server als
    /// Klick-Vorschlaege. Geteilte Model-Instanz mit der Context-&-Plugins-
    /// Seite — ein Cache, keine doppelten CLI-Laeufe.
    @State private var pluginModel = ClaudePluginManagerModel.shared

    // Editor-Drafts — bewusst vom Store entkoppelt, gespeichert wird nur
    // per "Save"-Button (kein Live-Schreiben bei jedem Tastendruck).
    @State private var draftName = ""
    @State private var draftDeniedServers = ""
    @State private var draftDisabledMcpServers = ""
    @State private var draftEnabledPlugins = ""
    @State private var draftEnvironment = ""
    @State private var editorFeedback: String?
    @State private var editorFeedbackTone: SettingsHelpText.Tone = .secondary

    /// Gaengige claude.ai-Connectoren als Klick-Vorschlaege — die reale
    /// Liste haengt vom Account ab, deshalb bleibt das Feld frei editierbar.
    private static let connectorSuggestions = [
        "claude.ai Gmail",
        "claude.ai Google Drive",
        "claude.ai Google Calendar",
        "claude.ai Apify MCP",
        "claude.ai Apollo.io",
        "claude.ai Atlassian Rovo",
        "claude.ai Close",
        "claude.ai Make",
        "claude.ai Miro",
        "claude.ai Slack"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Context Profiles") {
                SettingsHelpText("Named presets that hide claude.ai connectors, local MCP servers, and plugins per project — applied session-scoped via a temporary --settings file. Your global ~/.claude/settings.json stays untouched. Assign a default per project in the sidebar context menu; override per chat from the new-chat menu.")

                profileListRow

                if selectedProfile != nil {
                    editorRows
                }
            }
        }
        .onAppear(perform: syncSelectionToDrafts)
        .task {
            await pluginModel.loadIfNeeded()
        }
    }

    private var selectedProfile: ClaudeContextProfile? {
        profileStore.profiles.first { $0.id == selectedProfileID }
    }

    // MARK: - Liste

    private var profileListRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(profileStore.profiles) { profile in
                profileRow(profile)
            }

            HStack {
                Button("New Profile") {
                    createProfile()
                }
                .buttonStyle(SettingsButtonStyle.standard)

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func profileRow(_ profile: ClaudeContextProfile) -> some View {
        Button {
            selectedProfileID = profile.id
            syncSelectionToDrafts()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: profile.id == selectedProfileID ? "circle.inset.filled" : "circle")
                    .foregroundStyle(profile.id == selectedProfileID ? AppTheme.statusWorking : AppTheme.textTertiary)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(profileSummary(profile))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                Spacer()

                Button {
                    deleteProfile(profile)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete profile")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func profileSummary(_ profile: ClaudeContextProfile) -> String {
        var parts: [String] = []
        if !profile.deniedMcpServers.isEmpty {
            parts.append("\(profile.deniedMcpServers.count) connectors off")
        }
        if !profile.disabledMcpjsonServers.isEmpty {
            parts.append("\(profile.disabledMcpjsonServers.count) MCP servers off")
        }
        if !profile.enabledPlugins.isEmpty {
            parts.append("\(profile.enabledPlugins.count) plugin overrides")
        }
        if !profile.environment.isEmpty {
            parts.append("\(profile.environment.count) env vars")
        }
        return parts.isEmpty ? "Empty profile — no overlay" : parts.joined(separator: " · ")
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorRows: some View {
        SettingsRow(title: "Name") {
            TextField("Coding", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }

        SettingsTextArea(
            title: "Denied claude.ai connectors — one per line (e.g. \"claude.ai Gmail\")",
            text: $draftDeniedServers,
            minHeight: 72
        )

        connectorSuggestionRow

        SettingsTextArea(
            title: "Disabled local MCP servers (.mcp.json names) — one per line",
            text: $draftDisabledMcpServers,
            minHeight: 56
        )

        mcpServerSuggestionRow

        SettingsTextArea(
            title: "Plugin overrides — one per line as name@marketplace=false (or =true)",
            text: $draftEnabledPlugins,
            minHeight: 56
        )

        pluginSuggestionRow

        SettingsTextArea(
            title: "Environment variables — one per line as KEY=value (e.g. ENABLE_CLAUDEAI_MCP_SERVERS=false)",
            text: $draftEnvironment,
            minHeight: 56
        )

        if let editorFeedback {
            SettingsHelpText(editorFeedback, tone: editorFeedbackTone)
        }

        SettingsButtonRow(
            title: "Save profile",
            subtitle: "Changes apply to the next chat launch (running sessions keep their current overlay)."
        ) {
            Button("Save") {
                saveDrafts()
            }
            .buttonStyle(SettingsButtonStyle.primary)
        }
    }

    private var connectorSuggestionRow: some View {
        // Chips: bevorzugt die REAL vorhandenen Connectoren aus dem
        // MCP-Inventar (falls der MCP-Tab sie schon geladen hat), sonst die
        // statische Liste gaengiger claude.ai-Connectoren.
        let inventoryConnectors = pluginModel.mcpEntries
            .filter(\.isDeniableConnector)
            .map(\.name)
        let source = inventoryConnectors.isEmpty ? Self.connectorSuggestions : inventoryConnectors
        return FlowLayoutLite(items: source.filter { !draftDeniedLines.contains($0) }) { name in
            Button(name) {
                draftDeniedServers = (draftDeniedLines + [name]).joined(separator: "\n")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 10.5))
        }
    }

    private var draftDeniedLines: [String] {
        Self.parseLines(draftDeniedServers)
    }

    /// Chips: installierte Plugins, die noch keinen Override haben — Klick
    /// haengt "id=false" an (der haeufigste Fall: Plugin im Projekt aus).
    @ViewBuilder
    private var pluginSuggestionRow: some View {
        let overridden = Set(Self.parseKeyValueLines(draftEnabledPlugins).keys)
        let suggestions = pluginModel.pluginList.installed
            .filter { $0.enabled && !overridden.contains($0.id) }
            .map(\.id)
        if !suggestions.isEmpty {
            FlowLayoutLite(items: suggestions) { pluginID in
                Button("\(pluginID) off") {
                    let line = "\(pluginID)=false"
                    draftEnabledPlugins = draftEnabledPlugins.isEmpty
                        ? line
                        : draftEnabledPlugins + "\n" + line
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 10.5))
            }
        }
    }

    /// Chips: MCP-Server-Namen, die installierte Plugins mitbringen.
    @ViewBuilder
    private var mcpServerSuggestionRow: some View {
        let existing = Set(Self.parseLines(draftDisabledMcpServers))
        let suggestions = pluginModel.pluginList.installed
            .flatMap { $0.mcpServers.map { Array($0.keys) } ?? [] }
            .filter { !existing.contains($0) }
            .sorted()
        if !suggestions.isEmpty {
            FlowLayoutLite(items: suggestions) { serverName in
                Button(serverName) {
                    draftDisabledMcpServers = (Self.parseLines(draftDisabledMcpServers) + [serverName])
                        .joined(separator: "\n")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 10.5))
            }
        }
    }

    // MARK: - Aktionen

    private func createProfile() {
        let profile = ClaudeContextProfile(name: "New Profile")
        do {
            try profileStore.upsert(profile)
            selectedProfileID = profile.id
            syncSelectionToDrafts()
        } catch {
            showFeedback("Could not save: \(error.localizedDescription)", tone: .error)
        }
    }

    private func deleteProfile(_ profile: ClaudeContextProfile) {
        do {
            try profileStore.delete(id: profile.id)
            if selectedProfileID == profile.id {
                selectedProfileID = nil
            }
        } catch {
            showFeedback("Could not delete: \(error.localizedDescription)", tone: .error)
        }
    }

    private func syncSelectionToDrafts() {
        guard let profile = selectedProfile ?? profileStore.profiles.first else { return }
        selectedProfileID = profile.id
        draftName = profile.name
        draftDeniedServers = profile.deniedMcpServers.joined(separator: "\n")
        draftDisabledMcpServers = profile.disabledMcpjsonServers.joined(separator: "\n")
        draftEnabledPlugins = profile.enabledPlugins
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        draftEnvironment = profile.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        editorFeedback = nil
    }

    private func saveDrafts() {
        guard var profile = selectedProfile else { return }

        let environment = Self.parseKeyValueLines(draftEnvironment)
        let reserved = environment.keys.filter {
            ClaudeContextSettingsBuilder.reservedEnvironmentKeys.contains($0)
        }
        guard reserved.isEmpty else {
            showFeedback(
                "Reserved env keys are not allowed here: \(reserved.sorted().joined(separator: ", "))",
                tone: .error
            )
            return
        }

        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = trimmedName.isEmpty ? profile.name : trimmedName
        profile.deniedMcpServers = Self.parseLines(draftDeniedServers)
        profile.disabledMcpjsonServers = Self.parseLines(draftDisabledMcpServers)
        profile.enabledPlugins = Self.parseKeyValueLines(draftEnabledPlugins)
            .mapValues { ($0 as NSString).boolValue }
        profile.environment = environment

        do {
            try profileStore.upsert(profile)
            showFeedback("Saved. Applies to the next chat launch.", tone: .secondary)
        } catch {
            showFeedback("Could not save: \(error.localizedDescription)", tone: .error)
        }
    }

    private func showFeedback(_ message: String, tone: SettingsHelpText.Tone) {
        editorFeedback = message
        editorFeedbackTone = tone
    }

    // MARK: - Parsing (pur, eine Zeile pro Eintrag)

    static func parseLines(_ raw: String) -> [String] {
        SettingsLineParsing.parseLines(raw)
    }

    static func parseKeyValueLines(_ raw: String) -> [String: String] {
        SettingsLineParsing.parseKeyValueLines(raw)
    }
}

/// Minimaler Chip-Flow ohne Layout-Protokoll-Overhead: bricht die Vorschlags-
/// Buttons in Zeilen um. Bewusst simpel — nur fuer die Connector-Chips.
private struct FlowLayoutLite<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        // LazyVGrid mit adaptiven Spalten kommt dem Chip-Flow nah genug.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
