import Foundation
import XCTest
@testable import WhisperM8

// MARK: - Fixture: Home mit Claude-Konten

/// Ein Wegwerf-Home mit `~/.claude.json` (main) und `~/.claude-profiles/<name>/`.
private struct AccountHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8ChatsAccount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var profiles: ClaudeAccountProfiles {
        var profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = url
        return profiles
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func main(loggedIn: Bool) throws {
        try writeClaudeJSON(loggedIn: loggedIn, name: "main",
                            to: url.appendingPathComponent(".claude.json"))
    }

    func profile(_ name: String, loggedIn: Bool) throws {
        let dir = url.appendingPathComponent(".claude-profiles/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeClaudeJSON(loggedIn: loggedIn, name: name, to: dir.appendingPathComponent(".claude.json"))
    }

    func setActive(_ name: String) throws {
        let root = url.appendingPathComponent(".claude-profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try name.write(to: root.appendingPathComponent(".active"), atomically: true, encoding: .utf8)
    }

    private func writeClaudeJSON(loggedIn: Bool, name: String, to file: URL) throws {
        let payload: [String: Any] = loggedIn ? ["oauthAccount": ["emailAddress": "\(name)@example.com"]] : [:]
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
    }
}

private let validLogin = ClaudeLoginExpiryReading.login(
    ClaudeLoginExpiry(hasRefreshToken: true, endsAt: Date().addingTimeInterval(10 * 86_400)))
private let endedLogin = ClaudeLoginExpiryReading.login(
    ClaudeLoginExpiry(hasRefreshToken: false, endsAt: nil, endedByTimeLimit: true))

// MARK: - Kontowahl für `chats new`

final class ChatsNewAccountResolutionTests: XCTestCase {
    private func resolve(
        _ home: AccountHome,
        requested: String? = nil,
        followsActive: Bool = true,
        readings: [String: ClaudeLoginExpiryReading] = [:],
        consulted: ((String) -> Void)? = nil
    ) throws -> ClaudeAccountProfiles.NewChatAccount {
        try home.profiles.resolveNewChatAccount(
            requested: requested,
            followsActiveProfile: followsActive,
            loginReading: { name in
                consulted?(name)
                return readings[name] ?? validLogin
            })
    }

    private func expectError(
        _ body: () throws -> Void,
        reason: ClaudeAccountProfiles.NewChatAccountError.Reason,
        isActiveDefault: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let error = error as? ClaudeAccountProfiles.NewChatAccountError else {
                return XCTFail("falscher Fehlertyp: \(error)", file: file, line: line)
            }
            XCTAssertEqual(error.reason, reason, file: file, line: line)
            XCTAssertEqual(error.isActiveDefault, isActiveDefault, file: file, line: line)
        }
    }

    func testWithoutAccountTheActiveProfileWins() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RankM8")

        let account = try resolve(home)

        XCTAssertEqual(account, .init(profileName: "RankM8", source: .active))
        XCTAssertEqual(account.displayName, "RankM8")
    }

