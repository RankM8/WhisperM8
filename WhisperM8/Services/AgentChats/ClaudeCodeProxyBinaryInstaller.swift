import CryptoKit
import Foundation

/// Managed Download des `claude-code-proxy`-Binarys (MIT-lizenziert) aus den
/// GitHub-Releases von Upstream (`raine/claude-code-proxy`) nach
/// `~/Library/Application Support/WhisperM8/bin/`.
///
/// Welche Codex-Modelle angeboten werden, entscheidet nicht mehr ein
/// eigener Proxy-Fork (2026-09-06 bis 2026-09-23), sondern die Schnittmenge
/// aus Codex-Katalog und `/v1/models` des laufenden Proxys
/// (`ClaudeCodeProxyModelRegistry`). Neue Modelle kommen mit dem nächsten
/// Upstream-Release; `ensureRunning` hält das verwaltete Binary dafür
/// automatisch auf dem neuesten Release (`autoUpdateEnabled`).
///
/// Ein PATH-Binary bleibt der Power-User-Override — aber nur ab
/// `minimumVersion`. Ein älteres PATH-Binary (Vorfall 2026-09-08: Homebrew
/// 0.1.21 vom Juli) verliert den Vorrang gegen das verwaltete.
///
/// Sicherheitsmodell: Die App pinnt Version UND SHA-256 der known-good-
/// Version; für neuere Versionen (Auto-Update, Update-Button) wird gegen das
/// `.sha256`-Sidecar desselben Releases verifiziert. Downloads laufen
/// vollständig in Temp-Dateien und werden atomar an den Zielpfad bewegt.
struct ClaudeCodeProxyBinaryInstaller {
    /// Von uns getestete Version — der Ein-Klick-Setup installiert genau sie.
    static let knownGoodVersion = "0.1.42"

    /// SHA-256 der Release-Tarballs der known-good-Version (2026-09-23 von
    /// den Release-Sidecars übernommen).
    static let pinnedTarballSHA256: [String: String] = [
        "0.1.42/darwin-arm64": "97542c34398db90227210c6feb6de864c80f92e7a16379024340b2f50f14b696",
        "0.1.42/darwin-amd64": "e4bdd6f0b9478f30c914947ae7a75db9b25c6d05efbd9b2cd2fc012a83866ce7",
    ]

    static let repository = "raine/claude-code-proxy"
    static let binaryName = "claude-code-proxy"

