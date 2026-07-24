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

// MARK: - Move to Account (Transcript-Umzug)

extension ClaudeAccountProfilesTests {
    private func makeTranscript(inRoot root: URL, cwd: String, sessionID: String, withSubagents: Bool = false) throws -> URL {
        let encoded = AgentTranscriptLocator.encodeClaudeCwd(cwd)
        let dir = root.appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionID).jsonl")
        try "{\"sessionId\": \"\(sessionID)\"}\n".write(to: file, atomically: true, encoding: .utf8)
        if withSubagents {
            let subagents = dir.appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try "{}".write(to: subagents.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        }
        return file
    }

    private var mainProjectsRoot: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func testMoveTranscriptFromMainToProfile() throws {
        let service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "firma")
        let cwd = "/Users/x/repos/demo"
        let source = try makeTranscript(inRoot: mainProjectsRoot, cwd: cwd, sessionID: "abc-123", withSubagents: true)

        let moved = try service.moveTranscript(externalSessionID: "abc-123", cwd: cwd, toProfile: "firma")

        XCTAssertTrue(moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let encoded = AgentTranscriptLocator.encodeClaudeCwd(cwd)
        let targetDir = home.appendingPathComponent(".claude-profiles/firma/projects/\(encoded)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("abc-123.jsonl").path))
        // Subagent-Ordner wandert mit
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: targetDir.appendingPathComponent("abc-123/subagents/agent-1.jsonl").path
        ))
    }

    func testMoveTranscriptBackToMain() throws {
        let service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "firma")
        let cwd = "/Users/x/repos/demo"
        let profileRoot = home.appendingPathComponent(".claude-profiles/firma/projects", isDirectory: true)
        _ = try makeTranscript(inRoot: profileRoot, cwd: cwd, sessionID: "abc-123")

        let moved = try service.moveTranscript(externalSessionID: "abc-123", cwd: cwd, toProfile: nil)

        XCTAssertTrue(moved)
        let encoded = AgentTranscriptLocator.encodeClaudeCwd(cwd)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: mainProjectsRoot.appendingPathComponent("\(encoded)/abc-123.jsonl").path
        ))
    }

    func testMoveTranscriptWithoutFileReturnsFalse() throws {
        let service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "firma")

        XCTAssertFalse(try service.moveTranscript(externalSessionID: "fehlt", cwd: "/x", toProfile: "firma"))
    }

    func testMoveTranscriptToMissingProfileThrows() {
        let service = ClaudeAccountProfiles(homeDirectory: home)

        XCTAssertThrowsError(
            try service.moveTranscript(externalSessionID: "abc", cwd: "/x", toProfile: "geloescht")
        ) { error in
            XCTAssertEqual(
                error as? ClaudeAccountProfiles.MoveError,
                .targetProfileMissing("geloescht")
            )
        }
    }

    func testMoveTranscriptRefusesToOverwriteTarget() throws {
        let service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "firma")
        let cwd = "/Users/x/repos/demo"
        _ = try makeTranscript(inRoot: mainProjectsRoot, cwd: cwd, sessionID: "abc-123")
        let profileRoot = home.appendingPathComponent(".claude-profiles/firma/projects", isDirectory: true)
        _ = try makeTranscript(inRoot: profileRoot, cwd: cwd, sessionID: "abc-123")

        // Gleiche Session-ID existiert im Ziel → niemals ueberschreiben.
        // (Quelle main → Ziel firma; der Locator findet main zuerst.)
        XCTAssertThrowsError(
            try service.moveTranscript(externalSessionID: "abc-123", cwd: cwd, toProfile: "firma")
        )
    }

    func testMoveTranscriptAlreadyInTargetIsNoOp() throws {
        let service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "firma")
        let cwd = "/Users/x/repos/demo"
        let profileRoot = home.appendingPathComponent(".claude-profiles/firma/projects", isDirectory: true)
        let file = try makeTranscript(inRoot: profileRoot, cwd: cwd, sessionID: "abc-123")

        XCTAssertFalse(try service.moveTranscript(externalSessionID: "abc-123", cwd: cwd, toProfile: "firma"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

// MARK: - Keychain-Service & Rename

extension ClaudeAccountProfilesTests {
    func testKeychainServiceUsesVerifiedSHA256Suffix() {
        // Ground truth vom echten System (claude v2.1.207, 2026-07-12):
        // ~/.claude-profiles/PowerUser → Eintrag "…-7aab1f41".
        let service = ClaudeAccountProfiles(
            homeDirectory: URL(fileURLWithPath: "/Users/giulianocosta")
        )
        XCTAssertEqual(
            service.keychainService(forProfile: "PowerUser"),
            "Claude Code-credentials-7aab1f41"
        )
        XCTAssertEqual(service.keychainService(forProfile: "main"), "Claude Code-credentials")
    }

    func testCreateProfileWritesKeychainServiceMarker() throws {
        let profile = try service.createProfile(named: "firma")

        let marker = profile.configDir.appendingPathComponent(".keychain-service")
        let content = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(content, service.keychainService(forProfile: "firma"))
    }

    func testRenameProfileMovesDirAndKeychain() throws {
        var service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "alt")
        try service.setActiveProfile("alt")
        var securityCalls: [[String]] = []
        service.securityRunner = { arguments in
            securityCalls.append(arguments)
            if arguments.first == "find-generic-password" { return (0, "{\"claudeAiOauth\":{}}") }
            return (0, "")
        }

        try service.renameProfile(from: "alt", to: "neu")

        XCTAssertFalse(FileManager.default.fileExists(atPath: service.configDir(forProfile: "alt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.configDir(forProfile: "neu").path))
        // Keychain: gelesen (alter Service), angelegt (neuer), alter geloescht
        let oldService = service.keychainService(forProfile: "alt")
        let newService = service.keychainService(forProfile: "neu")
        XCTAssertTrue(securityCalls.contains { $0.first == "find-generic-password" && $0.contains(oldService) })
        XCTAssertTrue(securityCalls.contains { $0.first == "add-generic-password" && $0.contains(newService) })
        XCTAssertTrue(securityCalls.contains { $0.first == "delete-generic-password" && $0.contains(oldService) })
        // .active zieht mit, Marker aktualisiert
        XCTAssertEqual(service.activeProfileName(), "neu")
        XCTAssertEqual(
            try String(contentsOf: service.configDir(forProfile: "neu").appendingPathComponent(".keychain-service"), encoding: .utf8),
            newService
        )
    }

    func testRenameProfileRollsBackWhenKeychainAddFails() throws {
        var service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "alt")
        service.securityRunner = { arguments in
            if arguments.first == "find-generic-password" { return (0, "{\"claudeAiOauth\":{}}") }
            if arguments.first == "add-generic-password" { return (1, "") }
            return (0, "")
        }

        XCTAssertThrowsError(try service.renameProfile(from: "alt", to: "neu"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: service.configDir(forProfile: "alt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.configDir(forProfile: "neu").path))
    }

    func testRenameProfileWithoutLoginSkipsKeychainOps() throws {
        var service = ClaudeAccountProfiles(homeDirectory: home)
        _ = try service.createProfile(named: "alt")
        var mutatingCalls: [String] = []
        service.securityRunner = { arguments in
            if arguments.first != "find-generic-password" { mutatingCalls.append(arguments.first ?? "") }
            return (44, "")  // errSecItemNotFound-artiger Fehler beim Lesen
        }

        try service.renameProfile(from: "alt", to: "neu")

        XCTAssertTrue(mutatingCalls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.configDir(forProfile: "neu").path))
    }

    func testRenameProfileGuards() throws {
        _ = try service.createProfile(named: "alt")
        _ = try service.createProfile(named: "belegt")

        XCTAssertThrowsError(try service.renameProfile(from: "main", to: "x"))
        XCTAssertThrowsError(try service.renameProfile(from: "fehlt", to: "x"))
        XCTAssertThrowsError(try service.renameProfile(from: "alt", to: "belegt"))
        XCTAssertThrowsError(try service.renameProfile(from: "alt", to: "böse name"))
    }
}

// MARK: - Usage-Parsing

final class ClaudeAccountUsageFetcherTests: XCTestCase {
    func testParseUsageEndpointShape() throws {
        let json = """
        {"five_hour": {"utilization": 24.4, "resets_at": "2026-07-12T18:00:00.123456+00:00"},
         "seven_day": {"utilization": 6.0, "resets_at": "2026-07-17T17:00:00Z"}}
        """
        let usage = try XCTUnwrap(
            ClaudeAccountUsageFetcher.parseUsage(Data(json.utf8), fetchedAt: Date(), isLive: true)
        )
        XCTAssertEqual(usage.fiveHourPercent, 24.4)
        XCTAssertEqual(usage.sevenDayPercent, 6.0)
        XCTAssertNotNil(usage.fiveHourResetsAt)
        XCTAssertNotNil(usage.sevenDayResetsAt)
        XCTAssertTrue(usage.isLive)
    }

    func testParseUsageStatuslineStdinShape() throws {
        // Offizielles rate_limits-Format: used_percentage + Epoch-Sekunden
        let json = """
        {"five_hour": {"used_percentage": 12, "resets_at": 1784000000}}
        """
        let usage = try XCTUnwrap(
            ClaudeAccountUsageFetcher.parseUsage(Data(json.utf8), fetchedAt: Date(), isLive: false)
        )
        XCTAssertEqual(usage.fiveHourPercent, 12)
        XCTAssertEqual(usage.fiveHourResetsAt, Date(timeIntervalSince1970: 1_784_000_000))
        XCTAssertNil(usage.sevenDayPercent)
    }

    func testParseUsageRejectsGarbage() {
        XCTAssertNil(ClaudeAccountUsageFetcher.parseUsage(Data("{}".utf8), fetchedAt: Date(), isLive: true))
        XCTAssertNil(ClaudeAccountUsageFetcher.parseUsage(Data("kaputt".utf8), fetchedAt: Date(), isLive: true))
    }
}

extension ClaudeAccountUsageFetcherTests {
    func testParseUsageExtractsModelScopedWeeklyLimit() throws {
        // Reale Antwort-Form des oauth/usage-Endpoints (verifiziert 2026-07-12):
        // limits[] enthaelt session, weekly_all und weekly_scoped (Fable).
        let json = """
        {"five_hour": {"utilization": 18.0, "resets_at": "2026-07-12T20:09:59.933524+00:00"},
         "seven_day": {"utilization": 10.0, "resets_at": "2026-07-18T15:59:59.933546+00:00"},
         "limits": [
           {"kind": "session", "group": "session", "percent": 18, "resets_at": "2026-07-12T20:09:59.933524+00:00", "scope": null},
           {"kind": "weekly_all", "group": "weekly", "percent": 10, "resets_at": "2026-07-18T15:59:59.933546+00:00", "scope": null},
           {"kind": "weekly_scoped", "group": "weekly", "percent": 18, "resets_at": "2026-07-18T15:59:59.933828+00:00",
            "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
         ]}
        """
        let usage = try XCTUnwrap(
            ClaudeAccountUsageFetcher.parseUsage(Data(json.utf8), fetchedAt: Date(), isLive: true)
        )
        XCTAssertEqual(usage.modelWeeklyPercent, 18)
        XCTAssertEqual(usage.modelWeeklyLabel, "Fable")
        XCTAssertNotNil(usage.modelWeeklyResetsAt)
        // Die Basis-Fenster bleiben unangetastet
        XCTAssertEqual(usage.fiveHourPercent, 18.0)
        XCTAssertEqual(usage.sevenDayPercent, 10.0)
    }

    func testParseUsageWithoutLimitsArrayHasNoModelWeekly() throws {
        let json = """
        {"five_hour": {"utilization": 5.0, "resets_at": "2026-07-12T20:00:00Z"}}
        """
        let usage = try XCTUnwrap(
            ClaudeAccountUsageFetcher.parseUsage(Data(json.utf8), fetchedAt: Date(), isLive: true)
        )
        XCTAssertNil(usage.modelWeeklyPercent)
        XCTAssertNil(usage.modelWeeklyLabel)
    }
}

// MARK: - Live-Fetch mit Token-Refresh

extension ClaudeAccountUsageFetcherTests {
    private static let usageJSON = """
    {"five_hour": {"utilization": 7.0, "resets_at": "2026-07-23T20:00:00Z"},
     "seven_day": {"utilization": 41.0, "resets_at": "2026-07-25T19:00:00Z"}}
    """

    /// Sammelt Keychain- und HTTP-Aufrufe der injizierten Fakes.
    private final class Recorder: @unchecked Sendable {
        var securityCalls: [[String]] = []
        var tokenRequests: [URLRequest] = []
        var usageTokens: [String] = []
    }

    /// Fetcher mit Fake-Keychain und Fake-Endpoints: der Token-Endpoint
    /// rotiert r1 → (a2, r2), der Usage-Endpoint akzeptiert nur `validTokens`.
    private func makeFetcher(
        secretJSON: String?,
        tokenEndpointStatus: Int = 200,
        validTokens: Set<String>,
        busy: Set<String> = [],
        recorder: Recorder
    ) throws -> ClaudeAccountUsageFetcher {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-fetcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var profiles = ClaudeAccountProfiles()
        profiles.securityRunner = { args in
            recorder.securityCalls.append(args)
            if args.first == "find-generic-password" {
                guard let secretJSON else { return (1, "") }
                return (0, secretJSON)
            }
            return (0, "")
        }

        var fetcher = ClaudeAccountUsageFetcher(profiles: profiles)
        fetcher.temporaryDirectory = tmp.path
        fetcher.busyProfileNames = { busy }
        // Frischer Cooldown-Store pro Test — nie das prozessweite Singleton,
        // sonst koppeln Tests ueber Profilnamen aneinander.
        fetcher.refreshThrottle = ClaudeTokenRefreshThrottle()
        fetcher.httpResponse = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("console.anthropic.com/v1/oauth/token") {
                recorder.tokenRequests.append(request)
                guard tokenEndpointStatus == 200 else { return (Data("{}".utf8), tokenEndpointStatus) }
                return (Data(#"{"access_token": "a2", "refresh_token": "r2", "expires_in": 28800}"#.utf8), 200)
            }
            let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
                .replacingOccurrences(of: "Bearer ", with: "")
            recorder.usageTokens.append(token)
            guard validTokens.contains(token) else { return (Data("{}".utf8), 401) }
            return (Data(Self.usageJSON.utf8), 200)
        }
        return fetcher
    }

    private var expiredSecret: String {
        #"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","expiresAt":1000,"subscriptionType":"team","scopes":["user:inference"]},"mcpOAuth":{"server":"x"}}"#
    }

    private var validSecret: String {
        // expiresAt weit in der Zukunft (Jahr ~2096)
        #"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","expiresAt":4000000000000}}"#
    }

    func testExpiredTokenIsRefreshedRotatedAndWrittenBack() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(secretJSON: expiredSecret, validTokens: ["a2"], recorder: recorder)

        let fetched = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        let usage = try XCTUnwrap(fetched)
        XCTAssertTrue(usage.isLive)
        XCTAssertNil(usage.liveFetchProblem)
        XCTAssertEqual(usage.fiveHourPercent, 7.0)

        // Genau eine Rotation; Usage nur mit dem frischen Token abgefragt.
        XCTAssertEqual(recorder.tokenRequests.count, 1)
        XCTAssertEqual(recorder.usageTokens, ["a2"])
        let tokenBody = try XCTUnwrap(recorder.tokenRequests.first?.httpBody)
        let tokenParams = try XCTUnwrap(JSONSerialization.jsonObject(with: tokenBody) as? [String: String])
        XCTAssertEqual(tokenParams["grant_type"], "refresh_token")
        XCTAssertEqual(tokenParams["refresh_token"], "r1")
        XCTAssertEqual(tokenParams["client_id"], ClaudeAccountUsageFetcher.oauthClientID)

        // Write-back: rotiertes Secret feld-erhaltend zurueck in die Keychain.
        let addCall = try XCTUnwrap(recorder.securityCalls.first { $0.first == "add-generic-password" })
        XCTAssertTrue(addCall.contains("-U"))
        let wIndex = try XCTUnwrap(addCall.firstIndex(of: "-w"))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(addCall[wIndex + 1].utf8)) as? [String: Any]
        )
        let oauth = try XCTUnwrap(payload["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "a2")
        XCTAssertEqual(oauth["refreshToken"] as? String, "r2")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "team")
        XCTAssertNotNil(payload["mcpOAuth"], "fremde Felder (mcpOAuth) muessen den Write-back ueberleben")
        let expiresAt = try XCTUnwrap(oauth["expiresAt"] as? Double)
        XCTAssertGreaterThan(expiresAt / 1000, Date().timeIntervalSince1970)

        // Frische Antwort landet im TMPDIR-Cache.
        let cachePath = (fetcher.temporaryDirectory as NSString)
            .appendingPathComponent("claude-usage-cache-acc.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath))
    }

    func testUnauthorizedTriggersExactlyOneRefreshRetry() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(secretJSON: validSecret, validTokens: ["a2"], recorder: recorder)

        let fetched = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        let usage = try XCTUnwrap(fetched)
        XCTAssertTrue(usage.isLive)
        // Erst 401 mit a1, dann Refresh, dann Erfolg mit a2 — kein weiterer Versuch.
        XCTAssertEqual(recorder.usageTokens, ["a1", "a2"])
        XCTAssertEqual(recorder.tokenRequests.count, 1)
    }

    func testRefreshFailureFallsBackToCacheWithLoginExpired() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(
            secretJSON: expiredSecret,
            tokenEndpointStatus: 429,
            validTokens: [],
            recorder: recorder
        )
        let cachePath = (fetcher.temporaryDirectory as NSString)
            .appendingPathComponent("claude-usage-cache-acc.json")
        try #"{"five_hour": {"utilization": 63.0}}"#.write(toFile: cachePath, atomically: true, encoding: .utf8)

        let fetched = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        let usage = try XCTUnwrap(fetched)
        XCTAssertFalse(usage.isLive)
        // Rate-Limit auf dem Token-Endpoint ist KEIN toter Login — die UI darf
        // nicht faelschlich zum Re-Login auffordern.
        XCTAssertEqual(usage.liveFetchProblem, .httpStatus(429))
        XCTAssertEqual(usage.fiveHourPercent, 63.0)
        // Kein Write-back, wenn nichts rotiert wurde.
        XCTAssertNil(recorder.securityCalls.first { $0.first == "add-generic-password" })
    }

    func testBusyProfileNeverRotatesTheToken() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(
            secretJSON: expiredSecret,
            validTokens: [],
            busy: ["acc"],
            recorder: recorder
        )

        let fetched = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        let usage = try XCTUnwrap(fetched)
        // Laufende Session unter dem Profil → der Token-Endpoint bleibt tabu.
        XCTAssertTrue(recorder.tokenRequests.isEmpty)
        XCTAssertEqual(usage.liveFetchProblem, .refreshBlockedBySession)
        XCTAssertFalse(usage.hasLimitData)
    }

    func testMissingKeychainSecretWithoutCacheReturnsNil() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(secretJSON: nil, validTokens: [], recorder: recorder)
        let usage = await fetcher.fetchUsage(forProfile: "acc")
        XCTAssertNil(usage)
    }

    func testCacheFallbackReadsLegacyTmpPath() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(secretJSON: nil, validTokens: [], recorder: recorder)
        // Alt-Pfad frueherer App-Versionen: literal /tmp statt $TMPDIR.
        let profile = "legacy-\(UUID().uuidString.prefix(8))"
        let legacyPath = "/tmp/claude-usage-cache-\(profile).json"
        try #"{"five_hour": {"utilization": 12.0}}"#.write(toFile: legacyPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: legacyPath) }

        let fetched = await fetcher.fetchUsage(forProfile: profile)
        let usage = try XCTUnwrap(fetched)
        XCTAssertFalse(usage.isLive)
        XCTAssertEqual(usage.fiveHourPercent, 12.0)
        XCTAssertEqual(usage.liveFetchProblem, .noCredentials)
    }

    func testPassiveFetchNeverTouchesTokenEndpoint() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(secretJSON: expiredSecret, validTokens: [], recorder: recorder)
        let cachePath = (fetcher.temporaryDirectory as NSString)
            .appendingPathComponent("claude-usage-cache-acc.json")
        try #"{"five_hour": {"utilization": 63.0}}"#.write(toFile: cachePath, atomically: true, encoding: .utf8)

        // Default = passiv (onAppear von Tab/Popover): abgelaufenes Token →
        // KEIN POST auf den Token-Endpoint, nicht mal ein Usage-GET.
        let fetched = await fetcher.fetchUsage(forProfile: "acc")
        let usage = try XCTUnwrap(fetched)
        XCTAssertTrue(recorder.tokenRequests.isEmpty)
        XCTAssertTrue(recorder.usageTokens.isEmpty)
        XCTAssertFalse(usage.isLive)
        XCTAssertEqual(usage.liveFetchProblem, .tokenExpired)
        XCTAssertEqual(usage.fiveHourPercent, 63.0)
    }

    func testRateLimitedUpdateEntersCooldownAndBlocksSecondAttempt() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(
            secretJSON: expiredSecret,
            tokenEndpointStatus: 429,
            validTokens: [],
            recorder: recorder
        )

        let first = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        XCTAssertEqual(try XCTUnwrap(first).liveFetchProblem, .httpStatus(429))
        XCTAssertEqual(recorder.tokenRequests.count, 1)

        // Zweiter Update-Klick innerhalb des Cooldowns: kein weiterer POST,
        // stattdessen Cooldown-Hinweis mit Freigabezeit.
        let second = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        XCTAssertEqual(recorder.tokenRequests.count, 1)
        guard case .refreshCoolingDown(let until)? = try XCTUnwrap(second).liveFetchProblem else {
            return XCTFail("erwartet .refreshCoolingDown, war \(String(describing: second?.liveFetchProblem))")
        }
        XCTAssertGreaterThan(until, Date())
    }

    func testRejectedRefreshShowsLoginExpiredAlsoOnLaterPassiveFetches() async throws {
        let recorder = Recorder()
        let fetcher = try makeFetcher(
            secretJSON: expiredSecret,
            tokenEndpointStatus: 400,
            validTokens: [],
            recorder: recorder
        )

        let active = await fetcher.fetchUsage(forProfile: "acc", allowTokenRefresh: true)
        XCTAssertEqual(try XCTUnwrap(active).liveFetchProblem, .loginExpired)
        XCTAssertEqual(recorder.tokenRequests.count, 1)

        // Passive Folge-Fetches (Popover erneut geoeffnet) zeigen waehrend des
        // Cooldowns weiter den praezisen Grund statt „Update druecken".
        let passive = await fetcher.fetchUsage(forProfile: "acc")
        XCTAssertEqual(recorder.tokenRequests.count, 1)
        XCTAssertEqual(try XCTUnwrap(passive).liveFetchProblem, .loginExpired)
    }
}

