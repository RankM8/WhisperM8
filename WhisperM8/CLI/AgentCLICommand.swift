import Foundation

// MARK: - Dispatch

/// `whisperm8 agent <subcommand>` — Codex-Subagents spawnen und verwalten.
/// WhisperM8 ist hier selbst der Supervisor (Codex hat kein `--bg`-Pendant):
/// Jobs leben als Verzeichnisse unter Application Support/WhisperM8/agent-jobs,
/// jeder Turn ist ein eigener `codex exec`-Prozess.
enum AgentCLICommand {
    static func run(arguments: [String]) async -> Int32 {
        guard let subcommand = arguments.first else {
            CLIIO.out(AgentCLIHelp.text)
            return AgentCLIExit.usage
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "help", "--help", "-h":
            CLIIO.out(AgentCLIHelp.text)
            return AgentCLIExit.ok
        case "run":
            return await AgentRunCLI.run(rest)
        case "send":
            return await AgentSendCLI.run(rest)
        case "list":
            return AgentListCLI.run(rest)
        case "status":
            return AgentStatusCLI.run(rest)
        case "logs":
            return AgentLogsCLI.run(rest)
        case "stop":
            return AgentStopCLI.run(rest)
        case "rm":
            return AgentRemoveCLI.run(rest)
        default:
            CLIIO.err("Unbekannter agent-Befehl: \(subcommand)")
            CLIIO.out(AgentCLIHelp.text)
            return AgentCLIExit.usage
        }
    }
}

// MARK: - run

