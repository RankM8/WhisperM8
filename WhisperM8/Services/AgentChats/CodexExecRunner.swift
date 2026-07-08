import Foundation

// MARK: - Request / Result

enum CodexSandboxMode: String, Equatable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
}

/// Beschreibung eines einzelnen Subagent-Turns (ein `codex exec`-Prozess).
struct CodexTurnRequest {
    var codexPath: String
    var cwd: String
    var prompt: String
    /// nil = erster Turn; sonst `codex exec resume <threadID>`.
    var resumeThreadID: String?
    var sandbox: CodexSandboxMode = .workspaceWrite
    var model: String?
    var effort: String?
    /// Opt-in: erlaubt Netzwerk in der workspace-write-Sandbox (u.a. git push).
    var allowNetwork = false
    /// Optional: isoliertes Playwright-MCP mit dieser storageState-Datei starten.
    var playwrightStorageStatePath: String?
    /// .git-Verzeichnis, das für Commits beschreibbar sein muss (Codex behandelt
    /// das Top-Level-.git jeder writable root als read-only). nil = kein Repo
    /// bzw. read-only-Job — dann kein Override.
    var gitWritableRootPath: String?
    /// Generische Codex-Config-Overrides (`--config key=value`), 1:1 als `-c`
    /// durchgereicht — NACH den eingebauten Werten, damit sie gewinnen.
    var configOverrides: [String] = []
    var outputSchemaPath: String
    var outputLastMessagePath: String
    /// Idle-Watchdog: kein Gesamt-Timeout (Turns dürfen lange laufen), aber
    /// wenn so lange KEIN Event mehr kommt, gilt der Turn als stalled →
    /// SIGTERM. nil = kein Watchdog (Slice-1-Default).
    var idleTimeout: TimeInterval?
}

struct CodexTurnResult: Equatable {
    var exitCode: Int32
    /// Aus dem ersten `thread.started`-Event.
    var threadID: String?
    /// Inhalt von `--output-last-message` (der Report), nil wenn die Datei
    /// fehlt oder leer ist.
    var lastMessage: String?
    var stderrTail: String
    /// Meldung aus einem `turn.failed`-Event, falls eines kam.
    var turnFailedMessage: String?
    /// true = der Idle-Watchdog hat den Prozess abgebrochen.
    var stalled: Bool
}

// MARK: - Runner

/// Führt genau einen `codex exec --json`-Turn aus und streamt die
/// JSONL-Events live an den Aufrufer.
///
/// Bewusst NICHT auf `AgentHeadlessCLI`/`DefaultProcessRunner` aufgebaut:
/// beide lesen stdout erst nach Prozess-Ende — bei langen Codex-Sessions
/// läuft der 64-KB-Pipe-Puffer voll und der Prozess deadlockt. Hier wird
/// stdout streamend über `readabilityHandler` konsumiert.
final class CodexExecRunner: @unchecked Sendable {
    enum RunnerError: Error, LocalizedError {
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let reason):
                return "codex exec konnte nicht gestartet werden: \(reason)"
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var stalledFlag = false
    /// Gesetzt, sobald stdout-EOF + stderr-EOF + Termination da sind.
    private var runFinished = false

    // MARK: argv (pure, separat testbar)

    /// Gepinnte Playwright-MCP-Version — @latest würde Version-Drift zwischen
    /// parallelen QA-Wellen und langsame npx-Kaltstarts bedeuten.
    static let playwrightMCPVersion = "0.0.77"

