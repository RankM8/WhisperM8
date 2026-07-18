import AppKit
import Foundation

enum ClaudeCodeProxyError: LocalizedError, Equatable {
    case binaryMissing
    case startFailed(String)
    case notReachable(port: Int)
    case routerStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Das Binary claude-code-proxy wurde nicht gefunden. Bitte den Proxy installieren und den PATH pruefen."
        case .startFailed(let reason):
            return "Der GPT-Proxy konnte nicht gestartet werden: \(reason)"
        case .notReachable(let port):
            return "Der GPT-Proxy ist nach dem Start auf 127.0.0.1:\(port) nicht erreichbar."
        case .routerStartFailed(let reason):
            return "Der GPT-Mix-Router konnte nicht gestartet werden: \(reason)"
        }
    }
}

private final class ClaudeCodeProxyProbeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Eine Umleitung ist keine lokale Proxy-Signatur und darf die Probe
        // insbesondere nicht zu einem fremden HTTP-Ziel weitertragen.
        completionHandler(nil)
    }
}

private final class ClaudeCodeProxyProbeResult {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class ClaudeCodeProxyCommandOutput {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}

enum ClaudeCodeProxyAuthStatus: Equatable {
    case authenticated(account: String, expires: String)
    case notAuthenticated
    case unknown
}

struct ClaudeCodeProxyCommandResult: Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct ClaudeCodeProxyDeviceCodeInfo: Equatable {
    var visitURL: String
    var code: String
}

/// Abstrakter Prozessgriff fuer den langlebigen Proxy. Tests koennen damit
/// Start und Stop beobachten, ohne einen echten Subprozess zu erzeugen.
final class ClaudeCodeProxyProcessHandle {
    private let isRunningResolver: () -> Bool
    private let terminateAction: () -> Void

    init(
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Void
    ) {
        self.isRunningResolver = isRunning
        self.terminateAction = terminate
    }

    var isRunning: Bool { isRunningResolver() }

    func terminate() {
        terminateAction()
    }
}

/// Verwaltet ausschliesslich den von WhisperM8 gestarteten GPT-Proxy. Bereits
/// extern laufende Instanzen werden erkannt, aber niemals uebernommen/beendet.
final class ClaudeCodeProxyManager {
    static let shared = ClaudeCodeProxyManager()