enum AgentRunCLI {
    static func run(_ arguments: [String]) async -> Int32 {
        let options: AgentRunOptions
        do {
            options = try AgentCLIParser.parseRun(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }

        // Preflight: codex auflösen + Versionspolitik (zu alt = Abbruch,
        // neuere Major = nur Warnung).
        let codexVersion: String?
        switch await CodexAgentPreflight().check() {
        case .codexMissing:
            CLIIO.err("codex nicht gefunden — Codex.app installieren oder `codex` in den PATH legen.")
            return AgentCLIExit.environment
        case .versionTooOld(let found, let minimum):
            CLIIO.err("codex \(found) ist älter als die getestete Mindestversion \(minimum) — bitte aktualisieren.")
            return AgentCLIExit.environment
        case .versionUnparseable(_, let raw):
            CLIIO.err("Warnung: codex-Version nicht erkennbar (\(raw)) — fahre fort.")
            codexVersion = nil
        case .ok(_, let version, let warning):
            if let warning { CLIIO.err("Warnung: \(warning)") }
            codexVersion = version.description
        }

        let store = AgentJobCLIShared.storeFactory()
        let cwd = options.cd ?? FileManager.default.currentDirectoryPath
        let shortId = store.generateShortID()

        var initial = AgentJobState(
            shortId: shortId,
            state: .spawning,
            intent: options.prompt,
            cwd: cwd,
            sandbox: options.sandbox,
            parentSessionID: options.parentSessionID,
            codexVersion: codexVersion
        )
        initial.model = options.model
        initial.effort = options.effort
        initial.allowNetwork = options.allowNetwork
        // Parent-Fallback ohne --parent: die komplette Vorfahren-PID-Kette
        // merken — die App matcht irgendeine davon gegen die shellPids ihrer
        // PTY-Sessions und ordnet den Job dem spawnenden Chat zu (Claude Code
        // exportiert keine Session-ID in die Bash-Env; Prozessnamen sind
        // unzuverlässig — das native Binary heißt z.B. "2.1.201").
        if options.parentSessionID == nil {
            let chain = ProcessAncestry.ancestorChain()
            initial.parentProcessAncestry = chain.isEmpty ? nil : chain
            initial.parentProcessID = ProcessAncestry.findAncestor(named: "claude")
        }

        do {
            try store.createJob(initial: initial)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.environment
        }

        // Worktree (Opt-in): im Job-Verzeichnis, Branch subagent/<id>.
        if options.worktree {
            do {
                let worktree = try AgentWorktreeManager().createWorktree(
                    repoPath: cwd,
                    shortId: shortId,
                    at: store.jobDirectory(for: shortId).appendingPathComponent("worktree", isDirectory: true)
                )
                try store.mutateState(shortId: shortId) { $0.worktree = worktree }
            } catch {
                CLIIO.err(error.localizedDescription)
                try? store.removeJob(shortId: shortId)
                return AgentCLIExit.environment
            }
        }

        do {
            try store.writePendingPrompt(shortId: shortId, prompt: options.prompt + AgentSubagentPrompt.reportSuffix)
        } catch {
            CLIIO.err("Prompt-Handoff fehlgeschlagen: \(error.localizedDescription)")
            try? store.removeJob(shortId: shortId)
            return AgentCLIExit.environment
        }

        if options.wait {
            return await AgentJobCLIShared.superviseInlineAndEmit(store: store, shortId: shortId, json: options.json)
        }
        return AgentJobCLIShared.detachAndEmit(store: store, shortId: shortId, json: options.json)
    }
}

// MARK: - send

enum AgentSendCLI {
    static func run(_ arguments: [String]) async -> Int32 {
        let options: AgentSendOptions
        do {
            options = try AgentCLIParser.parseSend(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }

        let store = AgentJobCLIShared.storeFactory()
        // Existenz-Pre-Check (klare Meldung, bevor wir den Job-Lock nehmen —
        // der braucht das Verzeichnis als Anker).
        guard store.readCorrected(shortId: options.shortId) != nil else {
            CLIIO.err("Job \(options.shortId) nicht gefunden.")
            return AgentCLIExit.environment
        }

        // Claim atomar unterm Job-Lock: prüfen → reservieren (spawning) →
        // Prompt hinterlegen. Ohne den Lock ist das ein TOCTOU: zwei parallele
        // send könnten beide den ruhenden Job sehen, beide den Prompt schreiben
        // (einer verloren) und zwei Supervisoren starten.
        let claim: Result<Void, AgentSendClaimError>
        do {
            claim = try store.withExclusiveLock(shortId: options.shortId) {
                AgentSendCLI.claim(store: store, options: options)
            }
        } catch {
            CLIIO.err("Job-Lock fehlgeschlagen: \(error.localizedDescription)")
            return AgentCLIExit.environment
        }
        if case .failure(let error) = claim {
            CLIIO.err(error.message)
            return error.exit
        }

        if options.wait {
            return await AgentJobCLIShared.superviseInlineAndEmit(store: store, shortId: options.shortId, json: options.json)
        }
        return AgentJobCLIShared.detachAndEmit(store: store, shortId: options.shortId, json: options.json)
    }

    /// Fehler eines fehlgeschlagenen Claims: Meldung + CLI-Exit-Code.
    struct AgentSendClaimError: Error {
        let message: String
        let exit: Int32
    }

    /// Läuft UNTERM Job-Lock: Orphan-korrigiert lesen, Guards prüfen und —
    /// wenn legal — den Job auf `spawning` reservieren und den Prompt
    /// hinterlegen. Ab der Reservierung sehen konkurrierende send den Job als
    /// aktiv und prallen mit stateConflict ab.
    static func claim(store: AgentJobStore, options: AgentSendOptions) -> Result<Void, AgentSendClaimError> {
        // Orphan-Korrektur ZUERST — ein toter running-Job wird zu failed
        // und ist damit legal resumierbar.
        guard let state = store.readCorrected(shortId: options.shortId) else {
            return .failure(.init(message: "Job \(options.shortId) nicht gefunden.", exit: AgentCLIExit.environment))
        }
        if state.state == .takenOver {
            return .failure(.init(message: "Job \(options.shortId) wurde als interaktiver Chat übernommen — send ist deaktiviert.", exit: AgentCLIExit.stateConflict))
        }
        if state.isActive {
            return .failure(.init(message: "Job \(options.shortId) läuft gerade (Turn aktiv) — warte auf done/failed oder stoppe ihn.", exit: AgentCLIExit.stateConflict))
        }
        guard state.codexThreadID != nil else {
            return .failure(.init(message: "Job \(options.shortId) hat keine Codex-Thread-ID (erster Turn kam nie bis thread.started) — Resume unmöglich. `agent rm` und neu starten.", exit: AgentCLIExit.stateConflict))
        }

        do {
            // Reservieren: ruhend → spawning (macht den Job für parallele send
            // sofort aktiv), danach erst der Prompt-Handoff.
            try store.transition(shortId: options.shortId, to: .spawning)
            try store.writePendingPrompt(shortId: options.shortId, prompt: options.prompt + AgentSubagentPrompt.reportSuffix)
        } catch {
            return .failure(.init(message: "Prompt-Handoff fehlgeschlagen: \(error.localizedDescription)", exit: AgentCLIExit.environment))
        }
        return .success(())
    }
}

// MARK: - list / status / logs

enum AgentListCLI {
    static func run(_ arguments: [String]) -> Int32 {
        let json: Bool
        do {
            json = try AgentCLIParser.parseList(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }
        let jobs = AgentJobCLIShared.storeFactory().readAllCorrected()
        if json {
            CLIIO.out(AgentJobOutput.encodeStates(jobs))
        } else if jobs.isEmpty {
            CLIIO.err("Keine Jobs vorhanden.")
        } else {
            for job in jobs {
                let cwdName = (job.cwd as NSString).lastPathComponent
                let intent = job.intent.count > 44 ? job.intent.prefix(44) + "…" : Substring(job.intent)
                CLIIO.out("\(job.shortId)  \(job.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  turns:\(job.turns)  \(cwdName)  \(AgentJobOutput.age(of: job))  \(intent)")
            }
        }
        return AgentCLIExit.ok
    }
}

enum AgentStatusCLI {
    static func run(_ arguments: [String]) -> Int32 {
        let shortId: String
        let json: Bool
        do {
            (shortId, json) = try AgentCLIParser.parseIDCommand(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }
        let store = AgentJobCLIShared.storeFactory()
        guard let state = store.readCorrected(shortId: shortId) else {
            CLIIO.err("Job \(shortId) nicht gefunden.")
            return AgentCLIExit.environment
        }
        let lastMessage = store.readLastMessage(shortId: shortId)
        if json {
            CLIIO.out(AgentJobOutput.encodeStatus(state: state, lastMessage: lastMessage))
        } else {
            AgentJobOutput.emitHumanStatus(state: state, lastMessage: lastMessage)
        }
        return AgentJobOutput.exitCode(for: state, lastMessage: lastMessage)
    }
}

enum AgentLogsCLI {
    static func run(_ arguments: [String]) -> Int32 {
        let shortId: String
        let tail: Int
        do {
            (shortId, tail) = try AgentCLIParser.parseLogs(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }
        let store = AgentJobCLIShared.storeFactory()
        guard let state = store.readCorrected(shortId: shortId) else {
            CLIIO.err("Job \(shortId) nicht gefunden.")
            return AgentCLIExit.environment
        }
        if let content = try? String(contentsOf: store.eventsURL(for: shortId), encoding: .utf8) {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.suffix(tail) {
                CLIIO.out(String(line))
            }
        } else {
            CLIIO.err("Noch keine Events.")
        }
        if state.state == .failed {
            CLIIO.err("Job ist failed — Details ggf. in \(store.supervisorLogURL(for: shortId).path)")
        }
        return AgentCLIExit.ok
    }
}

// MARK: - stop / rm

enum AgentStopCLI {
    /// Test-Seam für kill(2).
    static var killProcess: (Int32, Int32) -> Int32 = { pid, sig in kill(pid, sig) }

