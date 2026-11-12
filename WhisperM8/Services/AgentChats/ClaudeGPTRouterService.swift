import Darwin
import Foundation

/// Laufzeit des Router-Dienstes `WhisperM8 gpt-router` (Plan
/// neustart-ohne-chatverlust.md, Paket 3).
///
/// Der Dienst hält den Mix-Router auf BSD-Sockets in einem eigenen Prozess,
/// damit ein Neustart der App keine laufende Antwort abreißt. Gesteuert wird
/// er über einen Unix-Socket (`<root>/router.sock`, Ordner 0700):
/// - `status` → PID, Build, Port, Generation, offene Verbindungen;
/// - `handover` → Generationsübergabe: anhalten, lauschenden Socket per
///   `SCM_RIGHTS` an die neue Generation, nach deren `ack` schließen und
///   auslaufen (laufende Antworten zu Ende bringen, dann beenden);
/// - `shutdown` → lauschenden Socket schließen (Port sofort frei), auslaufen.
///
/// Mehrfachstart: Der TCP-Port ist die Sperre — ein zweiter lauschender Socket
/// auf demselben Port scheitert an `bind`. Eine neue Generation bekommt den
/// Socket nur über `handover`.
final class ClaudeGPTRouterService {
    static let protocolVersion = 1
    static let socketName = "router.sock"

    struct Configuration {
        var root: URL
        var port: Int
        var build: String
        var takeOver: Bool
        /// Wie lange die alte Generation auf das `ack` der neuen wartet.
        var handoverAckTimeout: TimeInterval = 10
        /// Obergrenze fürs Auslaufen (Upstream-Frist 600 s plus Luft).
        var drainLimit: TimeInterval = 15 * 60
        var drainPollInterval: TimeInterval = 0.25
        /// Herkunft dieser Generation, im Handshake verglichen: Wurzel der
        /// Test-Instanz (leer im Normalbetrieb) und ob feste Test-Upstreams
        /// gelten (nur Debug). Eine Generation übergibt nur an eine mit
        /// gleicher Herkunft — sonst bekäme etwa ein Aufruf mit umgebogenem
        /// `WHISPERM8_INSTANCE_ROOT` oder ein gleich signierter Debug-Build mit
        /// fremden Upstreams den echten Socket.
        var instanceRoot: String = AppInstance.testRoot?.path ?? ""
        var testUpstreams = false
    }

    /// Reine Entscheidung — unit-getestet.
    static func handoverOriginMatches(_ request: [String: Any], configuration: Configuration) -> Bool {
        (request["instanceRoot"] as? String) == configuration.instanceRoot
            && (request["testUpstreams"] as? Bool) == configuration.testUpstreams
    }

    enum ServiceError: LocalizedError {
        case rootUnusable(String)
        case socketPathTooLong(String)
        case controlSocketFailed(Int32)
        case takeOverFailed(String)

        var errorDescription: String? {
            switch self {
            case .rootUnusable(let path): return "Ordner des Router-Dienstes ist nicht nutzbar: \(path)"
            case .socketPathTooLong(let path): return "Socket-Pfad zu lang: \(path)"
            case .controlSocketFailed(let code): return "Steuer-Socket fehlgeschlagen (errno \(code))."
            case .takeOverFailed(let reason): return "Übernahme gescheitert: \(reason)"
            }
        }
    }

    enum State: String {
        case serving
        case handingOver = "handing-over"
        case draining
    }

    let configuration: Configuration
    let router: ClaudeGPTMixRouter
    private let onExit: (Int32) -> Void
    private let stateQueue = DispatchQueue(label: "com.whisperm8.gpt-router.service.state")
    private let controlQueue = DispatchQueue(label: "com.whisperm8.gpt-router.service.control", attributes: .concurrent)
    private var controlFD: Int32 = -1
    private var controlSource: DispatchSourceRead?
    private var controlInode: ino_t = 0
    private var state: State = .serving
    private(set) var generation = 1
    private var didExit = false
    private let startedAt = Date()
    /// Programm dieses Prozesses, beim Start gelesen (nach `make dev` ist die
    /// Datei ersetzt, der Pfad bleibt derselbe).
    private let ownExecutablePath = ClaudeGPTRouterService.executablePath(of: getpid())

    /// Prüft die Gegenseite einer Übergabe (Standard: gleiche Code-Signatur).
    private let peerCheck: (Int32) -> Bool