    /// Kill-Switch für das automatische Update auf das neueste Upstream-
    /// Release: `defaults write com.whisperm8.app claudeCodeProxyAutoUpdateEnabled -bool NO`.
    static var autoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: "claudeCodeProxyAutoUpdateEnabled") as? Bool ?? true
    }

    /// Älteste Version, die WhisperM8 als vollwertig startet. Frühere
    /// WhisperM8-Fork-Builds (`0.1.36-whisperm8.1`) liegen numerisch darunter
    /// und werden damit ebenfalls durch das Upstream-Release ersetzt.
    static let minimumVersion = knownGoodVersion

    /// Erfüllt ein Binary dieser Version die Mindestversion? Unbekannte
    /// Version (kein `--version`-Output) zählt als nein — lieber das
    /// verwaltete Binary als ein blindes.
    static func meetsMinimumVersion(version: String?) -> Bool {
        guard let version else { return false }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !isVersion(minimumVersion, newerThan: trimmed)
    }

    /// Version aus der `--version`-Ausgabe (`claude-code-proxy 0.1.21`).
    /// Erstes Token, das wie eine Versionsnummer aussieht; `v`-Präfix fällt.
    static func parseVersionOutput(_ output: String) -> String? {
        for rawToken in output.split(whereSeparator: { $0.isWhitespace }) {
            var token = Substring(rawToken)
            if token.hasPrefix("v") { token = token.dropFirst() }
            guard let first = token.first, first.isNumber else { continue }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+"))
            guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
            return String(token)
        }
        return nil
    }

    /// Serialisiert Binary-Replace + Versions-Stempel prozessweit — Setup-
    /// Wizard und Settings-Update laufen sonst mit getrennten Instanzen
    /// parallel auf dasselbe Ziel (Review-Befund 2026-07-19: Binary B mit
    /// Stempel A möglich).
    private static let installLock = NSLock()

    enum InstallerError: LocalizedError, Equatable {
        case checksumMismatch(expected: String, actual: String)
        case checksumUnavailable(String)
        case extractionFailed(String)
        case latestVersionUnavailable

        var errorDescription: String? {
            switch self {
            case .checksumMismatch(let expected, let actual):
                return "Checksummen-Fehler beim Proxy-Download (erwartet \(expected.prefix(12))…, erhalten \(actual.prefix(12))…)."
            case .checksumUnavailable(let version):
                return "Keine Checksumme für Version \(version) verfügbar."
            case .extractionFailed(let reason):
                return "Proxy-Archiv konnte nicht entpackt werden: \(reason)"
            case .latestVersionUnavailable:
                return "Neueste Proxy-Version konnte nicht ermittelt werden."
            }
        }
    }

    var directory: URL
    var architecture: String
    /// Lädt eine URL vollständig in den Speicher (Assets sind ~4,5 MB).
    var downloader: (URL) async throws -> Data
    /// Entpackt `tarball` in `destination` (Default: /usr/bin/tar).
    var extractor: (URL, URL) throws -> Void

    init(
        directory: URL? = nil,
        architecture: String? = nil,
        downloader: ((URL) async throws -> Data)? = nil,
        extractor: ((URL, URL) throws -> Void)? = nil
    ) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperM8/bin", isDirectory: true)
        #if arch(arm64)
        self.architecture = architecture ?? "arm64"
        #else
        self.architecture = architecture ?? "amd64"
        #endif
        self.downloader = downloader ?? { url in
            try await URLSession.shared.data(from: url).0
        }
        self.extractor = extractor ?? { tarball, destination in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", tarball.path, "-C", destination.path]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                throw InstallerError.extractionFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - Pfade und Zustand

    var binaryURL: URL {
        directory.appendingPathComponent(Self.binaryName, isDirectory: false)
    }

    /// Versions-Stempel neben dem Binary — vermeidet `--version`-Subprozesse
    /// bei jeder Statusabfrage.
    var versionStampURL: URL {
        directory.appendingPathComponent("\(Self.binaryName).version", isDirectory: false)
    }

    /// Version des verwalteten Binarys, falls installiert.
    func installedManagedVersion() -> String? {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path),
              let stamp = try? String(contentsOf: versionStampURL, encoding: .utf8) else {
            return nil
        }
        let version = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    // MARK: - Release-URLs

    func assetName(version: String) -> String {
        "\(Self.binaryName)-darwin-\(architecture).tar.gz"
    }

    func assetURL(version: String) -> URL {
        URL(string: "https://github.com/\(Self.repository)/releases/download/v\(version)/\(assetName(version: version))")!
    }

    func checksumSidecarURL(version: String) -> URL {
        URL(string: "https://github.com/\(Self.repository)/releases/download/v\(version)/\(Self.binaryName)-darwin-\(architecture).sha256")!
    }

    // MARK: - Installation

    /// Installiert die known-good-Version (Pfad für den Setup-Wizard).
    @discardableResult
    func installKnownGood() async throws -> URL {
        try await install(version: Self.knownGoodVersion)
    }

    /// Lädt, verifiziert und installiert die angegebene Version atomar.
    @discardableResult
    func install(version: String) async throws -> URL {
        let tarballData = try await downloader(assetURL(version: version))

        let actual = SHA256.hash(data: tarballData)
            .map { String(format: "%02x", $0) }
            .joined()
        let expected = try await expectedChecksum(version: version)
        guard actual == expected else {
            throw InstallerError.checksumMismatch(expected: expected, actual: actual)
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperm8-proxy-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let tarballURL = workDir.appendingPathComponent(assetName(version: version))
        try tarballData.write(to: tarballURL)
        try extractor(tarballURL, workDir)

        let extracted = workDir.appendingPathComponent(Self.binaryName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw InstallerError.extractionFailed("Archiv enthält kein \(Self.binaryName)-Binary.")
        }
        // Quarantäne-Attribut entfernen, falls die Download-Route eins
        // gesetzt hat — sonst blockiert Gatekeeper den Prozessstart.
        removeQuarantine(at: extracted)

        // Stempel VORAB in eine Temp-Datei — scheitert der Write (voller
        // Datenträger o. ä.), bricht die Installation ab, BEVOR das Binary
        // ersetzt wurde.
        let stampStaging = workDir.appendingPathComponent("version-stamp", isDirectory: false)
        try version.write(to: stampStaging, atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Self.installLock.lock()
        defer { Self.installLock.unlock() }
        // Alten Stempel VOR dem Binary-Replace entfernen — und zwar mit `try`,
        // nicht `try?`: Lässt er sich nicht entfernen (z. B. immutabel per
        // chflags), bricht die Installation ab, BEVOR das Binary getauscht
        // wird. So kann nie ein neues Binary neben einem veralteten Stempel
        // stehen (die irreführendste Divergenz). Schlägt danach der
        // Stempel-Write fehl (voller Datenträger), ist der schlimmste
        // Zustand „Stempel fehlt" → installedManagedVersion nil, UI zeigt
        // „kein verwaltetes Binary" statt einer falschen Version.
        if FileManager.default.fileExists(atPath: versionStampURL.path) {
            try FileManager.default.removeItem(at: versionStampURL)
        }
        _ = try FileManager.default.replaceItemAt(binaryURL, withItemAt: extracted)
        // Rechte NACH dem Replace setzen: replaceItemAt übernimmt auf Darwin
        // die POSIX-Rechte des VORHANDENEN Ziels (Review-Befund 2026-07-19,
        // empirisch belegt: 0600-Ziel blieb 0600) — ein vorab-chmod am
        // entpackten File würde also verworfen.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path
        )
        _ = try FileManager.default.replaceItemAt(versionStampURL, withItemAt: stampStaging)
        Logger.debug("[Proxy] Binary v\(version) installiert: \(binaryURL.path)")
        return binaryURL
    }

    /// Numerischer Versionsvergleich (SemVer-artig, fehlende Komponenten = 0).
    /// Der Update-Check bietet nur echte UPGRADES an — ein zurückgezogenes
    /// Release darf nicht als „neuere Version“ zum Downgrade führen.
    static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        func components(_ raw: String) -> [Int] {
            raw.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = components(candidate)
        let b = components(baseline)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private func expectedChecksum(version: String) async throws -> String {
        if let pinned = Self.pinnedTarballSHA256["\(version)/darwin-\(architecture)"] {
            return pinned
        }
        // Neuere Versionen: Sidecar desselben Releases (Format `<hex>  <datei>`).
        guard let sidecar = try? await downloader(checksumSidecarURL(version: version)),
              let line = String(data: sidecar, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let hex = line.split(separator: " ").first,
              hex.count == 64 else {
            throw InstallerError.checksumUnavailable(version)
        }
        return String(hex).lowercased()
    }

    private func removeQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.quarantine", url.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Update-Check

    /// Neueste Release-Version laut GitHub-API (Tag ohne `v`-Präfix).
    func latestVersion() async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let data = try await downloader(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty else {
            throw InstallerError.latestVersionUnavailable
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}