// MARK: - Plan-Ableitung

extension ClaudeAccountProfilesTests {
    func testPlanLabelMapsObservedCombinations() {
        // Reale Kombinationen vom 2026-07-12 (vier eingeloggte Accounts)
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_max", seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: "default_claude_max_20x"
            ),
            "Max 20×"
        )
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_max", seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: "default_claude_max_5x"
            ),
            "Max 5×"
        )
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_team", seatTier: "team_tier_1",
                userRateLimitTier: "default_claude_max_5x", organizationRateLimitTier: "default_raven"
            ),
            "Team Premium"
        )
    }

    func testPlanLabelHandlesFurtherPlans() {
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_pro", seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: nil
            ),
            "Pro"
        )
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_team", seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: nil
            ),
            "Team"
        )
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_enterprise", seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: nil
            ),
            "Enterprise"
        )
        // Unbekannte Typen lesbar durchreichen, nie verschlucken
        XCTAssertEqual(
            ClaudeAccountProfiles.planLabel(
                organizationType: "claude_free", seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: nil
            ),
            "Free"
        )
        XCTAssertNil(
            ClaudeAccountProfiles.planLabel(
                organizationType: nil, seatTier: nil,
                userRateLimitTier: nil, organizationRateLimitTier: nil
            )
        )
    }

    func testProfileCarriesPlanFromClaudeJSON() throws {
        let dir = try makeProfileDir("firma")
        let json = """
        {"oauthAccount": {"emailAddress": "a@b.de", "organizationType": "claude_max",
         "organizationRateLimitTier": "default_claude_max_20x"}}
        """
        try json.write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(service.profile(named: "firma").planDisplayName, "Max 20×")
    }
}