    static func buildArguments(for request: CodexTurnRequest) -> [String] {
        // `-a never` (nur als Root-Flag VOR `exec` gültig) betrifft
        // Shell-Approvals. MCP-Tool-Approvals deckt es NICHT ab — die regelt
        // default_tools_approval_mode unten (A/B-verifiziert 2026-07-05).
        var args = ["-a", "never", "exec"]
        if request.resumeThreadID != nil {
            args.append("resume")
        }
        args += [
            "--json",
            "--skip-git-repo-check",
            "--output-schema", request.outputSchemaPath,
            "--output-last-message", request.outputLastMessagePath,
        ]
        if request.resumeThreadID == nil {
            args += ["--sandbox", request.sandbox.rawValue, "--cd", request.cwd]
        } else {
            // `exec resume` kennt --sandbox/--cd NICHT (verifiziert gegen
            // codex-cli 0.142.5) — Sandbox als Config-Override, cwd kommt
            // über `currentDirectoryURL` des Prozesses.
            args += ["-c", "sandbox_mode=\"\(request.sandbox.rawValue)\""]
        }
        // Commits freischalten: Codex' workspace-write behandelt das
        // Top-Level-.git jeder writable root als read-only — `git commit`
        // stirbt sonst an `.git/index.lock: Operation not permitted`
        // (empirisch verifiziert 2026-07-08, codex 0.142.5; gilt für
        // in-place UND Linked Worktrees, deren Metadaten im Haupt-.git
        // liegen). read-only-Jobs bekommen bewusst keinen Override.
        if request.sandbox == .workspaceWrite,
           let gitRoot = request.gitWritableRootPath, !gitRoot.isEmpty {
            args += ["-c", "sandbox_workspace_write.writable_roots=\(tomlArray([gitRoot]))"]
        }
        if let model = request.model, !model.isEmpty {
            args += ["-m", model]
        }
        if let effort = request.effort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\(effort)"]
        }
        if request.allowNetwork {
            args += ["-c", "sandbox_workspace_write.network_access=true"]
        }
        if let storageStatePath = request.playwrightStorageStatePath, !storageStatePath.isEmpty {
            let playwrightArgs = tomlArray([
                "-y",
                "@playwright/mcp@\(playwrightMCPVersion)",
                "--browser",
                "chrome",
                "--ignore-https-errors",
                "--isolated",
                "--storage-state",
                storageStatePath,
            ])
            // command explizit mitgeben — sonst hängt der Server an einem
            // vorhandenen [mcp_servers.playwright]-Eintrag in der User-Config.
            args += [
                "-c", "mcp_servers.playwright.command=\"npx\"",
                "-c", "mcp_servers.playwright.args=\(playwrightArgs)",
                // npx-Kaltstart (Paket-Download) kann den 10s-Default reißen.
                "-c", "mcp_servers.playwright.startup_timeout_sec=120",
                // Langsame Seiten/Screenshots unter Parallel-Last abfedern.
                "-c", "mcp_servers.playwright.tool_timeout_sec=180",
                // Codex gated nicht-read-only MCP-Tools (readOnlyHint) hinter
                // einer Freigabe; headless werden sie sonst als
                // "user cancelled MCP tool call" abgebrochen. `-a never`
                // deckt das NICHT ab.
                "-c", "mcp_servers.playwright.default_tools_approval_mode=\"approve\"",
            ]
        }
        // Generische Overrides als LETZTE -c-Werte: in der Codex CLI gewinnt
        // der letzte -c, so kann der Aufrufer auch eingebaute Werte (Effort,
        // writable_roots, Playwright-Konfiguration) gezielt übersteuern.
        for override in request.configOverrides where !override.isEmpty {
            args += ["-c", override]
        }
        if let resumeID = request.resumeThreadID {
            // Positional: [SESSION_ID] [PROMPT] — die ID direkt vor dem "-".
            args.append(resumeID)
        }
        // Prompt via stdin (Länge/Quoting/ps-Sichtbarkeit) — "-" als letztes
        // Argument aktiviert den stdin-Modus.
        args.append("-")
        return args
    }

    private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map { "\"\(tomlEscape($0))\"" }.joined(separator: ",") + "]"
    }

    private static func tomlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Ausführung

    /// Startet den Turn. `onEvent` wird pro geparster JSONL-Zeile auf einer
    /// Hintergrund-Queue aufgerufen (Aufrufer serialisiert selbst, falls
    /// nötig). Wirft nur bei Launch-Fehlern — alles andere steckt im Result.
    /// Einmalig pro Prozess: SIGPIPE ignorieren — der stdin-Write in einen
    /// bereits beendeten codex-Prozess darf uns nicht killen (der Fehler
    /// kommt dann als EPIPE aus write(2) und wird geschluckt).
    private static let ignoreSigpipe: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    func run(
        request: CodexTurnRequest,
        onEvent: @escaping (CodexExecEvent, _ rawLine: String) -> Void
    ) async throws -> CodexTurnResult {
        _ = Self.ignoreSigpipe
        // Frischer Lauf: Stall-Flag aus einem etwaigen Vorlauf zurücksetzen.
        // Der Runner ist zwar single-use (ein Supervisor = ein Turn), aber so
        // bleibt der Zustand ehrlich, falls ein Runner je wiederverwendet wird
        // — sonst würde ein alter Watchdog-Abbruch den nächsten Turn
        // fälschlich als stalled melden.
        resetStalled()
        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: request.codexPath)
            process.arguments = Self.buildArguments(for: request)
            process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)

            var env = LoginShellEnvironment.shared.processEnvironment()
            env["NO_COLOR"] = "1"
            env["CLICOLOR"] = "0"
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = makeState(onEvent: onEvent)

            // Idle-Watchdog: bei jedem Event neu geplant; feuert nur, wenn
            // der Stream idleTimeout lang komplett still war.
            var watchdog: DispatchSourceTimer?
            if let idle = request.idleTimeout {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + idle)
                timer.setEventHandler { [weak self, weak process] in
                    self?.markStalled()
                    if process?.isRunning == true {
                        process?.terminate()
                    }
                }
                state.installWatchdog(timer, idleTimeout: idle)
                watchdog = timer
                timer.resume()
            }

            // Drain-Koordination: stdout-EOF + stderr-EOF + Termination —
            // erst wenn alles drei da ist, ist das Result vollständig.
            let group = DispatchGroup()

            group.enter() // stdout
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.finishStdout()
                    group.leave()
                    return
                }
                state.consumeStdout(data)
            }

            group.enter() // stderr
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                    return
                }
                state.consumeStderr(data)
            }

            group.enter() // termination
            let exitBox = ExitCodeBox()
            process.terminationHandler = { proc in
                exitBox.code = proc.terminationStatus
                group.leave()
            }

            do {
                try process.run()
            } catch {
                watchdog?.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
                return
            }

            lock.lock()
            self.process = process
            lock.unlock()

            // Prompt auf separater Queue schreiben + FD schließen — nie auf
            // dem Thread, der auch liest (Deadlock bei großen Prompts).
            DispatchQueue.global(qos: .utility).async {
                let handle = stdinPipe.fileHandleForWriting
                if let data = request.prompt.data(using: .utf8) {
                    // write(contentsOf:) wirft bei früh beendetem Prozess
                    // (EPIPE) — bewusst schlucken, der Exit-Code erzählt es.
                    try? handle.write(contentsOf: data)
                }
                try? handle.close()
            }

            group.notify(queue: .global(qos: .utility)) { [weak self] in
                // Run als beendet markieren, BEVOR der Timer gecancelt wird:
                // ein bereits fälliger/enqueuter Handler darf den fertigen
                // Turn nicht nachträglich als stalled abstempeln (mapOutcome
                // prüft `stalled` vor dem Exit-Code — sonst würde ein
                // erfolgreicher Turn als failed enden).
                self?.markRunFinished()
                watchdog?.cancel()
                self?.clearProcess()
                continuation.resume(returning: exitBox.code)
            }
        }

        let lastMessage = (try? String(contentsOfFile: request.outputLastMessagePath, encoding: .utf8))
            .flatMap { $0.isEmpty ? nil : $0 }

        let snapshot = stateSnapshotAfterRun()
        return CodexTurnResult(
            exitCode: exitCode,
            threadID: snapshot.threadID,
            lastMessage: lastMessage,
            stderrTail: snapshot.stderrTail,
            turnFailedMessage: snapshot.turnFailedMessage,
            stalled: snapshot.stalled
        )
    }

    /// SIGTERM an den laufenden codex-Prozess (für `agent stop` und den
    /// Supervisor-Signal-Handler). No-op wenn nichts läuft.
    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    // MARK: - Interna

    /// No-op, sobald der Run vollständig abgeschlossen ist (siehe
    /// `markRunFinished`) — schützt gegen den spät feuernden Watchdog.
    /// `internal` statt `private`: der Guard ist ohne Timing-Flakiness nur
    /// direkt testbar.
    func markStalled() {
        lock.lock()
        if !runFinished {
            stalledFlag = true
        }
        lock.unlock()
    }

    func markRunFinished() {
        lock.lock()
        runFinished = true
        lock.unlock()
    }

    /// Test-Seam: aktueller Stand des Stall-Flags.
    var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalledFlag
    }

    private func resetStalled() {
        lock.lock()
        stalledFlag = false
        runFinished = false
        lock.unlock()
    }

    private func clearProcess() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    private var lastState: TurnStreamState?

    private func stateSnapshotAfterRun() -> (threadID: String?, stderrTail: String, turnFailedMessage: String?, stalled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (
            lastState?.threadID,
            lastState?.stderrTail ?? "",
            lastState?.turnFailedMessage,
            stalledFlag
        )
    }

    fileprivate func adopt(state: TurnStreamState) {
        lock.lock()
        lastState = state
        lock.unlock()
    }

    private final class ExitCodeBox: @unchecked Sendable {
        var code: Int32 = -1
    }
}

