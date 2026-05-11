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
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let completion = AgentHeadlessCLICompletion()

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                guard proc.terminationStatus == 0 else {
                    completion.finish(
                        .failure(AgentHeadlessCLIError.nonZeroExit(proc.terminationStatus, stderr: stderr)),
                        continuation: continuation
                    )
                    return
                }
                completion.finish(.success(stdout), continuation: continuation)
            }

            do {
                try process.run()
            } catch {
                completion.finish(.failure(error), continuation: continuation)
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            completion.setWatchdog(timer)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak process] in
                if process?.isRunning == true {
                    process?.terminate()
                }
                completion.finish(.failure(AgentHeadlessCLIError.timedOut(timeout)), continuation: continuation)
            }
            timer.resume()
        }
    }
}

private final class AgentHeadlessCLICompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private var watchdog: DispatchSourceTimer?

    func setWatchdog(_ watchdog: DispatchSourceTimer) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            watchdog.cancel()
            return
        }
        self.watchdog = watchdog
        lock.unlock()
    }

    func finish(
        _ result: Result<String, Error>,
        continuation: CheckedContinuation<String, Error>
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        watchdog?.cancel()
        lock.unlock()

        switch result {
        case .success(let output):
            continuation.resume(returning: output)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