    static func run(_ arguments: [String]) -> Int32 {
        let shortId: String
        do {
            (shortId, _) = try AgentCLIParser.parseIDCommand(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }
        let store = AgentJobCLIShared.storeFactory()
        guard let state = store.readCorrected(shortId: shortId) else {
            CLIIO.err("Job \(shortId) nicht gefunden.")
            return AgentCLIExit.environment
        }
        guard state.isActive else {
            CLIIO.err("Job \(shortId) läuft nicht (state: \(state.state.rawValue)).")
            return AgentCLIExit.stateConflict
        }
        guard let pid = state.supervisorPid else {
            CLIIO.err("Job \(shortId) hat keine Supervisor-PID — Zustand inkonsistent.")
            return AgentCLIExit.environment
        }

        _ = killProcess(pid, SIGTERM)

        // Kurz nachpollen, ob der Supervisor sauber auf stopped geht.
        for _ in 0..<10 {
            usleep(200_000)
            if let current = store.readState(shortId: shortId), !current.isActive {
                CLIIO.err("Job \(shortId) gestoppt (state: \(current.state.rawValue)).")
                return AgentCLIExit.ok
            }
        }
        CLIIO.err("Stop-Signal gesendet — Job \(shortId) beendet sich gleich (stopping…).")
        return AgentCLIExit.ok
    }
}

enum AgentRemoveCLI {
    static func run(_ arguments: [String]) -> Int32 {
        let shortId: String
        do {
            (shortId, _) = try AgentCLIParser.parseIDCommand(arguments)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.usage
        }
        let store = AgentJobCLIShared.storeFactory()
        guard let state = store.readCorrected(shortId: shortId) else {
            CLIIO.err("Job \(shortId) nicht gefunden.")
            return AgentCLIExit.environment
        }
        guard !state.isActive else {
            CLIIO.err("Job \(shortId) läuft — erst `agent stop \(shortId)`.")
            return AgentCLIExit.stateConflict
        }

        // Worktree abräumen — dirty verweigert (Änderungen retten!), das
        // Job-Verzeichnis bleibt dann stehen.
        if let worktree = state.worktree,
           FileManager.default.fileExists(atPath: worktree.path) {
            do {
                try AgentWorktreeManager().removeWorktree(repoPath: state.cwd, worktreePath: worktree.path)
            } catch {
                CLIIO.err(error.localizedDescription)
                return AgentCLIExit.environment
            }
        }

        do {
            try store.removeJob(shortId: shortId)
        } catch {
            CLIIO.err(error.localizedDescription)
            return AgentCLIExit.environment
        }
        CLIIO.err("Job \(shortId) entfernt. (Die Codex-Session in ~/.codex/sessions bleibt erhalten.)")
        return AgentCLIExit.ok
    }
}

// MARK: - Geteilte Abläufe

enum AgentJobCLIShared {
    /// Test-Seam: Commands holen ihren Store hierüber, damit Tests gegen
    /// ein Temp-Root laufen können (Konvention: Closure-DI).
    static var storeFactory: () -> AgentJobStore = { AgentJobStore() }