// MARK: - Stream-Zustand

/// Kapselt Zeilenpufferung, Event-Parsing und stderr-Tail. Alle Methoden
/// sind lock-geschützt — `readabilityHandler` für stdout und stderr laufen
/// auf unterschiedlichen Dispatch-Queues.
private final class TurnStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private let onEvent: (CodexExecEvent, String) -> Void

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private(set) var threadID: String?
    private(set) var turnFailedMessage: String?

    private var watchdog: DispatchSourceTimer?
    private var idleTimeout: TimeInterval = 0

    /// stderr wird nur als Tail behalten (Fehlerdiagnose) — codex kann dort
    /// viel Progress-Noise schreiben.
    private static let stderrTailLimit = 4096

    init(onEvent: @escaping (CodexExecEvent, String) -> Void) {
        self.onEvent = onEvent
    }

    func installWatchdog(_ timer: DispatchSourceTimer, idleTimeout: TimeInterval) {
        lock.lock()
        watchdog = timer
        self.idleTimeout = idleTimeout
        lock.unlock()
    }

    func consumeStdout(_ data: Data) {
        var events: [(CodexExecEvent, String)] = []
        lock.lock()
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let event = CodexExecEventParser.parse(line: line) {
                trackEventLocked(event)
                events.append((event, line))
            }
        }
        // Aktivität → Watchdog neu spannen.
        if !data.isEmpty {
            watchdog?.schedule(deadline: .now() + idleTimeout)
        }
        lock.unlock()
        // Callbacks außerhalb des Locks feuern.
        for (event, line) in events {
            onEvent(event, line)
        }
    }

    /// EOF: Restpuffer (letzte Zeile ohne Newline) noch verarbeiten.
    func finishStdout() {
        var pending: (CodexExecEvent, String)?
        lock.lock()
        if !stdoutBuffer.isEmpty,
           let line = String(data: stdoutBuffer, encoding: .utf8) {
            if let event = CodexExecEventParser.parse(line: line) {
                trackEventLocked(event)
                pending = (event, line)
            }
        }
        stdoutBuffer.removeAll()
        lock.unlock()
        if let (event, line) = pending {
            onEvent(event, line)
        }
    }

    func consumeStderr(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.stderrTailLimit {
            stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrTailLimit)
        }
        lock.unlock()
    }

    var stderrTail: String {
        lock.lock()
        defer { lock.unlock() }
        // Lossy dekodieren: der Byte-Schnitt am Tail-Limit kann ein
        // Mehrbyte-Zeichen halbieren — mit `String(data:encoding:)` wäre
        // dann die GANZE Diagnose weg (nil → ""). U+FFFD ist besser als nichts.
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    private func trackEventLocked(_ event: CodexExecEvent) {
        switch event {
        case .threadStarted(let id) where threadID == nil:
            threadID = id
        case .turnFailed(let message):
            turnFailedMessage = message ?? "turn.failed ohne Meldung"
        default:
            break
        }
    }
}