    init(
        configuration: Configuration,
        router: ClaudeGPTMixRouter,
        peerCheck: @escaping (Int32) -> Bool = { ClaudeGPTRouterPeerCheck.isSameProgram($0) },
        onExit: @escaping (Int32) -> Void
    ) {
        self.configuration = configuration
        self.router = router
        self.peerCheck = peerCheck
        self.onExit = onExit
    }

    static func socketURL(root: URL) -> URL {
        root.appendingPathComponent(socketName)
    }

    var socketPath: String { Self.socketURL(root: configuration.root).path }

    var currentState: State { stateQueue.sync { state } }

    // MARK: Start

    func start() -> Result<Void, Error> {
        guard AgentControlServer.prepareOwnedDirectory(at: configuration.root) else {
            return .failure(ServiceError.rootUnusable(configuration.root.path))
        }
        guard ChatsControlProtocol.socketPathFits(Self.socketURL(root: configuration.root)) else {
            return .failure(ServiceError.socketPathTooLong(socketPath))
        }
        // Eigene Signatur-Anforderung JETZT lesen, solange die Programmdatei
        // noch die ist, aus der dieser Prozess läuft. Bei der ersten Übergabe
        // hätte `make dev` oder brew sie schon ersetzt.
        _ = ClaudeGPTRouterPeerCheck.ownRequirement
        if configuration.takeOver {
            // Bis zur Freigabe der alten Generation nicht „serving“ melden —
            // die Aufsicht hielte die Übernahme sonst zu früh für gelungen.
            stateQueue.sync { state = .handingOver }
            let result = takeOver()
            if case .success = result { stateQueue.sync { state = .serving } }
            return result
        }
        if case .failure(let error) = router.start(port: configuration.port) {
            return .failure(error)
        }
        do {
            try bindControlSocket(replacingLiveSocket: false)
        } catch {
            router.stop()
            return .failure(error)
        }
        log("started pid=\(getpid()) port=\(router.listeningPort ?? -1) build=\(configuration.build)")
        return .success(())
    }

    /// Neue Generation: lauschenden Socket von der laufenden holen.
    private func takeOver() -> Result<Void, Error> {
        let fd: Int32
        do {
            fd = try ClaudeGPTRouterWire.connect(path: socketPath, timeout: configuration.handoverAckTimeout + 5)
        } catch {
            return .failure(ServiceError.takeOverFailed("keine laufende Generation (\(error))"))
        }
        defer { close(fd) }
        do {
            try ClaudeGPTRouterWire.send(fd, [
                "op": "handover",
                "protocol": Self.protocolVersion,
                "build": configuration.build,
                "pid": Int(getpid()),
                "instanceRoot": configuration.instanceRoot,
                "testUpstreams": configuration.testUpstreams,
            ])
            let reply = try ClaudeGPTRouterWire.receive(fd)
            guard reply.message["ok"] as? Bool == true, let listening = reply.descriptor else {
                reply.descriptor.map { _ = close($0) }
                let reason = reply.message["error"] as? String ?? "keine Freigabe"
                return .failure(ServiceError.takeOverFailed(reason))
            }
            if let previous = reply.message["generation"] as? Int { generation = previous + 1 }
            if case .failure(let error) = router.adoptListeningSocket(listening, requestedPort: configuration.port) {
                // Kein ack: die alte Generation nimmt nach ihrer Frist wieder an.
                return .failure(ServiceError.takeOverFailed(error.localizedDescription))
            }
            // Erst den eigenen Steuer-Socket aufbauen, dann bestätigen — so ist
            // der Pfad nie länger als nötig ohne Generation dahinter.
            try bindControlSocket(replacingLiveSocket: true)
            let released: Bool
            do {
                try ClaudeGPTRouterWire.send(fd, ["op": "ack"])
                released = (try ClaudeGPTRouterWire.receive(fd)).message["op"] as? String == "released"
            } catch {
                released = false
            }
            guard released else {
                // Spätes ACK: Die alte Generation hat ihre Frist verstrichen
                // lassen und nimmt wieder an. Zwei Generationen auf einem Socket
                // darf es nicht geben — diese gibt auf.
                abandonTakeOver()
                return .failure(ServiceError.takeOverFailed("keine Freigabe nach ack"))
            }
        } catch {
            if router.listeningSocketDescriptor != nil { abandonTakeOver() }
            return .failure(ServiceError.takeOverFailed("\(error)"))
        }
        log("took_over pid=\(getpid()) port=\(router.listeningPort ?? -1) generation=\(generation) build=\(configuration.build)")
        return .success(())
    }

