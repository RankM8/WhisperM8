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
    /// Verbundene Apps (`attach`).
    var attached: Int
    /// Programmpfad des Dienstes (leer bei älteren Generationen).
    var executable: String

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
        attached = payload["attached"] as? Int ?? 0
        executable = payload["executable"] as? String ?? ""
    }
}

/// Steuerbefehle an einen laufenden Router-Dienst.
enum ClaudeGPTRouterServiceClient {
    static func status(root: URL, timeout: TimeInterval = 1) -> ClaudeGPTRouterServiceStatus? {
        request(root: root, ["op": "status"], timeout: timeout).flatMap(ClaudeGPTRouterServiceStatus.init)
    }

    /// Ist der Steuer-Socket tot (Datei fehlt, niemand lauscht)? Ein Timeout
    /// zählt NICHT — dann lebt der Dienst, ist nur langsam. Nur in diesem Fall
    /// darf der Reaper einen Dienst vom Port räumen.
    static func controlSocketIsDead(root: URL) -> Bool {
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            let fd = try ClaudeGPTRouterWire.connect(path: path, timeout: 1)
            close(fd)
            return false
        } catch ClaudeGPTRouterWire.WireError.connectFailed(let code) {
            return code == ECONNREFUSED || code == ENOENT
        } catch {
            return false
        }
    }

    /// Lauscher schließen (Port sofort frei), auslaufen lassen.
    @discardableResult
    static func shutdown(root: URL, timeout: TimeInterval = 2) -> Bool {
        request(root: root, ["op": "shutdown"], timeout: timeout)?["ok"] as? Bool == true
    }

    /// Wie `shutdown`, aber ohne auf die Antwort zu warten — für den Main
    /// Thread (Stop-Knopf, `willTerminate`). Die Nachricht liegt nach dem
    /// Schreiben im Socket; der Dienst liest sie auch nach unserem `close`.
    static func requestShutdownWithoutWaiting(root: URL) {
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        guard FileManager.default.fileExists(atPath: path),
              let fd = try? ClaudeGPTRouterWire.connect(path: path, timeout: 0.2) else { return }
        defer { close(fd) }
        try? ClaudeGPTRouterWire.send(fd, ["op": "shutdown"])
    }

    /// Dauerverbindung „App lebt“ für die Leerlauf-Frist des Dienstes. Der
    /// Kernel schließt sie, wenn die App endet. `nil` = kein Dienst erreichbar.
    static func attach(root: URL, timeout: TimeInterval = 1) -> Int32? {
        let path = ClaudeGPTRouterService.socketURL(root: root).path
        guard FileManager.default.fileExists(atPath: path),
              let fd = try? ClaudeGPTRouterWire.connect(path: path, timeout: timeout) else { return nil }
        guard (try? ClaudeGPTRouterWire.send(fd, ["op": "attach"])) != nil,
              let reply = try? ClaudeGPTRouterWire.receive(fd),
              reply.message["op"] as? String == "attached" else {
            close(fd)
            return nil
        }
        reply.descriptor.map { _ = close($0) }
        return fd
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
    /// `attach`-Verbindung zur beobachteten Generation (Leerlauf-Frist).
    private var attachFD: Int32 = -1
    /// `stop()` angefordert: kein Neustart mehr. Eigener kleiner Lock, damit
    /// `stop()` nie auf ein laufendes `ensureRunning` wartet.
    private let stopLock = NSLock()
    private var stopRequestedStorage = false

    private var isStopRequested: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopRequestedStorage
    }

    private func setStopRequested(_ value: Bool) {
        stopLock.lock()
        stopRequestedStorage = value
        stopLock.unlock()
    }
    private let ownExecutable: String
    private let portReaper: (Int) -> Bool
    private let deadControlSocket: (URL) -> Bool

    init(
        root: URL = ClaudeGPTRouterServiceSupervisor.defaultRoot(),
        build: String = ClaudeGPTRouterBuild.current,
        spawner: @escaping Spawner = ClaudeGPTRouterServiceSupervisor.spawnFromAppBinary,
        statusResolver: @escaping (URL) -> ClaudeGPTRouterServiceStatus? = { ClaudeGPTRouterServiceClient.status(root: $0) },
        readyTimeout: TimeInterval = 10,
        restartDelays: [TimeInterval] = [0.5, 1, 2, 5, 10, 30],
        ownExecutable: String = ClaudeGPTRouterService.executablePath(of: getpid()) ?? "",
        portReaper: @escaping (Int) -> Bool = { ClaudeGPTRouterServiceReaper.freePortIfHeldByOrphanedService(port: $0) },
        deadControlSocket: @escaping (URL) -> Bool = { ClaudeGPTRouterServiceClient.controlSocketIsDead(root: $0) }
    ) {
        self.root = root
        self.build = build
        self.spawner = spawner
        self.statusResolver = statusResolver
        self.readyTimeout = readyTimeout
        self.restartDelays = restartDelays
        self.ownExecutable = ownExecutable
        self.portReaper = portReaper
        self.deadControlSocket = deadControlSocket
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
        setStopRequested(false)
        desiredPort = port
        if let status = settledStatus(), status.state == "serving" {
            switch Self.takeOverPlan(status: status, port: port, ownExecutable: ownExecutable, build: build) {
            case .keepRunning:
                watch(pid: status.pid)
                return .success(())
            case .takeOver:
                // Älteres Programm am selben Ort: neue Generation übernimmt den
                // lauschenden Socket, die alte läuft aus.
                switch launch(port: port, takeOver: true) {
                case .success:
                    return .success(())
                case .failure(let error):
                    // Abgelehnt (andere Signatur, andere Herkunft) oder zu
                    // spät: Die alte Generation nimmt wieder an. Statt sie für
                    // immer zu behalten und bei jedem Chat-Start erneut zu
                    // scheitern: geordnet ersetzen (Port sofort frei, laufende
                    // Antworten laufen in ihr aus; Claude wiederholt abgelehnte
                    // Verbindungen in der kurzen Lücke).
                    Logger.claudeGPTRouter.error(
                        "gpt_router_service_takeover_failed_replacing \(error.localizedDescription, privacy: .public)"
                    )
                    ClaudeGPTRouterServiceClient.shutdown(root: root)
                    waitUntilPortFree(port)
                }
            case .replace:
                // Anderer Port oder anderer Programmort: alte Generation gibt
                // den Port sofort frei und läuft aus, die neue startet frisch.
                ClaudeGPTRouterServiceClient.shutdown(root: root)
                waitUntilPortFree(port)
            }
        }
        if !ClaudeCodeProxyManager.isPortFree(port), deadControlSocket(root) {
            // Ein Dienst ohne erreichbaren Steuer-Socket hielte den Port sonst
            // bis zum Neustart des Macs.
            _ = portReaper(port)
        }
        return launch(port: port, takeOver: false)
    }

    enum TakeOverPlan: Equatable {
        case keepRunning
        case takeOver
        case replace
    }

    /// Reine Entscheidung — unit-getestet.
    static func takeOverPlan(
        status: ClaudeGPTRouterServiceStatus,
        port: Int,
        ownExecutable: String,
        build: String
    ) -> TakeOverPlan {
        guard status.port == port else { return .replace }
        if status.build == build { return .keepRunning }
        // Anderer Programmort: frisch statt Übernahme — die neue Generation
        // läuft aus diesem Ort, der Dienst soll zum Programm der App passen.
        if !status.executable.isEmpty, !ownExecutable.isEmpty, status.executable != ownExecutable {
            return .replace
        }
        return .takeOver
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
        guard watchedPID != pid else {
            if attachFD < 0 { attachToService() }
            return
        }
        exitSource?.cancel()
        watchedPID = pid
        attachToService()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.serviceExited(pid: pid) }
        exitSource = source
        source.resume()
        // Schon tot, bevor die Quelle stand?
        if kill(pid, 0) != 0, errno == ESRCH {
            queue.async { [weak self] in self?.serviceExited(pid: pid) }
        }
    }

    /// Nur unter `lock`. Hängt an der Generation, die gerade den Steuer-Socket
    /// hält (das ist die beobachtete).
    private func attachToService() {
        closeAttachment()
        attachFD = ClaudeGPTRouterServiceClient.attach(root: root) ?? -1
    }

    private func closeAttachment() {
        if attachFD >= 0 { close(attachFD) }
        attachFD = -1
    }

    private func serviceExited(pid: Int32) {
        lock.lock()
        guard watchedPID == pid, let port = desiredPort, !isStopRequested else {
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
            let stillWanted = self.desiredPort == port && self.watchedPID == nil && !self.isStopRequested
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
            let stillWanted = self.desiredPort == port && self.watchedPID == nil && !self.isStopRequested
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
    ///
    /// Läuft auf dem Main Thread (Stop-Knopf, `willTerminate`): wartet weder
    /// auf die Antwort des Dienstes noch auf ein laufendes `ensureRunning`.
    /// Das Aufräumen folgt im Hintergrund; hat ein gleichzeitiges
    /// `ensureRunning` noch einen Dienst gestartet, bekommt der dort ebenfalls
    /// sein `shutdown` (sonst endet er spätestens nach der Leerlauf-Frist).
    func stop() {
        setStopRequested(true)
        ClaudeGPTRouterServiceClient.requestShutdownWithoutWaiting(root: root)
        queue.async { [weak self] in self?.finishStop() }
    }

    private func finishStop() {
        lock.lock()
        defer { lock.unlock() }
        guard isStopRequested else { return }
        desiredPort = nil
        watchedPID = nil
        exitSource?.cancel()
        exitSource = nil
        closeAttachment()
        if statusResolver(root) != nil {
            ClaudeGPTRouterServiceClient.shutdown(root: root)
        }
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
