import SwiftUI
import UniformTypeIdentifiers

/// Settings-Bereich fürs whisperm8-CLI: zeigt den Installations-Status des
/// Symlinks, eine Kurzreferenz und stellt den Agent-Skill bereit (Claude-Code-
/// Install, Datei-Export, Zwischenablage), damit Nutzer das CLI ihren
/// KI-Assistenten beibringen können.
struct CLISettingsView: View {
    @State private var installState: CLIInstallStatus.State = .missing(expectedPath: "~/.local/bin/whisperm8")
    @State private var skillInstalled = false
    @State private var skillIsCurrent = false
    @State private var feedback: String?
    @State private var errorMessage: String?
    @State private var isReferenceExpanded = false
    @State private var skillMarkdown: String = ""

    private let exporter = CLISkillExporter()

    var body: some View {
        Form {
            cliStatusSection
            usageSection
            skillSection
            referenceSection
        }
        .formStyle(.grouped)
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
                        refresh()
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

    // MARK: - Kurzreferenz

    private var usageSection: some View {
        Section("Schnellstart") {
            VStack(alignment: .leading, spacing: 6) {
                commandExample("whisperm8 transcribe aufnahme.m4a", caption: "Audio → Text (stdout)")
                commandExample("whisperm8 transcribe video.mp4 -f srt -o video.srt", caption: "Video → Untertitel (Audiospur wird automatisch extrahiert)")
                commandExample("whisperm8 transcribe meeting.mp3 --mode clean -o meeting.txt", caption: "Transkript + Nachbearbeitung über einen Output-Mode")
                commandExample("whisperm8 transcribe workshop.mp4 --dry-run", caption: "Nur Dauer, Chunks und Kostenschätzung — keine API-Calls")
            }
            .padding(.vertical, 2)

            Text("Formate: txt, json, srt, vtt · Provider: Groq (Default) und OpenAI · lange Dateien werden automatisch gestückelt und wieder zusammengefügt. Alle Optionen: `whisperm8 --help`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commandExample(_ command: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button {
                    copyToPasteboard(command, feedbackText: "Befehl kopiert")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Befehl kopieren")
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Agent-Skill

    private var skillSection: some View {
        Section("Agent-Skill für Claude & ChatGPT") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skill „\(CLISkillExporter.skillName)“")
                    .font(.headline)
                Text("Bringt KI-Assistenten bei, was die CLI kann und wie man sie korrekt aufruft — z. B. „Transkribiere das Meeting-Video und fasse es zusammen“. Einmal installieren, danach erkennt der Assistent Transkriptions-Aufgaben von selbst.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    installSkillForClaudeCode()
                } label: {
                    Label(
                        skillInstalled ? (skillIsCurrent ? "In Claude Code installiert" : "Skill aktualisieren")
                                       : "In Claude Code installieren",
                        systemImage: skillInstalled && skillIsCurrent ? "checkmark.circle" : "arrow.down.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(skillInstalled && skillIsCurrent)

                Button {
                    saveSkillToDisk()
                } label: {
                    Label("Skill-Datei sichern…", systemImage: "square.and.arrow.down")
                }

                Button {
                    copyToPasteboard(skillMarkdown, feedbackText: "Skill kopiert")
                } label: {
                    Label("Inhalt kopieren", systemImage: "doc.on.doc")
                }
                .disabled(skillMarkdown.isEmpty)

                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
            }

            Text("Claude Code lädt Skills automatisch aus `~/.claude/skills`. Für ChatGPT oder Claude.ai den Inhalt kopieren und als Projekt-Anweisung bzw. Custom Instruction einfügen. Beim manuellen Ablegen gilt: Ordnername = Skill-Name, Datei heißt SKILL.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Skill-Vorschau

    private var referenceSection: some View {
        Section {
            DisclosureGroup("Skill-Inhalt ansehen", isExpanded: $isReferenceExpanded) {
                ScrollView {
                    Text(skillMarkdown.isEmpty ? "Skill-Ressource nicht gefunden." : skillMarkdown)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 320)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Aktionen

    private func refresh() {
        installState = CLIInstallStatus.current()
        skillInstalled = exporter.isInstalledForClaudeCode
        skillIsCurrent = exporter.installedSkillIsCurrent
        if skillMarkdown.isEmpty {
            skillMarkdown = (try? exporter.skillMarkdown()) ?? ""
        }
    }

    private func installSkillForClaudeCode() {
        do {
            try exporter.installForClaudeCode()
            refresh()
            showFeedback("Installiert ✓")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSkillToDisk() {
        guard !skillMarkdown.isEmpty else {
            errorMessage = CLISkillExporter.SkillError.resourceMissing.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SKILL.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.title = "Skill-Datei sichern"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try skillMarkdown.write(to: url, atomically: true, encoding: .utf8)
            showFeedback("Gesichert ✓")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyToPasteboard(_ text: String, feedbackText: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showFeedback(feedbackText)
    }

    private func showFeedback(_ text: String) {
        withAnimation { feedback = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { feedback = nil }
        }
    }
}
