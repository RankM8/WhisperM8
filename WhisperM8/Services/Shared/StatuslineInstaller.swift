import Foundation

/// Installiert die gebündelte WhisperM8-Statusline für Claude Code:
/// das Skript nach `~/.claude/statusline-command.sh` und den
/// `statusLine`-Eintrag in die settings.json des Main-Configs UND aller
/// Account-Profile (alle zeigen auf dasselbe Skript — es liest den
/// Profil-Kontext selbst über CLAUDE_CONFIG_DIR).
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

    var homeDirectory: URL
    var bundle: Bundle
    /// settings.json-Ziele: Main-Config plus alle Account-Profile.
    /// Im Test überschreibbar (Temp-Verzeichnisse).
    var settingsDirectories: () -> [URL]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main,
        settingsDirectories: (() -> [URL])? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.bundle = bundle
        self.settingsDirectories = settingsDirectories ?? {
            var directories = [
                homeDirectory.appendingPathComponent(".claude", isDirectory: true)
            ]
            directories.append(contentsOf: ClaudeAccountProfiles().profiles().map(\.configDir))
            return directories
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case resourceMissing
        case foreignScript(path: String)
        case corruptSettings(path: String)

        var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "Statusline-Ressource fehlt im App-Bundle (\(StatuslineInstaller.resourceName).sh)."
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

    /// Der Command-String, der in settings.json eingetragen wird.
    /// `~`-Schreibweise, damit der Eintrag maschinenübergreifend lesbar bleibt.
    var settingsCommand: String { "~/.claude/\(Self.scriptFileName)" }

    func bundledScript() throws -> String {
        guard let url = bundle.url(forResource: Self.resourceName, withExtension: "sh"),
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
        /// Unser Skript (Marker vorhanden), aber älterer/abweichender Stand.
        case outdated
        /// Am Zielpfad liegt ein Skript ohne Marker (User-eigen).
        case foreign
    }

    func status() -> Status {
        guard let installed = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            return .missing
        }
        guard installed.contains(Self.managedMarker) else { return .foreign }
        guard let bundled = try? bundledScript(), installed == bundled else {
            return .outdated
        }
        return .current
    }

    /// Anzahl der settings.json, deren statusLine bereits auf unser Skript
    /// zeigt. Symlinks (Profil → Main) lesen transparent durch und zählen
    /// damit automatisch als verdrahtet, sobald Main verdrahtet ist.
    func wiredSettingsCount() -> Int {
        settingsDirectories().filter { directory in
            guard let entry = readStatusLineEntry(in: directory) else { return false }
            return (entry["command"] as? String) == settingsCommand
        }.count
    }

    /// Anzahl der settings.json mit FREMDEM statusLine-Command (weder leer
    /// noch unseres) — die UI braucht dafür eine eigene Bestätigung.
    func foreignSettingsCount() -> Int {
        settingsDirectories().filter { directory in
            guard !settingsIsSymlink(in: directory),
                  let entry = readStatusLineEntry(in: directory),
                  let command = entry["command"] as? String else { return false }
            return command != settingsCommand
        }.count
    }

    // MARK: - Installation

    /// Installiert Skript + settings.json-Einträge.
    /// - `replaceForeignScript`: ersetzt auch ein markerloses User-Skript.
    /// - `replaceForeignSettings`: biegt fremde statusLine-Commands um.
    /// Beides sind GETRENNTE Entscheidungen — die UI bestätigt sie einzeln
    /// (Review-Befund 2026-07-19: force darf fremde Einträge nicht als
    /// Beifang der Skript-Ersetzung kapern).
    @discardableResult
    func install(
        replaceForeignScript: Bool = false,
        replaceForeignSettings: Bool = false
    ) throws -> URL {
        let content = try bundledScript()

        if !replaceForeignScript, status() == .foreign {
            throw InstallError.foreignScript(path: scriptURL.path)
        }

        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )

        for directory in settingsDirectories() {
            try wireSettings(in: directory, overwriteForeignEntry: replaceForeignSettings)
        }
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

    private func readStatusLineEntry(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL(in: directory)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["statusLine"] as? [String: Any]
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

        if let entry = object["statusLine"] as? [String: Any],
           let command = entry["command"] as? String,
           command != settingsCommand, !overwriteForeignEntry {
            return
        }

        object["statusLine"] = ["type": "command", "command": settingsCommand]
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
