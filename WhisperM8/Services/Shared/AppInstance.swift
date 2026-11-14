import Foundation

/// Zentrale Pfade der App — und der Schalter für die isolierte Test-Instanz.
///
/// Normalbetrieb: echtes Home, echtes `~/Library/Application Support`.
///
/// Test-Instanz (`WHISPERM8_INSTANCE_ROOT=<ordner>` in der Umgebung): Home wird
/// `<ordner>/home`, Application Support liegt darunter, der Control-Socket in
/// einem eigenen Verzeichnis. Damit liest und schreibt eine zweite App-Instanz
/// nichts von der laufenden Produktiv-App (Workspace, `~/.claude`, `~/.codex`,
/// Plugin, Skills, Logs). Foundation ignoriert `HOME` (gemessen 19.10.2026),
/// deshalb geht jeder Home-Zugriff über diesen Typ.
///
/// Bewusst NICHT umgebogen: Suchpfade für Binaries (`NSHomeDirectory()` in
/// `LoginShellEnvironment`/`AgentCommandBuilder`) — die Test-Instanz soll die
/// echten `claude`/`codex` finden — und vom Nutzer eingegebene `~`-Pfade.
enum AppInstance {
    static let rootEnvironmentKey = "WHISPERM8_INSTANCE_ROOT"

    /// Wurzel der Test-Instanz, `nil` im Normalbetrieb.
    static let testRoot: URL? = resolveTestRoot(ProcessInfo.processInfo.environment)

    static var isTestInstance: Bool { testRoot != nil }

    static let productionBundleIdentifier = "com.whisperm8.app"
    static let testBundleIdentifier = "com.whisperm8.app.test"

    /// Defaults-Domain der App, auch aus der CLI heraus (deren Standard-Domain
    /// hängt davon ab, über welchen Symlink sie gestartet wurde).
    static var defaultsDomain: String {
        isTestInstance ? testBundleIdentifier : productionBundleIdentifier
    }

    /// Läuft dieser Prozess als echte App (nicht unter `swift test`)?
    static var isAppBundleProcess: Bool {
        let id = Bundle.main.bundleIdentifier
        return id == productionBundleIdentifier || id == testBundleIdentifier
    }

    /// Home für alle Daten-Zugriffe (`~/.claude`, `~/.codex`, Profile, Logs).
    static var home: URL {
        testRoot?.appendingPathComponent("home", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// `~/Library/Application Support` (ohne `WhisperM8`-Unterordner).
    static var applicationSupport: URL {
        if testRoot != nil {
            return home.appendingPathComponent("Library/Application Support", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Kurzer Name für Socket-Verzeichnisse (Unix-Socket-Pfade sind auf 104 Byte begrenzt).
    static var socketDirectorySuffix: String {
        guard let testRoot else { return "" }
        return "-test-" + String(UInt32(truncatingIfNeeded: stableHash(testRoot.path)), radix: 36)
    }

    /// Zusätzliche Umgebung für Kindprozesse (Chats, Shells): In der Test-Instanz
    /// zeigt `HOME` auf das Test-Home, damit `claude`/`codex` deren Konfiguration
    /// dort anlegen, und die Wurzel wird weitergereicht, damit `whisperm8` in einem
    /// Test-Chat die Test-Instanz anspricht.
    ///
    /// Das fremde `HOME` trennt auch Claudes Login: Die Suchliste des
    /// Schlüsselbunds hängt am `HOME`, mit dem Test-Home findet `security` den
    /// Login-Schlüsselbund nicht. Claude legt einen Login dort deshalb im
    /// Klartext unter `<wurzel>/home/.claude/.credentials.json` ab und erreicht
    /// den echten Eintrag nie (gemessen 14.11.2026, Claude Code 2.1.325, WM8-63).
    static var childEnvironmentOverrides: [String: String] {
        childEnvironmentOverrides(testRoot: testRoot)
    }

    static func childEnvironmentOverrides(testRoot: URL?) -> [String: String] {
        guard let testRoot else { return [:] }
        return [
            "HOME": testHome(testRoot: testRoot).path,
            rootEnvironmentKey: testRoot.path,
        ]
    }

    static func testHome(testRoot: URL) -> URL {
        testRoot.appendingPathComponent("home", isDirectory: true)
    }

    /// `$HOME/.claude` der Test-Instanz. Daraus rechnet die App den
    /// Schlüsselbund-Dienst, den sie dort für `main` nimmt
    /// (`ClaudeAccountProfiles.mainKeychainService`).
    static func testClaudeConfigDirectory(testRoot: URL) -> URL {
        testHome(testRoot: testRoot).appendingPathComponent(".claude", isDirectory: true)
    }

    static func resolveTestRoot(_ environment: [String: String]) -> URL? {
        guard let raw = environment[rootEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    /// FNV-1a — stabil über Prozesse hinweg (anders als `Hasher`).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