    /// Übernahme gescheitert, nachdem der Socket schon hier lag: Lauscher und
    /// Steuer-Socket schließen (den Pfad nur, wenn er noch uns gehört) und
    /// bereits angenommene Anfragen zu Ende bringen.
    private func abandonTakeOver() {
        log("take_over_abandoned")
        router.closeListenerKeepingConnections()
        closeControlSocket(unlinkPath: true)
        let deadline = Date().addingTimeInterval(configuration.drainLimit)
        while router.activeConnectionCount > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: configuration.drainPollInterval)
        }
        router.stop()
    }

    // MARK: Steuer-Socket

    private func bindControlSocket(replacingLiveSocket: Bool) throws {
        let path = socketPath
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, existing.st_uid == getuid() else {
                throw ServiceError.rootUnusable(path)
            }
            // Ein lebender Socket gehört einer anderen Generation; nur die
            // Übernahme darf ihn ersetzen (die alte hält ihren Deskriptor).
            if !replacingLiveSocket, let probe = try? ClaudeGPTRouterWire.connect(path: path, timeout: 1) {
                close(probe)
                throw ServiceError.controlSocketFailed(EADDRINUSE)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceError.controlSocketFailed(errno) }
        AgentControlServer.setCloseOnExec(fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                bytes.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: bytes.count) }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ServiceError.controlSocketFailed(code)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ServiceError.controlSocketFailed(code)
        }
        var info = stat()
        let inode: ino_t = stat(path, &info) == 0 ? info.st_ino : 0
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: controlQueue)
        source.setEventHandler { [weak self] in self?.acceptControlConnection(listenFD: fd) }
        source.setCancelHandler { close(fd) }
        stateQueue.sync {
            controlFD = fd
            controlInode = inode
            controlSource = source
        }
        source.resume()
    }

    /// Schließt den eigenen Steuer-Socket. `unlinkPath` nur, wenn der Pfad noch
    /// auf diesen Socket zeigt (nach einer Übernahme gehört er der neuen
    /// Generation).
    private func closeControlSocket(unlinkPath: Bool) {
        let (source, inode): (DispatchSourceRead?, ino_t) = stateQueue.sync {
            let current = (controlSource, controlInode)
            controlSource = nil
            controlFD = -1
            controlInode = 0
            return current
        }
        source?.cancel()
        guard unlinkPath, inode != 0 else { return }
        var current = stat()
        if stat(socketPath, &current) == 0, current.st_ino == inode {
            unlink(socketPath)
        }
    }

    private func acceptControlConnection(listenFD: Int32) {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        AgentControlServer.setCloseOnExec(client)
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(client, &euid, &egid) == 0, euid == getuid() else {
            close(client)
            return
        }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        ClaudeGPTRouterWire.setTimeout(client, 5)
        controlQueue.async { [weak self] in
            defer { close(client) }
            guard let self, let request = try? ClaudeGPTRouterWire.receive(client) else { return }
            request.descriptor.map { _ = close($0) }
            self.handle(request.message, on: client)
        }
    }

    private func handle(_ request: [String: Any], on client: Int32) {
        switch request["op"] as? String {
        case "status":
            try? ClaudeGPTRouterWire.send(client, statusPayload())
        case "handover":
            handleHandover(request, on: client)
        case "shutdown":
            try? ClaudeGPTRouterWire.send(client, ["ok": true])
            shutdown(reason: "requested")
        default:
            try? ClaudeGPTRouterWire.send(client, ["ok": false, "error": "unknown op"])
        }
    }

    func statusPayload() -> [String: Any] {
        let current = stateQueue.sync { state }
        return [
            "ok": true,
            "protocol": Self.protocolVersion,
            "pid": Int(getpid()),
            "build": configuration.build,
            "port": router.listeningPort ?? -1,
            "generation": generation,
            "state": current.rawValue,
            "active": router.activeConnectionCount,
            "startedAt": startedAt.timeIntervalSince1970,
            "executable": ownExecutablePath ?? "",
        ]
    }

    // MARK: Generationsübergabe (alte Seite)

    private func handleHandover(_ request: [String: Any], on client: Int32) {
        guard (request["protocol"] as? Int) == Self.protocolVersion else {
            try? ClaudeGPTRouterWire.send(client, ["ok": false, "error": "protocol"])
            return
        }
        // Den lauschenden Socket bekommt nur dasselbe Programm (Code-Signatur,
        // bei jeder Nachricht neu geprüft). Sonst könnte jeder Prozess des
        // Nutzers den Router-Port übernehmen und die Anfragen der Chats samt
        // Zugangsdaten mitlesen.
        guard peerCheck(client) else {
            log("handover_refused_foreign_binary")
            try? ClaudeGPTRouterWire.send(client, ["ok": false, "error": "binary"])
            return
        }
        guard Self.handoverOriginMatches(request, configuration: configuration) else {
            log("handover_refused_foreign_origin")
            try? ClaudeGPTRouterWire.send(client, ["ok": false, "error": "origin"])
            return
        }
        let mayHandOver: Bool = stateQueue.sync {
            guard state == .serving else { return false }
            state = .handingOver
            return true
        }
        guard mayHandOver, let listening = router.listeningSocketDescriptor else {
            try? ClaudeGPTRouterWire.send(client, ["ok": false, "error": "busy"])
            return
        }
        let successorPID = request["pid"] as? Int ?? -1
        router.pauseAccepting()
        log("handover_begin successor=\(successorPID)")
        ClaudeGPTRouterWire.setTimeout(client, configuration.handoverAckTimeout)
        do {
            try ClaudeGPTRouterWire.send(client, [
                "ok": true,
                "op": "listener",
                "port": router.listeningPort ?? -1,
                "generation": generation,
            ], passing: listening)
            let ack = try ClaudeGPTRouterWire.receive(client)
            ack.descriptor.map { _ = close($0) }
            guard ack.message["op"] as? String == "ack", peerCheck(client) else {
                throw ClaudeGPTRouterWire.WireError.malformed
            }
        } catch {
            // Kein ack: Socket behalten und wieder annehmen. Der Steuer-Pfad
            // kann schon der gescheiterten Generation gehören — neu binden.
            log("handover_rolled_back successor=\(successorPID) error=\(error)")
            router.resumeAccepting()
            stateQueue.sync { state = .serving }
            closeControlSocket(unlinkPath: false)
            try? bindControlSocket(replacingLiveSocket: true)
            return
        }
        // ACK da: erst jetzt die eigene Kopie schließen.
        router.closeListenerKeepingConnections()
        closeControlSocket(unlinkPath: false)
        try? ClaudeGPTRouterWire.send(client, ["ok": true, "op": "released"])
        log("handover_done successor=\(successorPID) active=\(router.activeConnectionCount)")
        drain()
    }

    // MARK: Beenden

    /// Lauschenden Socket schließen (Port sofort frei), laufende Antworten zu
    /// Ende bringen, beenden.
    func shutdown(reason: String) {
        let shouldDrain: Bool = stateQueue.sync {
            guard state != .draining else { return false }
            state = .draining
            return true
        }
        guard shouldDrain else { return }
        log("shutdown reason=\(reason) active=\(router.activeConnectionCount)")
        router.closeListenerKeepingConnections()
        closeControlSocket(unlinkPath: true)
        drainLoop(deadline: Date().addingTimeInterval(configuration.drainLimit))
    }

    private func drain() {
        stateQueue.sync { state = .draining }
        drainLoop(deadline: Date().addingTimeInterval(configuration.drainLimit))
    }

    private func drainLoop(deadline: Date) {
        if router.activeConnectionCount == 0 || Date() >= deadline {
            let remaining = router.activeConnectionCount
            if remaining > 0 { log("drain_limit_reached active=\(remaining)") }
            router.stop()
            exit(code: 0)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + configuration.drainPollInterval) { [weak self] in
            self?.drainLoop(deadline: deadline)
        }
    }

    private func exit(code: Int32) {
        let first: Bool = stateQueue.sync {
            guard !didExit else { return false }
            didExit = true
            return true
        }
        guard first else { return }
        log("exit code=\(code)")
        onExit(code)
    }

    // MARK: Programmpfad (für den Status)

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Log

    private func log(_ message: String) {
        Logger.claudeGPTRouter.notice("gpt_router_service \(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(getpid())] \(message)\n"
        let url = configuration.root.appendingPathComponent("gpt-router.log")
        Self.appendLog(line, to: url)
    }

    /// Hängt an die Logdatei an; über 1 MB wird sie einmal gekürzt.
    static func appendLog(_ line: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size > 1_000_000 {
            ftruncate(fd, 0)
        }
        let data = Data(line.utf8)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