// MARK: - Verdrahtung Runner <-> State

extension CodexExecRunner {
    /// `run` erzeugt intern pro Lauf einen frischen Stream-State; diese
    /// Convenience macht den State nach dem Lauf fürs Result-Snapshot
    /// zugänglich. (Als eigene Methode, damit `run` lesbar bleibt.)
    fileprivate func makeState(onEvent: @escaping (CodexExecEvent, String) -> Void) -> TurnStreamState {
        let state = TurnStreamState(onEvent: onEvent)
        adopt(state: state)
        return state
    }
}

// MARK: - .git-Auflösung für den Commit-Override

/// Ermittelt das gemeinsame Git-Verzeichnis, das für Commits eines Jobs
/// beschreibbar sein muss (→ `CodexTurnRequest.gitWritableRootPath`).
///
/// Bewusst über `git rev-parse --git-common-dir` statt eigener Pfad-Heuristik:
/// git kennt alle Fälle, die eine Handrollung reihenweise verfehlt — cwd im
/// Repo-UNTERverzeichnis (häufigster Fall, `--cd /repo/Sources`), Linked
/// Worktrees (gemeinsames Verzeichnis ist das Haupt-`.git`), bare Repos ohne
/// `.git`-Pfadkomponente (`/repos/main.git`), relative `gitdir:`-Zeilen und
/// `$GIT_DIR`. `--git-common-dir` (nicht `--git-dir`) liefert bei Worktrees
/// genau das Verzeichnis, in dem index.lock/objects/refs landen.
///
/// Der Supervisor ruft das pro Turn auf — bewusst NICHT in
/// Store-Mutation-Closures (Subprozess unter dem Store-Lock ist verboten).
enum CodexGitWritableRoot {
    struct GitResult: Equatable {
        var exitCode: Int32
        var stdout: String
    }

    /// Test-Seam (Muster: GitProjectStatus/AgentWorktreeManager).
    static var gitRunner: ([String]) -> GitResult = runGit

    static func resolve(repoPath: String) -> String? {
        // `--path-format=absolute` MUSS vor dem Query-Flag stehen; ohne das
        // liefert git bei cwd == Repo-Root das relative ".git".
        let result = gitRunner(["-C", repoPath, "rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }
        // Gits Ausgabe UNVERÄNDERT übernehmen: sie ist absolut und bereits
        // symlink-aufgelöst (/private/var/… statt /var/…). `standardizedFileURL`
        // würde genau das rückgängig machen — ein Symlink-Pfad als
        // Sandbox-Root ist bestenfalls fragil.
        return path
    }

    private static func runGit(_ arguments: [String]) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // stderr verwerfen: "not a git repository" ist ein erwarteter Fall.
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return GitResult(
                exitCode: process.terminationStatus,
                stdout: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return GitResult(exitCode: -1, stdout: "")
        }
    }
}
