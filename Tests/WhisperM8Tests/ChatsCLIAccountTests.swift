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

    /// Befund 6: Nur eine fehlende `.active` heißt main. Ist sie da, aber
    /// unlesbar, scheitert der Start — kein stiller Rückfall auf main.
    func testUnreadableActiveFileFailsInsteadOfFallingBackToMain() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)
        let active = home.url.appendingPathComponent(".claude-profiles/.active")
        // Ordner statt Datei: Lesen scheitert, aber nicht mit „fehlt“.
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)

        XCTAssertThrowsError(try resolve(home)) { error in
            guard let error = error as? ClaudeAccountProfiles.NewChatAccountError,
                  case .activeProfileUnreadable = error.reason else {
                return XCTFail("erwartet activeProfileUnreadable, bekam \(error)")
            }
            XCTAssertTrue(error.isActiveDefault)
            XCTAssertTrue(error.errorDescription?.contains(".active") == true)
        }
    }

    func testActiveFileWithoutUTF8Fails() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.setActive("x")
        try Data([0xFF, 0xFE, 0xFD]).write(to: home.url.appendingPathComponent(".claude-profiles/.active"))

        expectError({ _ = try resolve(home) },
                    reason: .activeProfileUnreadable("kein UTF-8-Text"), isActiveDefault: true)
    }

    func testEmptyActiveFileStillMeansMain() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.setActive("  \n")

        XCTAssertEqual(try resolve(home), .init(profileName: nil, source: .active))
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

    func testMainWithoutOAuthLoginIsNotBlocked() throws {
        // API-Key, apiKeyHelper oder Proxy: main läuft ohne OAuth-Login.
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: false)

        XCTAssertEqual(try resolve(home, requested: "main", readings: ["main": .noLogin]),
                       .init(profileName: nil, source: .explicit))
        XCTAssertEqual(try resolve(home, readings: ["main": .noLogin]),
                       .init(profileName: nil, source: .active))
    }

    func testMainWithProvablyEndedLoginIsBlocked() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)

        expectError({ _ = try resolve(home, requested: "main", readings: ["main": endedLogin]) },
                    reason: .loginEnded("main"), isActiveDefault: false)
    }

    func testUsableAccountsLeaveOutEndedLogins() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("Abgelaufen", loggedIn: true)
        try home.profile("RankM8", loggedIn: true)

        XCTAssertThrowsError(try resolve(home, requested: "gibtsnicht", readings: ["Abgelaufen": endedLogin])) { error in
            XCTAssertEqual((error as? ClaudeAccountProfiles.NewChatAccountError)?.usableProfiles, ["main", "RankM8"])
        }
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

// MARK: - Ordner-Freigabe beim Umzug

