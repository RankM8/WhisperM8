import AppKit
import Foundation
import XCTest
@testable import WhisperM8

/// `whisperm8 chats move-account`: die CLI nutzt dieselbe Kette wie das
/// Kontextmenue (Fakten → Planer → Service → Journal). Getestet wird hier,
/// was die CLI dazubringt — geteilte Faktensammlung, Stop-and-Resume-Auswahl,
/// Entwurfs-Schutz, Warten aufs Prozessende und den CLI-Vertrag.
@MainActor
final class AccountMoveFactsTests: XCTestCase {
    private var home: URL!
    private var profiles: ClaudeAccountProfiles!
    private var store: AgentSessionStore!
    private let cwd = "/tmp/whisperm8-facts-test"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8FactsHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        profiles = ClaudeAccountProfiles()
        profiles.homeDirectory = home
        try FileManager.default.createDirectory(
            at: profiles.configDir(forProfile: "ai3"), withIntermediateDirectories: true
        )
        store = AgentSessionStore(fileURL: home.appendingPathComponent("AgentSessions.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func projectsDir(_ profile: String) -> URL {
        profiles.configDir(forProfile: profile)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(AgentTranscriptLocator.encodeClaudeCwd(cwd), isDirectory: true)
    }

    private func makeSession(externalID: String, profile: String? = nil) throws -> AgentChatSession {
        var session = try store.createSession(
            provider: .claude,
            projectPath: cwd,
            title: "Chat \(externalID)",
            claudeProfile: .explicit(profile)
        )
        session.externalSessionID = externalID
        return try store.upsertSession(session)
    }

    private func writeTranscript(_ id: String, in profile: String) throws {
        let dir = projectsDir(profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "verlauf-\(id)".write(
            to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8
        )
    }

    func testCandidatesCarryRunningStateAndTargetConflict() throws {
        let free = try makeSession(externalID: "facts-free")
        let clash = try makeSession(externalID: "facts-clash")
        try writeTranscript("facts-free", in: "main")
        try writeTranscript("facts-clash", in: "main")
        try writeTranscript("facts-clash", in: "ai3")
        let workspace = store.loadWorkspace()

        let candidates = AccountMoveFacts.candidates(
            for: workspace.sessions, projects: workspace.projects, target: "ai3",
            profiles: profiles, isRunning: { $0 == free.id }
        )

        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.sessionID, $0) })
        XCTAssertEqual(byID[free.id]?.isRunning, true)
        XCTAssertEqual(byID[free.id]?.hasTargetConflict, false)
        XCTAssertEqual(byID[clash.id]?.isRunning, false)
        XCTAssertEqual(byID[clash.id]?.hasTargetConflict, true)
    }

    func testMovesUseSubagentCwdAndReportUnresolvedSessions() throws {
        var worktree = try makeSession(externalID: "facts-wt", profile: "ai3")
        worktree.subagentCwd = "/tmp/whisperm8-worktree"
        worktree = try store.upsertSession(worktree)
        let plain = try makeSession(externalID: "facts-plain", profile: "ai3")
        let workspace = store.loadWorkspace()
        let ghost = AccountMovePlanner.Candidate(
            sessionID: UUID(), title: "Weg", currentProfile: nil, provider: .claude,
            kind: .chat, isRunning: false, hasTargetConflict: false
        )
        let candidates = AccountMoveFacts.candidates(
            for: workspace.sessions, projects: workspace.projects, target: nil,
            profiles: profiles, isRunning: { _ in false }
        )
        var plan = AccountMovePlanner.plan(candidates: candidates, targetProfile: nil, targetIsLoggedIn: true)
        plan.movable.append(ghost)

        let built = AccountMoveFacts.moves(for: plan, sessions: workspace.sessions, projects: workspace.projects)

        let byID = Dictionary(uniqueKeysWithValues: built.moves.map { ($0.sessionID, $0) })
        XCTAssertEqual(byID[worktree.id]?.cwd, "/tmp/whisperm8-worktree")
        XCTAssertEqual(byID[plain.id]?.cwd, cwd)
        XCTAssertEqual(byID[plain.id]?.fromProfile, "ai3")
        XCTAssertNil(byID[plain.id]?.toProfile)
        XCTAssertEqual(built.unresolved.map(\.sessionID), [ghost.id])
    }

    /// Die ganze Kette, wie der Control-Server sie faehrt: laufende Chats
    /// bleiben stehen, der Rest zieht um, und der Batch landet im Journal —
    /// „Rueckgaengig" in der App greift also auch fuer CLI-Umzuege.
    func testChainMovesIdleChatsSkipsRunningAndJournalsTheBatch() throws {
        let idle = try makeSession(externalID: "chain-idle")
        let running = try makeSession(externalID: "chain-running")
        try writeTranscript("chain-idle", in: "main")
        try writeTranscript("chain-running", in: "main")
        let workspace = store.loadWorkspace()

        let plan = AccountMovePlanner.plan(
            candidates: AccountMoveFacts.candidates(
                for: workspace.sessions, projects: workspace.projects, target: "ai3",
                profiles: profiles, isRunning: { $0 == running.id }),
            targetProfile: "ai3",
            targetIsLoggedIn: true
        )
        var service = AccountMoveService()
        service.store = store
        service.profiles = profiles
        service.journal = AccountMoveJournal(fileURL: home.appendingPathComponent("account-moves.jsonl"))
        service.suspendScans = {}
        service.resumeScans = {}
        let outcome = service.perform(
            AccountMoveFacts.moves(for: plan, sessions: workspace.sessions, projects: workspace.projects).moves
        )

        XCTAssertEqual(outcome.moved.map(\.sessionID), [idle.id])
        XCTAssertEqual(plan.skipped.map(\.reason), [.running])
        XCTAssertEqual(service.journal.lastBatch().map(\.sessionID), [idle.id])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectsDir("ai3").appendingPathComponent("chain-idle.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectsDir("main").appendingPathComponent("chain-running.jsonl").path))
    }
}

