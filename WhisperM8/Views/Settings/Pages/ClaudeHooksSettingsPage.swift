import SwiftUI

/// Eigene Seite der CLAUDE-CODE-Sektion (IA-Umbau 2026-07-19), vormals
/// Tab „Claude Hooks" in `AgentChatsSettingsPage`. Stand der Hooks:
/// `docs/plans/einstellungen-ordnung/hooks-analyse.md`.
struct ClaudeHooksSettingsPage: View {
    @AppStorage(PreferenceKeys.claudeHooksEnabled) private var hooksEnabled = true

    @State private var externalHookFindings: [ExternalClaudeHooksInspector.Finding] = []
    @State private var isExplainerExpanded = false
    @State private var isHookPreviewExpanded = false
    @State private var hookSettingsPreview = ""
    @State private var hookPreviewUsesReducedSet = true

    var body: some View {
        SettingsPageContainer(
            title: "Hooks",
            subtitle: "Session hooks link each chat to its Claude session. Claude launches with a temporary --settings file; your global ~/.claude/settings.json stays untouched."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSection("Claude Code Hooks") {
                    SettingsStatusRow(
                        title: hooksEnabled ? "Session hooks active" : "Session hooks disabled",
                        subtitle: hooksEnabled
                            ? "Claude chats start with a temporary hook configuration that links each chat to its Claude session. Live status comes from Claude's own session registry; your global ~/.claude/settings.json stays untouched."
                            : "Chats start without the hook configuration. Live status still comes from Claude's own session registry, but WhisperM8 can no longer link a chat to its Claude session automatically, and background agents lose their live status.",
                        tone: hooksEnabled ? .ok : .off,
                        detail: hooksEnabled ? "Session linking" : "Hooks off"
                    )

                    SettingsToggleRow(
                        title: "Use session hooks",
                        subtitle: "Launches Claude with a temporary --settings file that links the chat to its session. Your global ~/.claude/settings.json is never touched. Running sessions need a restart to pick up changes.",
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
                        VStack(alignment: .leading, spacing: 8) {
                            SettingsHelpText(hookPreviewUsesReducedSet
                                ? "Normal chats get only these four events; their live status comes from Claude's session registry. Background agents and Claude versions without the registry get the full set with eight events."
                                : "Chats currently get the full set with eight events, because the session registry is off or the installed Claude version does not write it yet.")
                            SettingsCodeBlock(text: hookSettingsPreview, minHeight: 220)
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .onAppear(perform: refresh)
        }
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

            Text(settingsLocalized: label)
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
                detail: String(localized: "\(externalHookFindings.count) found")
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
                Text(settingsLocalized: finding.eventName)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("matcher: \(finding.matcher ?? "none")")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)

                Spacer(minLength: 8)

                Text(settingsLocalized: finding.source)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textTertiary)
            }

            Text(settingsLocalized: finding.commandPreview)
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
        // Vorschau = der Satz, den ein normaler Chat beim nächsten Start
        // bekäme (dieselbe Entscheidung wie `prepareLaunchSettings`).
        let reduced = AgentSessionStatusCoordinator.usesReducedHooks(
            registryEnabled: AppPreferences.shared.isClaudeRegistryStatusEnabled,
            isBackground: false,
            cliSupportsRegistry: ClaudeCLIVersion.supportsRegistry(
                ClaudeCLIVersionProbe.shared.installedVersion()))
        hookPreviewUsesReducedSet = reduced
        let examplePath = "~/Library/Application Support/WhisperM8/claude-session-events/<session>.jsonl"
        if let data = try? ClaudeHookSettingsBuilder.serializedSettings(
            eventFilePath: examplePath,
            eventNames: reduced
                ? ClaudeHookSettingsBuilder.registryModeEventNames
                : ClaudeHookSettingsBuilder.trackedEventNames),
           let json = String(data: data, encoding: .utf8) {
            hookSettingsPreview = json
        }
    }
}
