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
        XCTAssertNoThrow(try installer.bundledSubagentScript())
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

        let subagentScript = try makeInstaller().bundledSubagentScript()
        XCTAssertTrue(subagentScript.hasPrefix("#!/bin/bash"))
        XCTAssertTrue(subagentScript.contains(StatuslineInstaller.managedMarker))
        XCTAssertTrue(subagentScript.contains("tokenCount"))
        XCTAssertTrue(subagentScript.contains("contextWindowSize"))
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

        let subagentURL = installer.subagentScriptURL
        let installedSubagent = try String(contentsOf: subagentURL, encoding: .utf8)
        XCTAssertTrue(installedSubagent.contains(StatuslineInstaller.managedMarker))
        let subagentPermissions = try FileManager.default.attributesOfItem(atPath: subagentURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(subagentPermissions, 0o755)

        for directory in [mainConfigDir!, profileDir!] {
            let object = try settingsJSON(in: directory)
            let entry = try XCTUnwrap(object["statusLine"] as? [String: Any])
            XCTAssertEqual(entry["type"] as? String, "command")
            XCTAssertEqual(entry["command"] as? String, "~/.claude/statusline-command.sh")
            let subagentEntry = try XCTUnwrap(object["subagentStatusLine"] as? [String: Any])
            XCTAssertEqual(subagentEntry["type"] as? String, "command")
            XCTAssertEqual(subagentEntry["command"] as? String, "~/.claude/subagent-statusline.sh")
        }
        // Fremdschlüssel unangetastet.
        let profileObject = try settingsJSON(in: profileDir)
        XCTAssertEqual(profileObject["model"] as? String, "opus")
        XCTAssertNotNil(profileObject["hooks"])

        XCTAssertEqual(installer.wiredSettingsCount(), 2)
        XCTAssertEqual(installer.status(), .current)

        let stamp = try XCTUnwrap(installer.readInstallStamp())
        XCTAssertEqual(stamp.source, StatuslineInstaller.InstallStamp.sourceBundle)
        XCTAssertEqual(stamp.installed, try installer.bundledHashes())
        XCTAssertEqual(stamp.bundled, try installer.bundledHashes())
    }

    func testStatusLifecycleMissingCurrentModifiedLocally() throws {
        let installer = makeInstaller()
        XCTAssertEqual(installer.status(), .missing)

        try installer.install()
        XCTAssertEqual(installer.status(), .current)

        // Lokal editiertes (aber weiterhin markiertes) Skript wird über den
        // Install-Stempel als lokale Änderung erkannt.
        let url = installer.scriptURL
        let edited = try String(contentsOf: url, encoding: .utf8) + "\n# lokale Anpassung\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.status(), .modifiedLocally)

        // Update stellt den gebündelten Stand wieder her.
        try installer.install()
        XCTAssertEqual(installer.status(), .current)
    }

    func testStatusWithoutStampRemainsOutdatedForBackwardCompatibility() throws {
        let installer = makeInstaller()
        try installer.install()
        try FileManager.default.removeItem(at: installer.installStampURL)

        let legacyScript = try installer.bundledScript() + "\n# markierter Altbestand\n"
        try legacyScript.write(to: installer.scriptURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(installer.status(), .outdated)
    }

    func testLegacyStampIsOutdatedEvenWhenBothScriptsMatchBundle() throws {
        let installer = makeInstaller()
        try installer.install()

        let mainScript = try String(contentsOf: installer.scriptURL, encoding: .utf8)
        let legacyHashes = [
            StatuslineInstaller.scriptFileName: StatuslineInstaller.sha256(of: mainScript),
        ]
        try installer.writeInstallStamp(StatuslineInstaller.InstallStamp(
            source: StatuslineInstaller.InstallStamp.sourceBundle,
            updatedAt: "2026-07-19T00:00:00Z",
            installed: legacyHashes,
            bundled: legacyHashes
        ))

        XCTAssertEqual(installer.status(), .outdated)
    }

    func testLegacyStampWithoutSubagentKeyIsOutdatedNotModifiedLocally() throws {
        let installer = makeInstaller()
        try installer.install()
        try FileManager.default.removeItem(at: installer.subagentScriptURL)

        let mainScript = try String(contentsOf: installer.scriptURL, encoding: .utf8)
        let legacyHashes = [
            StatuslineInstaller.scriptFileName: StatuslineInstaller.sha256(of: mainScript),
        ]
        try installer.writeInstallStamp(StatuslineInstaller.InstallStamp(
            source: StatuslineInstaller.InstallStamp.sourceResources,
            updatedAt: "2026-07-19T00:00:00Z",
            installed: legacyHashes,
            bundled: nil
        ))

        XCTAssertEqual(installer.status(), .outdated)
    }

    func testLegacyStampStillDetectsDriftInPresentSubagentScript() throws {
        let installer = makeInstaller()
        try installer.install()

        let mainScript = try String(contentsOf: installer.scriptURL, encoding: .utf8)
        let legacyHashes = [
            StatuslineInstaller.scriptFileName: StatuslineInstaller.sha256(of: mainScript),
        ]
        try installer.writeInstallStamp(StatuslineInstaller.InstallStamp(
            source: StatuslineInstaller.InstallStamp.sourceResources,
            updatedAt: "2026-07-19T00:00:00Z",
            installed: legacyHashes,
            bundled: nil
        ))
        let changedSubagent = try installer.bundledSubagentScript() + "\n# lokale Anpassung\n"
        try changedSubagent.write(
            to: installer.subagentScriptURL, atomically: true, encoding: .utf8
        )

        XCTAssertEqual(installer.status(), .modifiedLocally)
    }

    func testStatusRepoSyncedWhenResourcesAreAtLeastAsNewAsBundle() throws {
        let installer = makeInstaller()
        try installer.install()

        let repoScript = try installer.bundledScript() + "\n# neuerer Repo-Stand\n"
        try repoScript.write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        let repoHashes = try XCTUnwrap(installer.installedHashes())
        try installer.writeInstallStamp(StatuslineInstaller.InstallStamp(
            source: StatuslineInstaller.InstallStamp.sourceResources,
            updatedAt: "2026-07-20T12:00:00Z",
            installed: repoHashes,
            bundled: try installer.bundledHashes()
        ))

        XCTAssertEqual(installer.status(), .repoSynced)
    }

    func testStatusOutdatedAfterBundleMovedOnSinceRepoSync() throws {
        let installer = makeInstaller()
        try installer.install()

        let oldRepoScript = try installer.bundledScript() + "\n# alter Repo-Stand\n"
        try oldRepoScript.write(to: installer.scriptURL, atomically: true, encoding: .utf8)
        let oldRepoHashes = try XCTUnwrap(installer.installedHashes())
        try installer.writeInstallStamp(StatuslineInstaller.InstallStamp(
            source: StatuslineInstaller.InstallStamp.sourceResources,
            updatedAt: "2026-07-01T00:00:00Z",
            installed: oldRepoHashes,
            bundled: [StatuslineInstaller.scriptFileName: "veralteter-bundle-hash"]
        ))

        XCTAssertEqual(installer.status(), .outdated)
    }

    func testInstallStampSurvivesSyncScriptFormat() throws {
        let installer = makeInstaller()
        let json = """
        {
          "source": "resources",
          "updatedAt": "2026-07-20T12:00:00Z",
          "installed": { "statusline-command.sh": "abc" },
          "bundled": { "statusline-command.sh": "def" }
        }
        """
        try Data(json.utf8).write(to: installer.installStampURL)

        let stamp = try XCTUnwrap(installer.readInstallStamp())
        XCTAssertEqual(stamp.source, StatuslineInstaller.InstallStamp.sourceResources)
        XCTAssertEqual(stamp.installed[StatuslineInstaller.scriptFileName], "abc")
        XCTAssertEqual(stamp.bundled?[StatuslineInstaller.scriptFileName], "def")
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

    func testForeignSubagentScriptIsProtectedUnlessForced() throws {
        let installer = makeInstaller()
        let foreign = "#!/bin/bash\necho eigenes-subagent-skript\n"
        try foreign.write(to: installer.subagentScriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(installer.status(), .foreign)

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(
                error as? StatuslineInstaller.InstallError,
                .foreignScript(path: installer.subagentScriptURL.path)
            )
        }
        XCTAssertEqual(
            try String(contentsOf: installer.subagentScriptURL, encoding: .utf8), foreign
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.scriptURL.path))

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

    func testForeignSubagentStatusLineCommandSurvivesWithoutForce() throws {
        let mainSettings = mainConfigDir.appendingPathComponent("settings.json")
        try Data(#"{"subagentStatusLine":{"type":"command","command":"/eigenes/subagent.sh"}}"#.utf8)
            .write(to: mainSettings)

        let installer = makeInstaller()
        try installer.install()

        let mainObject = try settingsJSON(in: mainConfigDir)
        let mainEntry = try XCTUnwrap(mainObject["statusLine"] as? [String: Any])
        XCTAssertEqual(mainEntry["command"] as? String, "~/.claude/statusline-command.sh")
        let foreignEntry = try XCTUnwrap(mainObject["subagentStatusLine"] as? [String: Any])
        XCTAssertEqual(foreignEntry["command"] as? String, "/eigenes/subagent.sh")
        XCTAssertEqual(installer.wiredSettingsCount(), 1)
        XCTAssertEqual(installer.foreignSettingsCount(), 1)

        try installer.install(replaceForeignSettings: true)
        let forcedEntry = try XCTUnwrap(
            try settingsJSON(in: mainConfigDir)["subagentStatusLine"] as? [String: Any]
        )
        XCTAssertEqual(forcedEntry["command"] as? String, "~/.claude/subagent-statusline.sh")
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