    /// E1: --wait macht den Frontend-Prozess selbst zum Supervisor — kein
    /// File-Watching, kein Race. SIGINT (Ctrl-C) stoppt den Turn sauber.
    static func superviseInlineAndEmit(store: AgentJobStore, shortId: String, json: Bool) async -> Int32 {
        // Live-Progress nur für Menschen (stderr); --json bleibt still bis
        // zum finalen Objekt auf stdout.
        let supervisor = AgentJobSupervisor(store: store, onEvent: json ? nil : { event, _ in
            AgentJobOutput.progressLine(for: event).map(CLIIO.err)
        })

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        sigint.setEventHandler { supervisor.requestStop() }
        sigint.resume()
        defer { sigint.cancel() }

        let superviseExit = await supervisor.superviseCurrentTurn(shortId: shortId)
        emitFinal(store: store, shortId: shortId, json: json)
        return superviseExit
    }

    /// Detach: Supervisor-Prozess starten, PID persistieren, Short-ID melden.
    static func detachAndEmit(store: AgentJobStore, shortId: String, json: Bool) -> Int32 {
        do {
            let pid = try AgentSupervisorLauncher().launchDetached(
                shortId: shortId,
                logURL: store.supervisorLogURL(for: shortId)
            )
            try store.mutateState(shortId: shortId) { $0.supervisorPid = pid }
        } catch {
            CLIIO.err(error.localizedDescription)
            _ = try? store.mutateState(shortId: shortId) { job in
                if job.canTransition(to: .failed) { job.state = .failed }
                job.failureReason = "Supervisor-Launch fehlgeschlagen: \(error.localizedDescription)"
            }
            return AgentCLIExit.environment
        }

        if json {
            CLIIO.out(#"{"shortId":"\#(shortId)","state":"spawning"}"#)
        } else {
            CLIIO.out(shortId)
            CLIIO.err("  whisperm8 agent status \(shortId)   Zustand + Report")
            CLIIO.err("  whisperm8 agent logs \(shortId)     letzte Events")
            CLIIO.err("  whisperm8 agent send \(shortId) \"…\"  Folge-Turn")
            CLIIO.err("  whisperm8 agent stop \(shortId)     Turn abbrechen")
        }
        return AgentCLIExit.ok
    }

    /// Finales Ergebnis eines --wait-Laufs aus state.json + last-message.txt.
    static func emitFinal(store: AgentJobStore, shortId: String, json: Bool) {
        guard let state = store.readState(shortId: shortId) else {
            CLIIO.err("state.json nach dem Turn nicht lesbar — Job \(shortId).")
            return
        }
        let lastMessage = store.readLastMessage(shortId: shortId)
        if json {
            CLIIO.out(AgentJobOutput.encodeStatus(state: state, lastMessage: lastMessage))
        } else {
            AgentJobOutput.emitHumanStatus(state: state, lastMessage: lastMessage)
        }
    }
}

// MARK: - Prompt-Zusatz

enum AgentSubagentPrompt {
    /// Job-Anweisung, die das CLI IMMER injiziert (beschlossen: Projekt-
    /// Konventionen kommen aus AGENTS.md im Ziel-Repo, nicht von hier).
    static let reportSuffix = """


    ---
    [WhisperM8-Subagent] Beende deinen letzten Turn mit dem Abschluss-Report \
    als reines JSON gemäß dem vorgegebenen Output-Schema (status: \
    success|partial|failure, summary, filesChanged, commits, testsRun, \
    openQuestions). Kein Text um das JSON herum. Wenn die Sandbox etwas \
    blockiert (z.B. Netzwerk), benenne das explizit in openQuestions.
    """
}

// MARK: - Ausgabe

enum AgentJobOutput {
    /// Menschlicher Live-Fortschritt (stderr) — eine Zeile pro relevantem Event.
    static func progressLine(for event: CodexExecEvent) -> String? {
        switch event {
        case .threadStarted(let id):
            return "→ Thread \(id)"
        case .itemCompleted(let item) where item.type == "agent_message":
            return item.text.map { "· \($0)" }
        case .itemStarted(let item) where item.type == "command_execution":
            return item.command.map { "$ \($0)" }
        case .turnCompleted:
            return "✓ Turn abgeschlossen"
        case .turnFailed(let message):
            return "✗ Turn fehlgeschlagen: \(message ?? "unbekannt")"
        default:
            return nil
        }
    }