    func testWithoutActiveFileMainIsActive() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)

        let account = try resolve(home)

        XCTAssertEqual(account, .init(profileName: nil, source: .active))
        XCTAssertEqual(account.displayName, "main")
    }

    func testActiveFileWithOtherCaseUsesTheRealFolderName() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("rankm8\n")

        XCTAssertEqual(try resolve(home).profileName, "RankM8")
    }

    func testDeletedActiveProfileFailsInsteadOfFallingBackToMain() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.setActive("Weg")

        expectError({ _ = try resolve(home) }, reason: .activeProfileMissing("Weg"), isActiveDefault: true)
    }

    func testLoggedOutActiveProfileFails() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: false)
        try home.setActive("RankM8")

        expectError({ _ = try resolve(home) }, reason: .notLoggedIn("RankM8"), isActiveDefault: true)
    }

    func testExpiredActiveLoginFails() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RankM8")

        expectError({ _ = try resolve(home, readings: ["RankM8": endedLogin]) },
                    reason: .loginEnded("RankM8"), isActiveDefault: true)
    }

    func testMissingKeychainLoginCountsAsLoggedOut() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RankM8")

        expectError({ _ = try resolve(home, readings: ["RankM8": .noLogin]) },
                    reason: .notLoggedIn("RankM8"), isActiveDefault: true)
    }

    func testUnreadableKeychainDoesNotBlock() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RankM8")

        XCTAssertEqual(try resolve(home, readings: ["RankM8": .unreadable]).profileName, "RankM8")
    }

    func testExplicitMainBeatsActiveProfile() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RankM8")
        var consulted: [String] = []

        let account = try resolve(home, requested: "main", consulted: { consulted.append($0) })

        XCTAssertEqual(account, .init(profileName: nil, source: .explicit))
        XCTAssertEqual(consulted, ["main"], "geprüft wird nur das gewählte Konto")
    }

    func testExplicitMainMustBeLoggedInToo() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: false)

        expectError({ _ = try resolve(home, requested: "main") },
                    reason: .notLoggedIn("main"), isActiveDefault: false)
    }

    func testExplicitProfileIsCaseInsensitive() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("PowerUser", loggedIn: true)

        XCTAssertEqual(try resolve(home, requested: " poweruser ").profileName, "PowerUser")
    }

    func testUnknownExplicitProfileNamesTheLoggedInAccounts() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)
        try home.profile("Leer", loggedIn: false)

        XCTAssertThrowsError(try resolve(home, requested: "gibtsnicht")) { error in
            let error = error as? ClaudeAccountProfiles.NewChatAccountError
            XCTAssertEqual(error?.reason, .unknownProfile("gibtsnicht"))
            XCTAssertEqual(error?.usableProfiles, ["main", "RankM8"])
            XCTAssertTrue(error?.errorDescription?.contains("main, RankM8") == true)
        }
    }

    func testActiveErrorMessageExplainsTheWayOut() throws {
        let error = ClaudeAccountProfiles.NewChatAccountError(
            reason: .loginEnded("RankM8"), isActiveDefault: true, usableProfiles: ["main"])
        let text = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(text.contains("aktive Claude-Konto „RankM8“"))
        XCTAssertTrue(text.contains("abgelaufen"))
        XCTAssertTrue(text.contains("--account"))
        XCTAssertTrue(text.contains("Einstellungen → Konten"))
    }

    func testKillSwitchKeepsTheOldMainDefault() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RankM8")

        XCTAssertEqual(try resolve(home, followsActive: false), .init(profileName: nil, source: .killSwitch))
    }

    func testActiveProfileNameUsesTheRealFolderName() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("RankM8", loggedIn: true)
        try home.setActive("RANKM8")

        XCTAssertEqual(home.profiles.activeProfileName(), "RankM8")
    }
}

// MARK: - Argumente und Meldung von `chats new`

final class ChatsNewAccountArgumentTests: XCTestCase {
    func testAccountWithCodexIsRejected() {
        XCTAssertEqual(
            ChatsNewArguments.parse(["--project", "p", "--provider", "codex", "--account", "main"]),
            .failure(.accountRequiresClaude))
    }

    func testAccountTextNamesAccountAndOrigin() {
        XCTAssertEqual(ChatsNewArguments.accountText(account: "RankM8", source: "active"),
                       ", Konto: RankM8 (aktiv in den Einstellungen)")
        XCTAssertEqual(ChatsNewArguments.accountText(account: "main", source: "explicit"),
                       ", Konto: main (--account)")
        XCTAssertEqual(ChatsNewArguments.accountText(account: nil, source: nil), "")
    }
}

// MARK: - Konto in `list`/`show --json`

final class ChatsAccountDisplayTests: XCTestCase {
    private func session(
        provider: AgentProvider = .claude,
        kind: AgentSessionKind? = nil,
        profile: String? = nil
    ) -> AgentChatSession {
        AgentChatSession(provider: provider, projectID: UUID(), title: "T", kind: kind, claudeProfileName: profile)
    }

    func testMainChatShowsMainNotNull() {
        XCTAssertEqual(ChatsOutput.claudeAccount(session: session(), transcriptPath: nil),
                       .init(name: "main"))
    }

    func testProfileChatShowsItsStamp() {
        XCTAssertEqual(ChatsOutput.claudeAccount(session: session(profile: "RankM8"), transcriptPath: nil),
                       .init(name: "RankM8"))
    }

    func testBackgroundAgentShowsMain() {
        XCTAssertEqual(ChatsOutput.claudeAccount(session: session(kind: .backgroundChat), transcriptPath: nil),
                       .init(name: "main"))
    }

    func testCodexAndTerminalHaveNoClaudeAccount() {
        XCTAssertNil(ChatsOutput.claudeAccount(session: session(provider: .codex), transcriptPath: nil))
        XCTAssertNil(ChatsOutput.claudeAccount(session: session(kind: .terminal), transcriptPath: nil))
    }

    func testTranscriptLocationBeatsAStaleStamp() {
        let path = "/Users/t/.claude-profiles/RankM8/projects/-Users-t-repo/abc.jsonl"
        XCTAssertEqual(ChatsOutput.claudeAccount(session: session(), transcriptPath: path),
                       .init(name: "RankM8", stampedName: "main"))
        XCTAssertEqual(ChatsOutput.claudeAccount(session: session(profile: "RankM8"), transcriptPath: path),
                       .init(name: "RankM8"))
        XCTAssertEqual(
            ChatsOutput.claudeAccount(session: session(profile: "RankM8"),
                                      transcriptPath: "/Users/t/.claude/projects/-Users-t-repo/abc.jsonl"),
            .init(name: "main", stampedName: "RankM8"))
    }

