import AppKit
import Darwin
import Foundation

enum ClaudeCodeProxyError: LocalizedError, Equatable {
    case binaryMissing
    case startFailed(String)
    case notReachable(port: Int)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "Das Binary claude-code-proxy wurde nicht gefunden. Bitte den Proxy installieren und den PATH pruefen."
        case .startFailed(let reason):
            return "Der GPT-Proxy konnte nicht gestartet werden: \(reason)"
        case .notReachable(let port):
            return "Der GPT-Proxy ist nach dem Start auf 127.0.0.1:\(port) nicht erreichbar."
        }
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

    private let commandResolver: (String) -> String?
    private let reachabilityResolver: (Int) -> Bool
    private let processLauncher: ProcessLauncher
    private let commandRunner: CommandRunner
    private let environmentResolver: () -> [String: String]
    private let sleepResolver: (TimeInterval) -> Void
    private let retryAttempts: Int
    private let retryDelay: TimeInterval
    private let notificationCenter: NotificationCenter
    private let ensureLock = NSLock()
    private let processLock = NSLock()
    private var selfStartedProcess: ClaudeCodeProxyProcessHandle?
    private var terminateObserver: NSObjectProtocol?

    init(
        commandResolver: @escaping (String) -> String? = { AgentCommandBuilder.commandPath($0) },
        reachabilityResolver: @escaping (Int) -> Bool = { ClaudeCodeProxyManager.isReachable(port: $0) },
        processLauncher: @escaping ProcessLauncher = ClaudeCodeProxyManager.launchProcess,
        commandRunner: @escaping CommandRunner = ClaudeCodeProxyManager.runCommand,
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
        if isReachable(port: port) {
            return .success(())
        }

        // Zwei gleichzeitige Chat-Starts duerfen nicht zwei Proxy-Prozesse
        // erzeugen. Der zweite Aufrufer prueft nach dem Lock erneut.
        ensureLock.lock()
        defer { ensureLock.unlock() }

        if isReachable(port: port) {
            return .success(())
        }

        guard let executable = commandResolver("claude-code-proxy") else {
            return .failure(.binaryMissing)
        }

        let process: ClaudeCodeProxyProcessHandle
        do {
            process = try processLauncher(
                executable,
                ["serve", "--no-monitor", "--port", String(port)],
                environmentResolver()
            )
        } catch {
            return .failure(.startFailed(error.localizedDescription))
        }

        processLock.lock()
        selfStartedProcess = process
        processLock.unlock()

        for _ in 0..<max(0, retryAttempts) {
            if isReachable(port: port) {
                return .success(())
            }
            sleepResolver(retryDelay)
        }

        if isReachable(port: port) {
            return .success(())
        }
        return .failure(.notReachable(port: port))
    }

    func stopIfSelfStarted() {
        processLock.lock()
        let process = selfStartedProcess
        selfStartedProcess = nil
        processLock.unlock()

        if process?.isRunning == true {
            process?.terminate()
        }
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

    /// Kurzer non-blocking TCP-Connect; damit blockiert ein toter Port den
    /// Main-Thread hoechstens 400 ms statt des systemweiten Connect-Timeouts.
    static func isReachable(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags >= 0, fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) >= 0 else {
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            return false
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&pollDescriptor, 1, 400) > 0 else { return false }

        var socketError: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(
            socketFD,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &optionLength
        ) == 0 else {
            return false
        }
        return socketError == 0
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

    private static func runCommand(
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
        process.waitUntilExit()

        return ClaudeCodeProxyCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(
                data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}
