import Foundation

/// Ein ChatGPT-Konto-Profil des GPT-Backends. „main" ist der historische
/// Default-Store des Proxys (`~/.config/claude-code-proxy`, bleibt
/// unangetastet); Zusatzkonten leben je in einem eigenen `CCP_CONFIG_DIR`
/// unter `~/.gpt-profiles/<name>/`, in dem `claude-code-proxy` seinen eigenen
/// OAuth-Grant ablegt (`codex/auth.json`, eigene Refresh-Familie). WhisperM8
/// fasst nie Credentials an — es liest nur die `accountId`, um ein Profil als
/// eingeloggt zu erkennen.
///
/// Bewusst ein Parallelbau zu `ClaudeAccountProfiles` statt einer
/// Parametrisierung: dort haengen Keychain-Service, `oauthAccount`-Parsing
/// und der Transcript-Umzug am Claude-Layout. Hier gibt es weder Keychain
/// noch Transcripts — nur ein Verzeichnis mit einer Auth-Datei.
/// Plan: docs/plans/gpt-account-switcher.md
struct GPTAccountProfile: Identifiable, Equatable {
    var name: String
    var configDir: URL
    /// `accountId` aus `codex/auth.json` — der Beleg fuer einen EIGENEN Grant.
    var accountID: String?
    var emailAddress: String?
    var planType: String?

    var id: String { name }
    var isMain: Bool { name == GPTAccountProfiles.mainProfileName }
    /// Eingeloggt = das Profil traegt eine eigene Auth-Datei mit `accountId`.
    /// Der Proxy faellt bei fehlender Datei STILL auf den Default-Store bzw.
    /// `~/.codex/auth.json` zurueck (reproduziert 2026-09-16: leeres Config-Dir
    /// meldet das Standardkonto statt „Not authenticated") — deshalb zaehlt
    /// hier nur die Datei, nie die Ausgabe von `codex auth status`.
    var isLoggedIn: Bool { accountID != nil }
    var planDisplayName: String? { GPTAccountProfiles.planDisplayName(planType) }
}

/// Kontometadaten, die WhisperM8 nach Login bzw. Usage-Abruf neben die
/// Auth-Datei legt — das Pendant zu `oauthAccount` in `.claude.json`.
/// Keine Secrets; die Quelle ist die `wham/usage`-Antwort (E-Mail, Plan).
struct GPTAccountInfo: Codable, Equatable {
    var accountID: String
    var emailAddress: String?
    var planType: String?
    var fetchedAt: Date
}

/// Wie das GPT-Konto-Profil einer NEU erstellten Session bestimmt wird —
/// dieselbe Trennung „nicht angegeben" vs. „ausdruecklich main" wie bei
/// `ClaudeProfileSelection`, aus demselben Grund (stiller Main-Fallback ueber
/// den CLI-Pfad, Befund 2026-08-22).
enum GPTProfileSelection: Equatable {
    /// Kein Profil angegeben → das in den Settings aktive Profil gewinnt.
    case activeDefault
    /// Ausdrueckliche Wahl; `nil` = Default-Store (`main`).
    case explicit(String?)
}

