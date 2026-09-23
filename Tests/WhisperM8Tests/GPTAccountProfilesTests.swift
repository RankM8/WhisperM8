import XCTest
@testable import WhisperM8

/// Tests fuer die GPT-Konto-Profile (mehrere ChatGPT-Konten im GPT-Backend
/// via `CCP_CONFIG_DIR`). Alles laeuft gegen ein temporaeres Home — die
/// echten `~/.gpt-profiles` und `~/.config/claude-code-proxy` bleiben unberuehrt.
final class GPTAccountProfilesTests: XCTestCase {
    private var home: URL!
    private var service: GPTAccountProfiles!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpt-profiles-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        service = GPTAccountProfiles(homeDirectory: home, xdgConfigHome: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeProfileDir(_ name: String) throws -> URL {
        let dir = home.appendingPathComponent(".gpt-profiles/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Schreibt einen Proxy-Store im echten Schema (Werte sind Platzhalter).
    private func writeAuthFile(accountID: String?, in configDir: URL) throws {
        let codexDir = configDir.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "access": "access-placeholder",
            "refresh": "refresh-placeholder",
            "expires": 1_789_572_311_545,
        ]
        if let accountID { object["accountId"] = accountID }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: codexDir.appendingPathComponent("auth.json"))
    }

    // MARK: - Discovery

    func testProfilesAlwaysContainMainFirst() throws {
        _ = try makeProfileDir("zeta")
        _ = try makeProfileDir("alpha")
        let names = service.profiles().map(\.name)
        XCTAssertEqual(names, ["main", "alpha", "zeta"])
        XCTAssertTrue(service.profiles()[0].isMain)
    }

    func testMainConfigDirIsProxyDefaultStore() {
        XCTAssertEqual(
            service.configDir(forProfile: "main").path,
            home.appendingPathComponent(".config/claude-code-proxy").path
        )
        XCTAssertEqual(
            service.authFileURL(forProfile: "main").path,
            home.appendingPathComponent(".config/claude-code-proxy/codex/auth.json").path
        )
    }

    func testMainConfigDirFollowsXDGConfigHome() {
        let xdg = home.appendingPathComponent("xdg-config").path
        let service = GPTAccountProfiles(homeDirectory: home, xdgConfigHome: xdg)
        XCTAssertEqual(
            service.configDir(forProfile: "main").path,
            xdg + "/claude-code-proxy"
        )
    }

    func testProfileWithAuthFileIsLoggedIn() throws {
        let dir = try makeProfileDir("zweit")
        try writeAuthFile(accountID: "acct-2", in: dir)
        let profile = service.profile(named: "zweit")
        XCTAssertTrue(profile.isLoggedIn)
        XCTAssertEqual(profile.accountID, "acct-2")
        XCTAssertEqual(profile.configDir.path, dir.path)
    }

    func testProfileWithoutAuthFileIsNotLoggedIn() throws {
        _ = try makeProfileDir("leer")
        XCTAssertFalse(service.profile(named: "leer").isLoggedIn)
        XCTAssertNil(service.storedAccountID(forProfile: "leer"))
    }

    func testAuthFileWithoutAccountIDDoesNotCountAsLogin() throws {
        let dir = try makeProfileDir("kaputt")
        try writeAuthFile(accountID: nil, in: dir)
        XCTAssertFalse(service.profile(named: "kaputt").isLoggedIn)
    }

    func testStoredAccountIDCacheRefreshesOnFileChange() throws {
        let dir = try makeProfileDir("wechsel")
        try writeAuthFile(accountID: "acct-alt", in: dir)
        XCTAssertEqual(service.storedAccountID(forProfile: "wechsel"), "acct-alt")

        // Neuer Inhalt mit anderer Groesse UND anderer mtime → Cache-Miss.
        try writeAuthFile(accountID: "acct-neu-laenger", in: dir)
        let authURL = service.authFileURL(forProfile: "wechsel")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: authURL.path
        )
        XCTAssertEqual(service.storedAccountID(forProfile: "wechsel"), "acct-neu-laenger")
    }

    // MARK: - Kontometadaten

    func testAccountInfoRoundtripAndMatchesCurrentGrant() throws {
        let dir = try makeProfileDir("meta")
        try writeAuthFile(accountID: "acct-meta", in: dir)
        let info = GPTAccountInfo(
            accountID: "acct-meta",
            emailAddress: "ai@example.com",
            planType: "prolite",
            fetchedAt: Date(timeIntervalSince1970: 1_789_560_000)
        )
        try service.writeAccountInfo(info, forProfile: "meta")

        XCTAssertEqual(service.readAccountInfo(forProfile: "meta"), info)
        let profile = service.profile(named: "meta")
        XCTAssertEqual(profile.emailAddress, "ai@example.com")
        XCTAssertEqual(profile.planType, "prolite")
        XCTAssertEqual(profile.planDisplayName, "Pro Lite")
    }

