import Darwin
import Foundation

/// Status, wie ihn der Router-Dienst auf `status` meldet.
struct ClaudeGPTRouterServiceStatus: Equatable {
    var pid: Int32
    var build: String
    var port: Int
    var generation: Int
    var state: String
    var active: Int

    init?(_ payload: [String: Any]) {
        guard payload["ok"] as? Bool == true,
              let pid = payload["pid"] as? Int,
              let build = payload["build"] as? String,
              let port = payload["port"] as? Int else { return nil }
        self.pid = Int32(pid)
        self.build = build
        self.port = port
        generation = payload["generation"] as? Int ?? 0
        state = payload["state"] as? String ?? ""
        active = payload["active"] as? Int ?? 0
    }
}

/// Steuerbefehle an einen laufenden Router-Dienst.
enum ClaudeGPTRouterServiceClient {
    static func status(root: URL, timeout: TimeInterval = 1) -> ClaudeGPTRouterServiceStatus? {
        request(root: root, ["op": "status"], timeout: timeout).flatMap(ClaudeGPTRouterServiceStatus.init)
    }

    /// Lauscher schließen (Port sofort frei), auslaufen lassen.
    @discardableResult
    static func shutdown(root: URL, timeout: TimeInterval = 2) -> Bool {
        request(root: root, ["op": "shutdown"], timeout: timeout)?["ok"] as? Bool == true
    }

    private static func request(root: URL, _ message: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        guard FileManager.default.fileExists(atPath: path),
              let fd = try? ClaudeGPTRouterWire.connect(path: path, timeout: timeout) else { return nil }
        defer { close(fd) }
        guard (try? ClaudeGPTRouterWire.send(fd, message)) != nil,
              let reply = try? ClaudeGPTRouterWire.receive(fd) else { return nil }
        reply.descriptor.map { _ = close($0) }
        return reply.message
    }
}