    typealias ProcessLauncher = (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> ClaudeCodeProxyProcessHandle
    typealias CommandRunner = (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> ClaudeCodeProxyCommandResult
    typealias DeviceLoginLauncher = (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String],
        _ onOutput: @escaping (String) -> Void,
        _ onCompletion: @escaping (Int32) -> Void
    ) throws -> ClaudeCodeProxyProcessHandle
    typealias RouterStarter = (_ port: Int) -> Result<Void, Error>
    typealias RouterStopper = () -> Void

    private let commandResolver: (String) -> String?
    private let reachabilityResolver: (Int) -> Bool
    private let processLauncher: ProcessLauncher
    private let commandRunner: CommandRunner
    private let deviceLoginLauncher: DeviceLoginLauncher
    private let routerStarter: RouterStarter
    private let routerStopper: RouterStopper
    private let routerPortResolver: () -> Int
    private let environmentResolver: () -> [String: String]
    private let sleepResolver: (TimeInterval) -> Void
    private let retryAttempts: Int
    private let retryDelay: TimeInterval
    private let notificationCenter: NotificationCenter
    private let ensureLock = NSLock()
    private let processLock = NSLock()
    private var selfStartedProcess: ClaudeCodeProxyProcessHandle?
    private var deviceLoginProcess: ClaudeCodeProxyProcessHandle?
    private var terminateObserver: NSObjectProtocol?

    init(
        commandResolver: @escaping (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        reachabilityResolver: @escaping (Int) -> Bool = { ClaudeCodeProxyManager.isReachable(port: $0) },
        processLauncher: @escaping ProcessLauncher = ClaudeCodeProxyManager.launchProcess,
        commandRunner: @escaping CommandRunner = ClaudeCodeProxyManager.runCommand,
        deviceLoginLauncher: @escaping DeviceLoginLauncher = ClaudeCodeProxyManager.launchDeviceLogin,
        routerStarter: @escaping RouterStarter = { ClaudeGPTMixRouter.shared.start(port: $0) },
        routerStopper: @escaping RouterStopper = { ClaudeGPTMixRouter.shared.stop() },
        routerPortResolver: @escaping () -> Int = { AppPreferences.shared.claudeGPTRouterPort },
        environmentResolver: @escaping () -> [String: String] = {
            LoginShellEnvironment.shared.processEnvironment()
        },
        sleepResolver: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        retryAttempts: Int = 30,
        retryDelay: TimeInterval = 0.1,
        notificationCenter: NotificationCenter = .default
    ) {
        self.commandResolver = commandResolver
        self.reachabilityResolver = reachabilityResolver
        self.processLauncher = processLauncher
        self.commandRunner = commandRunner
        self.deviceLoginLauncher = deviceLoginLauncher
        self.routerStarter = routerStarter
        self.routerStopper = routerStopper
        self.routerPortResolver = routerPortResolver
        self.environmentResolver = environmentResolver
        self.sleepResolver = sleepResolver
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
        self.notificationCenter = notificationCenter

        terminateObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopIfSelfStarted()
            self?.stopDeviceLogin()
        }
    }

    deinit {
        if let terminateObserver {
            notificationCenter.removeObserver(terminateObserver)
        }
    }

    func isReachable(port: Int) -> Bool {
        reachabilityResolver(port)
    }

    func ensureRunning(port: Int) -> Result<Void, ClaudeCodeProxyError> {
        // Zwei gleichzeitige Chat-Starts duerfen nicht zwei Proxy-Prozesse
        // oder Router-Listener erzeugen. Beide Lifecycle-Schritte werden als
        // atomare Startsequenz serialisiert: zuerst Proxy, dann Router.
        ensureLock.lock()
        defer { ensureLock.unlock() }

        var processStartedForThisAttempt: ClaudeCodeProxyProcessHandle?
        if !isReachable(port: port) {
            // Ein registrierter, aber nicht mehr gesunder Prozess darf weder
            // weiterleben noch durch einen neuen Handle verdeckt werden.
            replaceSelfStartedProcess(with: nil)

            guard let executable = commandResolver("claude-code-proxy") else {
                return .failure(.binaryMissing)
            }

            let process: ClaudeCodeProxyProcessHandle
            do {
                var environment = environmentResolver()
                // Die echte Loopback-Garantie liefert das Binary selbst: der
                // raine-Proxy bindet hart auf 127.0.0.1 (verifiziert per lsof;
                // `serve` kennt keinen --host/--bind-Flag). CCP_BIND_ADDRESS
                // setzen wir nur als Defense-in-Depth — falls eine kuenftige
                // Version oder ein alternativer Proxy die Variable auswertet,
                // erzwingt sie ebenfalls loopback statt 0.0.0.0.
                environment["CCP_BIND_ADDRESS"] = "127.0.0.1"
                process = try processLauncher(
                    executable,
                    ["serve", "--no-monitor", "--port", String(port)],
                    environment
                )
            } catch {
                return .failure(.startFailed(error.localizedDescription))
            }

            replaceSelfStartedProcess(with: process)
            processStartedForThisAttempt = process

            var becameReachable = false
            for _ in 0..<max(0, retryAttempts) {
                if isReachable(port: port) {
                    becameReachable = true
                    break
                }
                sleepResolver(retryDelay)
            }

            if !becameReachable, !isReachable(port: port) {
                discardSelfStartedProcess(process)
                return .failure(.notReachable(port: port))
            }
        }

        switch routerStarter(routerPortResolver()) {
        case .success:
            return .success(())
        case .failure(let error):
            if let processStartedForThisAttempt {
                discardSelfStartedProcess(processStartedForThisAttempt)
            }
            return .failure(.routerStartFailed(error.localizedDescription))
        }
    }

    func stopIfSelfStarted() {
        routerStopper()

        replaceSelfStartedProcess(with: nil)
    }

    func authStatus() -> ClaudeCodeProxyAuthStatus {
        guard let executable = commandResolver("claude-code-proxy") else {
            return .unknown
        }
        do {
            let result = try commandRunner(
                executable,
                ["codex", "auth", "status"],
                environmentResolver()
            )
            return Self.parseAuthStatus(result.stdout)
        } catch {
            return .unknown
        }
    }

    func resolvedBinaryPath() -> String? {
        commandResolver("claude-code-proxy")
    }

    /// Startet den Device-Code-Flow als langlebigen Prozess. Der Manager
    /// puffert Chunks, weil URL und Code auch mitten in einer Pipe-Lieferung
    /// getrennt werden koennen.
    @discardableResult
    func startDeviceLogin(
        onCodeInfo: @escaping (ClaudeCodeProxyDeviceCodeInfo) -> Void,
        onCompletion: @escaping (Int32) -> Void
    ) -> Result<Void, ClaudeCodeProxyError> {
        guard let executable = resolvedBinaryPath() else {
            return .failure(.binaryMissing)
        }

        let outputLock = NSLock()
        var accumulatedOutput = ""
        var didPublishCode = false
        var didComplete = false

        do {
            let process = try deviceLoginLauncher(
                executable,
                ["codex", "auth", "device"],
                environmentResolver(),
                { chunk in
                    outputLock.lock()
                    accumulatedOutput += chunk
                    let info = didPublishCode ? nil : Self.parseDeviceCodeInfo(accumulatedOutput)
                    if info != nil { didPublishCode = true }
                    outputLock.unlock()

                    if let info {
                        onCodeInfo(info)
                    }
                },
                { [weak self] exitCode in
                    guard let self else { return }
                    self.processLock.lock()
                    didComplete = true
                    self.deviceLoginProcess = nil
                    self.processLock.unlock()
                    onCompletion(exitCode)
                }
            )
            processLock.lock()
            if !didComplete {
                deviceLoginProcess = process
            }
            processLock.unlock()
            return .success(())
        } catch {
            return .failure(.startFailed(error.localizedDescription))
        }
    }

    /// Der Parser bleibt bewusst tolerant gegen zusaetzliche Statuszeilen des
    /// externen Tools; Account und Ablauf muessen jedoch beide vorhanden sein.
    static func parseAuthStatus(_ output: String) -> ClaudeCodeProxyAuthStatus {
        if output.localizedCaseInsensitiveContains("Not authenticated") {
            return .notAuthenticated
        }

        var account: String?
        var expires: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("Account:") {
                account = String(value.dropFirst("Account:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.hasPrefix("Expires:") {
                expires = String(value.dropFirst("Expires:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let account, !account.isEmpty, let expires, !expires.isEmpty else {
            return .unknown
        }
        return .authenticated(account: account, expires: expires)
    }

    static func parseDeviceCodeInfo(_ output: String) -> ClaudeCodeProxyDeviceCodeInfo? {
        var visitURL: String?
        var code: String?

        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("Visit:") {
                visitURL = String(value.dropFirst("Visit:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.hasPrefix("Enter code:") {
                code = String(value.dropFirst("Enter code:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let visitURL, !visitURL.isEmpty, let code, !code.isEmpty else {
            return nil
        }
        return ClaudeCodeProxyDeviceCodeInfo(visitURL: visitURL, code: code)
    }

    private func stopDeviceLogin() {
        processLock.lock()
        let process = deviceLoginProcess
        deviceLoginProcess = nil
        processLock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
    }

    /// Registriert genau einen von WhisperM8 gestarteten Prozess. Ein alter
    /// Handle wird vor dem Vergessen beendet, damit App-Quit nichts verliert.
    private func replaceSelfStartedProcess(with replacement: ClaudeCodeProxyProcessHandle?) {
        processLock.lock()
        let previous = selfStartedProcess
        selfStartedProcess = replacement
        processLock.unlock()

        if previous !== replacement, previous?.isRunning == true {
            previous?.terminate()
        }
    }

    private func discardSelfStartedProcess(_ process: ClaudeCodeProxyProcessHandle) {
        processLock.lock()
        if selfStartedProcess === process {
            selfStartedProcess = nil
        }
        processLock.unlock()

        if process.isRunning {
            process.terminate()
        }
    }

    /// Der raine-Proxy besitzt mit `/healthz` eine eindeutige Probe. Nur die
    /// dokumentierte Kombination aus 200, JSON und `{ "ok": true }` gilt als
    /// gesund; ein beliebiger Listener auf dem Port reicht nicht mehr aus.
    static func isReachable(port: Int) -> Bool {
        guard
            (1...65_535).contains(port),
            let url = URL(string: "http://127.0.0.1:\(port)/healthz")
        else { return false }

        var request = URLRequest(url: url, timeoutInterval: 0.4)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.4
        configuration.timeoutIntervalForResource = 0.4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = ClaudeCodeProxyProbeDelegate()
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
        let result = ClaudeCodeProxyProbeResult()
        let finished = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            let response = response as? HTTPURLResponse
            result.store(error == nil && isHealthyProbeResponse(
                statusCode: response?.statusCode,
                contentType: response?.value(forHTTPHeaderField: "Content-Type"),
                body: data ?? Data()
            ))
            finished.signal()
        }
        task.resume()

        guard finished.wait(timeout: .now() + 0.5) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            return false
        }
        session.finishTasksAndInvalidate()
        return result.value
    }

    static func isHealthyProbeResponse(
        statusCode: Int?,
        contentType: String?,
        body: Data
    ) -> Bool {
        guard statusCode == 200 else { return false }
        let mediaType = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard mediaType?.caseInsensitiveCompare("application/json") == .orderedSame else {
            return false
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let dictionary = object as? [String: Any],
            dictionary["ok"] as? Bool == true
        else {
            return false
        }
        return true
    }

    private static func launchProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ClaudeCodeProxyProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        return ClaudeCodeProxyProcessHandle(
            isRunning: { process.isRunning },
            terminate: { process.terminate() }
        )
    }

    static func runCommand(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> ClaudeCodeProxyCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let stdout = ClaudeCodeProxyCommandOutput()
        let stderr = ClaudeCodeProxyCommandOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()

        return ClaudeCodeProxyCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.data, encoding: .utf8) ?? "",
            stderr: String(data: stderr.data, encoding: .utf8) ?? ""
        )
    }

    private static func launchDeviceLogin(
        executable: String,
        arguments: [String],
        environment: [String: String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (Int32) -> Void
    ) throws -> ClaudeCodeProxyProcessHandle {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let chunk = String(data: data, encoding: .utf8) {
                onOutput(chunk)
            }
        }
        process.terminationHandler = { completedProcess in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            onCompletion(completedProcess.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        return ClaudeCodeProxyProcessHandle(
            isRunning: { process.isRunning },
            terminate: { process.terminate() }
        )
    }
}