final class AccountMoveTrustDecisionTests: XCTestCase {
    private var trustedDir: URL!
    private var otherDir: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8Trust-\(UUID().uuidString)", isDirectory: true)
        trustedDir = root.appendingPathComponent("frei/repo", isDirectory: true)
        otherDir = root.appendingPathComponent("fremd", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: trustedDir.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Freigegeben ist der Elternordner „frei" — das gilt auch für „frei/repo".
    private var trustedPaths: Set<String> {
        [ClaudeSharedMemoryPath.realPath(trustedDir.deletingLastPathComponent().path)]
    }

    private func candidate(_ title: String) -> AccountMovePlanner.Candidate {
        AccountMovePlanner.Candidate(
            sessionID: UUID(), title: title, currentProfile: nil, provider: .claude,
            kind: .chat, isRunning: true, hasTargetConflict: false)
    }

    func testUnknownWorkingDirectoryCountsAsNotApproved() {
        XCTAssertFalse(AccountMoveStopResumePlanner.targetTrusts(cwd: nil, trustedPaths: trustedPaths))
        XCTAssertTrue(AccountMoveStopResumePlanner.targetTrusts(cwd: trustedDir.path, trustedPaths: trustedPaths))
        XCTAssertFalse(AccountMoveStopResumePlanner.targetTrusts(cwd: otherDir.path, trustedPaths: trustedPaths))
    }

    func testBusyChatsAreScheduledOnlyWithApproval() {
        let approved = candidate("Freigegeben")
        let foreign = candidate("Fremder Ordner")
        let unknown = candidate("Ohne Pfad")
        let me = candidate("Jarvis")
        let selection = AccountMoveStopResumePlanner.Selection(
            toStop: [],
            blocked: [
                .init(candidate: approved, reason: .working),
                .init(candidate: foreign, reason: .working),
                .init(candidate: unknown, reason: .unsentInput),
                .init(candidate: me, reason: .ownSession),
            ])
        let cwds: [UUID: String] = [
            approved.sessionID: trustedDir.path, foreign.sessionID: otherDir.path, me.sessionID: otherDir.path,
        ]

        let decision = AccountMoveStopResumePlanner.trustDecision(
            movable: [], selection: selection, cwd: { cwds[$0] },
            trustedPaths: trustedPaths, force: false, mayScheduleAfterTurn: true)

        XCTAssertEqual(decision.scheduleAfterTurn, [approved.sessionID])
        XCTAssertEqual(decision.blockedByTrust, [foreign.sessionID, unknown.sessionID])
        XCTAssertEqual(decision.trustMissing, [foreign.sessionID, unknown.sessionID],
                       "die eigene Session bleibt außen vor")
    }

    func testPreviewMarksMissingApprovalButSchedulesNothing() {
        let foreign = candidate("Fremd")
        let approved = candidate("Frei")
        let selection = AccountMoveStopResumePlanner.Selection(
            toStop: [], blocked: [.init(candidate: foreign, reason: .working), .init(candidate: approved, reason: .working)])
        let cwds = [foreign.sessionID: otherDir.path, approved.sessionID: trustedDir.path]

        let decision = AccountMoveStopResumePlanner.trustDecision(
            movable: [], selection: selection, cwd: { cwds[$0] },
            trustedPaths: trustedPaths, force: false, mayScheduleAfterTurn: false)

        XCTAssertTrue(decision.scheduleAfterTurn.isEmpty)
        XCTAssertEqual(decision.blockedByTrust, [foreign.sessionID])
    }

    func testChatsToStopAndMovableChatsGetTheTrustFlag() {
        let stopForeign = candidate("Anhalten, fremd")
        let stopApproved = candidate("Anhalten, frei")
        let movableForeign = UUID()
        let selection = AccountMoveStopResumePlanner.Selection(toStop: [stopForeign, stopApproved], blocked: [])
        let cwds = [
            stopForeign.sessionID: otherDir.path, stopApproved.sessionID: trustedDir.path,
            movableForeign: otherDir.path,
        ]

        let decision = AccountMoveStopResumePlanner.trustDecision(
            movable: [movableForeign], selection: selection, cwd: { cwds[$0] },
            trustedPaths: trustedPaths, force: true, mayScheduleAfterTurn: true)

        XCTAssertEqual(decision.trustMissing, [stopForeign.sessionID, movableForeign])
        XCTAssertTrue(decision.blockedByTrust.isEmpty)
        XCTAssertTrue(decision.scheduleAfterTurn.isEmpty)
        // Mit --force wird wie bisher angehalten.
        XCTAssertTrue(decision.stopHeldByTrust.isEmpty)
    }

    /// Befund 2: Ein ruhender, laufender Chat ohne Freigabe im Zielkonto wird
    /// ohne --force NICHT angehalten — die CLI läuft meist unbeobachtet, der
    /// Neustart landete im Trust-Dialog mit Vorauswahl „No, exit“.
    func testIdleChatWithoutApprovalIsNotStoppedWithoutForce() {
        let idleForeign = candidate("Ruht, fremd")
        let idleUnknown = candidate("Ruht, ohne Pfad")
        let idleApproved = candidate("Ruht, frei")
        let movableForeign = UUID()
        let selection = AccountMoveStopResumePlanner.Selection(
            toStop: [idleForeign, idleUnknown, idleApproved], blocked: [])
        let cwds = [
            idleForeign.sessionID: otherDir.path, idleApproved.sessionID: trustedDir.path,
            movableForeign: otherDir.path,
        ]

        let decision = AccountMoveStopResumePlanner.trustDecision(
            movable: [movableForeign], selection: selection, cwd: { cwds[$0] },
            trustedPaths: trustedPaths, force: false, mayScheduleAfterTurn: true)

        XCTAssertEqual(decision.stopHeldByTrust, [idleForeign.sessionID, idleUnknown.sessionID])
        // Ein Chat, der nicht läuft, zieht weiter um (Start erst beim Öffnen
        // des Tabs, also beobachtet) — er trägt nur den Hinweis.
        XCTAssertFalse(decision.stopHeldByTrust.contains(movableForeign))
        XCTAssertTrue(decision.trustMissing.contains(movableForeign))
        XCTAssertTrue(decision.scheduleAfterTurn.isEmpty)
    }

    func testTrustHintNamesTheWayOut() {
        let hint = AccountMoveStopResumePlanner.trustMissingHint
        XCTAssertTrue(hint.contains("im Zielkonto öffnen"))
        XCTAssertTrue(hint.contains("--force"))
    }
}

// MARK: - Antwort von `session.new`

final class SessionNewPayloadTests: XCTestCase {
    func testClaudeChatNamesAccountAndSource() {
        let payload = AgentControlRequestHandler.sessionNewPayload(
            id: UUID(), title: "T", projectName: "p", provider: .claude, storedProfile: "RankM8",
            account: .init(profileName: "RankM8", source: .active))
        XCTAssertEqual(payload["account"] as? String, "RankM8")
        XCTAssertEqual(payload["accountSource"] as? String, "active")

        let main = AgentControlRequestHandler.sessionNewPayload(
            id: UUID(), title: "T", projectName: "p", provider: .claude, storedProfile: nil,
            account: .init(profileName: nil, source: .explicit))
        XCTAssertEqual(main["account"] as? String, "main")
    }

