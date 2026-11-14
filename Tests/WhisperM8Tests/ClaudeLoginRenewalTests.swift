import XCTest
@testable import WhisperM8

// MARK: - Login-Frist

final class ClaudeLoginExpiryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func secret(refresh: String = "rt", endsIn days: Double?, loginEnded: String? = nil) -> String {
        var oauth: [String: Any] = ["accessToken": refresh.isEmpty ? "" : "at", "refreshToken": refresh]
        if let days { oauth["refreshTokenExpiresAt"] = (now.timeIntervalSince1970 + days * 86_400) * 1000 }
        if let loginEnded { oauth["loginEnded"] = loginEnded }
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth, "mcpOAuth": [:]])
        return String(data: data, encoding: .utf8)!
    }

    func testActiveLoginReportsFullDaysLeft() throws {
        let expiry = try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: 20.4)))
        XCTAssertEqual(expiry.status(now: now), .active(daysLeft: 20))
        XCTAssertEqual(expiry.urgency(now: now), .none)
    }

    func testUrgencyThresholds() throws {
        XCTAssertEqual(try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: 7.5))).urgency(now: now), .none)
        XCTAssertEqual(try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: 6.9))).urgency(now: now), .soon)
        XCTAssertEqual(try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: 3.1))).urgency(now: now), .soon)
        XCTAssertEqual(try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: 2.9))).urgency(now: now), .urgent)
        XCTAssertEqual(try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: 0.2))).urgency(now: now), .urgent)
    }

    func testClearedTokensMeanEndedEvenWithFutureDate() throws {
        // So hinterlässt Claude einen Login nach dem Zeitlimit.
        let expiry = try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(refresh: "", endsIn: 5, loginEnded: "time_limit")))
        XCTAssertEqual(expiry.status(now: now), .ended)
        XCTAssertTrue(expiry.endedByTimeLimit)
        XCTAssertEqual(expiry.urgency(now: now), .ended)
    }

    func testPassedDeadlineCountsAsEndedBeforeClaudeClearsTheTokens() throws {
        let expiry = try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: -1)))
        XCTAssertEqual(expiry.status(now: now), .ended)
    }

    func testOldEntryWithoutDeadlineStaysQuiet() throws {
        let expiry = try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: nil)))
        XCTAssertEqual(expiry.status(now: now), .active(daysLeft: nil))
        XCTAssertEqual(expiry.urgency(now: now), .none)
        XCTAssertEqual(expiry.summary(now: now), "")
    }

    func testForeignItemWithoutOauthIsNotALogin() {
        XCTAssertNil(ClaudeLoginExpiry.parse(secret: #"{"mcpOAuth":{}}"#))
        XCTAssertNil(ClaudeLoginExpiry.parse(secret: "not json"))
    }

    func testSummaryHasTextForEveryKnownState() throws {
        for days in [20.0, 5.0, 1.5, 0.3, -2.0] {
            let expiry = try XCTUnwrap(ClaudeLoginExpiry.parse(secret: secret(endsIn: days)))
            XCTAssertFalse(expiry.summary(now: now).isEmpty, "\(days) Tage")
        }
    }

    func testKeychainServiceHashesTheConfigDirVerbatim() {
        // Nachgemessen an Claude Code 2.1.322: Leerzeichen, Umlaute und ein
        // Schrägstrich am Ende gehen unverändert in den Hash ein.
        XCTAssertEqual(
            ClaudeAccountProfiles.keychainService(forConfigDirPath: "/tmp/Application Support/stage ä"),
            ClaudeAccountProfiles.keychainService(forConfigDirPath: "/tmp/Application Support/stage ä")
        )
        XCTAssertNotEqual(
            ClaudeAccountProfiles.keychainService(forConfigDirPath: "/tmp/stage"),
            ClaudeAccountProfiles.keychainService(forConfigDirPath: "/tmp/stage/")
        )
        XCTAssertTrue(ClaudeAccountProfiles.keychainService(forConfigDirPath: "/tmp/stage").hasPrefix("Claude Code-credentials-"))
    }
}

// MARK: - Vorwarnung

final class ClaudeLoginExpiryWarningPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func expiry(days: Double, hasToken: Bool = true) -> ClaudeLoginExpiry {
        ClaudeLoginExpiry(hasRefreshToken: hasToken, endsAt: now.addingTimeInterval(days * 86_400))
    }

    func testWarnsOncePerDeadlineAndStage() {
        let entries = ["a": expiry(days: 2), "b": expiry(days: 20), "c": expiry(days: -1)]
        let first = ClaudeLoginExpiryWarningPlanner.plan(entries: entries, now: now, notified: [:])
        XCTAssertEqual(first.warning?.endingSoon, ["a"])
        XCTAssertEqual(first.warning?.ended, ["c"])
        XCTAssertNil(first.markers["b"], "ein Login mit viel Restzeit bekommt keinen Merker")

        let second = ClaudeLoginExpiryWarningPlanner.plan(entries: entries, now: now, notified: first.markers)
        XCTAssertNil(second.warning, "dieselbe Frist wird nicht zweimal gemeldet")
        XCTAssertEqual(second.markers, first.markers)
    }

    func testEndedIsANewStageAfterTheEarlyWarning() {
        let soon = ["a": expiry(days: 2)]
        let first = ClaudeLoginExpiryWarningPlanner.plan(entries: soon, now: now, notified: [:])
        let later = now.addingTimeInterval(3 * 86_400)
        let second = ClaudeLoginExpiryWarningPlanner.plan(entries: soon, now: later, notified: first.markers)
        XCTAssertEqual(second.warning?.ended, ["a"])
        XCTAssertEqual(second.warning?.endingSoon, [])
    }

    func testRenewedLoginWarnsAgainForItsNewDeadline() {
        let first = ClaudeLoginExpiryWarningPlanner.plan(entries: ["a": expiry(days: 2)], now: now, notified: [:])
        // Erneuert: 30 Tage Rest, der Merker verschwindet.
        let renewed = ClaudeLoginExpiryWarningPlanner.plan(entries: ["a": expiry(days: 30)], now: now, notified: first.markers)
        XCTAssertNil(renewed.warning)
        XCTAssertTrue(renewed.markers.isEmpty)
        // 28 Tage später ist die neue Frist knapp.
        let later = now.addingTimeInterval(28 * 86_400)
        let again = ClaudeLoginExpiryWarningPlanner.plan(entries: ["a": expiry(days: 30)], now: later, notified: renewed.markers)
        XCTAssertEqual(again.warning?.endingSoon, ["a"])
    }

    func testUnreadableAccountKeepsItsMarker() {
        let first = ClaudeLoginExpiryWarningPlanner.plan(entries: ["a": expiry(days: 2)], now: now, notified: [:])
        // Einmal nicht lesbar: der Eintrag fehlt, der Merker darf nicht verschwinden.
        let blind = ClaudeLoginExpiryWarningPlanner.plan(entries: [:], now: now, notified: first.markers, unreadable: ["a"])
        XCTAssertNil(blind.warning)
        XCTAssertEqual(blind.markers, first.markers)
        let back = ClaudeLoginExpiryWarningPlanner.plan(entries: ["a": expiry(days: 2)], now: now, notified: blind.markers)
        XCTAssertNil(back.warning, "dieselbe Frist wird nach dem Lesefehler nicht erneut gemeldet")
    }

    func testEndedIsReportedOnceEvenWhenClaudeDropsTheDeadline() {
        // Frist vorbei, Tokens noch da.
        let passed = ["a": expiry(days: -1)]
        let first = ClaudeLoginExpiryWarningPlanner.plan(entries: passed, now: now, notified: [:])
        XCTAssertEqual(first.warning?.ended, ["a"])
        // Claude leert die Tokens und lässt das Datum weg.
        let cleared = ["a": ClaudeLoginExpiry(hasRefreshToken: false, endsAt: nil, endedByTimeLimit: true)]
        let second = ClaudeLoginExpiryWarningPlanner.plan(entries: cleared, now: now, notified: first.markers)
        XCTAssertNil(second.warning)
    }

    func testWarningTextNamesTheAccounts() {
        let warning = ClaudeLoginExpiryWarningPlanner.Warning(endingSoon: ["RankM8"], ended: ["main"])
        XCTAssertTrue(warning.body.contains("RankM8"))
        XCTAssertTrue(warning.body.contains("main"))
    }
}

