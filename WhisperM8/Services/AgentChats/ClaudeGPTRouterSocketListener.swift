import Darwin
import Foundation

/// Lauschender TCP-Socket des Router-Dienstes auf 127.0.0.1 (BSD-Sockets,
/// Vorlage `AgentControlServer`).
///
/// Anders als `NWListener` lässt er sich anhalten, ohne zu schließen: Neue
/// Verbindungen warten dann in der Warteschlange des Kernels. Das braucht die
/// Generationsübergabe — die alte Generation hält an, reicht den Deskriptor per
/// `SCM_RIGHTS` weiter und schließt ihn erst nach dem `ACK` der neuen.
final class ClaudeGPTRouterSocketListener {
    enum ListenerError: LocalizedError, Equatable {
        case invalidPort(Int)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case notAListeningSocket

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port): return "Ungültiger Router-Port: \(port)."
            case .socketFailed(let code): return "socket() fehlgeschlagen (errno \(code))."
            case .bindFailed(let code):
                return code == EADDRINUSE
                    ? "Der Router-Port ist belegt."
                    : "bind() fehlgeschlagen (errno \(code))."
            case .listenFailed(let code): return "listen() fehlgeschlagen (errno \(code))."
            case .notAListeningSocket: return "Der übergebene Deskriptor ist kein lauschender TCP-Socket."
            }
        }
    }

    static let backlog: Int32 = 128

    let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let onAccept: (Int32) -> Void
    private var source: DispatchSourceRead?
    private var isSuspended = true
    private var isClosed = false
    private let lock = NSLock()

    /// Übernimmt `fileDescriptor` (gehört danach diesem Objekt).
    init(fileDescriptor: Int32, queue: DispatchQueue, onAccept: @escaping (Int32) -> Void) {
        self.fileDescriptor = fileDescriptor
        self.queue = queue
        self.onAccept = onAccept
        AgentControlServer.setCloseOnExec(fileDescriptor)
        // Auch für übernommene Sockets älterer Generationen.
        Self.setNoSigPipe(fileDescriptor)
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fileDescriptor) }
        self.source = source
    }

    deinit {
        close()
    }

    /// Bindet einen neuen Socket auf 127.0.0.1:`port` (0 = beliebig).
    static func bind(port: Int) throws -> Int32 {
        guard (0...65_535).contains(port) else { throw ListenerError.invalidPort(port) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketFailed(errno) }
        AgentControlServer.setCloseOnExec(fd)
        var reuse: Int32 = 1
        // Wie NWListener: Verbindungen einer auslaufenden Generation (oder
        // TIME_WAIT-Reste) auf demselben Port blockieren das Binden nicht.
        // Ein zweiter LAUSCHENDER Socket bleibt ausgeschlossen (kein SO_REUSEPORT).
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setNoSigPipe(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ListenerError.bindFailed(code)
        }
        guard listen(fd, backlog) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ListenerError.listenFailed(code)
        }
        return fd
    }

    /// `SO_NOSIGPIPE` am LAUSCHENDEN Socket setzen: Angenommene Verbindungen
    /// erben die Option. Nachträglich am angenommenen Socket gesetzt, scheitert
    /// der Aufruf mit EINVAL, wenn die Gegenseite schon geschlossen hat — die
    /// nächste Antwort löste dann SIGPIPE aus (gemessen 13.11.2026, Unix und TCP).
    static func setNoSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Port eines gebundenen Sockets oder `nil`, wenn `fd` kein lauschender
    /// IPv4-TCP-Socket ist (Prüfung bei der Übernahme).
    static func listeningPort(of fd: Int32) -> Int? {
        // macOS kennt SO_ACCEPTCONN per getsockopt nicht (ENOPROTOOPT). Ein
        // lauschender Socket ist ein Stream-Socket ohne Gegenseite.
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == 0, type == SOCK_STREAM else {
            return nil
        }
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let hasPeer = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &peerLength) == 0 }
        }
        guard !hasPeer, errno == ENOTCONN else { return nil }
        var address = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addressLength) == 0
            }
        }
        guard ok, address.sin_family == sa_family_t(AF_INET) else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    var port: Int? { Self.listeningPort(of: fileDescriptor) }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, isSuspended, let source else { return }
        isSuspended = false
        source.resume()
    }

    /// Nimmt nichts Neues mehr an; der Socket bleibt offen, neue Verbindungen
    /// warten in der Warteschlange des Kernels.
    func pause() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !isSuspended, let source else { return }
        isSuspended = true
        source.suspend()
    }

    /// Schließt den lauschenden Socket (über den Cancel-Handler). Angenommene
    /// Verbindungen bleiben davon unberührt.
    func close() {
        lock.lock()
        guard !isClosed, let source else {
            lock.unlock()
            return
        }
        isClosed = true
        let wasSuspended = isSuspended
        isSuspended = false
        self.source = nil
        lock.unlock()
        source.cancel()
        // Der Cancel-Handler einer angehaltenen Quelle liefe nie.
        if wasSuspended { source.resume() }
    }

    private func acceptPending() {
        // Alles abholen, was gerade wartet; nicht blockierend.
        while true {
            let client = Darwin.accept(fileDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            onAccept(client)
        }
    }
}
