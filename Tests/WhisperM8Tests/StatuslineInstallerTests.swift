import XCTest

@testable import WhisperM8

/// Tests für den Statusline-Installer (Bundle-Ressource → Skript in
/// ~/.claude + statusLine-Eintrag in allen settings.json). Schutzregeln:
/// markerlose User-Skripte und fremde statusLine-Commands werden nur mit
/// explizitem force ersetzt; übrige settings.json-Schlüssel bleiben erhalten.
final class StatuslineInstallerTests: XCTestCase {
    private var tempHome: URL!
    private var mainConfigDir: URL!
    private var profileDir: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("statusline-tests-\(UUID().uuidString)", isDirectory: true)
        mainConfigDir = tempHome.appendingPathComponent(".claude", isDirectory: true)
        profileDir = tempHome.appendingPathComponent(".claude-profiles/Firma", isDirectory: true)
        try FileManager.default.createDirectory(at: mainConfigDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    private func makeInstaller() -> StatuslineInstaller {
        let directories = [mainConfigDir!, profileDir!]
        return StatuslineInstaller(
            homeDirectory: tempHome,
            bundle: .module,
            settingsDirectories: { directories }
        )
    }

    private func settingsJSON(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Ressource

    /// Regression 2026-07-19: Default-Bundle war .main — dort liegt die
    /// SwiftPM-Ressource nie (sie steckt im WhisperM8_WhisperM8.bundle),
    /// jede Installation aus der App brach mit resourceMissing ab.
    func testDefaultInstallerFindsBundledResource() throws {
        let installer = StatuslineInstaller(homeDirectory: tempHome)
        XCTAssertNoThrow(try installer.bundledScript())
    }

    /// Regression 2026-07-19: `profiles()` liefert `main` ebenfalls zurück.
    /// Die Default-Ziele dürfen den Main-Config-Pfad deshalb nicht doppeln und
    /// müssen Profile relativ zum injizierten Home ermitteln.
    func testDefaultSettingsDirectoriesAreUniqueAndUseInjectedHome() {
        let installer = StatuslineInstaller(homeDirectory: tempHome)
        let paths = installer.settingsDirectories().map(\.standardizedFileURL.path)

        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertEqual(paths, [mainConfigDir, profileDir].map(\.standardizedFileURL.path))
    }

    func testBundledScriptCarriesMarkerAndShebang() throws {
        let script = try makeInstaller().bundledScript()
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(script.contains(StatuslineInstaller.managedMarker))
        // Kernfunktionen der Anzeige müssen enthalten sein.
        XCTAssertTrue(script.contains("context_window"))
        XCTAssertTrue(script.contains("ctx_exact"))
    }

    // MARK: Installation

    func testInstallWritesExecutableScriptAndWiresAllSettings() throws {
        // Profil-settings.json mit Fremdschlüssel — der muss überleben.
        let profileSettings = profileDir.appendingPathComponent("settings.json")
        try Data(#"{"model":"opus","hooks":{"SessionStart":[]}}"#.utf8)
            .write(to: profileSettings)

        let installer = makeInstaller()
        let url = try installer.install()

        XCTAssertEqual(url.path, mainConfigDir.appendingPathComponent("statusline-command.sh").path)
        let installed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(installed.contains(StatuslineInstaller.managedMarker))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)

        for directory in [mainConfigDir!, profileDir!] {
            let object = try settingsJSON(in: directory)
            let entry = try XCTUnwrap(object["statusLine"] as? [String: Any])
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertEqual(entry["command"] as? String, "~/.claude/statusline-command.sh")
        }
        // Fremdschlüssel unangetastet.
        let profileObject = try settingsJSON(in: profileDir)
        XCTAssertEqual(profileObject["model"] as? String, "opus")
        XCTAssertNotNil(profileObject["hooks"])

        XCTAssertEqual(installer.wiredSettingsCount(), 2)
        XCTAssertEqual(installer.status(), .current)
    }

    func testStatusLifecycleMissingCurrentOutdated() throws {
        let installer = makeInstaller()
        XCTAssertEqual(installer.status(), .missing)

        try installer.install()
        XCTAssertEqual(installer.status(), .current)

        // Lokal editiertes (aber weiterhin markiertes) Skript = outdated.
        let url = installer.scriptURL
        let edited = try String(contentsOf: url, encoding: .utf8) + "\n# lokale Anpassung\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.status(), .outdated)

        // Update stellt den gebündelten Stand wieder her.
        try installer.install()
        XCTAssertEqual(installer.status(), .current)
    }

    // MARK: Schutzregeln

    func testForeignScriptIsProtectedUnlessForced() throws {
        let installer = makeInstaller()
        let foreign = "#!/bin/bash\necho eigenes-skript\n"
        try foreign.write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.status(), .foreign)

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(
                error as? StatuslineInstaller.InstallError,
                .foreignScript(path: installer.scriptURL.path)
            )
        }
        // Datei unverändert.
        XCTAssertEqual(try String(contentsOf: installer.scriptURL, encoding: .utf8), foreign)

        try installer.install(replaceForeignScript: true)
        XCTAssertEqual(installer.status(), .current)
    }

