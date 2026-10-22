import XCTest
@testable import WhisperM8

/// Vorfall 22.10.2026: Im Keychain lagen ZWEI Items mit dem Service
/// `Claude Code-credentials` — der echte main-Login (Account = User) und ein
/// fremdes Item (Account `unknown`, nur `mcpOAuth`). `security
/// find-generic-password -s …` ohne `-a` lieferte das fremde, das Usage-Popover
/// zeigte für das gerade genutzte Konto „Keine Daten". Claude Code liest immer
/// mit `-a <User>`; WhisperM8 muss exakt dasselbe Item treffen.
final class ClaudeKeychainAccountTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keychain-account-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Keychain-Attrappe mit (Service, Account) als Schlüssel. Ohne `-a`
    /// verhält sie sich wie der echte Fehlerfall: das fremde Item gewinnt.
    private final class DuplicateKeychain: @unchecked Sendable {
        static let ownAccount = "me"
        var items: [String: [String: String]]
        var deletes: [(account: String?, service: String)] = []

        init(items: [String: [String: String]]) { self.items = items }

        func run(_ arguments: [String]) -> (Int32, String) {
            func value(_ flag: String) -> String? {
                arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            }
            guard let service = value("-s") else { return (1, "") }
            let account = value("-a")
            let byAccount = items[service] ?? [:]
            switch arguments.first {
            case "find-generic-password":
                let chosen = account ?? byAccount.keys.sorted().first { $0 != Self.ownAccount } ?? byAccount.keys.first
                guard let chosen, let secret = byAccount[chosen] else { return (44, "") }
                return (0, secret + "\n")
            case "delete-generic-password":
                deletes.append((account, service))
                let target = account ?? byAccount.keys.sorted().first { $0 != Self.ownAccount }
                if let target { items[service]?[target] = nil }
                return (0, "")
            default:
                return (1, "")
            }
        }

        func write(service: String, account: String, secret: String) -> Int32 {
            items[service, default: [:]][account] = secret
            return 0
        }
    }

    private let foreignSecret = #"{"mcpOAuth":{"server":"x"}}"#
    private let mainSecret = #"{"claudeAiOauth":{"accessToken":"main-token","refreshToken":"r","expiresAt":4000000000000}}"#

    private func makeProfiles(_ keychain: DuplicateKeychain) -> ClaudeAccountProfiles {
        var profiles = ClaudeAccountProfiles(homeDirectory: home)
        profiles.keychainAccount = DuplicateKeychain.ownAccount
        profiles.securityRunner = { keychain.run($0) }
        profiles.keychainWriter = { keychain.write(service: $0, account: $1, secret: $2) }
        return profiles
    }

    // MARK: - Account-Ableitung wie Claude Code

    func testKeychainAccountFollowsClaudeCodeRules() {
        XCTAssertEqual(ClaudeAccountProfiles.claudeKeychainAccount(environment: ["USER": "giuliano"], userName: "x"), "giuliano")
        XCTAssertEqual(ClaudeAccountProfiles.claudeKeychainAccount(environment: [:], userName: "fallback"), "fallback")
        XCTAssertEqual(ClaudeAccountProfiles.claudeKeychainAccount(environment: ["USER": ""], userName: "fallback"), "fallback")
        XCTAssertEqual(ClaudeAccountProfiles.claudeKeychainAccount(environment: ["USER": "a b"], userName: "x"), "claude-code-user")
        XCTAssertEqual(ClaudeAccountProfiles.claudeKeychainAccount(environment: ["USER": "first.last-1_2"], userName: "x"), "first.last-1_2")
    }

    func testReadAndDeleteAlwaysPassAccount() {
        var calls: [[String]] = []
        var profiles = ClaudeAccountProfiles(homeDirectory: home)
        profiles.keychainAccount = "me"
        profiles.securityRunner = { calls.append($0); return (0, "") }
        _ = profiles.readKeychainSecret(service: "svc")
        profiles.deleteKeychainSecret(service: "svc")
        XCTAssertEqual(calls, [
            ["find-generic-password", "-a", "me", "-s", "svc", "-w"],
            ["delete-generic-password", "-a", "me", "-s", "svc"],
        ])
    }

    // MARK: - Usage-Fetch

    func testUsageFetchReadsOwnItemDespiteForeignDuplicate() async throws {
        let service = "Claude Code-credentials"
        let keychain = DuplicateKeychain(items: [service: ["unknown": foreignSecret, "me": mainSecret]])
        var fetcher = ClaudeAccountUsageFetcher(profiles: makeProfiles(keychain))
        fetcher.temporaryDirectory = home.path
        fetcher.busyProfileNames = { [] }
        fetcher.refreshThrottle = ClaudeTokenRefreshThrottle()
        fetcher.httpResponse = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer main-token" else {
                return (Data("{}".utf8), 401)
            }
            return (Data(#"{"five_hour":{"utilization":3.0},"seven_day":{"utilization":7.0}}"#.utf8), 200)
        }

        let fetched = await fetcher.fetchUsage(forProfile: ClaudeAccountProfiles.mainProfileName)
        let usage = try XCTUnwrap(fetched)
        XCTAssertTrue(usage.isLive)
        XCTAssertNil(usage.liveFetchProblem)
        XCTAssertEqual(usage.sevenDayPercent, 7.0)
    }

    // MARK: - Als Hauptkonto übernehmen

    /// Mit Doppel-Item las das Rücklesen nach dem Schreiben früher das fremde
    /// Item, wertete das als Fehlschlag und „rollte zurück" — mit dem Inhalt
    /// des fremden Items in den echten main-Login.
    func testPromoteWithForeignDuplicateWritesAndDeletesOnlyOwnItems() throws {
        let probe = ClaudeAccountProfiles(homeDirectory: home)
        let profile = try probe.createProfile(named: "ai3")
        try #"{"oauthAccount": {"emailAddress": "ai3@b.de"}}"#
            .write(to: profile.configDir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try #"{"oauthAccount": {"emailAddress": "office@b.de"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let mainService = probe.keychainService(forProfile: "main")
        let profileService = probe.keychainService(forProfile: "ai3")
        let keychain = DuplicateKeychain(items: [
            mainService: ["unknown": foreignSecret, "me": mainSecret],
            profileService: ["me": "ai3-secret"],
        ])
        let profiles = makeProfiles(keychain)

        try profiles.promoteToMain("ai3", trashItem: { _ in })

        XCTAssertEqual(keychain.items[mainService]?["me"], "ai3-secret")
        XCTAssertEqual(keychain.items[mainService]?["unknown"], foreignSecret)
        XCTAssertNil(keychain.items[profileService]?["me"])
        XCTAssertTrue(keychain.deletes.allSatisfy { $0.account == DuplicateKeychain.ownAccount })
    }
}
