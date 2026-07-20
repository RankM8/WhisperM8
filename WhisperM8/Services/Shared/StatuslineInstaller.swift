import CryptoKit
import Foundation

/// Installiert die gebündelten WhisperM8-Statuslines für Claude Code:
/// die Skripte nach `~/.claude/statusline-command.sh` und
/// `~/.claude/subagent-statusline.sh` sowie die passenden Settings-Einträge
/// in die settings.json des Main-Configs UND aller Account-Profile.
///
/// Schutzregeln analog `ClaudeGPTAgentDefinition`: eine vorhandene
/// Skript-Datei ohne unseren Marker ist ein User-eigenes Skript und wird
/// nur mit explizitem `force` ersetzt. Ein fremder `statusLine`-Eintrag
/// (anderes Command) wird ebenfalls nur mit `force` umgebogen; übrige
/// settings.json-Schlüssel bleiben in jedem Fall unangetastet.
struct StatuslineInstaller {
    static let managedMarker = "managed-by: whisperm8-statusline"
    static let resourceName = "whisperm8-statusline"
    static let scriptFileName = "statusline-command.sh"
    static let subagentResourceName = "whisperm8-subagent-statusline"
    static let subagentScriptFileName = "subagent-statusline.sh"

    var homeDirectory: URL
    var bundle: Bundle
    /// settings.json-Ziele: Main-Config plus alle Account-Profile.
    /// Im Test überschreibbar (Temp-Verzeichnisse).
    var settingsDirectories: () -> [URL]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        // .module, nicht .main: die .sh ist eine SwiftPM-Ressource und liegt
        // in Contents/Resources/WhisperM8_WhisperM8.bundle/ — Bundle.main
        // sucht nur flach in Contents/Resources und findet sie nie.
        bundle: Bundle = .module,
        settingsDirectories: (() -> [URL])? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.bundle = bundle
        self.settingsDirectories = settingsDirectories ?? {
            let mainDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
            let profileDirectories = ClaudeAccountProfiles(homeDirectory: homeDirectory)
                .profiles()
                .map(\.configDir)
            var seenPaths = Set<String>()
            return ([mainDirectory] + profileDirectories).filter {
                seenPaths.insert($0.standardizedFileURL.path).inserted
            }
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case resourceMissing
        case foreignScript(path: String)
        case corruptSettings(path: String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "Eine Statusline-Ressource fehlt im App-Bundle."
            case .foreignScript(let path):
                return "Am Zielpfad liegt ein eigenes Statusline-Skript (\(path)). Installation würde es ersetzen."
            case .corruptSettings(let path):
                return "\(path) ist kein lesbares JSON — Datei bitte prüfen; sie wird nicht überschrieben."
            }
        }
    }

    /// Zielpfad des Skripts. Bewusst immer im Main-Config-Dir — die
    /// settings.json der Profile referenzieren denselben absoluten Pfad,
    /// damit es genau EINE zu pflegende Skript-Kopie gibt.
    var scriptURL: URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(Self.scriptFileName, isDirectory: false)
    }

    var subagentScriptURL: URL {
        scriptURL.deletingLastPathComponent()
            .appendingPathComponent(Self.subagentScriptFileName, isDirectory: false)
    }

    /// Der Command-String, der in settings.json eingetragen wird.
    /// `~`-Schreibweise, damit der Eintrag maschinenübergreifend lesbar bleibt.
    var settingsCommand: String { "~/.claude/\(Self.scriptFileName)" }
    var subagentSettingsCommand: String { "~/.claude/\(Self.subagentScriptFileName)" }

    func bundledScript() throws -> String {
        try bundledScript(resourceName: Self.resourceName)
    }

    func bundledSubagentScript() throws -> String {
        try bundledScript(resourceName: Self.subagentResourceName)
    }

    private func bundledScript(resourceName: String) throws -> String {
        guard let url = bundle.url(forResource: resourceName, withExtension: "sh"),
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.isEmpty else {
            throw InstallError.resourceMissing
        }
        return content
    }

    // MARK: - Status (für die Settings-Anzeige)

    enum Status: Equatable {
        /// Nichts installiert.
        case missing
        /// Unser Skript liegt in der gebündelten Fassung vor.
        case current
        /// Unser Skript (Marker vorhanden), aber ein sicher ersetzbarer älterer Stand.
        case outdated
        /// Unser Skript wurde seit der letzten verwalteten Installation lokal geändert.
        case modifiedLocally
        /// Per `make skills` aus dem Repo synchronisiert und mindestens so neu
        /// wie die gebündelte Fassung.
        case repoSynced
        /// Am Zielpfad liegt ein Skript ohne Marker (User-eigen).
        case foreign
    }

    /// Install-Stempel neben dem Skript. `bundled` darf fehlen, wenn der
    /// Repo-Sync keine installierte App-Fassung lesen konnte.
    struct InstallStamp: Codable, Equatable {
        var source: String
        var updatedAt: String
        var installed: [String: String]
        var bundled: [String: String]?

        static let sourceBundle = "bundle"
        static let sourceResources = "resources"
    }

    /// Pfad des Install-Stempels: `~/.claude/.whisperm8-statusline-state.json`.
    var installStampURL: URL {
        scriptURL.deletingLastPathComponent()
            .appendingPathComponent(".whisperm8-statusline-state.json")
    }

    func bundledHashes() throws -> [String: String] {
        [
            Self.scriptFileName: Self.sha256(of: try bundledScript()),
            Self.subagentScriptFileName: Self.sha256(of: try bundledSubagentScript()),
        ]
    }

    func installedHashes() -> [String: String]? {
        var hashes: [String: String] = [:]
        if let script = try? String(contentsOf: scriptURL, encoding: .utf8) {
            hashes[Self.scriptFileName] = Self.sha256(of: script)
        }
        if let script = try? String(contentsOf: subagentScriptURL, encoding: .utf8) {
            hashes[Self.subagentScriptFileName] = Self.sha256(of: script)
        }
        return hashes.isEmpty ? nil : hashes
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

    func status() -> Status {
        let mainScript = try? String(contentsOf: scriptURL, encoding: .utf8)
        let subagentScript = try? String(contentsOf: subagentScriptURL, encoding: .utf8)
        guard mainScript != nil || subagentScript != nil else { return .missing }
        if let mainScript, !mainScript.contains(Self.managedMarker) { return .foreign }
        if let subagentScript, !subagentScript.contains(Self.managedMarker) { return .foreign }

        var installed: [String: String] = [:]
        if let mainScript {
            installed[Self.scriptFileName] = Self.sha256(of: mainScript)
        }
        if let subagentScript {
            installed[Self.subagentScriptFileName] = Self.sha256(of: subagentScript)
        }
        guard let bundled = try? bundledHashes() else { return .outdated }
        if installed == bundled {
            if let stamp = readInstallStamp(),
               Set(stamp.installed.keys) != Set(bundled.keys) {
                return .outdated
            }
            return .current
        }
        guard let stamp = readInstallStamp() else { return .outdated }

        // Alt-Stempel kennen die neu hinzugekommene Subagent-Datei noch nicht.
        // Nur Abweichungen an damals tatsächlich installierten Dateien sind
        // lokale Änderungen; neue oder inzwischen gebündelte Keys bedeuten Update.
        guard stamp.installed.allSatisfy({ installed[$0.key] == $0.value }) else {
            return .modifiedLocally
        }
        let unstampedDrift = installed.contains { key, hash in
            stamp.installed[key] == nil && bundled[key] != hash
        }
        if unstampedDrift { return .modifiedLocally }
        if stamp.source == InstallStamp.sourceResources,
           Set(stamp.installed.keys) == Set(bundled.keys),
           stamp.bundled == nil || stamp.bundled == bundled {
            return .repoSynced
        }
        return .outdated
    }

    static func sha256(of content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func foreignScriptURL() -> URL? {
        for url in [scriptURL, subagentScriptURL] {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               !content.contains(Self.managedMarker) {
                return url
            }
        }
        return nil
    }

    /// Anzahl der settings.json, deren beide Statusline-Einträge bereits auf
    /// unsere Skripte zeigen. Symlinks (Profil → Main) lesen transparent durch.
    func wiredSettingsCount() -> Int {
        settingsDirectories().filter { directory in
            guard let statusEntry = readSettingsEntry("statusLine", in: directory),
                  let subagentEntry = readSettingsEntry("subagentStatusLine", in: directory) else {
                return false
            }
            return (statusEntry["command"] as? String) == settingsCommand
                && (subagentEntry["command"] as? String) == subagentSettingsCommand
        }.count
    }

    /// Anzahl der settings.json mit mindestens einem FREMDEM Statusline-Command
    /// (weder leer noch unseres) — die UI bestätigt die Ersetzung pro Config.
    func foreignSettingsCount() -> Int {
        settingsDirectories().filter { directory in
            guard !settingsIsSymlink(in: directory) else { return false }
            let statusCommand = readSettingsEntry("statusLine", in: directory)?["command"] as? String
            let subagentCommand = readSettingsEntry("subagentStatusLine", in: directory)?["command"] as? String
            return (statusCommand != nil && statusCommand != settingsCommand)
                || (subagentCommand != nil && subagentCommand != subagentSettingsCommand)
        }.count
    }

    // MARK: - Installation

    /// Installiert beide Skripte + settings.json-Einträge.
    /// - `replaceForeignScript`: ersetzt auch markerlose User-Skripte.
    /// - `replaceForeignSettings`: biegt fremde Statusline-Commands um.
    /// Beides sind GETRENNTE Entscheidungen — die UI bestätigt sie einzeln
    /// (Review-Befund 2026-07-19: force darf fremde Einträge nicht als
    /// Beifang der Skript-Ersetzung kapern).
    @discardableResult
    func install(
        replaceForeignScript: Bool = false,
        replaceForeignSettings: Bool = false
    ) throws -> URL {
        let content = try bundledScript()
        let subagentContent = try bundledSubagentScript()

        if !replaceForeignScript, let foreignURL = foreignScriptURL() {
            throw InstallError.foreignScript(path: foreignURL.path)
        }

        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for (content, url) in [(content, scriptURL), (subagentContent, subagentScriptURL)] {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }

        for directory in settingsDirectories() {
            try wireSettings(in: directory, overwriteForeignEntry: replaceForeignSettings)
        }

        // Stempel für den Drei-Wege-Status: installierter Stand == Bundle-Stand.
        let hashes = try bundledHashes()
        try writeInstallStamp(InstallStamp(
            source: InstallStamp.sourceBundle,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            installed: hashes,
            bundled: hashes
        ))
        Logger.debug("[Statusline] installiert: \(scriptURL.path)")
        return scriptURL
    }

    // MARK: - settings.json

    private func settingsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Profile teilen ihre settings.json als Symlink auf Main
    /// (`ClaudeAccountProfiles.sharedItems`). Ein atomarer Write würde den
    /// Symlink durch eine echte Datei ersetzen und das Profil dauerhaft von
    /// den gemeinsamen Settings abkoppeln (Review-Befund 2026-07-19, auf
    /// realen Profilen verifiziert) — Symlinks werden deshalb NIE beschrieben;
    /// der Eintrag kommt über das Symlink-Ziel (Main) an.
    private func settingsIsSymlink(in directory: URL) -> Bool {
        let values = try? settingsURL(in: directory)
            .resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func readSettingsEntry(_ key: String, in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL(in: directory)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? [String: Any]
    }

    /// Setzt den statusLine-Eintrag, ohne andere Schlüssel anzufassen.
    /// Existiert bereits ein Eintrag mit anderem Command, bleibt er ohne
    /// `overwriteForeignEntry` stehen (kein stilles Kapern einer fremden
    /// Statusline). Unparsebares JSON bricht ab, statt die Datei auf einen
    /// nur-statusLine-Inhalt zu reduzieren.
    private func wireSettings(in directory: URL, overwriteForeignEntry: Bool) throws {
        guard !settingsIsSymlink(in: directory) else { return }

        let url = settingsURL(in: directory)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.corruptSettings(path: url.path)
            }
            object = existing
        } else if !FileManager.default.fileExists(atPath: directory.path) {
            // Kein Config-Dir → kein Profil-Root, nichts anlegen.
            return
        }

        let entries = [
            (key: "statusLine", command: settingsCommand),
            (key: "subagentStatusLine", command: subagentSettingsCommand),
        ]
        for entry in entries {
            if let existing = object[entry.key] as? [String: Any],
               let command = existing["command"] as? String,
               command != entry.command, !overwriteForeignEntry {
                continue
            }
            object[entry.key] = ["type": "command", "command": entry.command]
        }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
