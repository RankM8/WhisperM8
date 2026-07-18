import SwiftUI

/// Plugin-Manager: wrappt das `claude plugin`-CLI headless (Liste mit
/// projizierten Token-Kosten, Enable/Disable, Install/Uninstall/Update,
/// Marketplace-Verwaltung). Alle Mutationen laufen ueber das offizielle CLI
/// (`ClaudePluginCLI`) — WhisperM8 schreibt nie selbst unter `~/.claude/`.
struct ClaudePluginsSettingsPage: View {
    private enum PageTab: String, CaseIterable, Hashable {
        case plugins
        case marketplaces

        var title: String {
            switch self {
            case .plugins: return "Plugins"
            case .marketplaces: return "Marketplaces"
            }
        }
    }

    @State private var model = ClaudePluginManagerModel()
    @State private var selectedTab: PageTab = .plugins
    @State private var expandedPluginIDs: Set<String> = []
    @State private var availableSearch = ""
    @State private var installTarget: ClaudeAvailablePlugin?
    @State private var newMarketplaceSource = ""

    private let tabs = PageTab.allCases.map { SettingsTab(id: $0, title: $0.title) }
    private let accountProfiles = ClaudeAccountProfiles().profiles()

    var body: some View {
        SettingsPageContainer(
            title: "Claude Plugins",
            subtitle: "Manage Claude Code plugins and marketplaces via the official CLI. Token costs show what each plugin adds to every session."
        ) {
            SettingsTabs(selection: $selectedTab, tabs: tabs)
            headerRows
            switch selectedTab {
            case .plugins:
                pluginsTab
            case .marketplaces:
                marketplacesTab
            }
        }
        .task {
            await model.loadIfNeeded()
        }
        .sheet(item: $installTarget) { plugin in
            PluginInstallSheet(plugin: plugin, model: model)
        }
    }

    // MARK: - Kopf (Account-Profil, Busy, Fehler, Restart-Banner)

