import Foundation
import Darwin

// MARK: - Control-Socket-Server (App-Seite)

/// BSD-Unix-Domain-Socket-Server, über den die `whisperm8 chats`-CLI mutierende
/// und live-abfragende Befehle an die laufende App schickt. Bewusst kein
/// `NWListener` (GPT-Review): UDS + `getpeereid` gibt Peer-Credential-Prüfung,
/// Datei-Permission-basierte Zugriffskontrolle und kein Port-Management.
///
/// Sicherheitsmodell (Härtung aus dem Review):
/// - Ordner `control/` mit 0700, Socket mit 0600 nach bind.
/// - `sun_path`-Limit (104 B) geprüft, Fallback nach `/private/tmp/whisperm8-<uid>/`.
/// - `flock` auf `control.lock` gegen Doppel-Start; Stale-Socket nur nach
///   fehlgeschlagenem Connect + lstat-Owner-Check entfernt.
/// - `getpeereid` pro Verbindung: Peer-EUID muss App-EUID sein.
/// - Accept/Read/Decode off-main; nur validierte Commands hoppen auf MainActor.
final class AgentControlServer: @unchecked Sendable {
    static let shared = AgentControlServer()

    /// Kill-Switch analog zum Event-Watcher:
    /// `defaults write com.whisperm8.app agentControlServerEnabled -bool NO`.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "agentControlServerEnabled") as? Bool ?? true
    }

    /// Serielle Queue NUR für accept + Lifecycle (bind/stop). Verbindungen
    /// werden bewusst auf einer eigenen concurrent Queue bedient, sonst würde
    /// ein blockierender Handler (semaphore.wait) den accept-Loop stallen.
    private let queue = DispatchQueue(label: "com.whisperm8.control-server", qos: .utility)
    /// Bedient Verbindungen nebenläufig; die Semaphore deckelt auf 4
    /// gleichzeitige (Schutz gegen Verbindungs-Flut).
    private let connectionQueue = DispatchQueue(label: "com.whisperm8.control-conn", qos: .utility, attributes: .concurrent)
    private let connectionSlots = DispatchSemaphore(value: 4)
    private var listenFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketURL: URL?
    private var boundStat: stat?
    private var started = false

    /// Handler, der validierte Requests auf dem MainActor ausführt. Wird beim
    /// Start injiziert (der Handler kennt Registry, Store etc.).
    private var handler: AgentControlRequestHandling?

    private init() {}

    // MARK: Lifecycle

    func start(handler: AgentControlRequestHandling) {
        guard Self.isEnabled else {
            Logger.agentStore.notice("control_server_disabled_by_default")
            return
        }
        queue.async { [weak self] in
            self?.startLocked(handler: handler)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func startLocked(handler: AgentControlRequestHandling) {
        guard !started else { return }
        self.handler = handler

        let directory = ChatsControlProtocol.controlDirectory()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // Falls der Ordner schon existierte: Permissions hart durchsetzen.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            Logger.agentStore.error("control_server_dir_failed \(error.localizedDescription, privacy: .public)")
            return
        }

        // Single-Instance-Lock: exklusiv, nicht-blockierend. FAIL-CLOSED —
        // ohne Lock (open scheitert ODER flock hält ein anderer) startet der
        // Server NICHT (GPT-Review D: sonst könnte eine zweite Instanz denselben
        // Socket überschreiben). Alle Fehlerpfade ab hier räumen den lockFD
        // über `cleanupPartialStart()` auf, damit ein erneuter `start` keinen
        // FD leakt.
        lockFD = open(ChatsControlProtocol.lockFileURL().path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else {
            Logger.agentStore.error("control_server_lock_open_failed errno=\(errno)")
            return
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Logger.agentStore.notice("control_server_lock_held_by_other_instance")
            cleanupPartialStart()
            return
        }

        // Socket-Pfad wählen (sun_path-Limit).
        var chosen = ChatsControlProtocol.defaultSocketURL()
        if !ChatsControlProtocol.socketPathFits(chosen) {
            let fallbackDir = ChatsControlProtocol.fallbackSocketURL().deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: fallbackDir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallbackDir.path)
            chosen = ChatsControlProtocol.fallbackSocketURL()
            guard ChatsControlProtocol.socketPathFits(chosen) else {
                Logger.agentStore.error("control_server_socket_path_too_long")
                cleanupPartialStart()
                return
            }
        }
        socketURL = chosen

        guard bindListen(at: chosen) else {
            cleanupPartialStart()
            return
        }

        // Discovery-Datei mit dem realen Pfad publizieren.
        try? chosen.path.write(to: ChatsControlProtocol.discoveryFileURL(), atomically: true, encoding: .utf8)

        started = true
        Logger.agentStore.notice("control_server_started path=\(chosen.path, privacy: .public)")
        armAccept()
    }

    private func bindListen(at url: URL) -> Bool {
        // Bestehenden Socket sicher entfernen (Stale-Handling).
        reclaimStaleSocketIfSafe(at: url)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Logger.agentStore.error("control_server_socket_failed errno=\(errno)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Logger.agentStore.error("control_server_path_overflow")
            close(fd); return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    destPtr.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else {
            Logger.agentStore.error("control_server_bind_failed errno=\(errno)")
            close(fd); return false
        }

        // Socket auf 0600 — nur der Owner darf connecten (zusätzlich zum
        // 0700-Elternordner).
        chmod(url.path, 0o600)
        // dev+ino des frisch gebundenen Sockets merken — beim Shutdown nur
        // unlinken, wenn es noch DIESER Socket ist.
        var st = stat()
        if stat(url.path, &st) == 0 { boundStat = st }

        guard listen(fd, 8) == 0 else {
            Logger.agentStore.error("control_server_listen_failed errno=\(errno)")
            close(fd); return false
        }

        listenFD = fd
        return true
    }

    /// Entfernt einen bestehenden Socket NUR, wenn er tot ist und uns gehört.
    private func reclaimStaleSocketIfSafe(at url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }        // existiert nicht → nichts zu tun
        // Muss ein Socket sein und uns gehören.
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else {
            Logger.agentStore.error("control_server_refuse_unlink_foreign_path")
            return
        }
        // Lebt noch jemand? connect-Versuch.
        if canConnect(to: url) {
            // Sollte durch den flock oben eigentlich nicht passieren.
            Logger.agentStore.notice("control_server_socket_alive_skipping_unlink")
            return
        }
        unlink(url.path)
    }

    private func canConnect(to url: URL) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    destPtr.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }

    private func armAccept() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.resume()
        acceptSource = source
    }

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Peer-Credential-Prüfung: Cross-User-Zugriff hart ausschließen.
        var euid: uid_t = 0
        var egid: gid_t = 0
        if getpeereid(clientFD, &euid, &egid) != 0 || euid != getuid() {
            Logger.agentStore.error("control_server_peer_uid_mismatch")
            close(clientFD)
            return
        }

        // Verbindung auf der CONCURRENT Queue bedienen — der serielle
        // accept-Loop (queue) bleibt frei, auch wenn ein Handler bis zu 10 s
        // auf seiner Semaphore wartet. Connection-Slots deckeln die
        // Nebenläufigkeit; ist keiner frei, wird der Client sofort geschlossen
        // (besser als unbegrenzt Threads zu binden).
        guard connectionSlots.wait(timeout: .now()) == .success else {
            Logger.agentStore.notice("control_server_connection_limit_reached")
            close(clientFD)
            return
        }
        connectionQueue.async { [weak self] in
            defer { self?.connectionSlots.signal() }
            self?.serveConnection(clientFD)
        }
    }

    private func serveConnection(_ fd: Int32) {
        defer { close(fd) }
        // KRITISCH (GPT-Review): SO_NOSIGPIPE verhindert, dass ein `write` auf
        // einen vom Client (nach Timeout) bereits geschlossenen Socket ein
        // SIGPIPE auslöst — das würde sonst die GESAMTE App beenden. Realer
        // Pfad, weil der Client nach seinem Read-Timeout schließt, während der
        // Server noch antwortet.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Read-Timeout gegen hängende Clients.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let line = readLine(fd) else { return }
        guard line.count <= ChatsControlCodec.maxLineBytes else {
            respond(fd, .failure(requestID: "", code: .invalid, message: "Request zu groß"))
            return
        }

        let request: ChatsControlRequest
        do {
            request = try ChatsControlCodec.decode(ChatsControlRequest.self, from: line)
        } catch {
            respond(fd, .failure(requestID: "", code: .invalid, message: "Kaputtes Request-JSON"))
            return
        }

        guard request.protocolVersion == ChatsControlProtocol.version else {
            respond(fd, .failure(requestID: request.requestID, code: .invalid,
                                 message: "Protokoll-Version \(request.protocolVersion) ≠ App \(ChatsControlProtocol.version) — whisperm8-Symlink/App-Version prüfen"))
            return
        }

        guard let handler = self.handler else {
            respond(fd, .failure(requestID: request.requestID, code: .internalError, message: "Kein Handler"))
            return
        }

        // Genau eine Response pro Request. Handler entscheidet selbst, was auf
        // den MainActor hoppt. Die Box ist NSLock-geschützt (GPT-Review):
        // beim Handler-Timeout schreibt der Task sonst nebenläufig in die
        // Variable, während dieser Thread sie liest — Data-Race. Nach einem
        // Timeout wird das späte Ergebnis bewusst verworfen; die Mutation kann
        // trotzdem noch passieren (nicht abbrechbar) — deshalb sagt die
        // Timeout-Antwort explizit „Zustand unklar", statt Nicht-Ausführung zu
        // behaupten.
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let result = await handler.handle(request)
            box.set(result)
            semaphore.signal()
        }
        // Handler-Timeout großzügig (Mutationen sind schnell; nur Schutz gegen
        // Deadlock).
        let outcome = semaphore.wait(timeout: .now() + 10)
        if outcome == .success, let response = box.get() {
            respond(fd, response)
        } else {
            respond(fd, .failure(
                requestID: request.requestID, code: .internalError,
                message: "Handler-Timeout — Zustand unklar, ggf. `chats audit` prüfen"))
        }
    }

    /// Lock-geschützte Übergabe des Handler-Ergebnisses zwischen Task und
    /// Connection-Thread.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response: ChatsControlResponse?

        func set(_ value: ChatsControlResponse) {
            lock.lock(); response = value; lock.unlock()
        }

        func get() -> ChatsControlResponse? {
            lock.lock(); defer { lock.unlock() }
            return response
        }
    }

    private func readLine(_ fd: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while buffer.count <= ChatsControlCodec.maxLineBytes {
            let n = read(fd, &byte, 1)
            if n <= 0 { return buffer.isEmpty ? nil : buffer }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
        }
        return buffer
    }

    private func respond(_ fd: Int32, _ response: ChatsControlResponse) {
        guard let data = try? ChatsControlCodec.encodeLine(response) else { return }
        // Robuster Write: Partial Writes + EINTR behandeln (ein einzelnes
        // `write` ignoriert beides). Ein Fehler (Client weg) ist unkritisch —
        // SO_NOSIGPIPE verhindert das App-tötende Signal, der Loop bricht
        // einfach ab.
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n == -1 && errno == EINTR {
                    continue
                } else {
                    return  // EPIPE/EAGAIN/… — Client ist weg, Abbruch
                }
            }
        }
    }

    /// Räumt einen fehlgeschlagenen Start auf (lockFD, listenFD, Socket-Datei) —
    /// verhindert FD-Leaks, wenn ein erneuter `start` die Properties überschreibt.
    /// Unlinkt auch einen bereits gebundenen Socket (bind ok, listen scheiterte),
    /// inode-geprüft wie beim Shutdown (GPT-Review).
    private func cleanupPartialStart() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if let url = socketURL, let bound = boundStat {
            var current = stat()
            if stat(url.path, &current) == 0,
               current.st_dev == bound.st_dev, current.st_ino == bound.st_ino {
                unlink(url.path)
            }
        }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        socketURL = nil
        boundStat = nil
    }

    private func stopLocked() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        // Nur unlinken, wenn es noch UNSER Socket ist (dev+ino-Vergleich).
        if let url = socketURL, let bound = boundStat {
            var current = stat()
            if stat(url.path, &current) == 0,
               current.st_dev == bound.st_dev, current.st_ino == bound.st_ino {
                unlink(url.path)
            }
        }
        try? FileManager.default.removeItem(at: ChatsControlProtocol.discoveryFileURL())
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        started = false
    }
}

// MARK: - Handler-Protokoll

/// Trennt die Socket-Mechanik (dieser File) von der App-Logik
/// (`AgentControlRequestHandler`) — testbar mit einem Fake-Handler.
protocol AgentControlRequestHandling: Sendable {
    func handle(_ request: ChatsControlRequest) async -> ChatsControlResponse
}