    func testAccountInfoOfOtherGrantIsIgnored() throws {
        // Re-Login mit anderem Konto: alte Metadaten duerfen nicht anhaften.
        let dir = try makeProfileDir("relogin")
        try writeAuthFile(accountID: "acct-neu", in: dir)
        try service.writeAccountInfo(
            GPTAccountInfo(accountID: "acct-alt", emailAddress: "alt@example.com", planType: "pro", fetchedAt: Date()),
            forProfile: "relogin"
        )
        let profile = service.profile(named: "relogin")
        XCTAssertEqual(profile.accountID, "acct-neu")
        XCTAssertNil(profile.emailAddress)
    }

    func testMainAccountInfoLivesOutsideProxyDirectory() {
        XCTAssertEqual(
            service.accountInfoFileURL(forProfile: "main").path,
            home.appendingPathComponent(".gpt-profiles/.main-account.json").path
        )
    }

    // MARK: - Aktives Profil

    func testActiveProfileDefaultsToMain() {
        XCTAssertEqual(service.activeProfileName(), "main")
        XCTAssertNil(service.activeProfileNameOrNil())
    }

    func testSetActiveProfileRoundtrip() throws {
        _ = try makeProfileDir("zweit")
        try service.setActiveProfile("zweit")
        XCTAssertEqual(service.activeProfileName(), "zweit")
        XCTAssertEqual(service.activeProfileNameOrNil(), "zweit")
        try service.setActiveProfile("main")
        XCTAssertNil(service.activeProfileNameOrNil())
    }