// MARK: - Erneuerung

/// Schlüsselbund im Speicher: Service → Secret.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var failWritesFor: Set<String> = []
    /// Lesen scheitert mit Status 1 (z. B. Schlüsselbund gesperrt).
    var unreadable: Set<String> = []
    /// Schreiben „gelingt“, legt aber etwas anderes ab (Rücklesen weicht ab).
    var corruptWritesFor: Set<String> = []
    /// Läuft nach jedem erfolgreichen Schreiben.
    var afterWrite: ((String) -> Void)?
    /// Läuft vor jedem Lesen mit der laufenden Nummer je Service — für
    /// Überschreiber von außen zu einem bestimmten Zeitpunkt.
    var beforeRead: ((String, Int) -> Void)?
    private var readCounts: [String: Int] = [:]
    private(set) var deleted: [String] = []

    subscript(service: String) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return items[service] }
        set { lock.lock(); defer { lock.unlock() }; items[service] = newValue }
    }

    func install(in profiles: inout ClaudeAccountProfiles) {
        profiles.securityRunner = { [self] arguments in
            guard let index = arguments.firstIndex(of: "-s"), index + 1 < arguments.count else { return (1, "") }
            let service = arguments[index + 1]
            switch arguments.first {
            case "find-generic-password":
                lock.lock()
                let count = (readCounts[service] ?? 0) + 1
                readCounts[service] = count
                lock.unlock()
                beforeRead?(service, count)
                guard !unreadable.contains(service) else { return (1, "") }
                guard let secret = self[service] else { return (44, "") }
                return (0, secret + "\n")
            case "delete-generic-password":
                lock.lock(); deleted.append(service); lock.unlock()
                self[service] = nil
                return (0, "")
            default:
                return (1, "")
            }
        }
        profiles.keychainWriter = { [self] service, _, secret in
            guard !failWritesFor.contains(service) else { return 1 }
            self[service] = corruptWritesFor.contains(service) ? String(secret.prefix(9)) : secret
            afterWrite?(service)
            return 0
        }
    }
}