    func testCodexChatHasAccountNull() {
        let payload = AgentControlRequestHandler.sessionNewPayload(
            id: UUID(), title: "T", projectName: "p", provider: .codex, storedProfile: nil, account: nil)
        XCTAssertTrue(payload["account"] is NSNull)
        XCTAssertNil(payload["accountSource"])
    }
}

// MARK: - Kontoentscheidung von `session.new` (Befund 1)

final class SessionNewStartTests: XCTestCase {
    private struct LaunchFailed: Error {}

    private func launchResult() -> AgentChatLaunchService.ControlLaunchResult {
        AgentChatLaunchService.ControlLaunchResult(
            id: UUID(), title: "T", projectName: "p", profileName: "RankM8")
    }

    func testAccountErrorCreatesNoSession() async {
        var launches = 0
        let start = await AgentControlRequestHandler.startSessionNew(
            provider: .claude, requestedAccount: nil,
            resolveAccount: { _ in
                throw ClaudeAccountProfiles.NewChatAccountError(
                    reason: .loginEnded("RankM8"), isActiveDefault: true, usableProfiles: ["main"])
            },
            launch: { _ in launches += 1; return .success(self.launchResult()) })

        XCTAssertEqual(launches, 0, "bei einem Kontofehler darf keine Session entstehen")
        guard case .rejected(let code, let message, let auditOutcome) = start else {
            return XCTFail("erwartet: abgelehnt")
        }
        XCTAssertEqual(code, .notFound)
        XCTAssertEqual(auditOutcome, "account")
        XCTAssertTrue(message.contains("abgelaufen"))
    }

    func testResolvedAccountIsPassedExplicitlyNeverAsActiveDefault() async {
        for (requested, resolved) in [
            (nil as String?, ClaudeAccountProfiles.NewChatAccount(profileName: "RankM8", source: .active)),
            (nil, .init(profileName: nil, source: .active)),
            ("main", .init(profileName: nil, source: .explicit)),
            (nil, .init(profileName: nil, source: .killSwitch)),
        ] {
            var selections: [ClaudeProfileSelection] = []
            var asked: [String?] = []
            let start = await AgentControlRequestHandler.startSessionNew(
                provider: .claude, requestedAccount: requested,
                resolveAccount: { asked.append($0); return resolved },
                launch: { selections.append($0); return .success(self.launchResult()) })

            XCTAssertEqual(asked, [requested])
            XCTAssertEqual(selections, [.explicit(resolved.profileName)])
            XCTAssertFalse(selections.contains(.activeDefault))
            guard case .launched(_, let account) = start else { return XCTFail("erwartet: gestartet") }
            XCTAssertEqual(account, resolved)
        }
    }