    func testSessionJSONCarriesTheAccountField() {
        let runtime = ChatsRuntimeInfo(status: nil, source: "transcriptEstimate", since: nil, revision: nil,
                                       transcriptPath: nil, transcriptSizeBytes: nil, availability: .missingTranscript)
        func json(_ session: AgentChatSession) -> [String: Any] {
            ChatsOutput.sessionJSON(
                entry: ChatsSessionEntry(session: session, projectName: "p", projectPath: "/tmp/p"),
                runtime: runtime, selfID: nil, live: false)
        }
        XCTAssertEqual(json(session()) ["account"] as? String, "main")
        XCTAssertEqual(json(session(profile: "PowerUser"))["account"] as? String, "PowerUser")
        XCTAssertTrue(json(session(provider: .codex))["account"] is NSNull)
        XCTAssertNil(json(session())["accountStamp"])
    }
}

// MARK: - `chats move-account`

final class ChatsMoveAccountAccountTests: XCTestCase {
    func testBusyRuleMatchesTheApp() {
        typealias Planner = AccountMoveStopResumePlanner
        XCTAssertFalse(Planner.isBusy(status: .idle, openBackgroundTasks: 0))
        XCTAssertFalse(Planner.isBusy(status: .stopped, openBackgroundTasks: 0))
        XCTAssertTrue(Planner.isBusy(status: .working, openBackgroundTasks: 0))
        // Vorher hielt die CLI diese Chats sofort an, die App merkte sie vor.
        XCTAssertTrue(Planner.isBusy(status: .awaitingInput, openBackgroundTasks: 0))
        XCTAssertTrue(Planner.isBusy(status: nil, openBackgroundTasks: 0))
        XCTAssertTrue(Planner.isBusy(status: .idle, openBackgroundTasks: 2))
    }

    func testChatWaitingForAnAnswerIsNotStoppedWithoutForce() {
        let chat = AccountMovePlanner.Candidate(
            sessionID: UUID(), title: "Rückfrage", currentProfile: nil, provider: .claude,
            kind: .chat, isRunning: true, hasTargetConflict: false)
        let plan = AccountMovePlanner.plan(candidates: [chat], targetProfile: "RankM8", targetIsLoggedIn: true)
        let selection = AccountMoveStopResumePlanner.select(
            plan: plan, force: false, isCaller: { _ in false },
            isWorking: { _ in AccountMoveStopResumePlanner.isBusy(status: .awaitingInput, openBackgroundTasks: 0) },
            mayHaveUnsentInput: { _ in false })
        XCTAssertTrue(selection.toStop.isEmpty)
        XCTAssertEqual(selection.blocked.map(\.reason), [.working])
    }

    func testTargetIsCanonicalizedAndExpiredLoginReported() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)

        let ok = AgentControlRequestHandler.moveAccountTarget(
            "rankm8", profiles: home.profiles, loginReading: { _ in validLogin })
        XCTAssertEqual(ok.name, "RankM8")
        XCTAssertNil(ok.loginProblem)

        let ended = AgentControlRequestHandler.moveAccountTarget(
            "RankM8", profiles: home.profiles, loginReading: { _ in endedLogin })
        XCTAssertEqual(ended.loginProblem, .loginEnded("RankM8"))
        XCTAssertEqual(AgentControlRequestHandler.targetLoginCode(.loginEnded("RankM8")), "loginEnded")

        let main = AgentControlRequestHandler.moveAccountTarget(
            "main", profiles: home.profiles, loginReading: { _ in validLogin })
        XCTAssertEqual(main.name, "main")

        let unknown = AgentControlRequestHandler.moveAccountTarget(
            "gibtsnicht", profiles: home.profiles, loginReading: { _ in validLogin })
        XCTAssertNil(unknown.name)
        XCTAssertEqual(unknown.known, ["main", "RankM8"])
    }

    func testTrustHintInHumanLines() {
        var item = ChatsMoveAccountResultItem(
            id: UUID().uuidString, title: "Analyse", project: "whisperm8", fromProfile: "main",
            outcome: "moved", targetTrustMissing: true)
        XCTAssertTrue(ChatsMoveAccountSupport.humanLine(for: item, toProfile: "RankM8", fallbackLabel: nil)
            .contains("Ordner im Zielkonto noch nicht freigegeben"))
        item.targetTrustMissing = false
        XCTAssertFalse(ChatsMoveAccountSupport.humanLine(for: item, toProfile: "RankM8", fallbackLabel: nil)
            .contains("freigegeben"))
    }

    func testTrustFlagIsParsedFromTheServerResult() {
        let result = ChatsControlJSON.object([
            "results": [["id": "x", "outcome": "wouldMove", "targetTrustMissing": true]],
        ])
        XCTAssertEqual(ChatsMoveAccountSupport.items(from: result).first?.targetTrustMissing, true)
    }
}
