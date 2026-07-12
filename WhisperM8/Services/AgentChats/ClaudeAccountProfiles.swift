import Foundation

/// Ein Claude-Code-Account-Profil. „main" ist das historische `~/.claude`
/// (bleibt unangetastet); Zusatz-Accounts leben je in einem eigenen
/// `CLAUDE_CONFIG_DIR` unter `~/.claude-profiles/<name>/` — Claude Code
/// verwaltet dort seinen eigenen Keychain-Login, WhisperM8 fasst nie
/// Credentials an. Gleiche Struktur wie das `ccs`-CLI (ccs.zsh), damit
/// Terminal und App dieselben Profile teilen.
struct ClaudeAccountProfile: Identifiable, Equatable {
    var name: String
    var configDir: URL
    var emailAddress: String?
    var organizationName: String?
    var displayName: String?

    var id: String { name }
    var isMain: Bool { name == ClaudeAccountProfiles.mainProfileName }
    /// Eingeloggt = die Profil-`.claude.json` traegt einen `oauthAccount`.
    var isLoggedIn: Bool { emailAddress != nil }
}

/// Letzter bekannter Limit-Stand eines Accounts, gelesen aus dem Cache der
/// Statusline (`/tmp/claude-usage-cache-<profil>.json`). Nur Anzeige-Daten —
/// die App fragt selbst keine Anthropic-Endpoints ab.
struct ClaudeAccountUsageSnapshot: Equatable {
    var fiveHourUtilization: Double?
    var sevenDayUtilization: Double?
    var fetchedAt: Date
}

/// Verwaltung der Claude-Account-Profile (Discovery, aktives Profil,
/// Env-Injektion). Dateibasiert und zustandslos — SSoT sind die Verzeichnisse
/// und die `.active`-Datei, die auch das `ccs`-CLI liest/schreibt.
struct ClaudeAccountProfiles {
    static let mainProfileName = "main"

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var fileManager: FileManager = .default

    var profilesRoot: URL {
        homeDirectory.appendingPathComponent(".claude-profiles", isDirectory: true)
    }

    private var activeFileURL: URL {
        profilesRoot.appendingPathComponent(".active", isDirectory: false)
    }

    // MARK: - Discovery

