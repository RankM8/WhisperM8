import Foundation

/// Stellt den gebündelten Agent-Skill fürs whisperm8-CLI bereit (Anthropic-
/// SKILL.md-Format, Ressource `whisperm8-cli-skill.md`) und installiert ihn
/// auf Wunsch nach `~/.claude/skills/<name>/SKILL.md`, wo Claude Code ihn
/// automatisch entdeckt. Für andere Tools (ChatGPT, Claude.ai) liefert er den
/// Markdown-Inhalt zum Speichern/Kopieren.
struct CLISkillExporter {
    /// Muss dem `name:`-Frontmatter der Skill-Ressource entsprechen — Claude
    /// Code erwartet, dass der Ordnername dem Skill-Namen gleicht.
    static let skillName = "whisperm8-transcription"
    static let resourceName = "whisperm8-cli-skill"

    var homeDirectory: URL
    var bundle: Bundle

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) {
        self.homeDirectory = homeDirectory
        self.bundle = bundle
    }

    enum SkillError: LocalizedError {
        case resourceMissing

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "Skill-Ressource fehlt im App-Bundle (\(CLISkillExporter.resourceName).md)."
            }
        }
    }

    /// Der vollständige Skill-Inhalt (Frontmatter + Markdown-Body).
    func skillMarkdown() throws -> String {
        guard let url = bundle.url(forResource: Self.resourceName, withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else {
            throw SkillError.resourceMissing
        }
        return content
    }

    /// Zielpfad der Claude-Code-Installation: `~/.claude/skills/<name>/SKILL.md`.
    var claudeCodeSkillURL: URL {
        homeDirectory
            .appendingPathComponent(".claude/skills", isDirectory: true)
            .appendingPathComponent(Self.skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    var isInstalledForClaudeCode: Bool {
        FileManager.default.fileExists(atPath: claudeCodeSkillURL.path)
    }

    /// Ist der installierte Skill inhaltlich identisch mit dem gebündelten?
    /// `false` auch, wenn (noch) gar keiner installiert ist.
    var installedSkillIsCurrent: Bool {
        guard let bundled = try? skillMarkdown(),
              let installed = try? String(contentsOf: claudeCodeSkillURL, encoding: .utf8) else {
            return false
        }
        return installed == bundled
    }

    /// Schreibt (bzw. aktualisiert) den Skill für Claude Code. Idempotent.
    @discardableResult
    func installForClaudeCode() throws -> URL {
        let content = try skillMarkdown()
        let destination = claudeCodeSkillURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: destination, atomically: true, encoding: .utf8)
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