// MARK: - Codex-Usage (JSONL + wham/usage)

final class CodexUsageTests: XCTestCase {
    func testParseRateLimitsLineFromSessionJSONL() throws {
        // Reale Event-Form aus ~/.codex/sessions (verifiziert 2026-07-12)
        let line = """
        {"timestamp":"2026-07-12T21:55:10.123Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1784488204},"secondary":null,"credits":null,"individual_limit":null,"plan_type":"pro","rate_limit_reached_type":null}}}
        """
        let usage = try XCTUnwrap(CodexUsageReader.parseRateLimitsLine(line))
        XCTAssertEqual(usage.primary?.usedPercent, 4.0)
        XCTAssertEqual(usage.primary?.windowMinutes, 10080)
        XCTAssertEqual(usage.primary?.label, "wk")
        XCTAssertEqual(usage.primary?.resetsAt, Date(timeIntervalSince1970: 1_784_488_204))
        XCTAssertEqual(usage.planType, "pro")
        XCTAssertNil(usage.secondary)
        XCTAssertFalse(usage.isLive)
        XCTAssertNotNil(usage.capturedAt)
    }

    func testParseRateLimitsLineRejectsEventsWithoutWindows() {
        XCTAssertNil(CodexUsageReader.parseRateLimitsLine(
            #"{"timestamp":"2026-07-12T21:55:10Z","payload":{"type":"token_count","rate_limits":{"primary":null,"secondary":null}}}"#
        ))
        XCTAssertNil(CodexUsageReader.parseRateLimitsLine("kaputt"))
    }

