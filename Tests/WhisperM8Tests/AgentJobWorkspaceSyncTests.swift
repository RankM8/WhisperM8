import XCTest
@testable import WhisperM8

/// Tests für `AgentSessionStore.mergeSubagentJobs` — der Workspace-Teil des
/// Job→Session-Syncs (Muster: AgentSessionStoreTests mit temp-fileURL).
/// Die FSEvents-/Timing-Seite des `AgentJobWorkspaceSync` ist manuelle QA.
final class AgentJobWorkspaceSyncTests: XCTestCase {
    private var storeURL: URL!
    private var store: AgentSessionStore!

    override func setUpWithError() throws {
        storeURL = makeTempStoreURL()
        store = AgentSessionStore(fileURL: storeURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    private func makeJob(
        shortId: String = "a1b2c3d4",
        state: AgentJobState.State = .running,
        intent: String = "Testlauf für den Sync",
        cwd: String = "/tmp/subagent-sync-repo",
        parentSessionID: String? = nil,
        codexThreadID: String? = "thread-123",
        worktreePath: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        updatedAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> AgentJobState {
        var job = AgentJobState(
            shortId: shortId,
            state: state,
            intent: intent,
            cwd: cwd,
            sandbox: .workspaceWrite,
            parentSessionID: parentSessionID,
            createdAt: createdAt
        )
        job.codexThreadID = codexThreadID
        if let worktreePath {
            job.worktree = AgentJobState.Worktree(path: worktreePath, branch: "subagent/\(shortId)")
        }
        job.updatedAt = updatedAt
        return job
    }

    // MARK: - matchParentPid (pure — PID-Reuse-Schutz)

    /// Baut einen Job mit PID-Kandidaten; createdAt = t1000.
    private func makePidJob(
        parentProcessID: Int32? = nil,
        ancestry: [Int32] = []
    ) -> AgentJobState {
        var job = makeJob(parentSessionID: nil)
        job.parentProcessID = parentProcessID
        job.parentProcessAncestry = ancestry.isEmpty ? nil : ancestry
        return job
    }

    /// Echter Vorfahre: PID lebt und der Prozess lief schon vor dem Spawn.
    func testMatchParentPidAcceptsProcessStartedBeforeJobCreation() {
        let job = makePidJob(ancestry: [4242])
        let matched = AgentJobWorkspaceSync.matchParentPid(
            job: job,
            livePids: [4242],
            startTimeOf: { _ in Date(timeIntervalSince1970: 500) }
        )
        XCTAssertEqual(matched, 4242)
    }

    /// PID-Reuse: dieselbe PID gehört jetzt einem Prozess, der NACH dem
    /// Spawn gestartet ist — darf nicht matchen (sonst klebt der falsche
    /// Parent dauerhaft, Backfill überschreibt nie).
    func testMatchParentPidRejectsProcessStartedAfterJobCreation() {
        let job = makePidJob(ancestry: [4242])
        let matched = AgentJobWorkspaceSync.matchParentPid(
            job: job,
            livePids: [4242],
            startTimeOf: { _ in Date(timeIntervalSince1970: 90_000) }
        )
        XCTAssertNil(matched)
    }

    /// Unbekannte Startzeit (Prozess zwischen Snapshot und Check weg) ist
    /// KEIN Treffer — der nächste Sync probiert es erneut.
    func testMatchParentPidSkipsUnknownStartTime() {
        let job = makePidJob(ancestry: [4242])
        XCTAssertNil(AgentJobWorkspaceSync.matchParentPid(
            job: job,
            livePids: [4242],
            startTimeOf: { _ in nil }
        ))
    }

    /// Kette von unten nach oben: ein per Reuse verbrannter Kandidat wird
    /// übersprungen, der nächste echte gewinnt.
    func testMatchParentPidFallsThroughReusedCandidateToNextInChain() {
        let job = makePidJob(ancestry: [4242, 5353])
        let matched = AgentJobWorkspaceSync.matchParentPid(
            job: job,
            livePids: [4242, 5353],
            startTimeOf: { pid in
                pid == 4242
                    ? Date(timeIntervalSince1970: 90_000) // Reuse — nach Spawn
                    : Date(timeIntervalSince1970: 500)    // echt — vor Spawn
            }
        )
        XCTAssertEqual(matched, 5353)
    }

    /// Benannter Best-Guess (parentProcessID) hat Vorrang vor der Kette.
    func testMatchParentPidPrefersNamedParentProcessID() {
        let job = makePidJob(parentProcessID: 1111, ancestry: [4242])
        let matched = AgentJobWorkspaceSync.matchParentPid(
            job: job,
            livePids: [1111, 4242],
            startTimeOf: { _ in Date(timeIntervalSince1970: 500) }
        )
        XCTAssertEqual(matched, 1111)
    }

    /// Toleranzfenster: ISO8601 schneidet createdAt auf Sekunden ab — ein in
    /// derselben Sekunde gestarteter echter Parent darf nicht abgelehnt werden.
    func testMatchParentPidToleratesSameSecondStart() {
        let job = makePidJob(ancestry: [4242]) // createdAt = t1000 (truncated)
        let matched = AgentJobWorkspaceSync.matchParentPid(
            job: job,
            livePids: [4242],
            startTimeOf: { _ in Date(timeIntervalSince1970: 1_000.6) }
        )
        XCTAssertEqual(matched, 4242)
    }

    // MARK: - PID-aufgelöste Parents (Prozess-Abstammungs-Fallback)

    /// Ohne --parent, aber mit vom Sync aufgelöster PID-Zuordnung: die
    /// Session bekommt Parent + dessen Projekt wie beim expliziten Flag.
    func testCreateUsesResolvedParentWhenExplicitParentMissing() throws {
        let parent = try store.createSession(
            provider: .claude,
            projectPath: "/tmp/parent-project",
            title: "Parent-Chat",
            externalSessionID: "claude-ext-9"
        )

        let job = makeJob(cwd: "/tmp/anderswo", parentSessionID: nil)
        try store.mergeSubagentJobs(
            [job],
            resolvedParentExternalByShortId: [job.shortId: "claude-ext-9"]
        )

        let created = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(created?.subagentParentSessionID, "claude-ext-9")
        XCTAssertEqual(created?.projectID, parent.projectID)
    }

    /// Nachträgliche Zuordnung: der Job existierte schon parentlos (Chat war
    /// z.B. noch nicht gebunden) — ein späterer Sync mit Auflösung trägt den
    /// Parent nach, überschreibt aber nie einen vorhandenen.
    func testResolvedParentIsBackfilledButNeverOverwrites() throws {
        _ = try store.createSession(
            provider: .claude,
            projectPath: "/tmp/parent-project",
            title: "Parent-Chat",
            externalSessionID: "claude-ext-9"
        )

        let job = makeJob(parentSessionID: nil)
        try store.mergeSubagentJobs([job])
        XCTAssertNil(store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }?.subagentParentSessionID)

        // Zweiter Sync löst die PID auf → Backfill.
        try store.mergeSubagentJobs([job], resolvedParentExternalByShortId: [job.shortId: "claude-ext-9"])
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }?.subagentParentSessionID,
            "claude-ext-9"
        )

        // Dritter Sync mit ANDERER Auflösung darf nicht überschreiben.
        try store.mergeSubagentJobs([job], resolvedParentExternalByShortId: [job.shortId: "claude-ext-anders"])
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }?.subagentParentSessionID,
            "claude-ext-9"
        )
    }

    // MARK: - Modell/Effort der Job-Session (Header-Anzeige)

    /// Explizite Job-Parameter (--model/--effort) landen in der Session —
    /// nicht die App-Defaults (die zeigten fälschlich "gpt-5.5 · high").
    func testJobSessionUsesExplicitJobModelAndEffort() throws {
        var job = makeJob()
        job.model = "gpt-5.6-terra"
        job.effort = "xhigh"

        try store.mergeSubagentJobs([job], codexConfigDefaults: .empty)

        let session = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(session?.model, "gpt-5.6-terra")
        XCTAssertEqual(session?.reasoningEffort, "xhigh")
    }

    /// Job ohne --model/--effort läuft real mit den config.toml-Defaults —
    /// genau die muss die Session zeigen.
    func testJobSessionFallsBackToCodexConfigDefaults() throws {
        let job = makeJob()

        try store.mergeSubagentJobs(
            [job],
            codexConfigDefaults: CodexGlobalConfigDefaults(model: "gpt-5.6-sol", effort: "high")
        )

        let session = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(session?.model, "gpt-5.6-sol")
        XCTAssertEqual(session?.reasoningEffort, "high")
    }

    /// Bestand-Reparatur: eine früher mit App-Defaults angelegte Job-Session
    /// wird beim nächsten Sync auf die echten Werte korrigiert.
    func testKnownJobSessionModelIsCorrectedOnLaterSync() throws {
        let job = makeJob()
        // Erster Sync ohne bekannte Defaults → injizierter Fallback
        // (simuliert den alten Legacy-Stand gpt-5.5).
        try store.mergeSubagentJobs(
            [job],
            codexConfigDefaults: .empty,
            fallbackModelRaw: "gpt-5.5"
        )
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }?.model,
            "gpt-5.5"
        )

        // Späterer Sync kennt die config.toml-Defaults → korrigiert.
        try store.mergeSubagentJobs(
            [job],
            codexConfigDefaults: CodexGlobalConfigDefaults(model: "gpt-5.6-sol", effort: "high")
        )
        let session = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(session?.model, "gpt-5.6-sol")
        XCTAssertEqual(session?.reasoningEffort, "high")
    }

    /// Explizites --parent gewinnt gegen die PID-Auflösung.
    func testExplicitParentWinsOverResolvedParent() throws {
        _ = try store.createSession(
            provider: .claude,
            projectPath: "/tmp/parent-project",
            title: "Parent-Chat",
            externalSessionID: "claude-ext-explizit"
        )
        let job = makeJob(parentSessionID: "claude-ext-explizit")
        try store.mergeSubagentJobs(
            [job],
            resolvedParentExternalByShortId: [job.shortId: "claude-ext-pid"]
        )
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }?.subagentParentSessionID,
            "claude-ext-explizit"
        )
    }

    // MARK: - Anlegen

    func testCreateAssignsParentProjectViaParentSessionID() throws {
        // Parent-Claude-Session mit externalSessionID im Projekt anlegen.
        let parent = try store.createSession(
            provider: .claude,
            projectPath: "/tmp/parent-project",
            title: "Parent-Chat",
            externalSessionID: "claude-ext-1"
        )

        let job = makeJob(cwd: "/tmp/irgendwo-anders", parentSessionID: "claude-ext-1")
        try store.mergeSubagentJobs([job])

        let workspace = store.loadWorkspace()
        let created = workspace.sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertNotNil(created)
        XCTAssertEqual(created?.projectID, parent.projectID, "Job hängt am Parent-PROJEKT, nicht am Job-cwd")
        XCTAssertEqual(created?.provider, .codex)
        XCTAssertEqual(created?.kind, .subagentJob)
        XCTAssertEqual(created?.externalSessionID, "thread-123")
        XCTAssertEqual(created?.hasLaunchedInitialPrompt, true)
        XCTAssertEqual(created?.createdManually, true, "sonst unsichtbar — Sidebar filtert auf isManuallyCreated")
        XCTAssertEqual(created?.subagentParentSessionID, "claude-ext-1")
        XCTAssertEqual(created?.subagentCwd, "/tmp/irgendwo-anders")
    }

    func testCreateFallsBackToCwdProjectWhenParentUnknown() throws {
        let job = makeJob(cwd: "/tmp/fallback-repo", parentSessionID: "niemand-kennt-mich")
        try store.mergeSubagentJobs([job])

        let workspace = store.loadWorkspace()
        let created = workspace.sessions.first { $0.subagentJobShortID == job.shortId }
        let project = workspace.projects.first { $0.id == created?.projectID }
        XCTAssertEqual(project?.path, AgentSessionStore.canonicalProjectPath("/tmp/fallback-repo"))
    }

    func testCreateUsesWorktreePathAsSubagentCwd() throws {
        let job = makeJob(worktreePath: "/tmp/jobs/a1b2c3d4/worktree")
        try store.mergeSubagentJobs([job])

        let created = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(created?.subagentCwd, "/tmp/jobs/a1b2c3d4/worktree")
    }

    // MARK: - Titel-Kürzung

    func testTitleIsShortenedFirstLineOfIntent() throws {
        let longIntent = String(repeating: "a", count: 80) + "\nzweite Zeile"
        let job = makeJob(intent: longIntent)
        try store.mergeSubagentJobs([job])

        let created = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(created?.title.count, 60)
        XCTAssertTrue(created?.title.hasSuffix("…") == true)
        XCTAssertFalse(created?.title.contains("zweite") ?? true)
    }

    func testEmptyIntentGetsFallbackTitle() {
        XCTAssertEqual(AgentSessionStore.subagentSessionTitle(from: "   \n  "), "Subagent-Job")
    }

    // MARK: - Idempotenz

    func testSecondIdenticalMergeDoesNotChangeWorkspace() throws {
        let job = makeJob()
        try store.mergeSubagentJobs([job])
        let before = store.loadWorkspace()

        try store.mergeSubagentJobs([job])
        let after = store.loadWorkspace()

        XCTAssertEqual(before, after, "Sync-Tick ohne echte Änderung darf den Workspace nicht anfassen")
    }

    func testActivityBumpOnlyForTransitionedJobs() throws {
        let job = makeJob(updatedAt: Date(timeIntervalSince1970: 2_000))
        try store.mergeSubagentJobs([job])
        let created = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(created?.lastActivityAt, Date(timeIntervalSince1970: 2_000))

        // Phasen-Übergang: done mit späterem updatedAt + Bump-Set.
        var done = job
        done.state = .done
        done.updatedAt = Date(timeIntervalSince1970: 3_000)
        try store.mergeSubagentJobs([done], activityBumpShortIds: [job.shortId])
        let bumped = store.loadWorkspace().sessions.first { $0.subagentJobShortID == job.shortId }
        XCTAssertEqual(bumped?.lastActivityAt, Date(timeIntervalSince1970: 3_000))
    }

    func testThreadIDIsBackfilledButNeverOverwritten() throws {
        // Erster Merge ohne ThreadID (spawning, thread.started kam noch nicht).
        let spawning = makeJob(state: .spawning, codexThreadID: nil)
        try store.mergeSubagentJobs([spawning])
        XCTAssertNil(store.loadWorkspace().sessions.first { $0.subagentJobShortID == spawning.shortId }?.externalSessionID)

        // ThreadID taucht auf → nachtragen.
        let running = makeJob(state: .running, codexThreadID: "thread-neu")
        try store.mergeSubagentJobs([running])
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.subagentJobShortID == running.shortId }?.externalSessionID,
            "thread-neu"
        )

        // Eine bereits gebundene ID wird nie überschrieben.
        let other = makeJob(state: .done, codexThreadID: "thread-anders")
        try store.mergeSubagentJobs([other])
        XCTAssertEqual(
            store.loadWorkspace().sessions.first { $0.subagentJobShortID == other.shortId }?.externalSessionID,
            "thread-neu"
        )
    }

    // MARK: - agent rm

    func testRemovedJobDirectoryNilsShortIDButKeepsSession() throws {
        let job = makeJob()
        try store.mergeSubagentJobs([job])

        // Job-Verzeichnis weg (agent rm) → Merge ohne den Job.
        try store.mergeSubagentJobs([])

        let workspace = store.loadWorkspace()
        let session = workspace.sessions.first { $0.kind == .subagentJob }
        XCTAssertNotNil(session, "Session bleibt erhalten")
        XCTAssertNil(session?.subagentJobShortID, "Short-ID genil-t — Indexer darf adoptieren")
        XCTAssertEqual(session?.externalSessionID, "thread-123", "Codex-Bindung bleibt")
    }

    func testMergeDoesNotDuplicateAfterRmAndReMerge() throws {
        // Nach rm (Short-ID nil) darf ein NEUER Job mit derselben Short-ID
        // eine neue Session anlegen — die alte bleibt als Historie stehen.
        let job = makeJob()
        try store.mergeSubagentJobs([job])
        try store.mergeSubagentJobs([])
        try store.mergeSubagentJobs([makeJob(codexThreadID: "thread-999")])

        let sessions = store.loadWorkspace().sessions.filter { $0.kind == .subagentJob }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.filter { $0.subagentJobShortID == "a1b2c3d4" }.count, 1)
    }
}
