import CryptoKit
import Darwin
import Foundation

/// Das Claude-Code-Plugin `whisperm8`: alle Agent-Skills der App plus die Mods
/// (Jarvis-Board). Die App legt es beim Start unter
/// `~/Library/Application Support/WhisperM8/claude-plugin/` ab und gibt es
/// jeder Claude-Session über `CLAUDE_CODE_PLUGIN_DIRS` mit — ohne
/// `claude plugin install`, in jedem Profil, immer im Stand der App.
///
/// **Warum versionierte Ordner plus Symlink** (Prototyp 08.10.2026,
/// `docs/plans/whisperm8-plugin.md`): Claude Code überwacht einen Plugin-Ordner
/// und lädt JEDE laufende Session neu, sobald sich darin etwas ändert. Ein
/// App-Update, das in den laufenden Ordner kopiert, würde alle offenen Chats
/// mitten im Turn auf einen halb geschriebenen Stand umladen. Deshalb schreibt
/// die App jeden Stand in einen eigenen Ordner `versions/<hash>/whisperm8` und
/// biegt danach nur den Symlink `whisperm8` per `rename(2)` um. Ein verlinkter
/// Ordner wird am Ziel überwacht: laufende Sessions behalten ihren Stand, neue
/// bekommen den neuen.
struct WhisperM8ClaudePlugin {
    static let pluginName = "whisperm8"
    static let environmentKey = "CLAUDE_CODE_PLUGIN_DIRS"
    /// Alte Stände bleiben liegen, weil eine seit Tagen laufende Session noch
    /// auf ihnen steht; ein gelöschter Ordner ließe deren Mod still entladen.
    static let retainedVersions = 5

    var rootDirectory: URL
    var bundle: Bundle
    var appVersion: String
    var homeDirectory: URL

    init(
        rootDirectory: URL = WhisperM8ClaudePlugin.defaultRootDirectory(),
        bundle: Bundle = .module,
        appVersion: String = WhisperM8ClaudePlugin.bundleVersion(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.rootDirectory = rootDirectory
        self.bundle = bundle
        self.appVersion = appVersion
        self.homeDirectory = homeDirectory
    }

    static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("claude-plugin", isDirectory: true)
    }