final class AccountMoveStopResumePlannerTests: XCTestCase {
    private func candidate(
        _ title: String,
        kind: AgentSessionKind = .chat,
        provider: AgentProvider = .claude,
        currentProfile: String? = nil,
        isRunning: Bool = true,
        hasTargetConflict: Bool = false
    ) -> AccountMovePlanner.Candidate {
        AccountMovePlanner.Candidate(
            sessionID: UUID(), title: title, currentProfile: currentProfile, provider: provider,
            kind: kind, isRunning: isRunning, hasTargetConflict: hasTargetConflict
        )
    }

    private func select(
        _ candidates: [AccountMovePlanner.Candidate],
        force: Bool = false,
        caller: UUID? = nil,
        working: Set<UUID> = [],
        drafts: Set<UUID> = []
    ) -> AccountMoveStopResumePlanner.Selection {
        let plan = AccountMovePlanner.plan(candidates: candidates, targetProfile: "ai3", targetIsLoggedIn: true)
        return AccountMoveStopResumePlanner.select(
            plan: plan, force: force,
            isCaller: { $0 == caller },
            isWorking: { working.contains($0) },
            mayHaveUnsentInput: { drafts.contains($0) }
        )
    }

    func testIdleRunningChatIsStoppable() {
        let chat = candidate("Idle")
        let selection = select([chat])
        XCTAssertEqual(selection.toStop.map(\.sessionID), [chat.sessionID])
        XCTAssertTrue(selection.blocked.isEmpty)
    }

    func testOtherSkipReasonsAreNeverStopped() {
        // Laufend UND aus anderem Grund nicht umziehbar: Stop waere sinnlos.
        let background = candidate("BG", kind: .backgroundChat)
        let codex = candidate("Codex", provider: .codex)
        let already = candidate("Schon da", currentProfile: "ai3")
        let conflict = candidate("Kollision", hasTargetConflict: true)
        let idle = candidate("Idle", isRunning: false)

        let selection = select([background, codex, already, conflict, idle])

        XCTAssertTrue(selection.toStop.isEmpty)
        XCTAssertTrue(selection.blocked.isEmpty)
    }

    func testWorkingAndDraftAreBlockedWithoutForce() {
        let working = candidate("Arbeitet")
        let draft = candidate("Entwurf")
        let selection = select([working, draft], working: [working.sessionID], drafts: [draft.sessionID])
        XCTAssertTrue(selection.toStop.isEmpty)
        XCTAssertEqual(selection.blocked.map(\.reason), [.working, .unsentInput])
    }

    func testForceLiftsWorkingAndDraftGuards() {
        let working = candidate("Arbeitet")
        let draft = candidate("Entwurf")
        let selection = select(
            [working, draft], force: true, working: [working.sessionID], drafts: [draft.sessionID]
        )
        XCTAssertEqual(Set(selection.toStop.map(\.sessionID)), [working.sessionID, draft.sessionID])
    }

    func testCallerIsNeverStoppedEvenWithForce() {
        let me = candidate("Jarvis")
        let selection = select([me], force: true, caller: me.sessionID)
        XCTAssertTrue(selection.toStop.isEmpty)
        XCTAssertEqual(selection.blocked.map(\.reason), [.ownSession])
    }

