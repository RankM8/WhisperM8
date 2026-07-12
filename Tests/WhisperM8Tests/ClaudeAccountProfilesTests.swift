import XCTest
@testable import WhisperM8

/// Tests fuer die Claude-Account-Profile (Multi-Account via CLAUDE_CONFIG_DIR).
/// Alles laeuft gegen ein temporaeres Home-Verzeichnis — die echten
/// `~/.claude`/`~/.claude-profiles` des Users werden nie beruehrt.
final class ClaudeAccountProfilesTests: XCTestCase {
    private var home: URL!
    private var service: ClaudeAccountProfiles!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = ClaudeAccountProfiles(homeDirectory: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeProfileDir(_ name: String) throws -> URL {
        let dir = home.appendingPathComponent(".claude-profiles/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeClaudeJSON(email: String, org: String, to url: URL) throws {
        let json = """
        {"oauthAccount": {"emailAddress": "\(email)", "organizationName": "\(org)", "displayName": "Test"}}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Discovery

    func testProfilesAlwaysContainMainFirst() throws {
        _ = try makeProfileDir("zeta")
        _ = try makeProfileDir("alpha")

        let names = service.profiles().map(\.name)

        XCTAssertEqual(names, ["main", "alpha", "zeta"])
    }

    func testProfileReadsAccountInfoFromClaudeJSON() throws {
        let dir = try makeProfileDir("firma")
        try writeClaudeJSON(email: "a@b.de", org: "ACME", to: dir.appendingPathComponent(".claude.json"))
        // main liest historisch aus $HOME/.claude.json, nicht aus dem Config-Dir
        try writeClaudeJSON(email: "main@b.de", org: "Home", to: home.appendingPathComponent(".claude.json"))

        let profiles = service.profiles()

        XCTAssertEqual(profiles.first?.emailAddress, "main@b.de")
        XCTAssertEqual(profiles.last?.emailAddress, "a@b.de")
        XCTAssertTrue(profiles.last?.isLoggedIn ?? false)
    }

    func testProfileWithoutLoginIsNotLoggedIn() throws {
        _ = try makeProfileDir("frisch")

        let profile = service.profile(named: "frisch")

        XCTAssertFalse(profile.isLoggedIn)
    }

    // MARK: - Aktives Profil

    func testActiveProfileDefaultsToMain() {
        XCTAssertEqual(service.activeProfileName(), "main")
        XCTAssertNil(service.activeProfileNameOrNil())
    }

    func testSetActiveProfileRoundtrip() throws {
        _ = try makeProfileDir("firma")

        try service.setActiveProfile("firma")

        XCTAssertEqual(service.activeProfileName(), "firma")
        XCTAssertEqual(service.activeProfileNameOrNil(), "firma")
    }

    func testActiveProfileFallsBackToMainWhenDirMissing() throws {
        _ = try makeProfileDir("firma")
        try service.setActiveProfile("firma")
        try FileManager.default.removeItem(at: service.configDir(forProfile: "firma"))

        XCTAssertEqual(service.activeProfileName(), "main")
    }

    // MARK: - Env-Injektion

    func testEnvironmentOverridesForMainAndNilAreEmpty() throws {
        XCTAssertTrue(service.environmentOverrides(forProfile: nil).isEmpty)
        XCTAssertTrue(service.environmentOverrides(forProfile: "main").isEmpty)
    }

    func testEnvironmentOverridesForProfileSetConfigDir() throws {
        let dir = try makeProfileDir("firma")

        let env = service.environmentOverrides(forProfile: "firma")

        XCTAssertEqual(env, ["CLAUDE_CONFIG_DIR": dir.path])
    }

    func testEnvironmentOverridesForMissingProfileFallBackToEmpty() {
        XCTAssertTrue(service.environmentOverrides(forProfile: "geloescht").isEmpty)
    }

    // MARK: - Transcript-Roots

    func testClaudeProjectsRootsContainMainAndProfiles() throws {
        _ = try makeProfileDir("firma")

        let roots = service.claudeProjectsRoots().map(\.path)

        XCTAssertEqual(roots, [
            home.appendingPathComponent(".claude/projects").path,
            home.appendingPathComponent(".claude-profiles/firma/projects").path,
        ])
    }

    func testProfileNameForTranscriptPath() {
        XCTAssertEqual(
            ClaudeAccountProfiles.profileName(
                forTranscriptPath: "/Users/x/.claude-profiles/firma/projects/-repo/abc.jsonl"
            ),
            "firma"
        )
        XCTAssertNil(
            ClaudeAccountProfiles.profileName(
                forTranscriptPath: "/Users/x/.claude/projects/-repo/abc.jsonl"
            )
        )
    }

    // MARK: - Profil anlegen

    func testCreateProfileCreatesDirAndSymlinks() throws {
        let mainDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try "{}".write(to: mainDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let profile = try service.createProfile(named: "firma")

        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.configDir.path))
        let link = profile.configDir.appendingPathComponent("settings.json").path
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link),
            mainDir.appendingPathComponent("settings.json").path
        )
    }

    func testCreateProfileRejectsInvalidNames() {
        XCTAssertThrowsError(try service.createProfile(named: "main"))
        XCTAssertThrowsError(try service.createProfile(named: ""))
        XCTAssertThrowsError(try service.createProfile(named: "hat spaces"))
        XCTAssertThrowsError(try service.createProfile(named: "../evil"))
    }

    func testCreateProfileRejectsDuplicates() throws {
        _ = try service.createProfile(named: "firma")

        XCTAssertThrowsError(try service.createProfile(named: "firma")) { error in
            XCTAssertEqual(error as? ClaudeAccountProfiles.CreateError, .alreadyExists("firma"))
        }
    }
}