/// Verwaltung der GPT-Konto-Profile (Discovery, aktives Profil, Env-Injektion,
/// Anlegen/Entfernen). Dateibasiert und zustandslos — SSoT sind die
/// Verzeichnisse unter `~/.gpt-profiles` und die `.active`-Datei.
struct GPTAccountProfiles {
    static let mainProfileName = "main"
    /// Env-Variable, mit der der Proxy seine Konfigurations- und Store-Wurzel
    /// umhaengt (verifiziert 2026-09-16 mit Fork 0.1.36-whisperm8.1).
    static let configDirEnvironmentKey = "CCP_CONFIG_DIR"
    static let accountInfoFileName = "whisperm8-account.json"

    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var fileManager: FileManager = .default
    /// Default-Store des Proxys ohne `CCP_CONFIG_DIR`. Der Proxy folgt
    /// `XDG_CONFIG_HOME`, deshalb hier ebenfalls — sonst zeigte „main" auf
    /// ein Verzeichnis, das der Proxy gar nicht benutzt.
    var xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]

    var profilesRoot: URL {
        homeDirectory.appendingPathComponent(".gpt-profiles", isDirectory: true)
    }

    private var activeFileURL: URL {
        profilesRoot.appendingPathComponent(".active", isDirectory: false)
    }

    // MARK: - Discovery

    /// Alle Profile, `main` immer zuerst. Zusatzprofile = Unterordner von
    /// `~/.gpt-profiles` (versteckte Ordner ausgenommen).
    func profiles() -> [GPTAccountProfile] {
        var result = [profile(named: Self.mainProfileName)]
        let entries = (try? fileManager.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        // Nur gueltige Namen: ein von Hand angelegtes Verzeichnis mit
        // Leerzeichen oder Steuerzeichen darf weder ins Menue noch als
        // Header-Wert in einen Request (der Router verwirft es still).
        let names = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter(Self.isValidProfileName)
            .sorted()
        result.append(contentsOf: names.map { profile(named: $0) })
        return result
    }

    func profile(named name: String) -> GPTAccountProfile {
        var profile = GPTAccountProfile(name: name, configDir: configDir(forProfile: name))
        profile.accountID = storedAccountID(forProfile: name)
        if let info = readAccountInfo(forProfile: name), info.accountID == profile.accountID {
            // Metadaten nur, wenn sie zum aktuellen Grant gehoeren — nach einem
            // Re-Login mit anderem Konto waere die alte E-Mail eine Luege.
            profile.emailAddress = info.emailAddress
            profile.planType = info.planType
        }
        return profile
    }

    /// `CCP_CONFIG_DIR` des Profils. `main` → Default-Store des Proxys.
    func configDir(forProfile name: String) -> URL {
        if name == Self.mainProfileName {
            let base: URL
            if let xdg = xdgConfigHome, !xdg.isEmpty {
                base = URL(fileURLWithPath: xdg, isDirectory: true)
            } else {
                base = homeDirectory.appendingPathComponent(".config", isDirectory: true)
            }
            return base.appendingPathComponent("claude-code-proxy", isDirectory: true)
        }
        return profilesRoot.appendingPathComponent(name, isDirectory: true)
    }

    /// Der Credential-Store des Proxys innerhalb des Config-Dirs.
    func authFileURL(forProfile name: String) -> URL {
        configDir(forProfile: name)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Ablage der Kontometadaten. Fuer `main` liegt sie NICHT im Proxy-Dir
    /// (fremdes Tool, dort schreiben wir nichts), sondern versteckt unter
    /// `~/.gpt-profiles/.main-account.json`.
    func accountInfoFileURL(forProfile name: String) -> URL {
        if name == Self.mainProfileName {
            return profilesRoot.appendingPathComponent(".main-account.json", isDirectory: false)
        }
        return configDir(forProfile: name)
            .appendingPathComponent(Self.accountInfoFileName, isDirectory: false)
    }

    // MARK: - Auth-Datei lesen (gecacht)

    /// Prozessweiter Cache der gelesenen `accountId`, validiert ueber
    /// (mtime, size) der Auth-Datei — dieselbe Massnahme wie bei den
    /// Claude-Profilen (CPU-Befund 2026-08-23: Kontextmenues parsen sonst bei
    /// jedem Render-Pass alle Profil-Dateien). Fehlende Dateien werden nicht
    /// gecacht; der Fehlpfad ist ein einzelner stat().
    private static let accountIDCacheLock = NSLock()
    private static var accountIDCache: [String: (mtime: Date, size: Int, accountID: String?)] = [:]

    /// `accountId` aus `codex/auth.json` — `nil`, wenn Datei oder Feld fehlen.
    func storedAccountID(forProfile name: String) -> String? {
        let url = authFileURL(forProfile: name)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else {
            return nil
        }

        Self.accountIDCacheLock.lock()
        let cached = Self.accountIDCache[url.path]
        Self.accountIDCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size {
            return cached.accountID
        }

        let accountID = Self.parseAccountID(at: url)
        Self.accountIDCacheLock.lock()
        Self.accountIDCache[url.path] = (mtime, size, accountID)
        Self.accountIDCacheLock.unlock()
        return accountID
    }

    /// Schema des Proxy-Stores: `access`, `refresh`, `expires`, `accountId`.
    /// Nur die Konto-ID wird gelesen; Tokens verlassen diese Funktion nie.
    static func parseAccountID(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = object["accountId"] as? String else {
            return nil
        }
        let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Kontometadaten

    /// Gleicher (mtime, size)-Cache wie fuer die `accountId`: `profiles()`
    /// laeuft im Body des Kontextmenues, also bei jedem Render-Pass.
    private static let accountInfoCacheLock = NSLock()
    private static var accountInfoCache: [String: (mtime: Date, size: Int, info: GPTAccountInfo?)] = [:]

    func readAccountInfo(forProfile name: String) -> GPTAccountInfo? {
        let url = accountInfoFileURL(forProfile: name)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else {
            return nil
        }
        Self.accountInfoCacheLock.lock()
        let cached = Self.accountInfoCache[url.path]
        Self.accountInfoCacheLock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size {
            return cached.info
        }
        let info: GPTAccountInfo? = {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(GPTAccountInfo.self, from: data)
        }()
        Self.accountInfoCacheLock.lock()
        Self.accountInfoCache[url.path] = (mtime, size, info)
        Self.accountInfoCacheLock.unlock()
        return info
    }

    func writeAccountInfo(_ info: GPTAccountInfo, forProfile name: String) throws {
        let url = accountInfoFileURL(forProfile: name)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: url, options: .atomic)
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
    /// Session-Stempel verwendbar.
    func activeProfileNameOrNil() -> String? {
        let name = activeProfileName()
        return name == Self.mainProfileName ? nil : name
    }

    /// Fehler bei einer AUSDRUECKLICHEN Profilangabe (Settings, CLI).
    enum SelectionError: LocalizedError, Equatable {
        case unknownProfile(String)
        case notLoggedIn(String)

        var errorDescription: String? {
            switch self {
            case .unknownProfile(let name):
                return "GPT-Konto-Profil „\(name)“ existiert nicht."
            case .notLoggedIn(let name):
                return "GPT-Konto-Profil „\(name)“ ist nicht eingeloggt — bitte zuerst in den Einstellungen anmelden."
            }
        }
    }

    /// Prueft eine ausdrueckliche Profilangabe und normalisiert sie auf den
    /// Stempel-Wert (`nil` = main). Faellt bewusst NIE still auf main zurueck:
    /// wer ein Profil nennt, bekommt es — oder einen Fehler.
    func validatedProfileName(_ raw: String) throws -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != Self.mainProfileName else { return nil }
        guard Self.isValidProfileName(name),
              fileManager.fileExists(atPath: configDir(forProfile: name).path) else {
            throw SelectionError.unknownProfile(name)
        }
        guard profile(named: name).isLoggedIn else {
            throw SelectionError.notLoggedIn(name)
        }
        return name
    }

    func setActiveProfile(_ name: String) throws {
        try fileManager.createDirectory(at: profilesRoot, withIntermediateDirectories: true)
        try name.write(to: activeFileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Env-Injektion

    /// `CCP_CONFIG_DIR`-Override fuer Proxy-Start, Auth-Status und Login.
    ///
    /// Auch `main` bekommt die Variable — auf seinen bisherigen Default-Store,
    /// also denselben Pfad, den der Proxy ohne Variable naehme. Grund
    /// (Fork-Quellcode, 2026-09-23): OHNE `CCP_CONFIG_DIR` bevorzugt der Proxy
    /// auf macOS den Keychain; dessen Schreibzugriff scheitert im
    /// nicht-interaktiven Modus grundsaetzlich, und refreshte Tokens landeten
    /// nicht in der Datei — die Anzeige las einen seit dem 16.09. abgelaufenen
    /// Token, obwohl die Instanz lief. MIT der Variable arbeitet der Proxy
    /// rein dateibasiert und schreibt jeden Refresh zurueck. Leer nur fuer
    /// Profile, deren Verzeichnis nicht (mehr) existiert — ein frisch
    /// angelegtes, leeres Config-Dir liefe sonst still auf dem Default-Konto.
    func environmentOverrides(forProfile name: String?) -> [String: String] {
        guard let name, name != Self.mainProfileName else {
            return [Self.configDirEnvironmentKey: configDir(forProfile: Self.mainProfileName).path]
        }
        guard Self.isValidProfileName(name) else {
            // Kein Pfad aus einem Stempel wie "../x" — und kein stiller
            // main-Fallback fuer einen kaputten Namen: leer heisst fuer den
            // Manager „nicht angemeldet".
            Logger.agentStore.warning(
                "gpt_profile_invalid_name name=\(name, privacy: .public) — ignoriert"
            )
            return [:]
        }
        let dir = configDir(forProfile: name)
        guard fileManager.fileExists(atPath: dir.path) else {
            Logger.agentStore.warning(
                "gpt_profile_missing name=\(name, privacy: .public) — Aufruf faellt auf main zurueck"
            )
            return [:]
        }
        return [Self.configDirEnvironmentKey: dir.path]
    }

    // MARK: - Profil anlegen / entfernen

    enum CreateError: LocalizedError, Equatable {
        case invalidName(String)
        case alreadyExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "Ungültiger Profilname „\(name)“. Erlaubt sind Buchstaben, Ziffern, - und _; „main“ ist reserviert."
            case .alreadyExists(let name):
                return "Profil „\(name)“ existiert bereits."
            }
        }
    }

    enum RemoveError: LocalizedError, Equatable {
        case cannotRemoveMain
        case unknownProfile(String)

        var errorDescription: String? {
            switch self {
            case .cannotRemoveMain:
                return "Das Hauptkonto (Default-Store des Proxys) kann nicht entfernt werden."
            case .unknownProfile(let name):
                return "GPT-Konto-Profil „\(name)“ existiert nicht."
            }
        }
    }

    /// ASCII-Buchstaben/-Ziffern, `-` und `_`; „main" ist reserviert. Bewusst
    /// enger als Unicode-„isLetter": der Name wandert als Header-Wert in jeden
    /// Request und als Verzeichnisname ins Dateisystem.
    static func isValidProfileName(_ name: String) -> Bool {
        !name.isEmpty
            && name != mainProfileName
            && name.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                    || scalar == "-" || scalar == "_"
            }
    }

    /// Legt nur das Verzeichnis an. Der Login selbst bleibt interaktiv
    /// (Device-Code-Flow des Proxys mit diesem `CCP_CONFIG_DIR`) — bis dahin
    /// ist das Profil vorhanden, aber nicht eingeloggt, und wird von
    /// `validatedProfileName` und dem Proxy-Manager entsprechend abgewiesen.
    @discardableResult
    func createProfile(named name: String) throws -> GPTAccountProfile {
        guard Self.isValidProfileName(name) else { throw CreateError.invalidName(name) }
        let dir = configDir(forProfile: name)
        guard !fileManager.fileExists(atPath: dir.path) else { throw CreateError.alreadyExists(name) }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return profile(named: name)
    }

    /// Entfernt das Profil-Verzeichnis samt Grant. War es das aktive Profil,
    /// faellt `.active` auf main zurueck. Eine laufende Proxy-Instanz des
    /// Profils muss der Caller vorher beenden.
    func removeProfile(named name: String) throws {
        guard name != Self.mainProfileName else { throw RemoveError.cannotRemoveMain }
        let dir = configDir(forProfile: name)
        guard fileManager.fileExists(atPath: dir.path) else { throw RemoveError.unknownProfile(name) }
        try fileManager.removeItem(at: dir)
        if (try? String(contentsOf: activeFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == name {
            try? setActiveProfile(Self.mainProfileName)
        }
    }

    // MARK: - Anzeige

    /// Lesbarer Plan aus `plan_type` der Usage-Antwort (`pro`, `prolite`,
    /// `plus`, …). Unbekannte Kennungen werden nur kapitalisiert.
    static func planDisplayName(_ planType: String?) -> String? {
        guard let planType = planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !planType.isEmpty else {
            return nil
        }
        switch planType {
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return planType.prefix(1).uppercased() + planType.dropFirst()
        }
    }
}
