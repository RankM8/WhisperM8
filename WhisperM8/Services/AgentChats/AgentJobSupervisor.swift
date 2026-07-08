import Foundation

/// Superviselt genau EINEN Turn eines Subagent-Jobs: Prompt aus dem
/// Job-Verzeichnis konsumieren, `codex exec` fahren, Events + State-Übergänge
/// persistieren. Läuft entweder detacht (`agent-supervise <id>`, E5) oder
/// inline im Frontend-Prozess (`run/send --wait`, E1) — identischer Code.
final class AgentJobSupervisor: @unchecked Sendable {
    let store: AgentJobStore
    private let runner: CodexExecRunner
    private let commandResolver: (String) -> String?
    private let diffStatProvider: (String) -> AgentJobState.Metrics?
    private let idleTimeout: TimeInterval
    /// Optionaler Live-Beobachter (Inline-Modus: menschlicher Progress auf
    /// stderr; App: UI-Updates). Feuert auf einer Hintergrund-Queue.
    private let onEvent: ((CodexExecEvent, String) -> Void)?

    private let lock = NSLock()
    private var stopRequested = false

    init(
        store: AgentJobStore,
        runner: CodexExecRunner = CodexExecRunner(),
        commandResolver: @escaping (String) -> String? = { CodexStatusProbe.resolveCommandPath($0) },
        diffStatProvider: ((String) -> AgentJobState.Metrics?)? = nil,
        idleTimeout: TimeInterval = 1800,
        onEvent: ((CodexExecEvent, String) -> Void)? = nil
    ) {
        self.onEvent = onEvent
        self.store = store
        self.runner = runner
        self.commandResolver = commandResolver
        self.diffStatProvider = diffStatProvider ?? { path in
            guard let status = GitProjectStatus(path: path) else { return nil }
            return AgentJobState.Metrics(
                lastTurnSeconds: nil,
                diffChangedFiles: status.changedFiles,
                diffAdded: status.added,
                diffDeleted: status.deleted
            )
        }
        self.idleTimeout = idleTimeout
    }