    func testWindowLabels() {
        XCTAssertEqual(CodexUsage.Window(usedPercent: 0, windowMinutes: 300, resetsAt: nil).label, "5h")
        XCTAssertEqual(CodexUsage.Window(usedPercent: 0, windowMinutes: 10080, resetsAt: nil).label, "wk")
        XCTAssertEqual(CodexUsage.Window(usedPercent: 0, windowMinutes: 1440, resetsAt: nil).label, "24h")
    }

    func testParseWhamUsageResponse() throws {
        // Reale Antwort-Form von chatgpt.com/backend-api/wham/usage
        // (live verifiziert 2026-07-13)
        let json = """
        {"plan_type": "pro", "email": "a@b.de",
         "rate_limit": {"allowed": true, "limit_reached": false,
           "primary_window": {"used_percent": 4, "limit_window_seconds": 604800, "reset_after_seconds": 598182, "reset_at": 1784488204},
           "secondary_window": null},
         "additional_rate_limits": [
           {"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
            "rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 604800, "reset_at": 1784494823}}}
         ]}
        """
        let usage = try XCTUnwrap(CodexUsageFetcher.parseWhamUsage(Data(json.utf8), fetchedAt: Date()))
        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.emailAddress, "a@b.de")
        XCTAssertEqual(usage.primary?.usedPercent, 4)
        XCTAssertEqual(usage.primary?.windowMinutes, 10080)
        XCTAssertNil(usage.secondary)
        XCTAssertEqual(usage.scopedLimits.count, 1)
        XCTAssertEqual(usage.scopedLimits.first?.name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(usage.scopedLimits.first?.window.usedPercent, 12)
        XCTAssertTrue(usage.isLive)
    }

    func testLatestUsageReadsTailOfSessionFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-test.jsonl")
        let older = #"{"timestamp":"2026-07-12T20:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1784488204},"plan_type":"pro"}}}"#
        let newer = #"{"timestamp":"2026-07-12T21:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1784488204},"plan_type":"pro"}}}"#
        try ([older, newer].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let usage = try XCTUnwrap(CodexUsageReader(sessionsRoot: dir).latestUsage())

        // Das JÜNGSTE Event gewinnt
        XCTAssertEqual(usage.primary?.usedPercent, 9.0)
    }
}