    @ViewBuilder
    private var headerRows: some View {
        if accountProfiles.count > 1 {
            SettingsRow(
                title: "Account profile",
                subtitle: "Plugins live per CLAUDE_CONFIG_DIR. App-created profiles share the plugin store with main (symlink) — changes then apply across accounts."
            ) {
                Picker("", selection: accountBinding) {
                    Text("main").tag(String?.none)
                    ForEach(accountProfiles.filter { $0.name != ClaudeAccountProfiles.mainProfileName }, id: \.name) { profile in
                        Text(profile.name).tag(String?.some(profile.name))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .disabled(model.isBusy)
            }
        }

        if model.restartRequired {
            SettingsStatusRow(
                title: "Restart required",
                subtitle: "Plugin changes apply to new Claude sessions only — restart running sessions to pick them up.",
                tone: .warn,
                detail: "New sessions only"
            ) {
                Button("Dismiss") {
                    model.dismissRestartBanner()
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }
        }

        if let error = model.lastError {
            SettingsHelpText("Operation failed: \(error)", tone: .error)
        }

        if model.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Running claude plugin …")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var accountBinding: Binding<String?> {
        Binding(
            get: { model.accountProfileName },
            set: { newValue in
                Task { await model.switchAccountProfile(to: newValue) }
            }
        )
    }

    // MARK: - Tab: Plugins

    @ViewBuilder
    private var pluginsTab: some View {
        SettingsSection("Installed") {
            tokenSumRow

            if model.pluginList.installed.isEmpty && !model.isBusy {
                SettingsHelpText("No plugins installed — or the Claude CLI was not found.")
            }

            ForEach(model.pluginList.installed) { plugin in
                installedPluginCard(plugin)
            }

            SettingsButtonRow(
                title: "Prune",
                subtitle: "Removes auto-installed dependencies that are no longer needed."
            ) {
                Button("Prune") {
                    Task { await model.prune() }
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(model.isBusy)
            }

            if let pruneOutput = model.pruneOutput {
                SettingsCodeBlock(text: pruneOutput.isEmpty ? "Nothing to prune." : pruneOutput, minHeight: 60)
                Button("Hide output") { model.dismissPruneOutput() }
                    .buttonStyle(SettingsButtonStyle.standard)
            }
        }

        SettingsSection("Available") {
            SettingsRow(
                title: "Search catalog",
                subtitle: "\(filteredAvailable.count) of \(model.pluginList.available.count) plugins from configured marketplaces."
            ) {
                TextField("Search…", text: $availableSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            ForEach(filteredAvailable.prefix(30)) { plugin in
                availablePluginRow(plugin)
            }

            if filteredAvailable.count > 30 {
                SettingsHelpText("Showing the first 30 matches — refine the search to narrow down.")
            }
        }
    }

    private var tokenSumRow: some View {
        SettingsStatusRow(
            title: "Always-on context cost (enabled plugins)",
            subtitle: model.isTokenSumComplete
                ? "Sum of projected always-on tokens every session pays before any tool is used."
                : "Expand plugin cards to load their token cost — the sum is incomplete until all details are loaded.",
            tone: model.isTokenSumComplete ? .ok : .off,
            detail: "~\(model.enabledAlwaysOnTokenSum.formatted()) tok\(model.isTokenSumComplete ? "" : " (partial)")"
        )
    }

    private func installedPluginCard(_ plugin: ClaudeInstalledPlugin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggleExpanded(plugin)
                } label: {
                    Image(systemName: expandedPluginIDs.contains(plugin.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)

                Text(plugin.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                badge(plugin.version)
                badge(plugin.marketplaceName)
                badge(plugin.scope)

                if let tokens = model.detailsCache[model.cacheKey(for: plugin)]?.alwaysOnTokens {
                    Text("~\(tokens.formatted()) tok")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens > 5000 ? AppTheme.statusAwaiting : AppTheme.textSecondary)
                }

                Spacer()

                Toggle("", isOn: enabledBinding(plugin))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(AppTheme.statusWorking)
                    .disabled(model.isBusy)

                Menu {
                    Button("Update") {
                        Task { await model.update(plugin) }
                    }
                    Button("Uninstall", role: .destructive) {
                        Task { await model.uninstall(plugin) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .disabled(model.isBusy)
            }

            if expandedPluginIDs.contains(plugin.id) {
                pluginDetailsView(plugin)
            }
        }
        .padding(10)
        .background(AppTheme.control.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func pluginDetailsView(_ plugin: ClaudeInstalledPlugin) -> some View {
        if let details = model.detailsCache[model.cacheKey(for: plugin)] {
            VStack(alignment: .leading, spacing: 4) {
                if let description = details.descriptionText {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Text(inventorySummary(details))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)

                if details.alwaysOnTokens == nil && details.components.isEmpty {
                    Text("Token cost not available in this Claude version.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.textTertiary)
                }

                ForEach(details.components.prefix(12), id: \.name) { component in
                    HStack {
                        Text(component.name)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text("always-on \(component.alwaysOnTokens.map { "~\($0)" } ?? "—") · on-invoke \(component.onInvokeTokens.map { "~\($0)" } ?? "—")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }
                if details.components.count > 12 {
                    Text("+ \(details.components.count - 12) more components")
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            .padding(.leading, 18)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading details…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.leading, 18)
        }
    }

    private func inventorySummary(_ details: ClaudePluginDetails) -> String {
        var parts: [String] = []
        if let skills = details.skillCount { parts.append("\(skills) skills") }
        if let agents = details.agentCount { parts.append("\(agents) agents") }
        if let hooks = details.hookCount, hooks > 0 { parts.append("\(hooks) hooks") }
        if let mcp = details.mcpServerCount, mcp > 0 { parts.append("\(mcp) MCP servers") }
        if let lsp = details.lspServerCount, lsp > 0 { parts.append("\(lsp) LSP servers") }
        return parts.isEmpty ? "No component inventory" : parts.joined(separator: " · ")
    }

    private func availablePluginRow(_ plugin: ClaudeAvailablePlugin) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    badge(plugin.marketplaceName)
                }
                if let description = plugin.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isInstalled(plugin) {
                Text("Installed")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.textTertiary)
            } else {
                Button("Install…") {
                    installTarget = plugin
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 4)
    }

    private var filteredAvailable: [ClaudeAvailablePlugin] {
        let query = availableSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.pluginList.available }
        return model.pluginList.available.filter {
            $0.name.lowercased().contains(query)
                || $0.marketplaceName.lowercased().contains(query)
                || ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    private func isInstalled(_ plugin: ClaudeAvailablePlugin) -> Bool {
        model.pluginList.installed.contains { $0.id == plugin.pluginId }
    }

    // MARK: - Tab: Marketplaces

    @ViewBuilder
    private var marketplacesTab: some View {
        SettingsSection("Marketplaces") {
            SettingsRow(
                title: "Add marketplace",
                subtitle: "URL, local path, or GitHub owner/repo."
            ) {
                HStack(spacing: 8) {
                    TextField("owner/repo or URL", text: $newMarketplaceSource)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Add") {
                        let source = newMarketplaceSource.trimmingCharacters(in: .whitespaces)
                        guard !source.isEmpty else { return }
                        newMarketplaceSource = ""
                        Task { await model.addMarketplace(source: source) }
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                    .disabled(model.isBusy)
                }
            }

            ForEach(model.marketplaces) { marketplace in
                marketplaceRow(marketplace)
            }

            SettingsButtonRow(title: "Update all marketplaces") {
                Button("Update all") {
                    Task { await model.updateMarketplaces() }
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(model.isBusy)
            }
        }
    }

    private func marketplaceRow(_ marketplace: ClaudeMarketplace) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(marketplace.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.textPrimary)
                    badge(marketplace.source)
                }
                Text(marketplace.sourceDetail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Update") {
                Task { await model.updateMarketplaces(name: marketplace.name) }
            }
            .buttonStyle(SettingsButtonStyle.standard)
            .disabled(model.isBusy)

            Button("Remove", role: .destructive) {
                Task { await model.removeMarketplace(name: marketplace.name) }
            }
            .buttonStyle(SettingsButtonStyle.destructive)
            .disabled(model.isBusy)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helfer

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(AppTheme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(AppTheme.control.opacity(0.6), in: Capsule())
    }

    private func toggleExpanded(_ plugin: ClaudeInstalledPlugin) {
        if expandedPluginIDs.contains(plugin.id) {
            expandedPluginIDs.remove(plugin.id)
        } else {
            expandedPluginIDs.insert(plugin.id)
            Task { await model.loadDetailsIfNeeded(for: plugin) }
        }
    }

    private func enabledBinding(_ plugin: ClaudeInstalledPlugin) -> Binding<Bool> {
        Binding(
            get: { plugin.enabled },
            set: { newValue in
                Task { await model.setEnabled(newValue, plugin: plugin) }
            }
        )
    }
}

/// Install-Bestaetigung: Scope-Wahl + optionale `--config key=value`-Zeilen.
/// Schema-Validierung macht das CLI — Fehler kommen als Klartext zurueck.
private struct PluginInstallSheet: View {
    let plugin: ClaudeAvailablePlugin
    let model: ClaudePluginManagerModel

    @Environment(\.dismiss) private var dismiss
    @State private var configText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install \(plugin.name)")
                .font(.system(size: 14, weight: .semibold))
            Text("From marketplace \(plugin.marketplaceName). Applies to new Claude sessions after install.")
                .font(.system(size: 11.5))
                .foregroundStyle(AppTheme.textSecondary)

            // Bewusst NUR User-Scope: project/local schreiben relativ zum
            // Arbeitsverzeichnis des CLI-Aufrufs — die App hat aber kein
            // Projekt-cwd, ein Picker wuerde ins Leere installieren
            // (Review-Befund 2026-07-19). Projekt-Scope: `claude plugin
            // install --scope project` im Projekt-Terminal.
            Text("Scope: User (all projects). For project-scoped installs run the CLI inside the project.")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.textTertiary)

            SettingsTextArea(
                title: "Config (optional) — one per line as key=value",
                text: $configText,
                minHeight: 48
            )

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SettingsButtonStyle.standard)
                Button("Install") {
                    let config = SettingsLineParsing.parseKeyValueLines(configText)
                    dismiss()
                    Task { await model.install(plugin.pluginId, scope: .user, config: config) }
                }
                .buttonStyle(SettingsButtonStyle.primary)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