    static func bundleVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0-dev"
    }

    enum PluginError: LocalizedError {
        case skeletonMissing
        case invalidManifest

        var errorDescription: String? {
            switch self {
            case .skeletonMissing: return "Plugin-Gerüst fehlt im App-Bundle (claude-plugin/)."
            case .invalidManifest: return "Plugin-Manifest im App-Bundle ist kein JSON-Objekt."
            }
        }
    }

    /// Der Pfad, den Sessions in `CLAUDE_CODE_PLUGIN_DIRS` bekommen: der
    /// Symlink auf den aktuellen Stand.
    var activeLinkURL: URL { rootDirectory.appendingPathComponent(Self.pluginName) }
    var versionsDirectory: URL { rootDirectory.appendingPathComponent("versions", isDirectory: true) }

    // MARK: Zusammensetzen

    /// Alle Dateien des Plugins, relativer Pfad → Inhalt. Rein (kein
    /// Schreiben), damit Inhalt und Hash testbar sind.
    func assembleFiles() throws -> [String: Data] {
        guard let skeleton = bundle.url(forResource: "claude-plugin", withExtension: nil) else {
            throw PluginError.skeletonMissing
        }
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: skeleton, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        let base = skeleton.resolvingSymlinksInPath().path
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            guard Self.ships(relative) else { continue }
            files[relative] = try Data(contentsOf: url)
        }
        // Das Manifest liegt im Bundle flach (SwiftPM kopiert keine
        // Punkt-Ordner verlässlich) und bekommt hier die App-Version.
        guard let manifest = files.removeValue(forKey: "plugin.json") else {
            throw PluginError.skeletonMissing
        }
        files[".claude-plugin/plugin.json"] = try stampedManifest(manifest)

        for definition in CLISkillExporter.SkillDefinition.plugin {
            let exporter = CLISkillExporter(definition: definition, homeDirectory: homeDirectory, bundle: bundle)
            let prefix = "skills/\(definition.name)/"
            files[prefix + "SKILL.md"] = Data(try exporter.skillMarkdown().utf8)
            for reference in definition.references {
                files[prefix + "references/\(reference.fileName)"] = Data(try exporter.referenceMarkdown(reference).utf8)
            }
            for asset in definition.assets {
                files[prefix + asset.relativePath] = Data(try exporter.assetContent(asset).utf8)
            }
        }
        return files
    }

    /// Tests der Mod (`claude plugin test`) und Finder-Reste gehören nicht ins
    /// ausgelieferte Plugin.
    static func ships(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        if name == ".DS_Store" { return false }
        if name.hasSuffix(".test.ts") || name.hasSuffix(".test.tsx") { return false }
        return !relativePath.split(separator: "/").contains("..")
    }

    private func stampedManifest(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.invalidManifest
        }
        object["name"] = Self.pluginName
        object["version"] = appVersion
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Inhaltshash über Pfade und Inhalte, unabhängig von der Reihenfolge.
    static func contentHash(_ files: [String: Data]) -> String {
        var hasher = SHA256()
        for path in files.keys.sorted() {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: files[path]!)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Ablegen

    struct InstallResult: Equatable {
        var linkURL: URL
        var versionDirectory: URL
        var hash: String
        /// `false`, wenn genau dieser Stand schon lag (Normalfall ab dem
        /// zweiten Start einer Version).
        var wroteNewVersion: Bool
    }

    /// Legt den aktuellen Stand ab und biegt den Symlink darauf. Idempotent:
    /// gleicher Inhalt → gleicher Ordner, nichts wird neu geschrieben.
    @discardableResult
    func install() throws -> InstallResult {
        let files = try assembleFiles()
        let hash = String(Self.contentHash(files).prefix(16))
        let fm = FileManager.default
        try fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)

        let versionRoot = versionsDirectory.appendingPathComponent(hash, isDirectory: true)
        let pluginDirectory = versionRoot.appendingPathComponent(Self.pluginName, isDirectory: true)
        var wrote = false
        if !fm.fileExists(atPath: pluginDirectory.appendingPathComponent(".claude-plugin/plugin.json").path) {
            // Erst vollständig in einen Staging-Ordner schreiben, dann in einem
            // Schritt umbenennen: ein Leser sieht nie einen halben Stand.
            let staging = versionsDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            let stagingPlugin = staging.appendingPathComponent(Self.pluginName, isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            for (relative, data) in files {
                let destination = stagingPlugin.appendingPathComponent(relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination)
            }
            if fm.fileExists(atPath: versionRoot.path) {
                try fm.removeItem(at: versionRoot)
            }
            try fm.moveItem(at: staging, to: versionRoot)
            wrote = true
        }
        // Mtime anheben: Aufräumen behält die zuletzt benutzten Stände.
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: versionRoot.path)

        try pointActiveLink(to: "versions/\(hash)/\(Self.pluginName)")
        pruneVersions(keeping: hash)
        return InstallResult(linkURL: activeLinkURL, versionDirectory: pluginDirectory, hash: hash, wroteNewVersion: wrote)
    }

    /// Ersetzt den Symlink atomar (neuer Link daneben, dann `rename(2)`).
    private func pointActiveLink(to relativeTarget: String) throws {
        let fm = FileManager.default
        let link = activeLinkURL
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == relativeTarget {
            return
        }
        // Ein echter Ordner an der Stelle (Altbestand) wird nicht überlinkt,
        // `rename` auf einen Ordner scheitert sonst.
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: link.path, isDirectory: &isDirectory), isDirectory.boolValue,
           (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try fm.removeItem(at: link)
        }
        let temporary = rootDirectory.appendingPathComponent(".\(Self.pluginName)-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: relativeTarget)
        guard rename(temporary.path, link.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private func pruneVersions(keeping current: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: versionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
        else { return }
        let versions = entries
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != current }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for stale in versions.dropFirst(Self.retainedVersions - 1) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: Umgebung für Sessions

    /// Die Variable für einen Claude-Launch. Leer, wenn das Plugin aus ist oder
    /// (noch) nicht abgelegt wurde — dann startet die Session wie früher. Ein
    /// vom User selbst gesetztes `CLAUDE_CODE_PLUGIN_DIRS` bleibt erhalten,
    /// unser Ordner kommt hinten dazu.
    static func launchEnvironment(
        enabled: Bool,
        linkURL: URL,
        inherited: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        guard enabled, fileExists(linkURL.appendingPathComponent(".claude-plugin/plugin.json").path) else {
            return [:]
        }
        let ours = linkURL.path
        let existing = (inherited ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != ours }
        return [environmentKey: (existing + [ours]).joined(separator: ":")]
    }
}

// MARK: - Migration der losen Skill-Kopien

/// Räumt beim ersten Start mit Plugin die bisherigen Kopien aus
/// `~/.claude/skills` weg — sonst gäbe es jeden Skill doppelt (`jarvis` und
/// `whisperm8:jarvis`), und der kurze Aufruf `/jarvis` träfe die lose Kopie.
/// Nichts wird gelöscht: alles wandert nach
/// `~/.claude/skills/.whisperm8-backup/<zeitstempel>/`. Lokal geänderte Skills
/// (Stempel belegt eine Änderung durch den User) und Symlinks bleiben liegen.
struct ClaudePluginSkillMigration {
    var homeDirectory: URL
    var bundle: Bundle

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, bundle: Bundle = .module) {
        self.homeDirectory = homeDirectory
        self.bundle = bundle
    }

    struct Outcome: Equatable {
        var moved: [String] = []
        var kept: [String] = []
        var backupDirectory: URL?
    }

    var skillsDirectory: URL { homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true) }

    func run(now: Date = Date()) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = skillsDirectory
            .appendingPathComponent(".whisperm8-backup", isDirectory: true)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)

        for definition in CLISkillExporter.SkillDefinition.plugin {
            let exporter = CLISkillExporter(definition: definition, homeDirectory: homeDirectory, bundle: bundle)
            let directory = exporter.claudeCodeSkillURL.deletingLastPathComponent()
            guard let attributes = try? fm.attributesOfItem(atPath: directory.path) else { continue }
            if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                outcome.kept.append("\(definition.name) (Symlink)")
                continue
            }
            // `jarvis` hatte nie einen Stempel und kam nie aus der App: immer
            // sichern. Für die übrigen belegt der Stempel eine lokale Änderung.
            if definition != .jarvis, exporter.installState() == .modifiedLocally {
                outcome.kept.append("\(definition.name) (lokal geändert)")
                continue
            }
            do {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                try fm.moveItem(at: directory, to: backup.appendingPathComponent(definition.name, isDirectory: true))
                outcome.moved.append(definition.name)
                outcome.backupDirectory = backup
            } catch {
                outcome.kept.append("\(definition.name) (\(error.localizedDescription))")
            }
        }
        return outcome
    }
}

