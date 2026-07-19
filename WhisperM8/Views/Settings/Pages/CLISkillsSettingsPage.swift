import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CLISkillsSettingsPage: View {
    @State private var installState: CLIInstallStatus.State = .missing(expectedPath: "~/.local/bin/whisperm8")

    var body: some View {
        SettingsPageContainer(
            title: "CLI & Skills",
            subtitle: "Command line access and installable agent skills."
        ) {
            // Skills zuerst: die installierbaren Karten sind die Hauptaktion
            // der Seite (User-Wunsch 2026-07-06), CLI-Details folgen darunter.
            agentSkillsSection
            statuslineSection
            commandLineSection
            transcriptionQuickstartSection
            codexSubagentsQuickstartSection
        }
        .onAppear { installState = CLIInstallStatus.current() }
    }

    private var commandLineSection: some View {
        SettingsSection("Command Line") {
            SettingsStatusRow(
                title: statusTitle,
                tone: statusTone,
                detail: statusDetail
            ) {
                if needsInstallAction {
                    Button("Create Link") {
                        CLISymlinkInstaller.installIfNeeded()
                        installState = CLIInstallStatus.current()
                    }
                    .buttonStyle(SettingsButtonStyle.primary)
                }
            }

            SettingsHelpText("Uses the same Keychain API key as the app.")
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
        }
    }

    private var transcriptionQuickstartSection: some View {
        SettingsSection("Quickstart · Transcription") {
            SettingsCopyCommandRow(
                command: "whisperm8 transcribe aufnahme.m4a",
                caption: "Audio → Text (stdout)"
            )
            SettingsCopyCommandRow(
                command: "whisperm8 transcribe video.mp4 -f srt -o video.srt",
                caption: "Video → subtitles (audio track is extracted automatically)"
            )
            SettingsCopyCommandRow(
                command: "whisperm8 transcribe meeting.mp3 --mode clean -o meeting.txt",
                caption: "Transcript + post-processing through an output mode"
            )
            SettingsCopyCommandRow(
                command: "whisperm8 transcribe workshop.mp4 --dry-run",
                caption: "Duration, chunks, and cost estimate only — no API calls"
            )

            SettingsHelpText("Formats: txt, json, srt, vtt · Providers: Groq (default) and OpenAI · long files are chunked automatically and merged again. All options: `whisperm8 --help`.")
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
        }
    }

    private var codexSubagentsQuickstartSection: some View {
        SettingsSection("Quickstart · Codex Subagents") {
            SettingsHelpText("WhisperM8 is the supervisor for headless Codex agents; Codex does not have its own background system. Jobs run detached, can be continued across turns, appear live in Agent Chats, and can be taken over there as an interactive chat at any time.")
                .padding(.vertical, 10)
                .padding(.horizontal, 2)

            SettingsCopyCommandRow(
                command: "whisperm8 agent run --wait --json \"Review the diff from HEAD~3 for regressions.\"",
                caption: "Synchronous job — blocks until the report (JSON on stdout)"
            )
            SettingsCopyCommandRow(
                command: "whisperm8 agent run --worktree \"Implement X, test it, and commit when green.\"",
                caption: "Detached job in an isolated Git worktree (branch subagent/<id>)"
            )
            SettingsCopyCommandRow(
                command: "whisperm8 agent send <id> --wait \"Please cover the edge cases too.\"",
                caption: "Follow-up turn — the session keeps its context (codex exec resume)"
            )
            SettingsCopyCommandRow(
                command: "whisperm8 agent list",
                caption: "All jobs with state · status/logs/stop/rm for details and management"
            )

            SettingsHelpText("Sandbox: workspace-write (default, commits yes / pushes no) or read-only. Exit codes: 0 done · 2 failed · 3 conflict · 4 environment. All options: `whisperm8 agent help`.")
                .padding(.vertical, 10)
                .padding(.horizontal, 2)
        }
    }

    private var agentSkillsSection: some View {
        SettingsSection("Agent Skills") {
            VStack(alignment: .leading, spacing: 12) {
                CLISkillSettingsCard(
                    title: "Transcription Skill",
                    definition: .transcription,
                    summary: "Teaches AI assistants what the transcription CLI can do and how to call it correctly, for example transcribing a meeting video and summarizing it."
                )

                CLISkillSettingsCard(
                    title: "GPT & Codex Subagent Skill",
                    definition: .codexAgent,
                    summary: "Routes GPT subagent requests: native `gpt` agent type by default (WhisperM8 GPT backend), plus the full Codex CLI path — commands, flags, exit codes, image generation, and workflows."
                )

                CLISkillSettingsCard(
                    title: "Agent Chats Skill (Jarvis)",
                    definition: .chats,
                    summary: "Lets any chat see and manage all your agent sessions via `whisperm8 chats` — overview, read transcripts, send prompts, wait for events, interrupt, rename/archive. Includes the supervisor loop and safety rules (send confirmation, one-hop)."
                )
            }
            .padding(.vertical, 10)
        }
    }

    private var statuslineSection: some View {
        SettingsSection("Statusline") {
            StatuslineSettingsCard()
                .padding(.vertical, 10)
        }
    }

    private var statusTitle: String {
        switch installState {
        case .linked:
            return "whisperm8 is installed"
        case .linkedElsewhere:
            return "Link points to another app copy"
        case .missing:
            return "CLI link has not been created yet"
        }
    }

    private var statusDetail: String {
        switch installState {
        case .linked(let path):
            return path
        case .linkedElsewhere(let path, let destination):
            return "\(path) → \(destination)"
        case .missing(let expectedPath):
            return expectedPath
        }
    }

    private var statusTone: SettingsStatusTone {
        switch installState {
        case .linked:
            return .ok
        case .linkedElsewhere:
            return .warn
        case .missing:
            return .off
        }
    }

    private var needsInstallAction: Bool {
        if case .linked = installState { return false }
        return true
    }
}