    /// SIGTERM-Handler (agent stop) und App-Stop rufen das — der laufende
    /// codex-Prozess bekommt SIGTERM, der Turn endet als `stopped`.
    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        runner.terminate()
    }

    private var wasStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    /// Fährt den anstehenden Turn. Rückgabewert = Exit-Code nach dem
    /// agent-CLI-Vertrag (0 done, 2 failed, 3 Zustandskonflikt, 4 Umgebung).
    func superviseCurrentTurn(shortId: String) async -> Int32 {
        guard store.readState(shortId: shortId) != nil else {
            log("Job \(shortId) nicht gefunden unter \(store.rootDirectory.path)")
            return AgentCLIExit.environment
        }

        guard let prompt = store.consumePendingPrompt(shortId: shortId) else {
            markFailed(shortId: shortId, reason: "pending-prompt.txt fehlt — nichts zu tun")
            return AgentCLIExit.jobFailed
        }

        guard let codexPath = commandResolver("codex") else {
            markFailed(shortId: shortId, reason: "codex-Binary nicht gefunden")
            return AgentCLIExit.environment
        }

        // running + eigene PID atomar markieren. Verweigert die Guard-Tabelle
        // (z.B. weil inzwischen takenOver), fassen wir nichts an.
        let state: AgentJobState
        do {
            state = try store.transition(shortId: shortId, to: .running) { job in
                job.supervisorPid = ProcessInfo.processInfo.processIdentifier
            }
        } catch {
            log("Turn nicht startbar: \(error.localizedDescription)")
            return AgentCLIExit.stateConflict
        }

        do {
            try CodexReportSchema.write(to: store.reportSchemaURL(for: shortId))
        } catch {
            markFailed(shortId: shortId, reason: "Report-Schema nicht schreibbar: \(error.localizedDescription)")
            return AgentCLIExit.environment
        }

        let effectiveCwd = state.worktree?.path ?? state.cwd
        let sandbox = CodexSandboxMode(rawValue: state.sandbox) ?? .workspaceWrite
        let request = CodexTurnRequest(
            codexPath: codexPath,
            cwd: effectiveCwd,
            prompt: prompt,
            resumeThreadID: state.codexThreadID,
            sandbox: sandbox,
            model: state.model,
            effort: state.effort,
            allowNetwork: state.allowNetwork,
            playwrightStorageStatePath: state.playwrightStorageStatePath,
            // Aus dem effektiven cwd aufgelöst: beim Linked Worktree zeigt
            // dessen .git-DATEI auf das Haupt-.git — genau das muss
            // beschreibbar sein, damit Commits funktionieren.
            gitWritableRootPath: sandbox == .workspaceWrite
                ? CodexGitWritableRoot.resolve(repoPath: effectiveCwd)
                : nil,
            configOverrides: state.configOverrides ?? [],
            outputSchemaPath: store.reportSchemaURL(for: shortId).path,
            outputLastMessagePath: store.lastMessageURL(for: shortId).path,
            idleTimeout: idleTimeout
        )

        let executor = CodexTurnExecutor(runner: runner)
        let sink = JobDirectorySink(store: store, shortId: shortId, onEvent: onEvent)
        let outcome = await executor.execute(request: request, sink: sink)

        return finalize(shortId: shortId, outcome: outcome, effectiveCwd: effectiveCwd)
    }

    // MARK: - Abschluss

    private func finalize(shortId: String, outcome: CodexTurnOutcome, effectiveCwd: String) -> Int32 {
        switch outcome {
        case .done(let report, _, _, let duration):
            var metrics = diffStatProvider(effectiveCwd) ?? AgentJobState.Metrics()
            metrics.lastTurnSeconds = duration
            do {
                try store.transition(shortId: shortId, to: .done) { job in
                    job.turns += 1
                    job.metrics = metrics
                    job.failureReason = nil
                    job.supervisorPid = nil
                }
            } catch {
                log("done-Übergang verweigert: \(error.localizedDescription)")
                return AgentCLIExit.stateConflict
            }
            return report?.status == .failure ? AgentCLIExit.jobFailed : AgentCLIExit.ok

        case .failed(let reason, _, _, let duration):
            // Vom User gestoppt ist kein Fehler — eigener Zustand.
            let target: AgentJobState.State = wasStopRequested ? .stopped : .failed
            do {
                try store.transition(shortId: shortId, to: target) { job in
                    job.failureReason = target == .failed ? reason : nil
                    var metrics = job.metrics ?? AgentJobState.Metrics()
                    metrics.lastTurnSeconds = duration
                    job.metrics = metrics
                    job.supervisorPid = nil
                }
            } catch {
                log("\(target.rawValue)-Übergang verweigert: \(error.localizedDescription)")
                return AgentCLIExit.stateConflict
            }
            return target == .stopped ? AgentCLIExit.ok : AgentCLIExit.jobFailed
        }
    }

    private func markFailed(shortId: String, reason: String) {
        _ = try? store.mutateState(shortId: shortId) { job in
            if job.canTransition(to: .failed) {
                job.state = .failed
            }
            job.failureReason = reason
            job.supervisorPid = nil
        }
        log("Job \(shortId) failed: \(reason)")
    }

    /// Detacht landet das in supervisor.log (stdout/stderr sind dorthin
    /// umgebogen), inline auf stderr des Aufrufers.
    private func log(_ message: String) {
        FileHandle.standardError.write(Data(("[supervisor] " + message + "\n").utf8))
    }
}

// MARK: - Sink

/// Persistiert den Event-Strom ins Job-Verzeichnis. Die Thread-ID wird beim
/// ERSTEN Event sofort geschrieben — stirbt der Supervisor mitten im Turn,
/// bleibt der Job resumierbar (Fallstrick #2 des Plans).
private final class JobDirectorySink: AgentTurnSink, @unchecked Sendable {
    private let store: AgentJobStore
    private let shortId: String
    private let onEvent: ((CodexExecEvent, String) -> Void)?

    init(store: AgentJobStore, shortId: String, onEvent: ((CodexExecEvent, String) -> Void)?) {
        self.store = store
        self.shortId = shortId
        self.onEvent = onEvent
    }

    func turnWillStart(prompt: String) {}

    func received(event: CodexExecEvent, rawLine: String) {
        store.appendEvent(shortId: shortId, rawLine: rawLine)
        onEvent?(event, rawLine)
    }

    func threadStarted(threadID: String) {
        _ = try? store.mutateState(shortId: shortId) { job in
            if job.codexThreadID == nil {
                job.codexThreadID = threadID
            }
        }
    }

    func turnDidFinish(outcome: CodexTurnOutcome) {
        // Finaler State-Übergang läuft im Supervisor (finalize) — der Sink
        // ist nur der Schreiber für Streaming-Artefakte.
    }
}