/// Spielt `claude auth login`: schreibt Kontodaten und Secret in den Zwischenordner.
private struct FakeLoginRunner: ClaudeLoginProcessRunning {
    var keychain: FakeKeychain
    var signedInAccount: [String: Any]?
    var stagedSecret: String?
    var result = ClaudeLoginProcessResult(end: .exited, exitCode: 0, output: "Login successful.\n")
    var recorder = Recorder()
    /// Etwas, das passiert, während der Browser offen ist.
    var duringLogin: (() -> Void)?

    final class Recorder: @unchecked Sendable {
        var arguments: [String] = []
        var stagingDir: String?
    }

    func run(
        executable: String,
        arguments: [String],
        environmentOverrides: [String: String],
        workingDirectory: String,
        timeout: TimeInterval,
        control: ClaudeLoginProcessControl,
        onLoginURL: @escaping @Sendable (URL) -> Void
    ) async -> ClaudeLoginProcessResult {
        recorder.arguments = arguments
        let dir = environmentOverrides["CLAUDE_CONFIG_DIR"] ?? ""
        recorder.stagingDir = dir
        if let signedInAccount {
            let data = try! JSONSerialization.data(withJSONObject: ["oauthAccount": signedInAccount])
            try! data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(".claude.json"))
        }
        if let stagedSecret {
            keychain[ClaudeAccountProfiles.keychainService(forConfigDirPath: dir)] = stagedSecret
        }
        onLoginURL(URL(string: "https://claude.com/cai/oauth/authorize?code=true")!)
        duringLogin?()
        return result
    }
}

final class ClaudeLoginRenewerTests: XCTestCase {
    private var home: URL!
    private var keychain: FakeKeychain!
    private var profiles: ClaudeAccountProfiles!