    /// Alle Profile, `main` immer zuerst. Zusatzprofile = Unterordner von
    /// `~/.claude-profiles` (versteckte Ordner ausgenommen).
    func profiles() -> [ClaudeAccountProfile] {
        var result = [profile(named: Self.mainProfileName)]
        let entries = (try? fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let names = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
        result.append(contentsOf: names.map { profile(named: $0) })
        return result
    }

    func profile(named name: String) -> ClaudeAccountProfile {
        var profile = ClaudeAccountProfile(name: name, configDir: configDir(forProfile: name))
        if let account = accountInfo(forProfile: name) {
            profile.emailAddress = account.email
            profile.organizationName = account.organization
            profile.displayName = account.displayName
        }
        return profile
    }

    func configDir(forProfile name: String) -> URL {
        if name == Self.mainProfileName {
            return homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        return profilesRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Die `.claude.json` mit den `oauthAccount`-Metadaten. Fuer `main` liegt
    /// sie historisch in `$HOME`, fuer Profile im Config-Dir.
    func claudeJSONURL(forProfile name: String) -> URL {
        if name == Self.mainProfileName {
            return homeDirectory.appendingPathComponent(".claude.json", isDirectory: false)
        }
        return configDir(forProfile: name).appendingPathComponent(".claude.json", isDirectory: false)
    }

    private func accountInfo(forProfile name: String) -> (email: String?, organization: String?, displayName: String?)? {
        guard let data = try? Data(contentsOf: claudeJSONURL(forProfile: name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else {
            return nil
        }
        return (
            account["emailAddress"] as? String,
            account["organizationName"] as? String,
            account["displayName"] as? String
        )
    }

    // MARK: - Aktives Profil

    /// Aktives Profil aus `.active`. Fehlt die Datei, zeigt sie auf ein
    /// geloeschtes Profil oder ist sie leer → `main`.
    func activeProfileName() -> String {
        guard let raw = try? String(contentsOf: activeFileURL, encoding: .utf8) else {
            return Self.mainProfileName
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return Self.mainProfileName }
        guard name == Self.mainProfileName
                || fileManager.fileExists(atPath: configDir(forProfile: name).path) else {
            return Self.mainProfileName
        }
        return name
    }

    /// Wie `activeProfileName()`, aber `nil` fuer `main` — direkt als
    /// `claudeProfileName`-Stempel fuer neue Sessions verwendbar.
    func activeProfileNameOrNil() -> String? {
        let name = activeProfileName()
        return name == Self.mainProfileName ? nil : name
    }

    func setActiveProfile(_ name: String) throws {
        try fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        try name.write(to: activeFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Env-Injektion

    /// `CLAUDE_CONFIG_DIR`-Override fuer einen Launch. `nil` fuer `main`
    /// (Claude nutzt dann sein Default-`~/.claude`) und fuer Profile, deren
    /// Verzeichnis nicht (mehr) existiert — ein Resume unter einem falschen,
    /// frisch angelegten Config-Dir waere schlimmer als der Main-Fallback.
    func environmentOverrides(forProfile name: String?) -> [String: String] {
        guard let name, name != Self.mainProfileName else { return [:] }
        let dir = configDir(forProfile: name)
        guard fileManager.fileExists(atPath: dir.path) else {
            Logger.agentStore.warning("claude_profile_missing name=\(name, privacy: .public) — launch faellt auf main zurueck")
            return [:]
        }
        return ["CLAUDE_CONFIG_DIR": dir.path]
    }

    // MARK: - Transcript-Roots

    /// Alle `projects/`-Roots (main + Profile) fuer Indexer, Locator und
    /// FSEvents-Monitor. Reihenfolge: main zuerst.
    func claudeProjectsRoots() -> [URL] {
        profiles().map { $0.configDir.appendingPathComponent("projects", isDirectory: true) }
    }

    /// Ordnet einen Transcript-Pfad seinem Profil zu (`nil` = main).
    /// Pure — Grundlage fuer das Profil-Tagging im Indexer.
    static func profileName(forTranscriptPath path: String) -> String? {
        let marker = "/.claude-profiles/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let name = String(rest[..<slash])
        return name.isEmpty ? nil : name
    }

    // MARK: - Profil anlegen

    /// Diese Eintraege teilen alle Profile mit `~/.claude` (Symlinks) — die
    /// gleiche Liste wie in `ccs.zsh`. Getrennt bleiben bewusst: Credentials,
    /// `projects/`, `history.jsonl`.
    static let sharedItems = [
        "settings.json", "keybindings.json", "statusline-command.sh",
        "commands", "agents", "skills", "plugins", "CLAUDE.md",
    ]

    enum CreateError: LocalizedError, Equatable {
        case invalidName(String)
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "Invalid profile name “\(name)”. Use letters, digits, - and _; “main” is reserved."
            case .alreadyExists(let name):
                return "Profile “\(name)” already exists."
            }
        }
    }

    static func isValidProfileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != mainProfileName
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Legt das Profil-Verzeichnis samt Shared-Symlinks an. Der Login selbst
    /// bleibt interaktiv (Browser-OAuth) — der Caller startet dafuer eine
    /// Claude-Session mit diesem Config-Dir.
    @discardableResult
    func createProfile(named name: String) throws -> ClaudeAccountProfile {
        guard Self.isValidProfileName(name) else { throw CreateError.invalidName(name) }
        let dir = configDir(forProfile: name)
        guard !fileManager.fileExists(atPath: dir.path) else { throw CreateError.alreadyExists(name) }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let mainDir = configDir(forProfile: Self.mainProfileName)
        for item in Self.sharedItems {
            let source = mainDir.appendingPathComponent(item)
            let target = dir.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.createSymbolicLink(at: target, withDestinationURL: source)
        }
        Logger.agentStore.notice("claude_profile_created name=\(name, privacy: .public)")
        return profile(named: name)
    }

    // MARK: - Usage-Snapshot (Anzeige)

    /// Cache-Pfad identisch zur Statusline (`statusline-command.sh`) — bewusst
    /// literal `/tmp`, nicht `NSTemporaryDirectory()` (App-Sandbox-Pfad).
    func usageSnapshot(forProfile name: String) -> ClaudeAccountUsageSnapshot? {
        let path = "/tmp/claude-usage-cache-\(name).json"
        guard let data = fileManager.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let mtime = (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        func utilization(_ key: String) -> Double? {
            guard let window = obj[key] as? [String: Any] else { return nil }
            return (window["utilization"] as? Double) ?? (window["used_percentage"] as? Double)
        }
        let fiveHour = utilization("five_hour")
        let sevenDay = utilization("seven_day")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeAccountUsageSnapshot(
            fiveHourUtilization: fiveHour,
            sevenDayUtilization: sevenDay,
            fetchedAt: mtime
        )
    }
}