    func testNotLoggedInTargetStopsNothing() {
        let chat = candidate("Idle")
        let plan = AccountMovePlanner.plan(candidates: [chat], targetProfile: "ai3", targetIsLoggedIn: false)
        let selection = AccountMoveStopResumePlanner.select(
            plan: plan, force: true, isCaller: { _ in false }, isWorking: { _ in false },
            mayHaveUnsentInput: { _ in false }
        )
        XCTAssertTrue(selection.toStop.isEmpty)
    }
}

final class TerminalComposerDraftTrackerTests: XCTestCase {
    func testTypingMarksDraftAndReturnSubmits() {
        var tracker = TerminalComposerDraftTracker()
        XCTAssertFalse(tracker.mayHaveUnsentInput)
        tracker.recordKeyDown(keyCode: 0, modifiers: []) // „a"
        XCTAssertTrue(tracker.mayHaveUnsentInput)
        tracker.recordKeyDown(keyCode: 36, modifiers: [])
        XCTAssertFalse(tracker.mayHaveUnsentInput)
    }

    func testShiftReturnIsNewlineNotSubmit() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordKeyDown(keyCode: 36, modifiers: .shift)
        XCTAssertTrue(tracker.mayHaveUnsentInput)
    }

    func testCtrlCClearsAndPasteMarks() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordKeyDown(keyCode: 9, modifiers: .command) // Cmd+V
        XCTAssertTrue(tracker.mayHaveUnsentInput)
        tracker.recordKeyDown(keyCode: 8, modifiers: .control) // Ctrl+C
        XCTAssertFalse(tracker.mayHaveUnsentInput)
    }

    func testNavigationAndShortcutsLeaveStateUnchanged() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordKeyDown(keyCode: 126, modifiers: [])          // Pfeil hoch
        tracker.recordKeyDown(keyCode: 53, modifiers: [])           // ESC
        tracker.recordKeyDown(keyCode: 13, modifiers: .command)     // Cmd+W
        XCTAssertFalse(tracker.mayHaveUnsentInput)
    }

    func testProgrammaticInsertAndSubmit() {
        var tracker = TerminalComposerDraftTracker()
        tracker.recordTextInserted()
        XCTAssertTrue(tracker.mayHaveUnsentInput)
        tracker.recordSubmitted()
        XCTAssertFalse(tracker.mayHaveUnsentInput)
    }
}

final class ProcessExitWaiterTests: XCTestCase {
    func testOwnProcessHasNotExited() {
        XCTAssertFalse(ProcessExitWaiter.hasExited(pid: getpid()))
    }

    func testReapedProcessHasExited() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue(ProcessExitWaiter.hasExited(pid: process.processIdentifier))
    }

    func testWaitReturnsTrueOnceExited() async {
        var polls = 0
        let exited = await ProcessExitWaiter.waitForExit(
            pid: 4711, timeout: 2, pollInterval: 0.01,
            hasExited: { _ in
                polls += 1
                return polls >= 3
            }
        )
        XCTAssertTrue(exited)
        XCTAssertEqual(polls, 3)
    }

    func testWaitTimesOutWhileProcessLives() async {
        let exited = await ProcessExitWaiter.waitForExit(
            pid: 4711, timeout: 0.05, pollInterval: 0.01, hasExited: { _ in false }
        )
        XCTAssertFalse(exited)
    }
}