    /// Exit-Code nach dem CLI-Vertrag für einen ruhenden Job: 2 wenn `failed`
    /// ODER `done` mit Report-Status `failure` (spiegelt AgentJobSupervisor.
    /// finalize). So liefert `agent status` denselben Code wie der
    /// `--wait`-Lauf, der den Job beendet hat — ein Report-`failure` bleibt
    /// nicht unentdeckt, nur weil der State `.done` ist.
    static func exitCode(for state: AgentJobState, lastMessage: String?) -> Int32 {
        if state.state == .failed { return AgentCLIExit.jobFailed }
        if state.state == .done,
           let lastMessage,
           AgentReport.parse(lastMessage: lastMessage)?.status == .failure {
            return AgentCLIExit.jobFailed
        }
        return AgentCLIExit.ok
    }

    static func age(of job: AgentJobState) -> String {
        let seconds = Int(Date().timeIntervalSince(job.updatedAt))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// Status-Objekt für --json: kompletter State + geparster Report.
    static func encodeStatus(state: AgentJobState, lastMessage: String?) -> String {
        var object = stateDictionary(state)
        if state.state == .done, let lastMessage {
            if let report = AgentReport.parse(lastMessage: lastMessage),
               let data = try? JSONEncoder().encode(report),
               let dict = try? JSONSerialization.jsonObject(with: data) {
                object["report"] = dict
            } else {
                object["report"] = NSNull()
                object["rawLastMessage"] = lastMessage
            }
        }
        return encodeJSON(object)
    }

    static func encodeStates(_ states: [AgentJobState]) -> String {
        encodeJSON(states.map(stateDictionary))
    }

    static func emitHumanStatus(state: AgentJobState, lastMessage: String?) {
        var lines = [
            "Job:     \(state.shortId)   [\(state.state.rawValue)]   turns:\(state.turns)",
            "Intent:  \(state.intent)",
            "Cwd:     \(state.worktree?.path ?? state.cwd)",
        ]
        if let worktree = state.worktree {
            lines.append("Branch:  \(worktree.branch)")
        }
        if let threadID = state.codexThreadID {
            lines.append("Thread:  \(threadID)")
        }
        if let reason = state.failureReason {
            lines.append("Fehler:  \(reason)")
        }
        if let metrics = state.metrics {
            var parts: [String] = []
            if let seconds = metrics.lastTurnSeconds { parts.append("\(Int(seconds))s") }
            if let files = metrics.diffChangedFiles { parts.append("\(files) Dateien") }
            if let added = metrics.diffAdded, let deleted = metrics.diffDeleted {
                parts.append("+\(added) −\(deleted)")
            }
            if !parts.isEmpty { lines.append("Metrik:  \(parts.joined(separator: " · "))") }
        }
        CLIIO.out(lines.joined(separator: "\n"))

        guard state.state == .done, let lastMessage else { return }
        if let report = AgentReport.parse(lastMessage: lastMessage) {
            var reportLines = ["", "Status:  \(report.status.rawValue)", "Summary: \(report.summary)"]
            if !report.filesChanged.isEmpty {
                reportLines.append("Files:   \(report.filesChanged.joined(separator: ", "))")
            }
            for commit in report.commits {
                reportLines.append("Commit:  \(commit.sha) \(commit.message)")
            }
            if let tests = report.testsRun {
                reportLines.append("Tests:   \(tests.command) → \(tests.passed ? "passed" : "FAILED")")
            }
            for question in report.openQuestions {
                reportLines.append("Offen:   \(question)")
            }
            CLIIO.out(reportLines.joined(separator: "\n"))
        } else {
            CLIIO.err("Warnung: Report entspricht nicht dem Schema — Rohtext:")
            CLIIO.out(lastMessage)
        }
    }

    // MARK: Interna

    private static func stateDictionary(_ state: AgentJobState) -> [String: Any] {
        guard let data = try? AgentJobStore.encode(state),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["shortId": state.shortId, "state": state.state.rawValue]
        }
        return dict
    }