    func testCodexWithAccountIsRejectedWithoutLaunch() async {
        var launches = 0
        let start = await AgentControlRequestHandler.startSessionNew(
            provider: .codex, requestedAccount: "main",
            resolveAccount: { _ in XCTFail("Codex prüft kein Claude-Konto"); throw LaunchFailed() },
            launch: { _ in launches += 1; return .success(self.launchResult()) })

        XCTAssertEqual(launches, 0)
        guard case .rejected(let code, _, let auditOutcome) = start else { return XCTFail("erwartet: abgelehnt") }
        XCTAssertEqual(code, .invalid)
        XCTAssertNil(auditOutcome)
    }

    func testCodexWithoutAccountLaunchesWithoutClaudeAccount() async {
        var selections: [ClaudeProfileSelection] = []
        let start = await AgentControlRequestHandler.startSessionNew(
            provider: .codex, requestedAccount: nil,
            resolveAccount: { _ in XCTFail("Codex prüft kein Claude-Konto"); throw LaunchFailed() },
            launch: { selections.append($0); return .success(self.launchResult()) })

        XCTAssertEqual(selections, [.explicit(nil)])
        guard case .launched(_, let account) = start else { return XCTFail("erwartet: gestartet") }
        XCTAssertNil(account)
    }
}

// MARK: - Login-Prüfung beim Ausführen von `move-account` (Befund 1)

final class MoveAccountExecutionLoginTests: XCTestCase {
    func testMainWithoutOAuthAccountIsAllowed() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: false)

        XCTAssertTrue(AgentControlRequestHandler.executionTargetIsLoggedIn(
            plannedLoggedIn: true, targetName: "main", profiles: home.profiles))
    }

    func testMainWithoutClaudeJSONIsAllowed() throws {
        let home = try AccountHome(); defer { home.remove() }

        XCTAssertTrue(AgentControlRequestHandler.executionTargetIsLoggedIn(
            plannedLoggedIn: true, targetName: "main", profiles: home.profiles))
    }

    func testProfileWithoutLoginIsBlocked() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("RankM8", loggedIn: false)

        XCTAssertFalse(AgentControlRequestHandler.executionTargetIsLoggedIn(
            plannedLoggedIn: true, targetName: "RankM8", profiles: home.profiles))
    }

    func testProfileWithLoginIsAllowed() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.profile("RankM8", loggedIn: true)

        XCTAssertTrue(AgentControlRequestHandler.executionTargetIsLoggedIn(
            plannedLoggedIn: true, targetName: "RankM8", profiles: home.profiles))
    }

    func testFailedPlanningCheckWins() throws {
        let home = try AccountHome(); defer { home.remove() }
        try home.main(loggedIn: true)
        try home.profile("RankM8", loggedIn: true)

        XCTAssertFalse(AgentControlRequestHandler.executionTargetIsLoggedIn(
            plannedLoggedIn: false, targetName: "main", profiles: home.profiles))
        XCTAssertFalse(AgentControlRequestHandler.executionTargetIsLoggedIn(
            plannedLoggedIn: false, targetName: "RankM8", profiles: home.profiles))
    }
}

// MARK: - Vorschau zeigt Vormerken (Befund 8)

final class MoveAccountPreviewScheduleTests: XCTestCase {
    func testPreviewLineAndSummaryForWouldSchedule() {
        let item = ChatsMoveAccountResultItem(
            id: UUID().uuidString, title: "Analyse", project: "whisperm8", fromProfile: "main",
            outcome: "wouldSchedule", reason: "turnRunning", reasonLabel: "arbeitet")
        XCTAssertEqual(
            ChatsMoveAccountSupport.humanLine(for: item, toProfile: "RankM8", fallbackLabel: nil),
            "⏱ würde vormerken: whisperm8/Analyse (main → RankM8) — arbeitet")
        XCTAssertEqual(
            ChatsMoveAccountSupport.summaryLine(for: [item], dryRun: true),
            "0 würden umziehen · 1 würden vorgemerkt (wechseln nach dem Turn)")
        XCTAssertEqual(ChatsMoveAccountSupport.exitCode(for: [item], dryRun: true), ChatsCLIExit.ok)
    }
}