    private let account: [String: Any] = [
        "emailAddress": "ada@example.com", "accountUuid": "acct-1", "organizationUuid": "org-1",
    ]
    private let oldSecret = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"loginEnded":"time_limit"},"mcpOAuth":{"figma":{"accessToken":"keep-me"}}}"#
    private let freshSecret = #"{"claudeAiOauth":{"accessToken":"new-at","refreshToken":"new-rt","expiresAt":1900000000000,"refreshTokenExpiresAt":1902592000000}}"#

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("login-renew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        keychain = FakeKeychain()
        profiles = ClaudeAccountProfiles(homeDirectory: home, keychainAccount: "tester")
        keychain.install(in: &profiles)
        _ = try profiles.createProfile(named: "work")
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": account, "numStartups": 7])
        try data.write(to: profiles.claudeJSONURL(forProfile: "work"))
        keychain[profiles.keychainService(forProfile: "work")] = oldSecret
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func renewer(_ runner: FakeLoginRunner) -> ClaudeLoginRenewer {
        var renewer = ClaudeLoginRenewer()
        renewer.profiles = profiles
        renewer.commandResolver = { _ in "/usr/local/bin/claude" }
        renewer.processRunner = runner
        renewer.stagingRoot = home.appendingPathComponent("staging")
        renewer.makeStagingName = { "stage01" }
        renewer.settleDelay = 0
        return renewer
    }

    func testRenewMovesTheFreshLoginIntoTheProfileAndKeepsMCPLogins() async throws {
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }

        XCTAssertEqual(outcome, .renewed(endsAt: Date(timeIntervalSince1970: 1_902_592_000)))
        XCTAssertEqual(runner.recorder.arguments, ["auth", "login", "--claudeai", "--email", "ada@example.com"])

        let stored = try XCTUnwrap(keychain[profiles.keychainService(forProfile: "work")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        let oauth = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-rt")
        XCTAssertNil(oauth["loginEnded"], "der alte Zeitlimit-Vermerk darf nicht überleben")
        let mcp = try XCTUnwrap(object["mcpOAuth"] as? [String: Any])
        XCTAssertEqual((mcp["figma"] as? [String: Any])?["accessToken"] as? String, "keep-me")

        // Verschoben, nicht kopiert: Zwischen-Eintrag und Zwischenordner sind weg.
        let stagingDir = try XCTUnwrap(runner.recorder.stagingDir)
        XCTAssertNil(keychain[ClaudeAccountProfiles.keychainService(forConfigDirPath: stagingDir)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDir))
        // Die Kontodaten des Profils bleiben unberührt.
        let json = try XCTUnwrap(ClaudeAccountProfiles.readJSONObject(at: profiles.claudeJSONURL(forProfile: "work")))
        XCTAssertEqual(json["numStartups"] as? Int, 7)
    }

    func testWrongBrowserAccountLeavesTheProfileUntouched() async throws {
        let other: [String: Any] = ["emailAddress": "bob@example.com", "accountUuid": "acct-2", "organizationUuid": "org-9"]
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: other, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }

        XCTAssertEqual(outcome, .wrongAccount(signedInAs: "bob@example.com"))
        XCTAssertEqual(keychain[profiles.keychainService(forProfile: "work")], oldSecret)
        let stagingDir = try XCTUnwrap(runner.recorder.stagingDir)
        XCTAssertNil(keychain[ClaudeAccountProfiles.keychainService(forConfigDirPath: stagingDir)], "fremder Login wird verworfen")
    }

    func testSameEmailInAnotherOrganizationIsTheWrongAccount() async {
        var other = account
        other["organizationUuid"] = "org-team"
        other["organizationName"] = "Acme"
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: other, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        XCTAssertEqual(outcome, .wrongAccount(signedInAs: "ada@example.com · Acme"))
        XCTAssertEqual(keychain[profiles.keychainService(forProfile: "work")], oldSecret)
    }

    func testUnverifiableLoginIsNeverAdopted() async {
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: nil, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keychain[profiles.keychainService(forProfile: "work")], oldSecret)
    }

    func testCancelAndTimeoutChangeNothing() async {
        for (end, expected) in [
            (ClaudeLoginProcessResult.End.cancelled, ClaudeLoginRenewer.Outcome.cancelled),
            (.timedOut, .timedOut),
        ] {
            var runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
            runner.result = ClaudeLoginProcessResult(end: end, exitCode: 15, output: "")
            let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(keychain[profiles.keychainService(forProfile: "work")], oldSecret)
        }
    }

    func testFailedKeychainWriteRestoresThePreviousLogin() async {
        let service = profiles.keychainService(forProfile: "work")
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        keychain.failWritesFor = [service]
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keychain[service], oldSecret)
    }

    func testUnreadableProfileEntryIsNeverReplaced() async {
        // Lesefehler ist nicht „kein Eintrag“: sonst gingen die MCP-Logins verloren.
        let service = profiles.keychainService(forProfile: "work")
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        keychain.unreadable = [service]
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keychain[service], oldSecret)
    }

    func testGarbledProfileEntryIsNeverReplaced() async {
        let service = profiles.keychainService(forProfile: "work")
        keychain[service] = "7b22636c61756465"  // z. B. Hex-Ausgabe von `security -w`
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keychain[service], "7b22636c61756465")
    }

    func testProfileWithoutKeychainEntryGetsAFreshOne() async throws {
        let service = profiles.keychainService(forProfile: "work")
        keychain[service] = nil
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .renewed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(ClaudeLoginExpiry.parse(secret: try XCTUnwrap(keychain[service]))?.hasRefreshToken, true)
    }

    func testMismatchedWriteRestoresThePreviousLogin() async {
        let service = profiles.keychainService(forProfile: "work")
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        var writes = 0
        keychain.corruptWritesFor = [service]
        keychain.afterWrite = { [keychain] written in
            // Nur der erste Schreibvorgang landet verstümmelt, die Rücknahme gelingt.
            guard written == service else { return }
            writes += 1
            if writes == 1 { keychain?.corruptWritesFor = [] }
        }
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keychain[service], oldSecret, "der alte Stand steht wieder im Eintrag")
        XCTAssertEqual(writes, 2)
    }

    func testMismatchedWriteWithoutPreviousEntryLeavesNothingBehind() async {
        let service = profiles.keychainService(forProfile: "work")
        keychain[service] = nil
        keychain.corruptWritesFor = [service]
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(keychain[service], "kein verstümmelter Eintrag bleibt liegen")
    }

    func testAccountSwitchDuringTheLoginAbortsTheRenewal() async throws {
        // Während der Browser offen war, wurde das Profil auf ein anderes Konto umgestellt.
        var runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let jsonURL = profiles.claudeJSONURL(forProfile: "work")
        runner.duringLogin = {
            let other: [String: Any] = ["emailAddress": "eve@example.com", "accountUuid": "acct-3", "organizationUuid": "org-3"]
            try! JSONSerialization.data(withJSONObject: ["oauthAccount": other]).write(to: jsonURL)
        }
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(keychain[profiles.keychainService(forProfile: "work")], oldSecret)
    }

    func testLoginOverwrittenByAnotherProcessIsWrittenAgain() async throws {
        let service = profiles.keychainService(forProfile: "work")
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let staleWithNewMCP = #"{"claudeAiOauth":{"accessToken":"old-at","refreshToken":"old-rt"},"mcpOAuth":{"slack":{"accessToken":"added-meanwhile"}}}"#
        keychain.beforeRead = { [keychain] read, count in
            // Lesen 1 = Bestand, 2 = Rücklesen nach dem Schreiben, 3 = Nachprüfung.
            // Dazwischen schreibt ein laufender Chat seinen alten Stand zurück.
            guard read == service, count == 3 else { return }
            keychain?[service] = staleWithNewMCP
        }
        let outcome = await renewer(runner).renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        guard case .renewed = outcome else { return XCTFail("\(outcome)") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(keychain[service]).utf8)) as? [String: Any])
        XCTAssertEqual((object["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "new-rt")
        XCTAssertNotNil((object["mcpOAuth"] as? [String: Any])?["slack"], "was inzwischen dazukam, bleibt erhalten")
    }

    func testStaleStagingFoldersAreRemovedOnStart() throws {
        let renewer = renewer(FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret))
        let leftover = renewer.stagingRoot.appendingPathComponent("crashed")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let leftoverService = ClaudeAccountProfiles.keychainService(forConfigDirPath: leftover.path)
        keychain[leftoverService] = freshSecret

        renewer.removeStaleStaging()
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path), "frische Ordner bleiben während eines Laufs stehen")
        renewer.removeStaleStaging(olderThan: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertNil(keychain[leftoverService], "verwaiste Tokens bleiben nicht im Schlüsselbund")
    }

    func testProfileWithoutAccountDataIsNotRenewable() async throws {
        _ = try profiles.createProfile(named: "fresh")
        let runner = FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret)
        let outcome = await renewer(runner).renew(profileNamed: "fresh", control: ClaudeLoginProcessControl()) { _ in }
        XCTAssertEqual(outcome, .notRenewable)
        XCTAssertNil(runner.recorder.stagingDir, "ohne Kontodaten startet kein Login")
    }

    func testMissingCLIIsReported() async {
        var renewer = renewer(FakeLoginRunner(keychain: keychain, signedInAccount: account, stagedSecret: freshSecret))
        renewer.commandResolver = { _ in nil }
        let outcome = await renewer.renew(profileNamed: "work", control: ClaudeLoginProcessControl()) { _ in }
        XCTAssertEqual(outcome, .claudeMissing)
    }

    func testStagedLoginWithoutTokensIsRejected() {
        XCTAssertNil(ClaudeLoginRenewer.mergedSecret(existing: oldSecret, staged: #"{"claudeAiOauth":{"accessToken":"","refreshToken":""}}"#))
        XCTAssertNil(ClaudeLoginRenewer.mergedSecret(existing: oldSecret, staged: "garbage"))
    }

    func testMergeWorksWithoutAnExistingEntry() throws {
        let merged = try XCTUnwrap(ClaudeLoginRenewer.mergedSecret(existing: "", staged: freshSecret))
        XCTAssertEqual(ClaudeLoginExpiry.parse(secret: merged)?.hasRefreshToken, true)
    }

    func testLoginURLIsReadFromTheHyperlinkWrappedOutput() {
        let url = "https://claude.com/cai/oauth/authorize?code=true&state=abc&login_hint=a%40b.com"
        let output = "Opening browser to sign in…\nIf the browser didn't open, visit: \u{1B}]8;;\(url)\u{07}\(url)\u{1B}]8;;\u{07}\nPaste code here if prompted > "
        XCTAssertEqual(ClaudeLoginProcessRunner.extractLoginURL(from: output)?.absoluteString, url)
        XCTAssertNil(ClaudeLoginProcessRunner.extractLoginURL(from: "Opening browser to sign in…"))
    }

    func testFailureTextSkipsTheLoginAddress() {
        let output = "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/x\nPaste code here if prompted > \nLogin failed: organization not allowed\n"
        XCTAssertEqual(ClaudeLoginRenewer.failureText(fromOutput: output, exitCode: 1), "Login failed: organization not allowed")
    }

    func testCancelBeforeAttachStillCancels() {
        let control = ClaudeLoginProcessControl()
        control.cancel()
        var cancelled = false
        control.attach(cancel: { cancelled = true }, submitCode: { _ in })
        XCTAssertTrue(cancelled)
        XCTAssertTrue(control.isCancelled)
    }
}

// MARK: - Prozess-Steuerung

final class ClaudeLoginProcessRunnerTests: XCTestCase {
    private func run(
        _ script: String,
        timeout: TimeInterval = 20,
        control: ClaudeLoginProcessControl = ClaudeLoginProcessControl(),
        onLoginURL: @escaping @Sendable (URL) -> Void = { _ in }
    ) async -> ClaudeLoginProcessResult {
        await ClaudeLoginProcessRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environmentOverrides: [:],
            workingDirectory: NSTemporaryDirectory(),
            timeout: timeout,
            control: control,
            onLoginURL: onLoginURL
        )
    }

    func testImmediateExitReportsCodeAndOutput() async {
        let result = await run("echo 'Login failed: nope'; exit 3")
        XCTAssertEqual(result.end, .exited)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.output.contains("Login failed: nope"))
    }

    func testLoginAddressIsReportedOnceAndCancelStopsTheProcess() async {
        let control = ClaudeLoginProcessControl()
        let seen = Recorded<[URL]>([])
        let started = Date()
        let result = await run(
            "printf 'If the browser did not open, visit: https://claude.com/x?state=1\\nPaste code here if prompted > '; sleep 30",
            control: control,
            onLoginURL: { url in
                seen.update { $0.append(url) }
                control.cancel()
            }
        )
        XCTAssertEqual(result.end, .cancelled)
        XCTAssertEqual(seen.value.map(\.absoluteString), ["https://claude.com/x?state=1"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTimeoutEndsAWaitingLogin() async {
        let result = await run("sleep 30", timeout: 0.5)
        XCTAssertEqual(result.end, .timedOut)
    }

    func testProcessIgnoringSIGTERMIsKilled() async {
        // Ohne SIGKILL bliebe der Lauf für immer hängen.
        let control = ClaudeLoginProcessControl()
        let started = Date()
        let result = await run(
            "trap '' TERM; printf 'visit: https://claude.com/y\\nPaste code'; while true; do sleep 1; done",
            control: control,
            onLoginURL: { _ in control.cancel() }
        )
        XCTAssertEqual(result.end, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), ClaudeLoginProcessRunner.killGrace + 6)
    }

    func testFinishedLoginWinsOverALateCancel() async {
        // Abbruch und erfolgreiches Ende fast gleichzeitig: der Login zählt.
        let control = ClaudeLoginProcessControl()
        let result = await run(
            "printf 'visit: https://claude.com/z\\nPaste code\\n'; trap 'echo Login successful.; exit 0' TERM; while true; do sleep 0.1; done",
            control: control,
            onLoginURL: { _ in control.cancel() }
        )
        XCTAssertEqual(result.end, .exited)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSubmittedCodeReachesTheProcess() async {
        let control = ClaudeLoginProcessControl()
        let result = await run(
            "printf 'visit: https://claude.com/c\\nPaste code here if prompted > '; read code; echo \"got:$code\"",
            control: control,
            onLoginURL: { _ in control.submit(code: "  abc#123 ") }
        )
        XCTAssertEqual(result.end, .exited)
        XCTAssertTrue(result.output.contains("got:abc#123"), result.output)
    }

    func testMultiByteOutputSplitAcrossReadsStaysIntact() async {
        // „…“ (3 Bytes) in zwei Schüben geschrieben.
        let result = await run("printf 'Opening\\342\\200'; sleep 0.3; printf '\\246 done\\n'")
        XCTAssertTrue(result.output.contains("Opening… done"), result.output)
    }
}

// MARK: - Store

@MainActor
final class ClaudeLoginExpiryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(
        readings: Recorded<[String: ClaudeLoginExpiryReading]>,
        posted: Recorded<[ClaudeLoginExpiryWarningPlanner.Warning]>
    ) -> (ClaudeLoginExpiryStore, UserDefaults) {
        let suite = "login-expiry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ClaudeLoginExpiryStore()
        let moment = now
        store.now = { moment }
        store.reader = { readings.value }
        store.preferences = { AppPreferences(defaults: defaults) }
        store.postNotification = { warning in posted.update { $0.append(warning) } }
        return (store, defaults)
    }

    private func expiry(_ days: Double) -> ClaudeLoginExpiry {
        ClaudeLoginExpiry(hasRefreshToken: true, endsAt: now.addingTimeInterval(days * 86_400))
    }

    func testWarnsOnceAndKeepsTheStateThroughAReadError() async {
        let readings = Recorded<[String: ClaudeLoginExpiryReading]>(["a": .login(expiry(2)), "b": .login(expiry(20))])
        let posted = Recorded<[ClaudeLoginExpiryWarningPlanner.Warning]>([])
        let (store, _) = makeStore(readings: readings, posted: posted)

        await store.refresh()
        XCTAssertEqual(store.attentionNames, ["a"])
        XCTAssertEqual(posted.value.count, 1)

        // Lesefehler: Frist und Markierung bleiben, keine zweite Warnung danach.
        readings.value = ["a": .unreadable, "b": .login(expiry(20))]
        await store.refresh()
        XCTAssertEqual(store.attentionNames, ["a"])
        readings.value = ["a": .login(expiry(2)), "b": .login(expiry(20))]
        await store.refresh()
        XCTAssertEqual(posted.value.count, 1)
    }

    func testDisabledWarningStaysSilentButRemembers() async {
        let readings = Recorded<[String: ClaudeLoginExpiryReading]>(["a": .login(expiry(2))])
        let posted = Recorded<[ClaudeLoginExpiryWarningPlanner.Warning]>([])
        let (store, defaults) = makeStore(readings: readings, posted: posted)
        AppPreferences(defaults: defaults).isClaudeLoginExpiryWarningEnabled = false

        await store.refresh()
        XCTAssertTrue(posted.value.isEmpty)
        // Wieder eingeschaltet: kein Schwall alter Meldungen.
        AppPreferences(defaults: defaults).isClaudeLoginExpiryWarningEnabled = true
        await store.refresh()
        XCTAssertTrue(posted.value.isEmpty)
    }

    func testAccountWithoutLoginDisappears() async {
        let readings = Recorded<[String: ClaudeLoginExpiryReading]>(["a": .login(expiry(2))])
        let posted = Recorded<[ClaudeLoginExpiryWarningPlanner.Warning]>([])
        let (store, _) = makeStore(readings: readings, posted: posted)
        await store.refresh()
        readings.value = ["a": .noLogin]
        await store.refresh()
        XCTAssertTrue(store.entries.isEmpty)
    }
}

// MARK: - Echte CLI (nur auf Wunsch)

/// Startet die echte Claude-CLI, liest die Login-Adresse und bricht ab — ohne
/// Browser und ohne ein Konto anzufassen. Läuft nur mit
/// `WHISPERM8_LIVE_CLAUDE_LOGIN=1`, weil er eine installierte CLI braucht.
final class ClaudeLoginProcessLiveTests: XCTestCase {
    func testRealCLIPrintsTheLoginAddressAndStopsOnCancel() async throws {
        guard ProcessInfo.processInfo.environment["WHISPERM8_LIVE_CLAUDE_LOGIN"] == "1" else {
            throw XCTSkip("nur mit WHISPERM8_LIVE_CLAUDE_LOGIN=1")
        }
        let claude = try XCTUnwrap(AgentCommandBuilder.commandPath("claude"))
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("login live \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let control = ClaudeLoginProcessControl()
        let seenURL = Recorded<URL?>(nil)
        let started = Date()
        let result = await ClaudeLoginProcessRunner().run(
            executable: claude,
            arguments: ["auth", "login", "--claudeai", "--email", "nobody@example.com"],
            // Kein Browser-Fenster: die CLI ruft stattdessen `true` auf.
            environmentOverrides: ["CLAUDE_CONFIG_DIR": staging.path, "BROWSER": "/usr/bin/true"],
            workingDirectory: staging.path,
            timeout: 30,
            control: control,
            onLoginURL: { url in
                seenURL.value = url
                control.cancel()
            }
        )

        XCTAssertEqual(result.end, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "Abbruch statt Timeout")
        let url = try XCTUnwrap(seenURL.value)
        XCTAssertEqual(url.scheme, "https")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "login_hint" }?.value, "nobody@example.com")
        XCTAssertFalse(result.output.isEmpty)
    }
}