final class ChatsMoveAccountCLITests: XCTestCase {
    func testParseRefsTargetAndFlags() throws {
        let options = try ChatsCLIParser.parseMoveAccount(
            ["whisperm8/a", "b1c2d3e4", "--to", "ai3", "--dry-run", "--json"]
        )
        XCTAssertEqual(options.refs, ["whisperm8/a", "b1c2d3e4"])
        XCTAssertEqual(options.toProfile, "ai3")
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.json)
        XCTAssertFalse(options.stopAndResume)
    }

    func testParseRequiresRefAndTarget() {
        XCTAssertThrowsError(try ChatsCLIParser.parseMoveAccount(["--to", "ai3"]))
        XCTAssertThrowsError(try ChatsCLIParser.parseMoveAccount(["chat"]))
        XCTAssertThrowsError(try ChatsCLIParser.parseMoveAccount(["chat", "--to"]))
        XCTAssertThrowsError(try ChatsCLIParser.parseMoveAccount(["chat", "--to", "--json"]))
    }

    func testForceOnlyWithStopAndResume() throws {
        XCTAssertThrowsError(try ChatsCLIParser.parseMoveAccount(["chat", "--to", "ai3", "--force"]))
        let options = try ChatsCLIParser.parseMoveAccount(
            ["chat", "--to", "ai3", "--stop-and-resume", "--force"]
        )
        XCTAssertTrue(options.stopAndResume)
        XCTAssertTrue(options.force)
    }

    func testUnknownFlagFails() {
        XCTAssertThrowsError(try ChatsCLIParser.parseMoveAccount(["chat", "--to", "ai3", "--stop"]))
    }

    private func item(
        _ outcome: String,
        reason: String? = nil,
        reasonLabel: String? = nil,
        stopAndResume: Bool = false,
        stopAndResumePossible: Bool = false,
        resumeScheduled: Bool = false
    ) -> ChatsMoveAccountResultItem {
        ChatsMoveAccountResultItem(
            id: UUID().uuidString, title: "Chat", project: "whisperm8", fromProfile: "main",
            outcome: outcome, reason: reason, reasonLabel: reasonLabel,
            stopAndResume: stopAndResume, stopAndResumePossible: stopAndResumePossible,
            resumeScheduled: resumeScheduled
        )
    }

    func testItemsParseFromServerResult() {
        let result = ChatsControlJSON.object([
            "results": [[
                "id": "abc", "title": "T", "project": "P", "fromProfile": "main",
                "outcome": "skipped", "reason": "running", "reasonLabel": "läuft gerade",
                "stopAndResume": false, "stopAndResumePossible": true,
                "stopBlocked": "working", "resumeScheduled": false,
            ]],
        ])
        let items = ChatsMoveAccountSupport.items(from: result)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].reason, "running")
        XCTAssertTrue(items[0].stopAndResumePossible)
        XCTAssertEqual(items[0].stopBlocked, "working")
    }

    func testExitCodeContract() {
        let moved = item("moved")
        let already = item("skipped", reason: "alreadyInTarget")
        let running = item("skipped", reason: "running")
        let failed = item("failed", reason: "moveFailed")
        let missing = item("notFound")

        XCTAssertEqual(ChatsMoveAccountSupport.exitCode(for: [moved, already], dryRun: false), ChatsCLIExit.ok)
        XCTAssertEqual(ChatsMoveAccountSupport.exitCode(for: [moved, running], dryRun: false), ChatsCLIExit.conflict)
        XCTAssertEqual(ChatsMoveAccountSupport.exitCode(for: [moved, failed], dryRun: false), ChatsCLIExit.conflict)
        XCTAssertEqual(ChatsMoveAccountSupport.exitCode(for: [moved, missing], dryRun: false), ChatsCLIExit.notFound)
        // Vorschau aendert nichts → 0, auch wenn etwas uebersprungen wuerde.
        XCTAssertEqual(ChatsMoveAccountSupport.exitCode(for: [item("wouldMove"), running], dryRun: true), ChatsCLIExit.ok)
    }

    func testHumanLinesNameRouteReasonAndRestart() {
        let preview = ChatsMoveAccountSupport.humanLine(
            for: item("wouldMove", stopAndResume: true), toProfile: "ai3", fallbackLabel: nil)
        XCTAssertEqual(preview, "↻ würde anhalten, umziehen und neu starten: whisperm8/Chat (main → ai3)")

        let moved = ChatsMoveAccountSupport.humanLine(
            for: item("moved", resumeScheduled: true), toProfile: "ai3", fallbackLabel: nil)
        XCTAssertEqual(moved, "✓ umgezogen, Neustart vorgemerkt: whisperm8/Chat (main → ai3)")

        let skipped = ChatsMoveAccountSupport.humanLine(
            for: item("skipped", reason: "running", reasonLabel: "läuft gerade", stopAndResumePossible: true),
            toProfile: "ai3", fallbackLabel: nil)
        XCTAssertEqual(skipped, "– übersprungen: whisperm8/Chat — läuft gerade (mit --stop-and-resume umziehbar)")
    }

    func testSummaryCountsOutcomes() {
        let items = [item("moved"), item("moved"), item("skipped"), item("failed")]
        XCTAssertEqual(
            ChatsMoveAccountSupport.summaryLine(for: items, dryRun: false),
            "2 umgezogen · 1 übersprungen · 1 fehlgeschlagen"
        )
        XCTAssertEqual(
            ChatsMoveAccountSupport.summaryLine(for: [item("wouldMove")], dryRun: true),
            "1 würden umziehen"
        )
    }
}
