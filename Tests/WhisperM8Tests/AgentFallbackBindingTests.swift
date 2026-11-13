import XCTest
@testable import WhisperM8

/// Rückfall-Bindung neuer Chats (Befund 13.11.2026, Test-Instanz): „soak bash“
/// und „soak question“ starteten 3 s nacheinander im selben Ordner. Der Poller
/// des zweiten band das jüngste Transcript im Ordner (cd00c6c0) — das des
/// ersten. Beide Chats trugen danach dieselbe Claude-Sitzung.
final class AgentFallbackBindingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperM8FallbackBinding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func indexed(_ id: String, cwd: String, createdAt: Date, provider: AgentProvider = .claude) -> IndexedAgentSession {
        IndexedAgentSession(provider: provider, externalSessionID: id, cwd: cwd, title: "Transcript \(id)",
                            model: nil, reasoningEffort: nil, createdAt: createdAt, lastActivityAt: createdAt)
    }

    /// Zwei Chats im selben Ordner, der erste gebunden; Zeiten wie im Beleg.
    private func makeStoreWithSoakChats() throws -> (store: AgentSessionStore, bash: AgentChatSession, question: AgentChatSession, t0: Date) {
        let store = AgentSessionStore(fileURL: tempDir.appendingPathComponent("workspace.json"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var bash = try store.createSession(provider: .claude, projectPath: tempDir.path, title: "soak bash")
        bash.createdAt = t0
        bash.externalSessionID = "cd00c6c0"
        bash.status = .running
        _ = try store.upsertSession(bash)
        var question = try store.createSession(provider: .claude, projectPath: tempDir.path, title: "soak question")
        question.createdAt = t0.addingTimeInterval(3)
        question.status = .running
        _ = try store.upsertSession(question)
        return (store, bash, question, t0)
    }

    func testFallbackNeverBindsTranscriptOfAnotherChat() throws {
        let (store, _, question, t0) = try makeStoreWithSoakChats()
        // Transcript des ersten Chats, geschrieben NACH dem Start des zweiten.
        let foreign = indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))

        let bound = try store.bindLatestIndexedSession(
            localSessionID: question.id, provider: .claude, projectPath: tempDir.path, indexedSessions: [foreign])

        XCTAssertNil(bound, "fremdes Transcript gebunden")
        XCTAssertNil(store.loadWorkspace().sessions.first(where: { $0.id == question.id })?.externalSessionID)
    }

    func testFallbackBindsOwnTranscriptNextToForeignOne() throws {
        let (store, _, question, t0) = try makeStoreWithSoakChats()
        let foreign = indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))
        let own = indexed("aa82d0ba", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.2))

        let bound = try store.bindLatestIndexedSession(
            localSessionID: question.id, provider: .claude, projectPath: tempDir.path,
            indexedSessions: [foreign, own])

        XCTAssertEqual(bound?.externalSessionID, "aa82d0ba")
    }

    func testFallbackMatchesBoundIDsCaseInsensitively() throws {
        let (store, _, question, t0) = try makeStoreWithSoakChats()
        let foreign = indexed("CD00C6C0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))
        XCTAssertNil(try store.bindLatestIndexedSession(
            localSessionID: question.id, provider: .claude, projectPath: tempDir.path, indexedSessions: [foreign]))
    }

    func testFallbackWaitsForHookWhileTwoChatsStartTogether() throws {
        // Beide noch ungebunden: welches Transcript zu wem gehört, weiß nur der Hook.
        let (store, bash, question, t0) = try makeStoreWithSoakChats()
        var unbound = bash
        unbound.externalSessionID = nil
        _ = try store.upsertSession(unbound)
        let transcript = indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3.5))

        for chat in [bash, question] {
            XCTAssertNil(try store.bindLatestIndexedSession(
                localSessionID: chat.id, provider: .claude, projectPath: tempDir.path, indexedSessions: [transcript]))
        }
    }

    func testRivalOutsideWindowOrElsewhereDoesNotBlock() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let here = AgentProject(name: "hier", path: tempDir.path)
        let other = AgentProject(name: "dort", path: tempDir.appendingPathComponent("dort").path)
        let chat = AgentChatSession(provider: .claude, projectID: here.id, title: "neu", createdAt: t0)
        let old = AgentChatSession(provider: .claude, projectID: here.id, title: "alt", createdAt: t0.addingTimeInterval(-120))
        let elsewhere = AgentChatSession(provider: .claude, projectID: other.id, title: "anderswo", createdAt: t0)
        let codex = AgentChatSession(provider: .codex, projectID: here.id, title: "codex", createdAt: t0)
        let workspace = AgentWorkspace(projects: [here, other], sessions: [chat, old, elsewhere, codex])

        let candidate = AgentSessionStore.fallbackBindingCandidate(
            for: chat, projectPath: tempDir.path, provider: .claude, workspace: workspace,
            indexedSessions: [indexed("eigen", cwd: tempDir.path, createdAt: t0.addingTimeInterval(1))])

        XCTAssertEqual(candidate?.externalSessionID, "eigen")
    }

    func testCodexBindsDespiteRivalButNeverSharesTranscript() throws {
        // Codex hat weder Hook noch Registry; ohne Bindung bliebe der Chat für immer ungebunden.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let here = AgentProject(name: "hier", path: tempDir.path)
        let first = AgentChatSession(provider: .codex, projectID: here.id, externalSessionID: "x",
                                     title: "erster", createdAt: t0)
        let rival = AgentChatSession(provider: .codex, projectID: here.id, title: "rivale", createdAt: t0)
        let chat = AgentChatSession(provider: .codex, projectID: here.id, title: "neu", createdAt: t0.addingTimeInterval(1))
        let workspace = AgentWorkspace(projects: [here], sessions: [first, rival, chat])
        let transcripts = [indexed("x", cwd: tempDir.path, createdAt: t0.addingTimeInterval(3), provider: .codex),
                           indexed("y", cwd: tempDir.path, createdAt: t0.addingTimeInterval(2), provider: .codex)]

        let candidate = AgentSessionStore.fallbackBindingCandidate(
            for: chat, projectPath: tempDir.path, provider: .codex, workspace: workspace, indexedSessions: transcripts)

        XCTAssertEqual(candidate?.externalSessionID, "y")
    }

    // MARK: Registry per PID (Claude)

    private func record(_ id: String, pid: Int32, kind: String = "interactive") -> ClaudeSessionRecord {
        ClaudeSessionRecord(profileName: "main", pid: pid, sessionID: id, kind: kind)
    }

    private func step(_ arguments: [String]? = ["--settings", "/x.json"], registry: Bool = true, pid: Int32? = 200,
                      startedAt: Date? = nil, records: [ClaudeSessionRecord], last: Bool = false) -> AgentSessionStore.ClaudeFallbackStep {
        AgentSessionStore.claudeFallbackStep(launchArguments: arguments, registryEnabled: registry, processID: pid,
                                             processStartedAt: startedAt, records: records, isLastAttempt: last)
    }

    func testClaudeStepBindsRegistryEntryOfOwnProcess() {
        let records = [record("cd00c6c0", pid: 100), record("aa82d0ba", pid: 200)]
        XCTAssertEqual(step(records: records), .bind("aa82d0ba"))
    }

    func testClaudeStepWaitsForRegistryBeforeLookingAtTranscripts() {
        let records = [record("cd00c6c0", pid: 100), record("bgjob", pid: 200, kind: "bg")]
        XCTAssertEqual(step(records: records), .wait)
        XCTAssertEqual(step(pid: nil, records: records), .wait)
        XCTAssertEqual(step(records: records, last: true), .transcriptFallback)
    }

    /// Messung 13.11.2026 (`scripts/measure-claude-registry.py`): Auch bei
    /// Resume und Fork trägt der erste Registry-Eintrag die endgültige ID.
    func testClaudeStepUsesRegistryForResumeAndFork() {
        XCTAssertEqual(step(["--settings", "/x.json", "--resume", "quelle", "--fork-session"],
                            records: [record("neue-fork-id", pid: 200)]), .bind("neue-fork-id"), "Fork")
        XCTAssertEqual(step(["--settings", "/x.json", "--resume", "quelle"],
                            records: [record("quelle", pid: 200)]), .bind("quelle"), "Resume")
    }

    /// Opus-Review: Zeigt die Registry (nach einem CLI-Update) beim Fork kurz
    /// die Quelle, darf der Poller sie nicht binden — der Fork-SessionStart
    /// würde danach als `source: fork` ignoriert.
    func testForkNeverBindsItsSourceAndResumeOnlyTheResumedID() {
        let fork = ["--settings", "/x.json", "--resume", "quelle", "--fork-session"]
        XCTAssertEqual(step(fork, records: [record("QUELLE", pid: 200)]), .wait)
        XCTAssertEqual(step(fork, records: [record("quelle", pid: 200)], last: true), .transcriptFallback)
        let resume = ["--settings", "/x.json", "--resume", "quelle"]
        XCTAssertEqual(step(resume, records: [record("vorlaeufig", pid: 200)]), .wait)
        XCTAssertTrue(AgentSessionStore.registryIDFits("neu", arguments: ["--settings", "/x.json"]), "frischer Start")
    }

    /// Vic: auch die Gleichheitsform `--resume=<id>` aus eigenen Argumenten.
    func testForkGuardUnderstandsResumeWithEqualsSign() {
        let fork = ["--settings", "/x.json", "--resume=quelle", "--fork-session"]
        XCTAssertEqual(step(fork, records: [record("quelle", pid: 200)]), .wait)
        XCTAssertEqual(step(fork, records: [record("neu", pid: 200)]), .bind("neu"))
        XCTAssertEqual(step(["--resume=quelle"], records: [record("anders", pid: 200)]), .wait)
        XCTAssertEqual(AgentSessionStore.resumedSessionID(in: ["-r", "abc"]), "abc")
        XCTAssertNil(AgentSessionStore.resumedSessionID(in: ["--resume="]))
        XCTAssertNil(AgentSessionStore.resumedSessionID(in: ["--settings", "/x.json"]))
    }

    func testClaudeStepSkipsRegistryForAttachAndWithoutSwitch() {
        let records = [record("quelle", pid: 200)]
        XCTAssertEqual(step(["attach", "abc"], records: records), .transcriptFallback, "Background-Agent")
        XCTAssertEqual(step(nil, records: records), .transcriptFallback, "kein Controller")
        XCTAssertEqual(step(registry: false, records: records), .transcriptFallback, "Schalter aus")
    }

    func testClaudeStepIgnoresStaleEntryOfReusedPID() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = record("alt", pid: 200)
        stale.startedAt = started.addingTimeInterval(-3600)
        XCTAssertEqual(step(startedAt: started, records: [stale]), .wait)
        var fresh = record("neu", pid: 200)
        fresh.startedAt = started.addingTimeInterval(0.4)
        XCTAssertEqual(step(startedAt: started, records: [fresh]), .bind("neu"))
    }

    func testOnlyRealChatsCountAsRivals() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let here = AgentProject(name: "hier", path: tempDir.path)
        let chat = AgentChatSession(provider: .claude, projectID: here.id, title: "neu", createdAt: t0)
        let agentView = AgentChatSession(provider: .claude, projectID: here.id, title: "Agent View",
                                         createdAt: t0, kind: .agentView)
        let background = AgentChatSession(provider: .claude, projectID: here.id, title: "bg",
                                          createdAt: t0, kind: .backgroundChat)
        var archived = AgentChatSession(provider: .claude, projectID: here.id, title: "archiviert", createdAt: t0)
        archived.status = .archived
        let workspace = AgentWorkspace(projects: [here], sessions: [chat, agentView, background, archived])

        let candidate = AgentSessionStore.fallbackBindingCandidate(
            for: chat, projectPath: tempDir.path, provider: .claude, workspace: workspace,
            indexedSessions: [indexed("eigen", cwd: tempDir.path, createdAt: t0.addingTimeInterval(1))])

        XCTAssertEqual(candidate?.externalSessionID, "eigen")
    }

    /// Gleiche Fehlerklasse in der Resume-Reparatur (Opus-Review): Chat A ohne
    /// Transcript darf nicht auf das Transcript von Chat B umgebunden werden.
    func testResumeRepairNeverRebindsToTranscriptOfAnotherChat() throws {
        let (store, bash, question, t0) = try makeStoreWithSoakChats()
        var unused = question
        unused.externalSessionID = "leer-ohne-transcript"
        unused.hasLaunchedInitialPrompt = true
        _ = try store.upsertSession(unused)
        _ = bash

        let result = try store.repairResumeStateBeforeLaunch(
            localSessionID: question.id, projectPath: tempDir.path,
            indexedSessions: [indexed("cd00c6c0", cwd: tempDir.path, createdAt: t0.addingTimeInterval(4))],
            now: t0.addingTimeInterval(600))

        XCTAssertNotEqual(result?.session.externalSessionID, "cd00c6c0")
        XCTAssertEqual(store.loadWorkspace().sessions.first(where: { $0.id == question.id })?.externalSessionID,
                       "leer-ohne-transcript")
    }

    func testRegistryBindingOnlyBindsUnboundChat() throws {
        let (store, bash, question, _) = try makeStoreWithSoakChats()
        XCTAssertNil(try store.bindRegistryExternalSessionID(localSessionID: bash.id, externalSessionID: "anders"))
        XCTAssertEqual(store.loadWorkspace().sessions.first(where: { $0.id == bash.id })?.externalSessionID, "cd00c6c0")
        XCTAssertEqual(try store.bindRegistryExternalSessionID(localSessionID: question.id, externalSessionID: "aa82d0ba")?
                        .externalSessionID, "aa82d0ba")
    }
}
