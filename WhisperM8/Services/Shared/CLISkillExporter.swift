import Foundation

/// Stellt die gebündelten Agent-Skills fürs whisperm8-CLI bereit (Anthropic-
/// SKILL.md-Format, Ressourcen im App-Bundle) und installiert sie auf Wunsch
/// nach `~/.claude/skills/<name>/SKILL.md`, wo Claude Code sie automatisch
/// entdeckt. Für andere Tools (ChatGPT, Claude.ai) liefert er den
/// Markdown-Inhalt zum Speichern/Kopieren.
struct CLISkillExporter {
    /// Eine Referenz-Datei eines Skills: wird nach
    /// `~/.claude/skills/<name>/references/<fileName>` installiert.
    struct SkillReference: Equatable {
        /// Dateiname im references/-Ordner (inkl. .md).
        let fileName: String
        /// Bundle-Ressource (ohne .md-Endung).
        let resourceName: String
    }

    /// Ein installierbarer Skill: `name` muss dem `name:`-Frontmatter der
    /// Ressource entsprechen — Claude Code erwartet Ordnername == Skill-Name.
    struct SkillDefinition: Equatable {
        let name: String
        let resourceName: String
        /// Vertiefende references/-Dateien (SKILL.md verweist auf sie).
        var references: [SkillReference] = []

        /// Transkriptions-Skill (`whisperm8 transcribe …`).
        static let transcription = SkillDefinition(
            name: "whisperm8-transcription",
            resourceName: "whisperm8-cli-skill"
        )
        /// Codex-Subagents (`whisperm8 agent …`).
        static let codexAgent = SkillDefinition(
            name: "codex-subagent",
            resourceName: "whisperm8-agent-skill",
            references: [
                SkillReference(
                    fileName: "playwright-browser-qa.md",
                    resourceName: "whisperm8-agent-skill-ref-playwright-browser-qa"
                ),
                SkillReference(
                    fileName: "1password-cli.md",
                    resourceName: "whisperm8-agent-skill-ref-1password-cli"
                ),
                SkillReference(
                    fileName: "claude-workflows.md",
                    resourceName: "whisperm8-agent-skill-ref-claude-workflows"
                ),
            ]
        )

        static let all: [SkillDefinition] = [.transcription, .codexAgent]
    }

    /// Rückwärtskompatibler Alias (Tests/ältere Aufrufer).
    static let skillName = SkillDefinition.transcription.name
    static let resourceName = SkillDefinition.transcription.resourceName

    var definition: SkillDefinition
    var homeDirectory: URL
    var bundle: Bundle

    init(
        definition: SkillDefinition = .transcription,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) {
        self.definition = definition
        self.homeDirectory = homeDirectory
        self.bundle = bundle
    }

    enum SkillError: LocalizedError {
        case resourceMissing(String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing(let name):
                return "Skill-Ressource fehlt im App-Bundle (\(name).md)."
            }
        }
    }

    /// Der vollständige Skill-Inhalt (Frontmatter + Markdown-Body).
    func skillMarkdown() throws -> String {
        try resourceMarkdown(definition.resourceName)
    }

    /// Inhalt einer Referenz-Datei aus dem Bundle.
    func referenceMarkdown(_ reference: SkillReference) throws -> String {
        try resourceMarkdown(reference.resourceName)
    }

    private func resourceMarkdown(_ resourceName: String) throws -> String {
        guard let url = bundle.url(forResource: resourceName, withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else {
            throw SkillError.resourceMissing(resourceName)
        }
        return content
    }

    /// Zielpfad der Claude-Code-Installation: `~/.claude/skills/<name>/SKILL.md`.
    var claudeCodeSkillURL: URL {
        homeDirectory
            .appendingPathComponent(".claude/skills", isDirectory: true)
            .appendingPathComponent(definition.name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    /// Zielordner der Referenz-Dateien: `~/.claude/skills/<name>/references/`.
    var claudeCodeReferencesDirectory: URL {
        claudeCodeSkillURL
            .deletingLastPathComponent()
            .appendingPathComponent("references", isDirectory: true)
    }

    func claudeCodeReferenceURL(for reference: SkillReference) -> URL {
        claudeCodeReferencesDirectory.appendingPathComponent(reference.fileName)
    }

    var isInstalledForClaudeCode: Bool {
        FileManager.default.fileExists(atPath: claudeCodeSkillURL.path)
    }

    /// Ist der installierte Skill inhaltlich identisch mit dem gebündelten
    /// (SKILL.md UND alle verwalteten references/-Dateien)? `false` auch,
    /// wenn (noch) gar keiner installiert ist.
    var installedSkillIsCurrent: Bool {
        guard let bundled = try? skillMarkdown(),
              let installed = try? String(contentsOf: claudeCodeSkillURL, encoding: .utf8),
              installed == bundled else {
            return false
        }
        for reference in definition.references {
            guard let bundledReference = try? referenceMarkdown(reference),
                  let installedReference = try? String(
                    contentsOf: claudeCodeReferenceURL(for: reference), encoding: .utf8),
                  installedReference == bundledReference else {
                return false
            }
        }
        return true
    }

    /// Schreibt (bzw. aktualisiert) den Skill für Claude Code: SKILL.md plus
    /// alle verwalteten references/-Dateien. Idempotent. Fremde Dateien im
    /// references/-Ordner (z. B. lokale Ergänzungen des Users) bleiben
    /// unangetastet.
    @discardableResult
    func installForClaudeCode() throws -> URL {
        let content = try skillMarkdown()
        let destination = claudeCodeSkillURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: destination, atomically: true, encoding: .utf8)

        if !definition.references.isEmpty {
            try FileManager.default.createDirectory(
                at: claudeCodeReferencesDirectory,
                withIntermediateDirectories: true
            )
            for reference in definition.references {
                let referenceContent = try referenceMarkdown(reference)
                try referenceContent.write(
                    to: claudeCodeReferenceURL(for: reference),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        Logger.debug("[CLI] Skill installiert: \(destination.path)")
        return destination
    }
}

// MARK: - CLI-Status (für die Settings-Anzeige)

/// Prüft, ob der `whisperm8`-Symlink existiert und auf das laufende App-Binary
/// zeigt — dieselbe Logik-Grundlage wie `CLISymlinkInstaller`, nur lesend.
struct CLIInstallStatus {
    enum State: Equatable {
        /// Symlink vorhanden und zeigt auf das aktuelle Binary.
        case linked(path: String)
        /// Am Zielpfad liegt etwas, aber es zeigt woandershin (z. B. alte App-Kopie).
        case linkedElsewhere(path: String, destination: String)
        /// Nichts installiert.
        case missing(expectedPath: String)
    }

    static func current(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        executableURL: URL? = Bundle.main.executableURL
    ) -> State {
        let linkURL = homeDirectory
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent(CLISymlinkInstaller.linkName)

        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else {
            // Kein Symlink; eine reguläre Datei werten wir als "fremd installiert".
            if FileManager.default.fileExists(atPath: linkURL.path) {
                return .linkedElsewhere(path: linkURL.path, destination: linkURL.path)
            }
            return .missing(expectedPath: linkURL.path)
        }

        let resolvedDestination = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
        if let executableURL,
           resolvedDestination == executableURL.resolvingSymlinksInPath().path {
            return .linked(path: linkURL.path)
        }
        return .linkedElsewhere(path: linkURL.path, destination: resolvedDestination)
    }
}