// MARK: - Ablauf im Dialog

/// Sammelt Werte aus dem nebenläufig laufenden Erneuerungs-Closure.
private final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}

@MainActor
final class ClaudeLoginRenewalSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ name: String, selected: Bool = true) -> ClaudeLoginRenewalSession.Row {
        ClaudeLoginRenewalSession.Row(name: name, email: "\(name)@example.com", expiry: nil, isSelected: selected)
    }

    private func waitUntilIdle(_ session: ClaudeLoginRenewalSession) async {
        for _ in 0..<200 where session.isRunning {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testRunsSelectedAccountsOneAfterAnother() async {
        let order = Recorded<[String]>([])
        let session = ClaudeLoginRenewalSession(rows: [row("a"), row("b", selected: false), row("c")]) { name, _, _ in
            order.update { $0.append(name) }
            return .renewed(endsAt: nil)
        }
        var renewed: [String] = []
        session.onRenewed = { renewed.append($0) }
        session.start()
        await waitUntilIdle(session)

        XCTAssertEqual(order.value, ["a", "c"])
        XCTAssertEqual(renewed, ["a", "c"])
        XCTAssertEqual(session.rows.map(\.status), [.renewed(endsAt: nil), .pending, .renewed(endsAt: nil)])
        XCTAssertEqual(session.renewedCount, 2)
        XCTAssertEqual(session.selectedCount, 0)
    }

    func testWrongAccountPausesTheRunUntilContinued() async {
        let attempts = Recorded<[String]>([])
        let browserFixed = Recorded(false)
        let session = ClaudeLoginRenewalSession(rows: [row("a"), row("b")]) { name, _, _ in
            attempts.update { $0.append(name) }
            if name == "a", !browserFixed.value {
                return .wrongAccount(signedInAs: "other@example.com")
            }
            return .renewed(endsAt: nil)
        }
        session.start()
        await waitUntilIdle(session)
        XCTAssertEqual(attempts.value, ["a"], "das nächste Konto träfe dieselbe Browser-Sitzung")
        XCTAssertEqual(session.rows[0].status, .wrongAccount(signedInAs: "other@example.com"))
        XCTAssertEqual(session.rows[1].status, .pending)

        browserFixed.value = true
        session.start()
        await waitUntilIdle(session)
        XCTAssertEqual(attempts.value, ["a", "a", "b"])
        XCTAssertEqual(session.renewedCount, 2)
    }

    func testSkipContinuesWithTheNextAccount() async {
        let session = ClaudeLoginRenewalSession(rows: [row("a"), row("b")]) { name, control, _ in
            guard name == "a" else { return .renewed(endsAt: nil) }
            while !control.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .cancelled
        }
        session.start()
        for _ in 0..<200 where session.currentName != "a" { try? await Task.sleep(nanoseconds: 2_000_000) }
        session.skipCurrent()
        await waitUntilIdle(session)
        XCTAssertEqual(session.rows.map(\.status), [.skipped, .renewed(endsAt: nil)])
    }

    func testStopEndsTheWholeRun() async {
        let attempts = Recorded<[String]>([])
        let session = ClaudeLoginRenewalSession(rows: [row("a"), row("b")]) { name, control, _ in
            attempts.update { $0.append(name) }
            while !control.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .cancelled
        }
        session.start()
        for _ in 0..<200 where session.currentName != "a" { try? await Task.sleep(nanoseconds: 2_000_000) }
        session.stop()
        await waitUntilIdle(session)
        XCTAssertEqual(attempts.value, ["a"])
        XCTAssertFalse(session.isRunning)
    }

    func testMissingCLIStopsFurtherAttempts() async {
        let attempts = Recorded(0)
        let session = ClaudeLoginRenewalSession(rows: [row("a"), row("b")]) { _, _, _ in
            attempts.update { $0 += 1 }
            return .claudeMissing
        }
        session.start()
        await waitUntilIdle(session)
        XCTAssertEqual(attempts.value, 1)
        XCTAssertTrue(session.claudeMissing)
        session.start()
        XCTAssertFalse(session.isRunning)
    }

    func testStartingASecondRunStopsTheFirst() async {
        let waiting: ClaudeLoginRenewalSession.Renew = { _, control, _ in
            while !control.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .cancelled
        }
        let first = ClaudeLoginRenewalSession(rows: [row("a")], renew: waiting)
        first.start()
        for _ in 0..<200 where first.currentName != "a" { try? await Task.sleep(nanoseconds: 2_000_000) }

        let second = ClaudeLoginRenewalSession(rows: [row("b")]) { _, _, _ in .renewed(endsAt: nil) }
        second.start()
        await waitUntilIdle(first)
        await waitUntilIdle(second)
        XCTAssertEqual(first.rows[0].status, .skipped, "es läuft nie mehr als ein Login")
        XCTAssertEqual(second.renewedCount, 1)
    }

    func testStopActiveEndsTheRunningLogin() async {
        let session = ClaudeLoginRenewalSession(rows: [row("a"), row("b")]) { _, control, _ in
            while !control.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            return .cancelled
        }
        session.start()
        for _ in 0..<200 where session.currentName != "a" { try? await Task.sleep(nanoseconds: 2_000_000) }
        ClaudeLoginRenewalSession.stopActive()
        await waitUntilIdle(session)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.rows.map(\.status), [.skipped, .pending])
    }

    func testRowsPreselectEverythingExceptFreshLogins() {
        func profile(_ name: String, email: String?) -> ClaudeAccountProfile {
            ClaudeAccountProfile(name: name, configDir: URL(fileURLWithPath: "/tmp/\(name)"), emailAddress: email)
        }
        func expiry(_ days: Double, token: Bool = true) -> ClaudeLoginExpiry {
            ClaudeLoginExpiry(hasRefreshToken: token, endsAt: now.addingTimeInterval(days * 86_400))
        }
        let rows = ClaudeLoginRenewalSession.makeRows(
            profiles: [
                profile("main", email: "m@example.com"),
                profile("fresh", email: "f@example.com"),
                profile("soon", email: "s@example.com"),
                profile("unknown", email: "u@example.com"),
                profile("nologin", email: nil),
            ],
            expiries: ["main": expiry(-3, token: false), "fresh": expiry(29.5), "soon": expiry(4)],
            now: now
        )
        XCTAssertEqual(rows.map(\.name), ["main", "fresh", "soon", "unknown"], "ohne Adresse kein Erneuern")
        XCTAssertEqual(rows.map(\.isSelected), [true, false, true, true])

        let single = ClaudeLoginRenewalSession.makeRows(
            profiles: [profile("main", email: "m@example.com"), profile("soon", email: "s@example.com")],
            expiries: [:],
            preselected: ["soon"],
            now: now
        )
        XCTAssertEqual(single.map(\.isSelected), [false, true])
    }
}


