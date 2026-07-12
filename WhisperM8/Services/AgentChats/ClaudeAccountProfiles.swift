import CryptoKit
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
    /// Menschlich lesbarer Abo-Plan („Max 20×", „Team Premium", „Pro", …),
    /// abgeleitet aus den oauthAccount-Feldern. `nil` wenn nicht eingeloggt.
    var planDisplayName: String?

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
            profile.planDisplayName = account.plan
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

    private func accountInfo(forProfile name: String) -> (email: String?, organization: String?, displayName: String?, plan: String?)? {
        guard let data = try? Data(contentsOf: claudeJSONURL(forProfile: name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else {
            return nil
        }
        return (
            account["emailAddress"] as? String,
            account["organizationName"] as? String,
            account["displayName"] as? String,
            Self.planLabel(
                organizationType: account["organizationType"] as? String,
                seatTier: account["seatTier"] as? String,
                userRateLimitTier: account["userRateLimitTier"] as? String,
                organizationRateLimitTier: account["organizationRateLimitTier"] as? String
            )
        )
    }

    /// Leitet den Anzeige-Plan aus den oauthAccount-Feldern ab. Beobachtete
    /// Kombinationen (2026-07-12): `claude_max` + Org-Tier `…max_20x`/`…max_5x`
    /// → „Max 20×"/„Max 5×"; `claude_team` + `seatTier=team_tier_1` (User-Tier
    /// `…max_5x`) → „Team Premium". Unbekannte Werte werden lesbar
    /// durchgereicht statt verschluckt.
    static func planLabel(
        organizationType: String?,
        seatTier: String?,
        userRateLimitTier: String?,
        organizationRateLimitTier: String?
    ) -> String? {
        guard let organizationType, !organizationType.isEmpty else { return nil }

        // „20×"/„5×" aus dem spezifischsten Rate-Limit-Tier ziehen
        let tier = userRateLimitTier ?? organizationRateLimitTier ?? ""
        let multiplier: String? = {
            guard let range = tier.range(of: #"max_(\d+)x"#, options: .regularExpression) else { return nil }
            return tier[range].replacingOccurrences(of: "max_", with: "").replacingOccurrences(of: "x", with: "×")
        }()

        switch organizationType {
        case "claude_max":
            return multiplier.map { "Max \($0)" } ?? "Max"
        case "claude_pro":
            return "Pro"
        case "claude_team":
            switch seatTier {
            case "team_tier_1":
                return "Team Premium"
            case nil, "":
                return "Team"
            case .some(let raw):
                return "Team \(raw.replacingOccurrences(of: "team_tier_", with: "Tier "))"
            }
        case "claude_enterprise":
            return "Enterprise"
        default:
            // z. B. "claude_free" → "Free"
            return organizationType
                .replacingOccurrences(of: "claude_", with: "")
                .capitalized
        }
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
        writeKeychainServiceMarker(forProfile: name)
        return profile(named: name)
    }

    // MARK: - Keychain-Service

    /// Keychain-Service-Name eines Profils. Claude Code benutzt fuer das
    /// Default-`~/.claude` den blanken Namen und haengt fuer abweichende
    /// `CLAUDE_CONFIG_DIR`s die ersten 8 Hex-Zeichen von
    /// `sha256(<config-dir-pfad>)` an — empirisch verifiziert (v2.1.207,
    /// 2026-07-12) gegen zwei unabhaengige Profile.
    func keychainService(forProfile name: String) -> String {
        guard name != Self.mainProfileName else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir(forProfile: name).path.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(suffix)"
    }

    /// Hinterlegt den (berechneten) Service-Namen als `.keychain-service` im
    /// Profil — die Statusline (`statusline-command.sh`) und `ccs status`
    /// lesen diese Datei. Heilt auch Profile nach, die vor dieser Logik
    /// angelegt wurden. `main` braucht keinen Marker.
    func writeKeychainServiceMarker(forProfile name: String) {
        guard name != Self.mainProfileName else { return }
        let dir = configDir(forProfile: name)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        let marker = dir.appendingPathComponent(".keychain-service")
        try? keychainService(forProfile: name).write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Profil umbenennen

    enum RenameError: LocalizedError, Equatable {
        case invalidName(String)
        case profileMissing(String)
        case targetExists(String)
        case keychainMoveFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "Invalid profile name “\(name)”. Use letters, digits, - and _; “main” is reserved."
            case .profileMissing(let name):
                return "Account profile “\(name)” does not exist."
            case .targetExists(let name):
                return "A profile named “\(name)” already exists."
            case .keychainMoveFailed(let detail):
                return "Could not move the Keychain login to the new profile name: \(detail)"
            }
        }
    }

    /// Fuer Tests injizierbarer Runner fuer `/usr/bin/security`-Aufrufe.
    /// Rueckgabe: (exitCode, stdout).
    var securityRunner: ([String]) -> (Int32, String) = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Benennt ein Profil um — inklusive Keychain-Umzug, damit der Login
    /// erhalten bleibt: der Service-Name haengt am Verzeichnis-Pfad
    /// (sha256-Suffix), ein blosser Ordner-Rename wuerde Claude also vom
    /// Login trennen. Ablauf: Secret lesen → Ordner umbenennen → Item unter
    /// neuem Namen anlegen → altes Item loeschen. Schlaegt der Keychain-Teil
    /// fehl, wird der Ordner-Rename zurueckgerollt.
    ///
    /// Der Caller muss sicherstellen, dass keine Session dieses Profils
    /// laeuft, und danach die Session-Stempel im Store umziehen
    /// (`AgentSessionStore.renameClaudeSessionProfiles`).
    func renameProfile(from oldName: String, to newName: String) throws {
        guard oldName != Self.mainProfileName else { throw RenameError.invalidName(oldName) }
        guard Self.isValidProfileName(newName) else { throw RenameError.invalidName(newName) }
        let oldDir = configDir(forProfile: oldName)
        let newDir = configDir(forProfile: newName)
        guard fileManager.fileExists(atPath: oldDir.path) else { throw RenameError.profileMissing(oldName) }
        guard !fileManager.fileExists(atPath: newDir.path) else { throw RenameError.targetExists(newName) }

        let oldService = keychainService(forProfile: oldName)
        // Secret VOR dem Rename lesen (Exit != 0 = kein Login vorhanden — dann
        // ist nichts zu retten und der reine Ordner-Rename reicht).
        let (readStatus, secret) = securityRunner(["find-generic-password", "-s", oldService, "-w"])
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)

        try fileManager.moveItem(at: oldDir, to: newDir)

        if readStatus == 0, !trimmedSecret.isEmpty {
            let newService = keychainService(forProfile: newName)
            let account = NSUserName()
            let (addStatus, _) = securityRunner([
                "add-generic-password", "-a", account, "-s", newService,
                "-l", newService, "-w", trimmedSecret, "-U",
            ])
            guard addStatus == 0 else {
                // Rollback: Ordner zurueck, Login bleibt am alten Namen intakt.
                try? fileManager.moveItem(at: newDir, to: oldDir)
                throw RenameError.keychainMoveFailed("security add-generic-password exit \(addStatus)")
            }
            _ = securityRunner(["delete-generic-password", "-s", oldService])
        }

        writeKeychainServiceMarker(forProfile: newName)

        // Aktives Profil nachziehen, falls es auf den alten Namen zeigte.
        if (try? String(contentsOf: activeFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == oldName {
            try? setActiveProfile(newName)
        }
        Logger.agentStore.notice("claude_profile_renamed from=\(oldName, privacy: .public) to=\(newName, privacy: .public)")
    }

    // MARK: - Chat zu anderem Account verschieben

    enum MoveError: LocalizedError, Equatable {
        case targetProfileMissing(String)
        case targetTranscriptExists(String)

        var errorDescription: String? {
            switch self {
            case .targetProfileMissing(let name):
                return "Account profile “\(name)” does not exist."
            case .targetTranscriptExists(let path):
                return "A transcript with this session ID already exists in the target account: \(path)"
            }
        }
    }

    /// Verschiebt das Transcript einer Session in den `projects/`-Root des
    /// Ziel-Profils (`nil` = main) — der lokale Verlauf ist nicht account-
    /// gebunden, nur sein Ablageort entscheidet, unter welchem Account
    /// `--resume` ihn findet. Verschieben statt Kopieren: eine Kopie wuerde
    /// der Multi-Root-Indexer doppelt adoptieren. Der Subagent-Ordner
    /// (`<id>/` neben der JSONL) wandert mit.
    ///
    /// - Returns: `true` wenn eine Datei bewegt wurde, `false` wenn (noch)
    ///   kein Transcript existiert oder es schon im Ziel-Root liegt — der
    ///   Caller stempelt die Session in beiden Faellen um.
    @discardableResult
    func moveTranscript(
        externalSessionID: String,
        cwd: String,
        toProfile targetName: String?
    ) throws -> Bool {
        let target = targetName ?? Self.mainProfileName
        guard target == Self.mainProfileName
                || fileManager.fileExists(atPath: configDir(forProfile: target).path) else {
            throw MoveError.targetProfileMissing(target)
        }

        let encoded = AgentTranscriptLocator.encodeClaudeCwd(cwd)
        let targetDir = configDir(forProfile: target)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
        let targetFile = targetDir.appendingPathComponent("\(externalSessionID).jsonl")

        // Quelle ueber alle Roots suchen (main + Profile).
        var sourceFile: URL?
        for root in claudeProjectsRoots() {
            let candidate = root
                .appendingPathComponent(encoded, isDirectory: true)
                .appendingPathComponent("\(externalSessionID).jsonl")
            if fileManager.fileExists(atPath: candidate.path) {
                sourceFile = candidate
                break
            }
        }
        guard let sourceFile else { return false }
        guard sourceFile.path != targetFile.path else { return false }
        guard !fileManager.fileExists(atPath: targetFile.path) else {
            throw MoveError.targetTranscriptExists(targetFile.path)
        }

        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceFile, to: targetFile)

        // Subagent-Transcripts liegen als Ordner `<id>/` neben der JSONL.
        let sourceSubagents = sourceFile.deletingPathExtension()
        if fileManager.fileExists(atPath: sourceSubagents.path) {
            let targetSubagents = targetFile.deletingPathExtension()
            try? fileManager.moveItem(at: sourceSubagents, to: targetSubagents)
        }
        Logger.agentStore.notice("claude_transcript_moved session=\(externalSessionID, privacy: .public) target=\(target, privacy: .public)")
        return true
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