    func testProfileSettingsSymlinkIsPreservedAndCountsViaMain() throws {
        // Reale Profil-Anlage: settings.json ist ein Symlink auf Main
        // (ClaudeAccountProfiles.sharedItems). Der Installer darf ihn nie
        // durch eine echte Datei ersetzen.
        let mainSettings = mainConfigDir.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: mainSettings)
        let profileSettings = profileDir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(
            at: profileSettings, withDestinationURL: mainSettings
        )

        let installer = makeInstaller()
        try installer.install()

        let values = try profileSettings.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true, "Symlink muss Symlink bleiben")
        let mainEntry = try XCTUnwrap(try settingsJSON(in: mainConfigDir)["statusLine"] as? [String: Any])
        XCTAssertEqual(mainEntry["command"] as? String, "~/.claude/statusline-command.sh")
        // Symlink liest transparent durch → beide Configs gelten als verdrahtet.
        XCTAssertEqual(installer.wiredSettingsCount(), 2)
        XCTAssertEqual(installer.foreignSettingsCount(), 0)
    }

    func testCorruptSettingsJSONAbortsInsteadOfOverwriting() throws {
        let mainSettings = mainConfigDir.appendingPathComponent("settings.json")
        let corrupt = "{not-json"
        try Data(corrupt.utf8).write(to: mainSettings)

        let installer = makeInstaller()
        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(
                error as? StatuslineInstaller.InstallError,
                .corruptSettings(path: mainSettings.path)
            )
        }
        XCTAssertEqual(
            try String(contentsOf: mainSettings, encoding: .utf8), corrupt,
            "Kaputtes JSON darf nicht überschrieben werden"
        )
    }

    func testForeignStatusLineCommandSurvivesWithoutForce() throws {
        let mainSettings = mainConfigDir.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"/eigenes/statusline.sh"}}"#.utf8)
            .write(to: mainSettings)

        let installer = makeInstaller()
        try installer.install()

        // Fremder Eintrag bleibt stehen, Profil (ohne Eintrag) wird verdrahtet.
        let mainEntry = try XCTUnwrap(try settingsJSON(in: mainConfigDir)["statusLine"] as? [String: Any])
        XCTAssertEqual(mainEntry["command"] as? String, "/eigenes/statusline.sh")
        XCTAssertEqual(installer.wiredSettingsCount(), 1)
        XCTAssertEqual(installer.foreignSettingsCount(), 1)

        // Skript-Ersetzung allein darf fremde Einträge NICHT kapern.
        try installer.install(replaceForeignScript: true)
        XCTAssertEqual(installer.foreignSettingsCount(), 1)

        try installer.install(replaceForeignSettings: true)
        let forcedEntry = try XCTUnwrap(try settingsJSON(in: mainConfigDir)["statusLine"] as? [String: Any])
        XCTAssertEqual(forcedEntry["command"] as? String, "~/.claude/statusline-command.sh")
        XCTAssertEqual(installer.wiredSettingsCount(), 2)
        XCTAssertEqual(installer.foreignSettingsCount(), 0)
    }

    func testMissingProfileDirectoryIsSkipped() throws {
        let ghost = tempHome.appendingPathComponent(".claude-profiles/Geist", isDirectory: true)
        let directories = [mainConfigDir!, ghost]
        let installer = StatuslineInstaller(
            homeDirectory: tempHome,
            bundle: .module,
            settingsDirectories: { directories }
        )

        try installer.install()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ghost.appendingPathComponent("settings.json").path),
            "Nicht existierende Profil-Roots dürfen nicht angelegt werden"
        )
        XCTAssertEqual(installer.wiredSettingsCount(), 1)
    }
}