    func testActiveProfileFallsBackToMainWhenDirMissing() throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gpt-profiles"), withIntermediateDirectories: true
        )
        try "geloescht".write(
            to: home.appendingPathComponent(".gpt-profiles/.active"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(service.activeProfileName(), "main")
    }

    func testValidatedProfileNameNormalizesMainAndEmpty() throws {
        XCTAssertNil(try service.validatedProfileName("main"))
        XCTAssertNil(try service.validatedProfileName("  "))
    }

    func testValidatedProfileNameRejectsUnknownAndNotLoggedIn() throws {
        XCTAssertThrowsError(try service.validatedProfileName("nix")) { error in
            XCTAssertEqual(error as? GPTAccountProfiles.SelectionError, .unknownProfile("nix"))
        }
        _ = try makeProfileDir("leer")
        XCTAssertThrowsError(try service.validatedProfileName("leer")) { error in
            XCTAssertEqual(error as? GPTAccountProfiles.SelectionError, .notLoggedIn("leer"))
        }
        let dir = try makeProfileDir("ok")
        try writeAuthFile(accountID: "acct-ok", in: dir)
        XCTAssertEqual(try service.validatedProfileName(" ok "), "ok")
    }

    // MARK: - Env-Injektion

    func testEnvironmentOverridesForMainPointToDefaultStore() {
        // Datei-Modus auch fuer main: derselbe Pfad, den der Proxy ohne
        // Variable naehme — nur eben ohne Keychain-Vorrang.
        let expected = ["CCP_CONFIG_DIR": home.appendingPathComponent(".config/claude-code-proxy").path]
        XCTAssertEqual(service.environmentOverrides(forProfile: nil), expected)
        XCTAssertEqual(service.environmentOverrides(forProfile: "main"), expected)
    }

    func testEnvironmentOverridesForProfileSetConfigDir() throws {
        let dir = try makeProfileDir("zweit")
        XCTAssertEqual(
            service.environmentOverrides(forProfile: "zweit"),
            ["CCP_CONFIG_DIR": dir.path]
        )
    }

    func testEnvironmentOverridesForMissingProfileFallBackToEmpty() {
        XCTAssertEqual(service.environmentOverrides(forProfile: "fehlt"), [:])
    }

    // MARK: - Anlegen / Entfernen

    func testCreateProfileCreatesDirectoryWithoutLogin() throws {
        let profile = try service.createProfile(named: "neu")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.configDir.path))
        XCTAssertFalse(profile.isLoggedIn)
        XCTAssertEqual(service.profiles().map(\.name), ["main", "neu"])
    }

    func testProfilesIgnoreDirectoriesWithInvalidNames() throws {
        _ = try makeProfileDir("gut")
        _ = try makeProfileDir("mein konto")
        _ = try makeProfileDir("ü")
        XCTAssertEqual(service.profiles().map(\.name), ["main", "gut"])
        XCTAssertEqual(service.environmentOverrides(forProfile: "mein konto"), [:])
        XCTAssertEqual(service.environmentOverrides(forProfile: "../gut"), [:])
        XCTAssertThrowsError(try service.validatedProfileName("../gut"))
    }

    func testProfileNameValidationIsASCIIOnly() {
        XCTAssertTrue(GPTAccountProfiles.isValidProfileName("ai-2_b"))
        XCTAssertFalse(GPTAccountProfiles.isValidProfileName("ü"))
        XCTAssertFalse(GPTAccountProfiles.isValidProfileName("a b"))
        XCTAssertFalse(GPTAccountProfiles.isValidProfileName("a\r\nb"))
        XCTAssertFalse(GPTAccountProfiles.isValidProfileName("main"))
    }

    func testCreateProfileRejectsInvalidNames() {
        for name in ["", "main", "a b", "x/y", "ü.ä"] {
            XCTAssertThrowsError(try service.createProfile(named: name), name)
        }
        XCTAssertTrue(GPTAccountProfiles.isValidProfileName("ai_2"))
        XCTAssertTrue(GPTAccountProfiles.isValidProfileName("office-hb"))
    }

    func testCreateProfileRejectsDuplicates() throws {
        try service.createProfile(named: "doppelt")
        XCTAssertThrowsError(try service.createProfile(named: "doppelt")) { error in
            XCTAssertEqual(error as? GPTAccountProfiles.CreateError, .alreadyExists("doppelt"))
        }
    }

    func testRemoveProfileDeletesDirectoryAndResetsActive() throws {
        let dir = try makeProfileDir("weg")
        try writeAuthFile(accountID: "acct-weg", in: dir)
        try service.setActiveProfile("weg")

        try service.removeProfile(named: "weg")

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(service.activeProfileName(), "main")
    }

    func testRemoveProfileRefusesMainAndUnknown() {
        XCTAssertThrowsError(try service.removeProfile(named: "main")) { error in
            XCTAssertEqual(error as? GPTAccountProfiles.RemoveError, .cannotRemoveMain)
        }
        XCTAssertThrowsError(try service.removeProfile(named: "nix")) { error in
            XCTAssertEqual(error as? GPTAccountProfiles.RemoveError, .unknownProfile("nix"))
        }
    }

    // MARK: - Anzeige

    func testPlanDisplayNames() {
        XCTAssertEqual(GPTAccountProfiles.planDisplayName("pro"), "Pro")
        XCTAssertEqual(GPTAccountProfiles.planDisplayName("PROLITE"), "Pro Lite")
        XCTAssertEqual(GPTAccountProfiles.planDisplayName("plus"), "Plus")
        XCTAssertEqual(GPTAccountProfiles.planDisplayName("unbekannt"), "Unbekannt")
        XCTAssertNil(GPTAccountProfiles.planDisplayName(nil))
        XCTAssertNil(GPTAccountProfiles.planDisplayName(" "))
    }

    // MARK: - Proxy-Store als Usage-Quelle

    func testProxyStoreCredentialsAreReadFromFlatSchema() throws {
        let dir = try makeProfileDir("usage")
        try writeAuthFile(accountID: "acct-usage", in: dir)
        let credentials = CodexUsageFetcher.proxyStoreCredentials(
            at: service.authFileURL(forProfile: "usage")
        )
        XCTAssertEqual(
            credentials,
            CodexUsageFetcher.Credentials(accessToken: "access-placeholder", accountID: "acct-usage")
        )
    }

    func testUsageFetcherFromProxyStoreSendsTokenAndAccountHeader() async throws {
        let dir = try makeProfileDir("usage")
        try writeAuthFile(accountID: "acct-usage", in: dir)
        var captured: URLRequest?
        let fetcher = CodexUsageFetcher(
            proxyAuthFile: service.authFileURL(forProfile: "usage"),
            httpBody: { request in
                captured = request
                return Data("""
                {"plan_type":"prolite","email":"ai@example.com","rate_limit":{"primary_window":{"used_percent":4,"limit_window_seconds":604800,"reset_at":1790000000}}}
                """.utf8)
            }
        )

        let usage = await fetcher.fetchLiveUsage()

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer access-placeholder")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "acct-usage")
        XCTAssertEqual(usage?.planType, "prolite")
        XCTAssertEqual(usage?.emailAddress, "ai@example.com")
        XCTAssertEqual(usage?.primary?.usedPercent, 4)
        XCTAssertEqual(usage?.isLive, true)
    }
}