// MARK: - App-Start

enum ClaudePluginBootstrap {
    /// Beim App-Start, VOR dem ersten PTY-Spawn: Plugin ablegen und einmalig
    /// die losen Skills wegräumen. Scheitert das Ablegen, startet jede Session
    /// wie früher (ohne Variable) — die Migration läuft dann ebenfalls nicht,
    /// damit niemand ohne Skills dasteht.
    static func run(preferences: AppPreferences = .shared) {
        guard preferences.isClaudePluginEnabled else {
            Logger.info("claude_plugin_disabled")
            return
        }
        let plugin = WhisperM8ClaudePlugin()
        do {
            let result = try plugin.install()
            Logger.info("claude_plugin_installed hash=\(result.hash) new=\(result.wroteNewVersion) link=\(result.linkURL.path)")
        } catch {
            Logger.info("claude_plugin_install_failed error=\(error.localizedDescription)")
            return
        }
        guard !preferences.claudePluginSkillMigrationDone else { return }
        let outcome = ClaudePluginSkillMigration().run()
        Logger.info("claude_plugin_skill_migration moved=\(outcome.moved.joined(separator: ",")) kept=\(outcome.kept.joined(separator: ",")) backup=\(outcome.backupDirectory?.path ?? "-")")
        preferences.claudePluginSkillMigrationDone = true
    }

    /// Variable für einen Claude-Launch (siehe `AgentCommandBuilder`). Nur im
    /// echten App-Prozess: unter `swift test` läge sonst der Plugin-Ordner des
    /// Entwicklerrechners in jedem Launch-Test.
    static func launchEnvironment(preferences: AppPreferences = .shared) -> [String: String] {
        guard Bundle.main.bundleIdentifier == "com.whisperm8.app" else { return [:] }
        return WhisperM8ClaudePlugin.launchEnvironment(
            enabled: preferences.isClaudePluginEnabled,
            linkURL: WhisperM8ClaudePlugin.defaultRootDirectory().appendingPathComponent(WhisperM8ClaudePlugin.pluginName),
            inherited: LoginShellEnvironment.shared.processEnvironment()[WhisperM8ClaudePlugin.environmentKey]
        )
    }
}