/// Startet und überwacht den Router-Dienst aus der App (Labs
/// `restartKeepsChatsEnabled`). Der Dienst überlebt App-Neustarts; die App
/// findet ihn über seinen Steuer-Socket, übernimmt ihn bei gleichem Build und
/// startet bei anderem Build eine neue Generation, die den lauschenden Socket
/// übernimmt (die alte läuft aus). Stirbt der Dienst, startet die App ihn neu.
final class ClaudeGPTRouterServiceSupervisor: @unchecked Sendable {
    enum SupervisorError: LocalizedError {
        case spawnFailed(String)
        case notReady

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let reason): return "Router-Dienst startet nicht: \(reason)"
            case .notReady: return "Router-Dienst wurde nicht rechtzeitig bereit."
            }
        }
    }

    /// Startet `WhisperM8 gpt-router` mit den Argumenten, liefert die PID.
    typealias Spawner = (_ arguments: [String]) throws -> Int32

    static let shared = ClaudeGPTRouterServiceSupervisor()

    let root: URL
    let build: String
    private let spawner: Spawner
    private let statusResolver: (URL) -> ClaudeGPTRouterServiceStatus?
    private let readyTimeout: TimeInterval
    private let restartDelays: [TimeInterval]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.whisperm8.gpt-router.supervisor")
    private var watchedPID: Int32?
    private var exitSource: DispatchSourceProcess?
    private var desiredPort: Int?
    private var restartAttempt = 0
    private var lastHealthyStart: Date?

    init(
        root: URL = ClaudeGPTRouterServiceSupervisor.defaultRoot(),
        build: String = ClaudeGPTRouterBuild.current,
        spawner: @escaping Spawner = ClaudeGPTRouterServiceSupervisor.spawnFromAppBinary,
        statusResolver: @escaping (URL) -> ClaudeGPTRouterServiceStatus? = { ClaudeGPTRouterServiceClient.status(root: $0) },
        readyTimeout: TimeInterval = 10,
        restartDelays: [TimeInterval] = [0.5, 1, 2, 5, 10, 30]
    ) {
        self.root = root
        self.build = build
        self.spawner = spawner
        self.statusResolver = statusResolver
        self.readyTimeout = readyTimeout
        self.restartDelays = restartDelays
    }

    /// `<Application Support>/WhisperM8/gpt-router`; wird der Socket-Pfad zu
    /// lang (Test-Instanz), ein eigener 0700-Ordner unter `/private/tmp`.
    static func defaultRoot() -> URL {
        let standard = AppInstance.applicationSupport
            .appendingPathComponent("WhisperM8", isDirectory: true)
            .appendingPathComponent("gpt-router", isDirectory: true)
        if ChatsControlProtocol.socketPathFits(ClaudeGPTRouterService.socketURL(root: standard)) {
            return standard
        }
        return URL(
            fileURLWithPath: "/private/tmp/whisperm8-\(getuid())\(AppInstance.socketDirectorySuffix)-router",
            isDirectory: true
        )
    }

    // MARK: Start

    /// Sorgt dafür, dass ein Dienst mit dem Build dieser App auf `port` lauscht.
    func ensureRunning(port: Int) -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        desiredPort = port
        if let status = settledStatus(), status.state == "serving" {
            if status.port == port, status.build == build {
                watch(pid: status.pid)
                return .success(())
            }
            if status.port == port {
                // Älteres (oder anderes) Programm: neue Generation übernimmt
                // den lauschenden Socket, die alte läuft aus.
                switch launch(port: port, takeOver: true) {
                case .success:
                    return .success(())
                case .failure(let error):
                    // Die alte Generation nimmt nach ihrer Frist wieder an.
                    Logger.claudeGPTRouter.error(
                        "gpt_router_service_takeover_failed \(error.localizedDescription, privacy: .public)"
                    )
                    watch(pid: status.pid)
                    return .success(())
                }
            }
            // Anderer Port eingestellt: alte Generation freigeben, neu starten.
            ClaudeGPTRouterServiceClient.shutdown(root: root)
            waitUntilPortFree(port)
        }
        return launch(port: port, takeOver: false)
    }

    /// Status, aber nicht mitten in einer Übergabe: Die dauert Millisekunden;
    /// ein frischer Start dazwischen scheiterte am belegten Port.
    private func settledStatus() -> ClaudeGPTRouterServiceStatus? {
        var status = statusResolver(root)
        let deadline = Date().addingTimeInterval(3)
        while let current = status, current.state != "serving", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            status = statusResolver(root)
        }
        return status
    }

    private func launch(port: Int, takeOver: Bool) -> Result<Void, Error> {
        var arguments = ["gpt-router", "--root", root.path, "--port", String(port)]
        if takeOver { arguments.append("--take-over") }
        let pid: Int32
        do {
            pid = try spawner(arguments)
        } catch {
            return .failure(SupervisorError.spawnFailed(error.localizedDescription))
        }
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if let status = statusResolver(root), status.pid == pid, status.state == "serving" {
                Logger.claudeGPTRouter.notice(
                    "gpt_router_service_ready pid=\(pid) port=\(status.port) generation=\(status.generation) takeOver=\(takeOver)"
                )
                watch(pid: pid)
                lastHealthyStart = Date()
                return .success(())
            }
            if kill(pid, 0) != 0, errno == ESRCH { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return .failure(SupervisorError.notReady)
    }

    private func waitUntilPortFree(_ port: Int) {
        for _ in 0..<60 where !ClaudeCodeProxyManager.isPortFree(port) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: Überwachen

    /// Beobachtet das Ende des Dienstes per kqueue (auch ohne Elternbeziehung,
    /// der Dienst kann aus einem früheren App-Lauf stammen).
    private func watch(pid: Int32) {
        guard watchedPID != pid else { return }
        exitSource?.cancel()
        watchedPID = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.serviceExited(pid: pid) }
        exitSource = source
        source.resume()
        // Schon tot, bevor die Quelle stand?
        if kill(pid, 0) != 0, errno == ESRCH {
            queue.async { [weak self] in self?.serviceExited(pid: pid) }
        }
    }

    private func serviceExited(pid: Int32) {
        lock.lock()
        guard watchedPID == pid, let port = desiredPort else {
            lock.unlock()
            return
        }
        watchedPID = nil
        exitSource?.cancel()
        exitSource = nil
        // Nach einer Generationsübergabe endet die alte; dann lauscht schon die
        // neue — die wird beobachtet, kein Neustart.
        if let status = statusResolver(root), status.state == "serving", status.port == port {
            watch(pid: status.pid)
            lock.unlock()
            return
        }
        if let healthy = lastHealthyStart, Date().timeIntervalSince(healthy) > 60 { restartAttempt = 0 }
        let delay = restartDelays[min(restartAttempt, restartDelays.count - 1)]
        restartAttempt += 1
        lock.unlock()
        Logger.claudeGPTRouter.error("gpt_router_service_exited pid=\(pid) restartIn=\(delay)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillWanted = self.desiredPort == port && self.watchedPID == nil
            self.lock.unlock()
            guard stillWanted else { return }
            if case .failure(let error) = self.ensureRunning(port: port) {
                Logger.claudeGPTRouter.error(
                    "gpt_router_service_restart_failed \(error.localizedDescription, privacy: .public)"
                )
                self.serviceRestartFailed(port: port)
            }
        }
    }

    /// Nach gescheitertem Neustart erneut versuchen (mit wachsendem Abstand).
    private func serviceRestartFailed(port: Int) {
        lock.lock()
        let delay = restartDelays[min(restartAttempt, restartDelays.count - 1)]
        restartAttempt += 1
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillWanted = self.desiredPort == port && self.watchedPID == nil
            self.lock.unlock()
            guard stillWanted else { return }
            if case .failure = self.ensureRunning(port: port) {
                self.serviceRestartFailed(port: port)
            }
        }
    }

    // MARK: Beenden

    /// GPT-Backend aus oder echtes Beenden der App: Dienst auslaufen lassen,
    /// nicht neu starten.
    func stop() {
        lock.lock()
        desiredPort = nil
        watchedPID = nil
        exitSource?.cancel()
        exitSource = nil
        lock.unlock()
        ClaudeGPTRouterServiceClient.shutdown(root: root)
    }

    /// PID des beobachteten Dienstes (Tests, Diagnose).
    var currentPID: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return watchedPID
    }

    // MARK: Prozessstart

    /// Startet das eigene Programm im Modus `gpt-router`. `Process` nutzt
    /// posix_spawn mit close-on-exec als Standard — der Dienst erbt keine
    /// Deskriptoren der App (auch keine PTY-Master).
    static func spawnFromAppBinary(arguments: [String]) throws -> Int32 {
        guard let executable = Bundle.main.executableURL else {
            throw SupervisorError.spawnFailed("Programmpfad unbekannt")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = serviceEnvironment(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Der Handler hält das Objekt, bis das Kind endet und abgeholt ist.
        process.terminationHandler = { _ in }
        try process.run()
        return process.processIdentifier
    }

    /// Schmale Umgebung: nur, was Defaults, Pfade und die Test-Instanz brauchen.
    static func serviceEnvironment(_ environment: [String: String]) -> [String: String] {
        let kept = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", AppInstance.rootEnvironmentKey]
        return environment.filter { kept.contains($0.key) }
    }
}