private struct CLISkillSettingsCard: View {
    let title: String
    let definition: CLISkillExporter.SkillDefinition
    let summary: String

    @State private var installed = false
    @State private var isCurrent = false
    @State private var markdown = ""
    @State private var feedback: SettingsFeedbackState
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?
    @State private var isPreviewPresented = false

    @MainActor
    init(title: String, definition: CLISkillExporter.SkillDefinition, summary: String) {
        self.title = title
        self.definition = definition
        self.summary = summary
        self._feedback = State(initialValue: SettingsFeedbackState(duration: .milliseconds(2500)))
    }

    private var exporter: CLISkillExporter {
        CLISkillExporter(definition: definition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("Skill · \(definition.name)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)

                SettingsHelpText(summary)

                SettingsHelpText("Claude Code reads from ~/.claude/skills; other tools need the file copied manually.")
            }

            HStack(spacing: 8) {
                Button(installButtonTitle) {
                    install()
                }
                .buttonStyle(SettingsButtonStyle.primary)
                .disabled(installed && isCurrent)

                Button("Save…") {
                    saveToDisk()
                }
                .buttonStyle(SettingsButtonStyle.standard)

                Button("Copy") {
                    copyToPasteboard()
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(markdown.isEmpty)

                Button("View") {
                    isPreviewPresented = true
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(markdown.isEmpty)

                if let feedbackMessage, feedback.isActive {
                    Text(feedbackMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.statusWorking)
                        .transition(.opacity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $isPreviewPresented) {
            CLISkillPreviewSheet(
                title: "Skill · \(definition.name)",
                markdown: markdown.isEmpty ? "Skill resource not found." : markdown
            )
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var installButtonTitle: String {
        if installed && isCurrent {
            return "Installed"
        }
        if installed {
            return "Update Skill"
        }
        return "Install"
    }

    private func refresh() {
        installed = exporter.isInstalledForClaudeCode
        isCurrent = exporter.installedSkillIsCurrent
        if markdown.isEmpty {
            markdown = (try? exporter.skillMarkdown()) ?? ""
        }
    }

    private func install() {
        do {
            try exporter.installForClaudeCode()
            refresh()
            showFeedback("Installed")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveToDisk() {
        guard !markdown.isEmpty else {
            errorMessage = CLISkillExporter.SkillError.resourceMissing(definition.resourceName).localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SKILL.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.title = "Save Skill File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            showFeedback("Saved")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        showFeedback("Copied")
    }

    private func showFeedback(_ text: String) {
        feedbackMessage = text
        withAnimation { feedback.trigger() }
    }
}

private struct StatuslineSettingsCard: View {
    @State private var status: StatuslineInstaller.Status = .missing
    @State private var wiredCount = 0
    @State private var totalConfigs = 0
    @State private var foreignSettings = 0
    @State private var script = ""
    @State private var feedback: SettingsFeedbackState
    @State private var feedbackMessage: String?
    @State private var errorMessage: String?
    @State private var isPreviewPresented = false
    @State private var isReplaceConfirmPresented = false
    @State private var isForeignSettingsConfirmPresented = false

    @MainActor
    init() {
        self._feedback = State(initialValue: SettingsFeedbackState(duration: .milliseconds(2500)))
    }

    private var installer: StatuslineInstaller { StatuslineInstaller() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("WhisperM8 Statusline")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Text("~/.claude/\(StatuslineInstaller.scriptFileName)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)

                SettingsHelpText("Claude Code status line: repo/branch, context usage with exact token count (incl. GPT sessions via the 272k window), model, effort, account usage limits, active subagents (Claude & GPT), and the active account profile.")

                SettingsHelpText(wiringSummary)

                if status == .foreign {
                    SettingsHelpText("A custom status line script exists at the target path. Installing replaces it — save a copy first if you want to keep it.")
                }
            }

            HStack(spacing: 8) {
                Button(installButtonTitle) {
                    if status == .foreign {
                        isReplaceConfirmPresented = true
                    } else if foreignSettings > 0, wiredCount < totalConfigs {
                        isForeignSettingsConfirmPresented = true
                    } else {
                        install()
                    }
                }
                .buttonStyle(SettingsButtonStyle.primary)
                .disabled(status == .current && wiredCount == totalConfigs)

                Button("View") {
                    isPreviewPresented = true
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(script.isEmpty)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script, forType: .string)
                    showFeedback("Copied")
                }
                .buttonStyle(SettingsButtonStyle.standard)
                .disabled(script.isEmpty)

                if let feedbackMessage, feedback.isActive {
                    Text(feedbackMessage)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.statusWorking)
                        .transition(.opacity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $isPreviewPresented) {
            CLISkillPreviewSheet(
                title: "Statusline · \(StatuslineInstaller.scriptFileName)",
                markdown: script.isEmpty ? "Statusline resource not found." : script
            )
        }
        .confirmationDialog(
            "Replace existing status line script?",
            isPresented: $isReplaceConfirmPresented
        ) {
            Button("Replace Script", role: .destructive) { install(replaceScript: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The script at the target path was not installed by WhisperM8 and will be overwritten. Custom statusLine entries in settings.json are NOT touched by this.")
        }
        .confirmationDialog(
            "Replace custom statusLine entries?",
            isPresented: $isForeignSettingsConfirmPresented
        ) {
            Button("Replace Entries", role: .destructive) { install(replaceSettings: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(foreignSettings) config(s) point to a different status line command. Replacing switches them to the WhisperM8 status line.")
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var installButtonTitle: String {
        switch status {
        case .current:
            if wiredCount == totalConfigs { return "Installed" }
            return foreignSettings > 0 ? "Repair Settings…" : "Repair Settings"
        case .outdated:
            return "Update"
        case .foreign:
            return "Replace…"
        case .missing:
            return "Install"
        }
    }

    private var wiringSummary: String {
        guard totalConfigs > 0 else { return "" }
        var text = "statusLine entry active in \(wiredCount) of \(totalConfigs) Claude configs (main + account profiles; symlinked profiles follow main automatically)."
        if foreignSettings > 0 {
            text += " \(foreignSettings) config(s) use a different status line command."
        }
        return text
    }

    private func refresh() {
        status = installer.status()
        wiredCount = installer.wiredSettingsCount()
        totalConfigs = installer.settingsDirectories().count
        foreignSettings = installer.foreignSettingsCount()
        if script.isEmpty {
            script = (try? installer.bundledScript()) ?? ""
        }
    }

    private func install(replaceScript: Bool = false, replaceSettings: Bool = false) {
        do {
            try installer.install(
                replaceForeignScript: replaceScript,
                replaceForeignSettings: replaceSettings
            )
            refresh()
            showFeedback("Installed")
        } catch {
            refresh()
            errorMessage = error.localizedDescription
        }
    }

    private func showFeedback(_ text: String) {
        feedbackMessage = text
        withAnimation { feedback.trigger() }
    }
}

private struct CLISkillPreviewSheet: View {
    let title: String
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(SettingsButtonStyle.standard)
            }

            SettingsCodeBlock(text: markdown, minHeight: 420)
        }
        .padding(20)
        .frame(width: 720, height: 540)
        .background(AppTheme.background)
    }
}
