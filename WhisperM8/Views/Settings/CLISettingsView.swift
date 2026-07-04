import SwiftUI
import UniformTypeIdentifiers

/// Settings-Bereich fürs whisperm8-CLI: Installations-Status des Symlinks,
/// Kurzreferenzen für beide CLI-Systeme (Transkription + Codex-Subagents)
/// und die installierbaren Agent-Skills (Claude-Code-Install, Datei-Export,
/// Zwischenablage), damit Nutzer das CLI ihren KI-Assistenten beibringen.
struct CLISettingsView: View {
    @State private var installState: CLIInstallStatus.State = .missing(expectedPath: "~/.local/bin/whisperm8")

    var body: some View {
        Form {
            cliStatusSection
            transcribeUsageSection
            agentUsageSection
            Section("Agent-Skills für Claude & ChatGPT") {
                SkillCardView(
                    definition: .transcription,
                    summary: "Bringt KI-Assistenten bei, was die Transkriptions-CLI kann und wie man sie korrekt aufruft — z. B. „Transkribiere das Meeting-Video und fasse es zusammen“. Einmal installieren, danach erkennt der Assistent Transkriptions-Aufgaben von selbst."
                )
                Divider()
                SkillCardView(
                    definition: .codexAgent,
                    summary: "Beschreibt das komplette Codex-Subagent-System präzise: alle Befehle, Flags, Exit-Codes, JSON-Formate, Report-Vertrag und Workflows. Damit kann Claude Code Codex-Subagents spawnen, nachsteuern und verwalten — z. B. „Lass Codex das parallel implementieren“."
                )
                Text("Claude Code lädt Skills automatisch aus `~/.claude/skills`. Für ChatGPT oder Claude.ai den Inhalt kopieren und als Projekt-Anweisung bzw. Custom Instruction einfügen. Beim manuellen Ablegen gilt: Ordnername = Skill-Name, Datei heißt SKILL.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { installState = CLIInstallStatus.current() }
    }

    // MARK: - CLI-Status

    private var cliStatusSection: some View {
        Section("Kommandozeile") {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if needsInstallAction {
                    Button("Link anlegen") {
                        CLISymlinkInstaller.installIfNeeded()
                        installState = CLIInstallStatus.current()
                    }
                }
            }

            Text("Die CLI ist Teil der App und nutzt denselben API-Key aus dem Schlüsselbund — keine separate Anmeldung nötig. Der Link wird bei jedem App-Start automatisch gepflegt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: some View {
        Group {
            switch installState {
            case .linked:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .linkedElsewhere:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            case .missing:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.title3)
    }

    private var statusTitle: String {
        switch installState {
        case .linked: return "whisperm8 ist installiert"
        case .linkedElsewhere: return "Link zeigt auf eine andere App-Kopie"
        case .missing: return "CLI-Link noch nicht angelegt"
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

    private var needsInstallAction: Bool {
        if case .linked = installState { return false }
        return true
    }

    // MARK: - Schnellstart: Transkription

    private var transcribeUsageSection: some View {
        Section("Schnellstart: Transkription") {
            VStack(alignment: .leading, spacing: 6) {
                CommandExampleRow(command: "whisperm8 transcribe aufnahme.m4a", caption: "Audio → Text (stdout)")
                CommandExampleRow(command: "whisperm8 transcribe video.mp4 -f srt -o video.srt", caption: "Video → Untertitel (Audiospur wird automatisch extrahiert)")
                CommandExampleRow(command: "whisperm8 transcribe meeting.mp3 --mode clean -o meeting.txt", caption: "Transkript + Nachbearbeitung über einen Output-Mode")
                CommandExampleRow(command: "whisperm8 transcribe workshop.mp4 --dry-run", caption: "Nur Dauer, Chunks und Kostenschätzung — keine API-Calls")
            }
            .padding(.vertical, 2)

            Text("Formate: txt, json, srt, vtt · Provider: Groq (Default) und OpenAI · lange Dateien werden automatisch gestückelt und wieder zusammengefügt. Alle Optionen: `whisperm8 --help`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Schnellstart: Codex-Subagents

    private var agentUsageSection: some View {
        Section("Schnellstart: Codex-Subagents") {
            Text("WhisperM8 ist der Supervisor für headless Codex-Agenten (Codex hat kein eigenes Background-System). Jobs laufen detacht, sind über Turns fortsetzbar, erscheinen live in den Agent Chats — und lassen sich dort jederzeit als interaktiver Chat übernehmen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                CommandExampleRow(command: "whisperm8 agent run --wait --json \"Reviewe den Diff von HEAD~3 auf Regressionen.\"", caption: "Synchroner Job — blockiert bis zum Report (JSON auf stdout)")
                CommandExampleRow(command: "whisperm8 agent run --worktree \"Implementiere X, teste, committe bei grün.\"", caption: "Detachter Job im isolierten Git-Worktree (Branch subagent/<id>)")
                CommandExampleRow(command: "whisperm8 agent send <id> --wait \"Bitte auch die Edge-Cases abdecken.\"", caption: "Folge-Turn — die Session behält ihren Kontext (codex exec resume)")
                CommandExampleRow(command: "whisperm8 agent list", caption: "Alle Jobs mit Zustand · status/logs/stop/rm für Details und Verwaltung")
            }
            .padding(.vertical, 2)

            Text("Sandbox: workspace-write (Default, committen ja / pushen nein) oder read-only. Exit-Codes: 0 done · 2 failed · 3 Konflikt · 4 Umgebung. Alle Optionen: `whisperm8 agent help`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Befehls-Beispielzeile

private struct CommandExampleRow: View {
    let command: String
    let caption: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(command)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(command, forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Befehl kopieren")
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Skill-Karte (pro Skill: Install, Export, Kopieren, Vorschau)

private struct SkillCardView: View {
    let definition: CLISkillExporter.SkillDefinition
    let summary: String

    @State private var installed = false
    @State private var isCurrent = false
    @State private var markdown = ""
    @State private var feedback: String?
    @State private var errorMessage: String?
    @State private var isPreviewExpanded = false

    private var exporter: CLISkillExporter {
        CLISkillExporter(definition: definition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skill „\(definition.name)“")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    install()
                } label: {
                    Label(
                        installed ? (isCurrent ? "In Claude Code installiert" : "Skill aktualisieren")
                                  : "In Claude Code installieren",
                        systemImage: installed && isCurrent ? "checkmark.circle" : "arrow.down.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(installed && isCurrent)

                Button {
                    saveToDisk()
                } label: {
                    Label("Skill-Datei sichern…", systemImage: "square.and.arrow.down")
                }

                Button {
                    copyToPasteboard()
                } label: {
                    Label("Inhalt kopieren", systemImage: "doc.on.doc")
                }
                .disabled(markdown.isEmpty)

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            DisclosureGroup("Skill-Inhalt ansehen", isExpanded: $isPreviewExpanded) {
                ScrollView {
                    Text(markdown.isEmpty ? "Skill-Ressource nicht gefunden." : markdown)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 320)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .onAppear(perform: refresh)
        .alert("Fehler", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Aktionen

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
            showFeedback("Installiert ✓")
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
        panel.title = "Skill-Datei sichern"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            showFeedback("Gesichert ✓")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        showFeedback("Skill kopiert")
    }

    private func showFeedback(_ text: String) {
        withAnimation { feedback = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { feedback = nil }
        }
    }
}