/// WM8-63: `main` der Test-Instanz hat ein eigenes Login-Fach; im Normalbetrieb
/// bleibt der blanke Name des Hauptkontos.
final class TestInstanceKeychainServiceTests: XCTestCase {
    func testMainServiceIsUnchangedOutsideTheTestInstance() {
        XCTAssertEqual(ClaudeAccountProfiles.mainKeychainService(testRoot: nil), "Claude Code-credentials")
        XCTAssertEqual(ClaudeAccountProfiles().keychainService(forProfile: ClaudeAccountProfiles.mainProfileName),
                       "Claude Code-credentials", "swift test läuft als Produktiv-Instanz")
    }

    /// Gleicher Wert wie `claude auth status` mit CLAUDE_SECURESTORAGE_CONFIG_DIR
    /// und wie `scripts/test-instance.sh status` (nachgerechnet 14.11.2026).
    func testMainServiceOfTheTestInstanceFollowsItsClaudeFolder() {
        let root = URL(fileURLWithPath: "/Users/giulianocosta/.whisperm8-test-instance", isDirectory: true)
        XCTAssertEqual(ClaudeAccountProfiles.mainKeychainService(testRoot: root), "Claude Code-credentials-38a46618")
        XCTAssertEqual(ClaudeAccountProfiles.mainKeychainService(testRoot: root),
                       ClaudeAccountProfiles.keychainService(forConfigDirPath: AppInstance.childEnvironmentOverrides(
                           testRoot: root)[AppInstance.claudeSecureStorageKey]!))
    }
}

/// Vic, WM8-63: Skript (`test-instance.sh login-service`, Python-Normalisierung)
/// und App (`standardizedFileURL`) müssen für dieselbe Wurzel denselben
/// Dienstnamen rechnen, sonst verfehlt `reset` den Test-Eintrag.
final class TestInstanceScriptKeychainServiceTests: XCTestCase {
    private static var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/test-instance.sh")
    }

    private func scriptService(root: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script.path, "login-service"]
        process.environment = ProcessInfo.processInfo.environment.merging(["WHISPERM8_TEST_ROOT": root]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testScriptAndAppComputeTheSameService() throws {
        for root in ["/Users/x/.whisperm8-test-instance", "/Users/x/.whisperm8-test-instance/", "/Users/x/./a/../.whisperm8-test-instance"] {
            let appRoot = try XCTUnwrap(AppInstance.resolveTestRoot([AppInstance.rootEnvironmentKey: root]))
            XCTAssertEqual(try scriptService(root: root), ClaudeAccountProfiles.mainKeychainService(testRoot: appRoot), root)
        }
        XCTAssertEqual(try scriptService(root: "/Users/giulianocosta/.whisperm8-test-instance"),
                       "Claude Code-credentials-38a46618")
    }
}
