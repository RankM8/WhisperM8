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
        XCTAssertTrue(subagentScript.contains("startTime"))
        XCTAssertTrue(subagentScript.contains("elapsed_label"))
        XCTAssertFalse(subagentScript.contains("tokenCount"))
        XCTAssertFalse(subagentScript.contains("contextWindowSize"))
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

    // MARK: GPT-Kontextmetadaten

    func testMainStatuslineCorrectsGPTCustomModelFallbackTo272K() throws {
        let input: [String: Any] = [
            "model": ["display_name": "gpt-5.6-sol"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
                "context_window_size": 200_000,
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-gpt-context-statusline.sh",
            input: input,
            environmentOverrides: ["WHISPERM8_GPT56_CONTEXT_WINDOW": "272000"]
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("9k/272k"), text)
    }

    func testMainStatuslineWithoutExplicitGPTCapacityKeepsReported200K() throws {
        let input: [String: Any] = [
            "model": ["display_name": "gpt-5.6-sol"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
                "context_window_size": 200_000,
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-gpt-context-without-env-statusline.sh",
            input: input
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("9k/200k"), text)
        XCTAssertFalse(text.contains("9k/272k"), text)
    }

    func testMainStatuslineUsesConfiguredGPTModelCapacity() throws {
        let input: [String: Any] = [
            "model": ["display_name": "gpt-5.4-mini"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
                "context_window_size": 200_000,
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-custom-gpt-context-statusline.sh",
            input: input,
            environmentOverrides: ["WHISPERM8_GPT56_CONTEXT_WINDOW": "250000"]
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("9k/250k"), text)
        XCTAssertFalse(text.contains("9k/1000k"), text)
    }

    func testMainStatuslineUsesSol372KCompactBudgetAt339K() throws {
        func input(currentTokens: Int) -> [String: Any] {
            [
                "model": ["display_name": "gpt-5.6-sol-fast"],
                "cost": ["total_cost_usd": 0],
                "context_window": [
                    "current_usage": [
                        "input_tokens": currentTokens,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 0,
                    ],
                    "context_window_size": 200_000,
                ],
                "mcp_servers": [],
            ]
        }

        let beforeOutput = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-sol-372k-before-compact-statusline.sh",
            input: input(currentTokens: 338_000),
            environmentOverrides: ["WHISPERM8_GPT56_CONTEXT_WINDOW": "372000"]
        )
        let beforeText = String(decoding: beforeOutput, as: UTF8.self)
        XCTAssertTrue(beforeText.contains("99%"), beforeText)
        XCTAssertTrue(beforeText.contains("338k/372k"), beforeText)

        let atOutput = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-sol-372k-at-compact-statusline.sh",
            input: input(currentTokens: 339_000),
            environmentOverrides: ["WHISPERM8_GPT56_CONTEXT_WINDOW": "372000"]
        )
        let atText = String(decoding: atOutput, as: UTF8.self)
        XCTAssertTrue(atText.contains("100%"), atText)
        XCTAssertTrue(atText.contains("339k/372k"), atText)
    }

    func testMainStatuslineDoesNotApplySol372KProfileToTerra() throws {
        let input: [String: Any] = [
            "model": ["display_name": "gpt-5.6-terra-fast"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
                "context_window_size": 200_000,
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-terra-rejects-sol-372k-statusline.sh",
            input: input,
            environmentOverrides: ["WHISPERM8_GPT56_CONTEXT_WINDOW": "372000"]
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("9k/200k"), text)
        XCTAssertFalse(text.contains("9k/372k"), text)
    }

    func testMainStatuslineDoesNotRewriteSimilarGPTCustomID() throws {
        let input: [String: Any] = [
            "model": ["display_name": "gpt-5.6-solar"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
                "context_window_size": 200_000,
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-foreign-gpt-context-statusline.sh",
            input: input
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("9k/200k"), text)
        XCTAssertFalse(text.contains("9k/272k"), text)
    }

    func testMainStatuslineHandlesMissingContextWindowSize() throws {
        let input: [String: Any] = [
            "model": ["display_name": "gpt-5.6-terra"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-missing-context-statusline.sh",
            input: input,
            environmentOverrides: ["WHISPERM8_GPT56_CONTEXT_WINDOW": "272000"]
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains("9k/272k"), text)
    }

    func testMainStatuslineDoesNotInventMissingClaudeWindow() throws {
        let input: [String: Any] = [
            "model": ["display_name": "claude-fable-5"],
            "cost": ["total_cost_usd": 0],
            "context_window": [
                "current_usage": [
                    "input_tokens": 9_000,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
            ],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-missing-fable-context-statusline.sh",
            input: input
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertFalse(text.contains("9k/200k"), text)
        XCTAssertFalse(text.contains("9k/272k"), text)
    }

    func testSubagentStatuslineShowsElapsedTimeInsteadOfTokens() throws {
        let now = 1_700_000_712_000
        let input: [String: Any] = [
            "columns": 120,
            "tasks": [
                [
                    "id": "running-task",
                    "name": "ui-reviewer",
                    "status": "running",
                    "startTime": 1_700_000_000_000,
                    "model": "gpt-5.6-sol",
                    "description": "Review UI-Regeländerungen",
                    // Claude Code liefert für GPT häufig dauerhaft nullartige
                    // Fortschrittswerte. Sie dürfen nicht mehr sichtbar sein.
                    "tokenCount": 0,
                    "contextWindowSize": 272_000,
                ],
                [
                    "id": "completed-task",
                    "name": "done-reviewer",
                    "status": "completed",
                    "startTime": 1_700_000_000_000,
                    "model": "gpt-5.6-terra",
                    "description": "Review abgeschlossen",
                    "tokenCount": 9_000,
                    "contextWindowSize": 272_000,
                ],
                [
                    "id": "missing-start-task",
                    "name": "new-reviewer",
                    "status": "running",
                    "model": "gpt-5.6-sol",
                    "description": "Wartet auf Startmetadaten",
                    "tokenCount": 9_000,
                    "contextWindowSize": 272_000,
                ],
            ],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledSubagentScript(),
            named: "subagent-elapsed-statusline.sh",
            input: input,
            environmentOverrides: [
                "WHISPERM8_SUBAGENT_STATUSLINE_NOW_MS": String(now),
            ]
        )
        let lines = try XCTUnwrap(String(data: output, encoding: .utf8))
            .split(separator: "\n")
        let objects = try lines.map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
        let byID: [String: String] = Dictionary(
            uniqueKeysWithValues: objects.compactMap { object -> (String, String)? in
                guard let id = object["id"] as? String,
                      let content = object["content"] as? String else { return nil }
                return (id, content)
            }
        )

        let running = try XCTUnwrap(byID["running-task"])
        XCTAssertTrue(running.contains("gpt-5.6-sol"), running)
        XCTAssertTrue(running.contains("Review UI-Regeländerungen"), running)
        XCTAssertTrue(running.contains("11m 52s"), running)

        let completed = try XCTUnwrap(byID["completed-task"])
        XCTAssertTrue(completed.contains("gpt-5.6-terra"), completed)
        XCTAssertFalse(completed.contains("11m 52s"), completed)

        let missingStart = try XCTUnwrap(byID["missing-start-task"])
        XCTAssertFalse(missingStart.contains("11m 52s"), missingStart)

        let allContent = byID.values.joined(separator: "\n")
        XCTAssertFalse(allContent.contains("0k/"), allContent)
        XCTAssertFalse(allContent.contains("9k/"), allContent)
        XCTAssertFalse(allContent.contains("272k"), allContent)
    }

    func testSubagentStatuslineFormatsElapsedTimeAcrossRanges() throws {
        let now = 1_700_100_000_000
        let input: [String: Any] = [
            "columns": 100,
            "tasks": [
                [
                    "id": "seconds",
                    "name": "seconds-worker",
                    "status": "running",
                    "startTime": now - 42_000,
                    "model": "gpt-5.6-sol",
                ],
                [
                    "id": "minutes",
                    "name": "minutes-worker",
                    "status": "running",
                    "startTime": now - 662_000,
                    "model": "gpt-5.6-sol",
                ],
                [
                    "id": "hours",
                    "name": "hours-worker",
                    "status": "running",
                    "startTime": now - 4_110_000,
                    "model": "gpt-5.6-sol",
                ],
                [
                    "id": "future",
                    "name": "future-worker",
                    "status": "running",
                    "startTime": now + 1_000,
                    "model": "gpt-5.6-sol",
                ],
            ],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledSubagentScript(),
            named: "subagent-elapsed-ranges-statusline.sh",
            input: input,
            environmentOverrides: [
                "WHISPERM8_SUBAGENT_STATUSLINE_NOW_MS": String(now),
            ]
        )
        let lines = try XCTUnwrap(String(data: output, encoding: .utf8))
            .split(separator: "\n")
        let byID: [String: String] = Dictionary(
            uniqueKeysWithValues: try lines.map { line -> (String, String) in
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
                return (
                    try XCTUnwrap(object["id"] as? String),
                    try XCTUnwrap(object["content"] as? String)
                )
            }
        )

        XCTAssertTrue(try XCTUnwrap(byID["seconds"]).contains("42s"))
        XCTAssertTrue(try XCTUnwrap(byID["minutes"]).contains("11m 02s"))
        XCTAssertTrue(try XCTUnwrap(byID["hours"]).contains("1h 08m"))
        let future = try XCTUnwrap(byID["future"])
        XCTAssertFalse(future.hasSuffix("s\u{001B}[0m"), future)
        XCTAssertFalse(future.hasSuffix("m\u{001B}[0m"), future)
    }

    // MARK: Terminal-Steuerzeichen

    func testMainStatuslineSanitizesExternalTerminalSequences() throws {
        let escape = String(UnicodeScalar(0x1B)!)
        let bell = String(UnicodeScalar(0x07)!)
        let payload = "SAFE\\n\(escape)]52;c;Y29waWVk\(bell)END\\cTAIL"
        let input: [String: Any] = [
            "model": ["display_name": payload],
            "cost": ["total_cost_usd": 0],
            "context_window": ["current_usage": NSNull()],
            "mcp_servers": [],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledScript(),
            named: "main-statusline.sh",
            input: input
        )
        let text = String(decoding: output, as: UTF8.self)

        XCTAssertTrue(text.contains(#"SAFE\n"#), text)
        XCTAssertTrue(text.contains(#"END\cTAIL"#), text)
        assertContainsOnlyFixedANSIControls(output, allowsTrailingLineFeed: true)
    }

    func testSubagentStatuslineSanitizesTaskTerminalSequences() throws {
        let escape = String(UnicodeScalar(0x1B)!)
        let bell = String(UnicodeScalar(0x07)!)
        let payload = "SAFE\\n\(escape)]52;c;Y29waWVk\(bell)END\\cTAIL"
        let input: [String: Any] = [
            "columns": 200,
            "tasks": [[
                "id": "task-1",
                "name": "worker",
                "model": "claude-sonnet-5",
                "description": payload,
            ]],
        ]

        let output = try runStatuslineScript(
            try makeInstaller().bundledSubagentScript(),
            named: "subagent-statusline.sh",
            input: input
        )
        let line = try XCTUnwrap(String(data: output, encoding: .utf8)?.split(separator: "\n").first)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let content = try XCTUnwrap(object["content"] as? String)

        XCTAssertTrue(content.contains(#"SAFE\n"#), content)
        XCTAssertTrue(content.contains(#"END\cTAIL"#), content)
        assertContainsOnlyFixedANSIControls(
            Data(content.utf8),
            allowsTrailingLineFeed: false
        )
    }

    private func runStatuslineScript(
        _ script: String,
        named fileName: String,
        input: [String: Any],
        environmentOverrides: [String: String] = [:]
    ) throws -> Data {
        let scriptURL = tempHome.appendingPathComponent(fileName)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let temporaryDirectory = tempHome.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.currentDirectoryURL = tempHome
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = tempHome.path
        environment["TMPDIR"] = temporaryDirectory.path + "/"
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        environment.removeValue(forKey: "WHISPERM8_GPT56_CONTEXT_WINDOW")
        environment.removeValue(forKey: "WHISPERM8_SUBAGENT_STATUSLINE_NOW_MS")
        environment.merge(environmentOverrides) { _, override in override }
        process.environment = environment

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        standardInput.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: error, as: UTF8.self)
        )
        return output
    }

    private func assertContainsOnlyFixedANSIControls(
        _ data: Data,
        allowsTrailingLineFeed: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                var end = index + 2
                guard index + 2 < bytes.count, bytes[index + 1] == 0x5B else {
                    return XCTFail("Unerlaubte ESC-Sequenz bei Byte \(index)", file: file, line: line)
                }
                while end < bytes.count,
                      (bytes[end] == 0x3B || (0x30...0x39).contains(bytes[end])) {
                    end += 1
                }
                guard end < bytes.count, bytes[end] == 0x6D else {
                    return XCTFail("Unerlaubte ANSI-Sequenz bei Byte \(index)", file: file, line: line)
                }
                index = end + 1
                continue
            }
            if byte == 0x0A, allowsTrailingLineFeed, index == bytes.count - 1 {
                index += 1
                continue
            }
            if byte < 0x20 || byte == 0x7F {
                return XCTFail("Unerlaubtes Steuerbyte 0x\(String(byte, radix: 16))", file: file, line: line)
            }
            if byte == 0xC2, index + 1 < bytes.count, (0x80...0x9F).contains(bytes[index + 1]) {
                return XCTFail("Unerlaubtes C1-Steuerzeichen bei Byte \(index)", file: file, line: line)
            }
            index += 1
        }
    }
}
