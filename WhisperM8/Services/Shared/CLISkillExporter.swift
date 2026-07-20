import CryptoKit
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

    /// Eine zusätzliche Skill-Datei außerhalb von references/, etwa eine
    /// ausführbare Workflow-Vorlage unter examples/.
    struct SkillAsset: Equatable {
        /// Relativer Zielpfad innerhalb des Skill-Ordners.
        let relativePath: String
        /// Bundle-Ressource ohne Dateiendung.
        let resourceName: String
        /// Dateiendung der Bundle-Ressource, z. B. `js`.
        let resourceExtension: String
    }

    /// Ein installierbarer Skill: `name` muss dem `name:`-Frontmatter der
    /// Ressource entsprechen — Claude Code erwartet Ordnername == Skill-Name.
    struct SkillDefinition: Equatable {
        let name: String
        let resourceName: String
        /// Vertiefende references/-Dateien (SKILL.md verweist auf sie).
        var references: [SkillReference] = []
        /// Weitere Dateien mit frei wählbarem Unterordner und Dateityp.
        var assets: [SkillAsset] = []

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

        /// Agent-Chats-Verwaltung (`whisperm8 chats …`, „Jarvis").
        static let chats = SkillDefinition(
            name: "whisperm8-chats",
            resourceName: "whisperm8-chats-skill"
        )

        /// Session-weiter Delegations-Modus für GPT-Subagents.
        static let gptCoworker = SkillDefinition(
            name: "gpt-coworker",
            resourceName: "whisperm8-gpt-coworker-skill"
        )

        /// GPT-only Multi-Agent-Reviews über das Workflow-Tool.
        static let gptWorkflow = SkillDefinition(
            name: "gpt-workflow",
            resourceName: "whisperm8-gpt-workflow-skill",
            assets: [
                SkillAsset(
                    relativePath: "examples/wf-code-review.js",
                    resourceName: "whisperm8-gpt-workflow-example-code-review",
                    resourceExtension: "js"
                ),
                SkillAsset(
                    relativePath: "examples/wf-docs-review.js",
                    resourceName: "whisperm8-gpt-workflow-example-docs-review",
                    resourceExtension: "js"
                ),
            ]
        )

        static let all: [SkillDefinition] = [
            .transcription,
            .codexAgent,
            .chats,
            .gptCoworker,
            .gptWorkflow,
        ]
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
        bundle: Bundle = .module
    ) {
        self.definition = definition
        self.homeDirectory = homeDirectory
        self.bundle = bundle
    }

    enum SkillError: LocalizedError {
        case resourceMissing(String)
        case replacementRequiresConfirmation(String)
        case symbolicLinkTarget(String)
        case invalidAssetPath(String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing(let name):
                let fileName = name.contains(".") ? name : "\(name).md"
                return "Skill-Ressource fehlt im App-Bundle (\(fileName))."
            case .replacementRequiresConfirmation(let path):
                return "Der installierte Skill ist fremd oder lokal geändert und wird nicht ohne Bestätigung ersetzt (\(path))."
            case .symbolicLinkTarget(let path):
                return "Ein Skill-Symlink wird aus Sicherheitsgründen nicht überschrieben (\(path))."
            case .invalidAssetPath(let path):
                return "Ungültiger relativer Pfad einer Skill-Ressource (\(path))."
            }
        }
    }

    /// Der vollständige Skill-Inhalt (Frontmatter + Markdown-Body).
    func skillMarkdown() throws -> String {
        try resourceText(definition.resourceName, extension: "md")
    }

    /// Inhalt einer Referenz-Datei aus dem Bundle.
    func referenceMarkdown(_ reference: SkillReference) throws -> String {
        try resourceText(reference.resourceName, extension: "md")
    }

    /// Inhalt einer zusätzlichen Skill-Datei aus dem Bundle.
    func assetContent(_ asset: SkillAsset) throws -> String {
        try resourceText(asset.resourceName, extension: asset.resourceExtension)
    }

    private func resourceText(_ resourceName: String, extension resourceExtension: String) throws -> String {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else {
            throw SkillError.resourceMissing("\(resourceName).\(resourceExtension)")
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

    func claudeCodeAssetURL(for asset: SkillAsset) -> URL {
        claudeCodeSkillURL
            .deletingLastPathComponent()
            .appendingPathComponent(asset.relativePath)
    }

    var isInstalledForClaudeCode: Bool {
        FileManager.default.fileExists(atPath: claudeCodeSkillURL.path)
    }

    /// Ist der installierte Skill inhaltlich identisch mit dem gebündelten
    /// (SKILL.md UND alle verwalteten references/-Dateien)? `false` auch,
    /// wenn (noch) gar keiner installiert ist.
    var installedSkillIsCurrent: Bool {
        installState() == .current
    }

    // MARK: Drei-Wege-Status (Bundle vs. installiert vs. Install-Stempel)

    /// Installationszustand mit konservativer Konflikterkennung. Der Stempel
    /// unterscheidet verwaltete von nachträglich lokal geänderten Dateien. Bei
    /// einem seitdem abweichenden Bundle bleibt die Versionsrichtung unbekannt,
    /// weil Hashes allein weder Upgrade noch Downgrade belegen.
    enum InstallState: Equatable {
        /// Kein SKILL.md am Zielpfad.
        case notInstalled
        /// Installiert == gebündelt.
        case current
        /// Installiert weicht vom Stempel ab — der User hat lokal editiert.
        case modifiedLocally
        /// Per `make skills` aus dem Repo synchronisiert; das App-Bundle ist
        /// seither unverändert, der installierte Stand also mindestens so neu.
        case repoSynced
        /// Installiert != gebündelt, aber kein Stempel vorhanden — Richtung
        /// unbekannt (Altbestand von vor der Stempel-Einführung).
        case unknownDrift
    }

    /// Install-Stempel neben der SKILL.md. `bundled` darf fehlen, wenn der
    /// Schreiber (z. B. `make skills` ohne installierte App) das Bundle nicht
    /// lesen konnte.
    struct InstallStamp: Codable, Equatable {
        var source: String
        var updatedAt: String
        var installed: [String: String]
        var bundled: [String: String]?

        static let sourceBundle = "bundle"
        static let sourceResources = "resources"
    }

    /// Pfad des Install-Stempels: `~/.claude/skills/<name>/.whisperm8-state.json`.
    var installStampURL: URL {
        claudeCodeSkillURL
            .deletingLastPathComponent()
            .appendingPathComponent(".whisperm8-state.json")
    }

    /// SHA-256-Hashes der gebündelten Dateien, gekeyt wie im Stempel
    /// (`SKILL.md`, `references/<fileName>`).
    func bundledHashes() throws -> [String: String] {
        var hashes = ["SKILL.md": Self.sha256(of: try skillMarkdown())]
        for reference in definition.references {
            hashes["references/\(reference.fileName)"] =
                Self.sha256(of: try referenceMarkdown(reference))
        }
        for asset in definition.assets {
            hashes[asset.relativePath] = Self.sha256(of: try assetContent(asset))
        }
        return hashes
    }

    /// SHA-256-Hashes der installierten Dateien; fehlende Dateien fehlen im
    /// Dictionary. `nil`, wenn gar kein SKILL.md installiert ist.
    func installedHashes() -> [String: String]? {
        guard let skill = try? String(contentsOf: claudeCodeSkillURL, encoding: .utf8) else {
            return nil
        }
        var hashes = ["SKILL.md": Self.sha256(of: skill)]
        for reference in definition.references {
            if let content = try? String(
                contentsOf: claudeCodeReferenceURL(for: reference), encoding: .utf8) {
                hashes["references/\(reference.fileName)"] = Self.sha256(of: content)
            }
        }
        for asset in definition.assets {
            if let content = try? String(
                contentsOf: claudeCodeAssetURL(for: asset), encoding: .utf8) {
                hashes[asset.relativePath] = Self.sha256(of: content)
            }
        }
        return hashes
    }

    func readInstallStamp() -> InstallStamp? {
        guard let data = try? Data(contentsOf: installStampURL) else { return nil }
        return try? JSONDecoder().decode(InstallStamp.self, from: data)
    }

    func writeInstallStamp(_ stamp: InstallStamp) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stamp).write(to: installStampURL, options: .atomic)
    }

    func installState() -> InstallState {
        guard let installed = installedHashes() else { return .notInstalled }
        guard let bundled = try? bundledHashes() else { return .unknownDrift }
        if installed == bundled { return .current }
        guard let stamp = readInstallStamp() else { return .unknownDrift }
        guard stamp.installed == installed else { return .modifiedLocally }
        if stamp.source == InstallStamp.sourceResources {
            if stamp.bundled == nil || stamp.bundled == bundled {
                return .repoSynced
            }
            return .unknownDrift
        }
        return .unknownDrift
    }

    static func sha256(of content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Schreibt (bzw. aktualisiert) den Skill für Claude Code: SKILL.md plus
    /// alle verwalteten references/-Dateien. Idempotent. Fremde Dateien im
    /// references/-Ordner (z. B. lokale Ergänzungen des Users) bleiben
    /// unangetastet. Abweichende fremde oder lokal geänderte Dateien werden nur
    /// nach expliziter Bestätigung ersetzt; Symlinks werden nie beschrieben.
    @discardableResult
    func installForClaudeCode(force: Bool = false) throws -> URL {
        let content = try skillMarkdown()
        let destination = claudeCodeSkillURL
        let referenceContents = try definition.references.map { reference in
            (reference, try referenceMarkdown(reference))
        }
        let assetContents = try definition.assets.map { asset in
            try validateAssetPath(asset.relativePath)
            return (asset, try assetContent(asset))
        }

        try rejectSymbolicLink(at: destination.deletingLastPathComponent())
        try rejectSymbolicLink(at: installStampURL)
        if !referenceContents.isEmpty {
            try rejectSymbolicLink(at: claudeCodeReferencesDirectory)
        }
        for (asset, _) in assetContents {
            try rejectSymbolicLink(at: claudeCodeAssetURL(for: asset).deletingLastPathComponent())
        }
        try validateReplacement(
            content: content,
            at: destination,
            force: force
        )
        for (reference, referenceContent) in referenceContents {
            try validateReplacement(
                content: referenceContent,
                at: claudeCodeReferenceURL(for: reference),
                force: force
            )
        }
        for (asset, assetContent) in assetContents {
            try validateReplacement(
                content: assetContent,
                at: claudeCodeAssetURL(for: asset),
                force: force
            )
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: destination, atomically: true, encoding: .utf8)

        if !referenceContents.isEmpty {
            try FileManager.default.createDirectory(
                at: claudeCodeReferencesDirectory,
                withIntermediateDirectories: true
            )
            for (reference, referenceContent) in referenceContents {
                try referenceContent.write(
                    to: claudeCodeReferenceURL(for: reference),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        for (asset, assetContent) in assetContents {
            let assetURL = claudeCodeAssetURL(for: asset)
            try FileManager.default.createDirectory(
                at: assetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try assetContent.write(to: assetURL, atomically: true, encoding: .utf8)
        }
        // Stempel für den Drei-Wege-Status: installierter Stand == Bundle-Stand.
        let hashes = try bundledHashes()
        try writeInstallStamp(InstallStamp(
            source: InstallStamp.sourceBundle,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            installed: hashes,
            bundled: hashes
        ))
        Logger.debug("[CLI] Skill installiert: \(destination.path)")
        return destination
    }

    /// Exportiert einen vollständigen Skill-Ordner für die manuelle Nutzung:
    /// SKILL.md, references/ und zusätzliche Assets. Ein vorhandenes Ziel wird
    /// nicht überschrieben; damit bleiben fremde oder lokale Dateien geschützt.
    @discardableResult
    func exportSkillDirectory(to directory: URL) throws -> URL {
        try rejectSymbolicLink(at: directory)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SkillError.replacementRequiresConfirmation(directory.path)
        }

        let references = try definition.references.map { reference in
            (reference, try referenceMarkdown(reference))
        }
        let assets = try definition.assets.map { asset in
            try validateAssetPath(asset.relativePath)
            return (asset, try assetContent(asset))
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try skillMarkdown().write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        for (reference, content) in references {
            let destination = directory
                .appendingPathComponent("references", isDirectory: true)
                .appendingPathComponent(reference.fileName)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: destination, atomically: true, encoding: .utf8)
        }
        for (asset, content) in assets {
            let destination = directory.appendingPathComponent(asset.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: destination, atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func validateAssetPath(_ relativePath: String) throws {
        let components = NSString(string: relativePath).pathComponents
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !components.contains("..") else {
            throw SkillError.invalidAssetPath(relativePath)
        }
    }

    private func validateReplacement(
        content: String,
        at destination: URL,
        force: Bool
    ) throws {
        try rejectSymbolicLink(at: destination)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let installedContent = try? String(
            contentsOf: destination,
            encoding: .utf8
        ) else {
            throw SkillError.replacementRequiresConfirmation(destination.path)
        }
        guard installedContent != content else { return }
        guard force else {
            throw SkillError.replacementRequiresConfirmation(destination.path)
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeSymbolicLink else {
            return
        }
        throw SkillError.symbolicLinkTarget(url.path)
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
