import Foundation

enum AgentHeadlessCLIError: Error, LocalizedError, Equatable {
    case timedOut(TimeInterval)
    case nonZeroExit(Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            return "Headless-CLI timed out after \(Int(timeout)) seconds."
        case .nonZeroExit(let code, let stderr):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                return "Headless-CLI exited with code \(code)."
            }
            return message
        }
    }
}

struct AgentHeadlessCLI {
    var timeout: TimeInterval

    init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            // Kein stdin: headless Subcommands duerfen nie auf interaktive
            // Eingaben warten (z. B. Bestaetigungs-Prompts) — EOF sofort.
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = AgentHeadlessCLIState(continuation: continuation)

            process.terminationHandler = { proc in
                state.processExited(status: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                state.forceFinish(.failure(error))
                return
            }

            // Blockierende Reader auf eigenen Queues statt Lesen im
            // terminationHandler: `readDataToEndOfFile` konsumiert den
            // ~64-KB-Pipe-Puffer fortlaufend — grosse Ausgaben (z. B.
            // `claude plugin list --available --json` mit hunderten
            // Eintraegen) liessen den Prozess sonst beim Schreiben blockieren
            // und nie terminieren (Review-Befund 2026-07-19). Bewusst KEIN
            // `readabilityHandler`: dessen EOF-Callback ist unzuverlaessig,
            // wenn ein Stream leer bleibt oder Daten und EOF zusammenfallen.
            DispatchQueue.global(qos: .utility).async {
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                state.streamFinished(.stdout, data: data)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                state.streamFinished(.stderr, data: data)
            }

            // Timeout-Kaskade: Die Continuation wird NICHT beim Timeout
            // resumed, sondern erst wenn der Prozess wirklich beendet ist —
            // sonst gilt der Aufruf als "fertig", waehrend das CLI noch auf
            // Config-Dateien schreibt (Review-Befund 2026-07-19).
            // 1) t:      timedOut markieren + SIGTERM
            // 2) t+5s:   SIGKILL, falls noch am Leben
            // 3) t+10s:  Failsafe — Continuation trotzdem freigeben, damit
            //            ein unkillbarer Prozess den Caller nicht ewig haengt.
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            state.setWatchdog(timer)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak process] in
                state.markTimedOut(AgentHeadlessCLIError.timedOut(timeout))
                if process?.isRunning == true {
                    process?.terminate()
                }
                let killTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                state.setWatchdog(killTimer)
                killTimer.schedule(deadline: .now() + 5)
                killTimer.setEventHandler { [weak process] in
                    if let process, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    let failsafe = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                    state.setWatchdog(failsafe)
                    failsafe.schedule(deadline: .now() + 5)
                    failsafe.setEventHandler {
                        state.forceFinish(.failure(AgentHeadlessCLIError.timedOut(timeout)))
                    }
                    failsafe.resume()
                }
                killTimer.resume()
            }
            timer.resume()
        }
    }
}

/// Sammelt Streams + Exit-Status und resumed die Continuation genau einmal,
/// sobald BEIDE Streams EOF gemeldet haben UND der Prozess beendet ist.
/// Dadurch ist garantiert: (a) keine abgeschnittenen Ausgaben, (b) der
/// Aufruf gilt erst als beendet, wenn der Subprozess wirklich tot ist.
private final class AgentHeadlessCLIState: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let continuation: CheckedContinuation<String, Error>
    private var stdoutData = Data()
    private var stderrData = Data()
    private var finishedStreams: Set<Stream> = []
    private var exitStatus: Int32?
    private var timedOutError: AgentHeadlessCLIError?
    private var didFinish = false
    private var watchdogs: [DispatchSourceTimer] = []

    init(continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func streamFinished(_ stream: Stream, data: Data) {
        lock.lock()
        switch stream {
        case .stdout: stdoutData = data
        case .stderr: stderrData = data
        }
        finishedStreams.insert(stream)
        let result = readyResultLocked()
        lock.unlock()
        if let result { finish(result) }
    }

    func processExited(status: Int32) {
        lock.lock()
        exitStatus = status
        let result = readyResultLocked()
        lock.unlock()
        if let result { finish(result) }
    }

    func markTimedOut(_ error: AgentHeadlessCLIError) {
        lock.lock()
        if timedOutError == nil { timedOutError = error }
        lock.unlock()
    }

    func setWatchdog(_ watchdog: DispatchSourceTimer) {
        lock.lock()
        if didFinish {
            lock.unlock()
            watchdog.cancel()
            return
        }
        watchdogs.append(watchdog)
        lock.unlock()
    }

    /// Sofort-Abschluss ohne auf Streams/Exit zu warten (Launch-Fehler,
    /// Failsafe bei unkillbarem Prozess).
    func forceFinish(_ result: Result<String, Error>) {
        finish(result)
    }

    /// Nur unterm Lock aufrufen. Nil = noch nicht fertig.
    private func readyResultLocked() -> Result<String, Error>? {
        guard let exitStatus, finishedStreams.count == 2 else { return nil }
        if let timedOutError {
            return .failure(timedOutError)
        }
        guard exitStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            return .failure(AgentHeadlessCLIError.nonZeroExit(exitStatus, stderr: stderr))
        }
        return .success(String(data: stdoutData, encoding: .utf8) ?? "")
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let pending = watchdogs
        watchdogs = []
        lock.unlock()

        for watchdog in pending { watchdog.cancel() }

        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
