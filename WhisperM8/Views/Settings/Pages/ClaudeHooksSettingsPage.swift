import SwiftUI

/// Eigene Seite der CLAUDE-CODE-Sektion (IA-Umbau 2026-07-19) — vormals
/// Tab „Claude Hooks" in `AgentChatsSettingsPage`; Inhalt unveraendert.
struct ClaudeHooksSettingsPage: View {
    @AppStorage(PreferenceKeys.claudeHooksEnabled) private var hooksEnabled = true

    @State private var externalHookFindings: [ExternalClaudeHooksInspector.Finding] = []
    @State private var isExplainerExpanded = false
    @State private var isHookPreviewExpanded = false
    @State private var hookSettingsPreview = ""

    var body: some View {
        SettingsPageContainer(
            title: "Hooks",
            subtitle: "Session hooks for live status. Claude launches with a temporary --settings file; your global ~/.claude/settings.json stays untouched."
        ) {
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