    private static func encodeJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"error":"internal JSON encoding error"}"#
        }
        return string
    }
}

// MARK: - Hilfetext

enum AgentCLIHelp {
    static let text = """
    whisperm8 agent — Codex-Subagents spawnen und verwalten

    VERWENDUNG
      whisperm8 agent run  [optionen] "<prompt>"       Job starten (detacht; --wait = synchron)
      whisperm8 agent send <id> [--wait] "<prompt>"    Folge-Turn (codex exec resume)
      whisperm8 agent list [--json]                    alle Jobs
      whisperm8 agent status <id> [--json]             Zustand + Report
      whisperm8 agent logs <id> [--tail N]             letzte Events (Default 50)
      whisperm8 agent stop <id>                        laufenden Turn abbrechen
      whisperm8 agent rm <id>                          Job entfernen (Codex-Session bleibt)

    RUN-OPTIONEN
      --wait                 Synchron: blockiert bis Turn-Ende, Report auf stdout.
      --json                 Maschinenlesbares Ergebnis-Objekt auf stdout.
      --cd <dir>             Working Directory (Default: aktuelles Verzeichnis).
      --sandbox <mode>       read-only | workspace-write (Default).
      --model <name>         Codex-Modell-Override.
      --effort <level>       model_reasoning_effort-Override.
      --allow-network        Netzwerk in der Sandbox erlauben (u.a. git push).
      --worktree             Job in frischem Git-Worktree (Branch subagent/<id>).
      --parent <session-id>  Claude-Session, die diesen Subagent gespawnt hat.

    EXIT-CODES
      0  ok / Job done          3  Zustandskonflikt (läuft schon, übernommen, …)
      1  Usage-Fehler           4  Umgebungsproblem (codex fehlt/zu alt, Job unbekannt, …)
      2  Job failed

    BEISPIELE
      whisperm8 agent run --wait --json --sandbox read-only \\
        "Reviewe den Diff von HEAD~3 auf Regressionen. Nur Analyse."
      whisperm8 agent run --worktree "Implementiere X, teste, committe bei grün."
      whisperm8 agent send a3f81c2e --wait "Klärung: bitte auch die Edge-Cases abdecken."
    """
}
