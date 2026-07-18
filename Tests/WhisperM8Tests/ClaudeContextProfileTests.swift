import XCTest
@testable import WhisperM8

/// Tests fuer das Context-Profil-Modell, den Store (CRUD + leniente
/// Aufloesung) und den Settings-Fragment-Builder.
@MainActor
final class ClaudeContextProfileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var fileURL: URL {
        tempDir.appendingPathComponent("profiles.json")
    }

    private func makeProfile(name: String = "Coding") -> ClaudeContextProfile {
        ClaudeContextProfile(
            name: name,
            deniedMcpServers: ["claude.ai Gmail", "claude.ai Miro"],
            disabledMcpjsonServers: ["playwright"],
            enabledPlugins: ["leadgenjay@360-plugins": false],
            environment: ["ENABLE_CLAUDEAI_MCP_SERVERS": "false"]
        )
    }

    // MARK: Store: CRUD + Persistenz

    func testUpsertPersistsAndReloads() throws {
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        let profile = makeProfile()
        try store.upsert(profile)

        let reloaded = ClaudeContextProfileStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.id, profile.id)
        XCTAssertEqual(reloaded.profiles.first?.deniedMcpServers, profile.deniedMcpServers)
        XCTAssertEqual(reloaded.profiles.first?.enabledPlugins, profile.enabledPlugins)
    }

    func testUpsertUpdatesExistingByID() throws {
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        var profile = makeProfile()
        try store.upsert(profile)
        profile.name = "Umbenannt"
        try store.upsert(profile)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Umbenannt")
    }

    func testDeleteRemovesProfile() throws {
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        let profile = makeProfile()
        try store.upsert(profile)
        try store.delete(id: profile.id)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(ClaudeContextProfileStore(fileURL: fileURL).profiles.isEmpty)
    }

    // MARK: Store: leniente Dekodierung

    func testLoadToleratesMissingFieldsAndUnknownSchema() throws {
        // Minimale Datei ohne schemaVersion, Profil nur mit id — alles andere
        // muss auf Defaults fallen statt den Bestand zu verwerfen.
        let json = """
        { "profiles": [ { "id": "1B671A64-40D5-491E-99B0-DA01FF1F3341" } ] }
        """
        try json.data(using: .utf8)!.write(to: fileURL)
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Profil")
        XCTAssertEqual(store.profiles.first?.isEmpty, true)
    }

    func testLoadWithCorruptFileYieldsEmptyListAndQuarantinesFile() throws {
        try "kein json".data(using: .utf8)!.write(to: fileURL)
        XCTAssertTrue(ClaudeContextProfileStore(fileURL: fileURL).profiles.isEmpty)
        // Quarantaene-Backup: der naechste persist() darf den alten Bestand
        // nicht endgueltig plattmachen (Review-Befund 2026-07-19).
        let quarantine = tempDir.appendingPathComponent("profiles.json.decode-failed.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testSingleBrokenProfileDoesNotDropTheWholeStore() throws {
        // Ein Profil mit kaputter UUID → nur dieses eine faellt raus
        // (Review-Befund 2026-07-19: vorher verwarf es den ganzen Bestand,
        // und der naechste upsert ueberschrieb die Datei leer).
        let json = """
        { "schemaVersion": 1, "profiles": [
            { "id": "NICHT-EINE-UUID", "name": "Kaputt" },
            { "id": "1B671A64-40D5-491E-99B0-DA01FF1F3341", "name": "Heil" }
        ] }
        """
        try json.data(using: .utf8)!.write(to: fileURL)
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        XCTAssertEqual(store.profiles.map(\.name), ["Heil"])
    }

    func testFailedPersistRollsBackInMemoryState() throws {
        // Parent-Pfad ist eine DATEI → createDirectory/persist muss scheitern;
        // der In-Memory-Bestand darf danach nicht vom Disk-Stand abweichen.
        let blockingFile = tempDir.appendingPathComponent("blocker")
        try Data().write(to: blockingFile)
        let unwritable = blockingFile.appendingPathComponent("profiles.json")
        let store = ClaudeContextProfileStore(fileURL: unwritable)

        XCTAssertThrowsError(try store.upsert(makeProfile()))
        XCTAssertTrue(store.profiles.isEmpty)
    }

    // MARK: Store: Aufloesungs-Kette

    func testResolvedProfilePrefersSessionStampOverProjectDefault() throws {
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        let stamped = makeProfile(name: "Session")
        let projectDefault = makeProfile(name: "Projekt")
        try store.upsert(stamped)
        try store.upsert(projectDefault)

        XCTAssertEqual(
            store.resolvedProfile(sessionStamp: stamped.id, projectDefault: projectDefault.id)?.name,
            "Session"
        )
        XCTAssertEqual(
            store.resolvedProfile(sessionStamp: nil, projectDefault: projectDefault.id)?.name,
            "Projekt"
        )
        XCTAssertNil(store.resolvedProfile(sessionStamp: nil, projectDefault: nil))
    }

    func testResolvedProfileWithDeletedStampDoesNotFallBackToProjectDefault() throws {
        let store = ClaudeContextProfileStore(fileURL: fileURL)
        let projectDefault = makeProfile(name: "Projekt")
        try store.upsert(projectDefault)
        // Gestempeltes Profil existiert nicht (geloescht) → bewusst KEIN
        // stiller Fallback auf den Projekt-Default.
        XCTAssertNil(store.resolvedProfile(sessionStamp: UUID(), projectDefault: projectDefault.id))
    }

    // MARK: Settings-Fragment-Builder

    func testSettingsFragmentShape() throws {
        let fragment = ClaudeContextSettingsBuilder.settingsFragment(for: makeProfile())

        // deniedMcpServers MUSS als Dict-Array serialisieren (Claude-Format).
        let denied = try XCTUnwrap(fragment["deniedMcpServers"] as? [[String: String]])
        XCTAssertEqual(denied, [
            ["serverName": "claude.ai Gmail"],
            ["serverName": "claude.ai Miro"]
        ])
        XCTAssertEqual(fragment["disabledMcpjsonServers"] as? [String], ["playwright"])
        XCTAssertEqual(fragment["enabledPlugins"] as? [String: Bool], ["leadgenjay@360-plugins": false])
        XCTAssertEqual(fragment["env"] as? [String: String], ["ENABLE_CLAUDEAI_MCP_SERVERS": "false"])
    }

    func testEmptyProfileYieldsEmptyFragment() {
        let fragment = ClaudeContextSettingsBuilder.settingsFragment(
            for: ClaudeContextProfile(name: "Leer")
        )
        XCTAssertTrue(fragment.isEmpty)
    }

    func testReservedEnvironmentKeysAreFiltered() {
        let profile = ClaudeContextProfile(
            name: "Boese",
            environment: [
                "CLAUDE_CONFIG_DIR": "/tmp/kapern",
                "ANTHROPIC_BASE_URL": "http://evil",
                "ANTHROPIC_API_KEY": "x",
                "PATH": "/tmp",
                "ENABLE_TOOL_SEARCH": "auto"
            ]
        )
        let fragment = ClaudeContextSettingsBuilder.settingsFragment(for: profile)
        XCTAssertEqual(fragment["env"] as? [String: String], ["ENABLE_TOOL_SEARCH": "auto"])
        XCTAssertEqual(
            ClaudeContextSettingsBuilder.processEnvironmentOverlay(for: profile),
            ["ENABLE_TOOL_SEARCH": "auto"]
        )
        XCTAssertTrue(ClaudeContextSettingsBuilder.processEnvironmentOverlay(for: nil).isEmpty)
    }

    func testMergedIsFlatAndLastWins() {
        let merged = ClaudeContextSettingsBuilder.merged([
            ["hooks": ["Stop": []], "a": 1],
            ["deniedMcpServers": [["serverName": "x"]], "a": 2]
        ])
        XCTAssertEqual(Set(merged.keys), ["hooks", "deniedMcpServers", "a"])
        XCTAssertEqual(merged["a"] as? Int, 2)
    }

    // MARK: Workspace-Modell: Decode-Abwaertskompatibilitaet

    func testProjectAndSessionDecodeWithoutContextProfileID() throws {
        // Muster AgentProjectMetadataTests: JSON ohne das neue Feld → nil.
        let projectJSON = """
        {
            "id": "1B671A64-40D5-491E-99B0-DA01FF1F3341",
            "name": "P", "path": "/tmp", "color": "blue",
            "createdAt": "2026-01-01T00:00:00Z", "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(AgentProject.self, from: projectJSON.data(using: .utf8)!)
        XCTAssertNil(project.contextProfileID)

        let sessionJSON = """
        {
            "id": "1B671A64-40D5-491E-99B0-DA01FF1F3342",
            "provider": "claude",
            "projectID": "1B671A64-40D5-491E-99B0-DA01FF1F3341",
            "title": "S",
            "createdAt": "2026-01-01T00:00:00Z",
            "lastActivityAt": "2026-01-01T00:00:00Z"
        }
        """
        let session = try decoder.decode(AgentChatSession.self, from: sessionJSON.data(using: .utf8)!)
        XCTAssertNil(session.contextProfileID)
    }

    func testStoreMutatorRoundTrip() throws {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let projectDir = tempDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let profileID = UUID()

        let session = try store.createSession(
            provider: .claude,
            projectPath: projectDir.path,
            title: "Chat",
            contextProfileID: profileID
        )
        XCTAssertEqual(session.contextProfileID, profileID)

        let projectID = try XCTUnwrap(store.loadWorkspace().projects.first?.id)
        try store.setProjectContextProfile(id: projectID, profileID: profileID)

        let reloaded = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json")).loadWorkspace()
        XCTAssertEqual(reloaded.projects.first?.contextProfileID, profileID)
        XCTAssertEqual(reloaded.sessions.first?.contextProfileID, profileID)

        try store.setProjectContextProfile(id: projectID, profileID: nil)
        XCTAssertNil(store.loadWorkspace().projects.first?.contextProfileID)
    }
}
