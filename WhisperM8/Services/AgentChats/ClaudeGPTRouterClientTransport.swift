import Darwin
import Foundation
import Network

/// Ein- und Ausgabe einer Client-Verbindung des Mix-Routers.
///
/// Die HTTP-Logik (`ClaudeGPTMixRouter.ClientConnection`) kennt nur diese
/// Schnittstelle. Der Router in der App benutzt weiter `NWConnection`; der
/// Router-Dienst lauscht auf BSD-Sockets, weil Network.framework keinen
/// vorhandenen Socket übernehmen kann (Generationsübergabe, Plan
/// neustart-ohne-chatverlust.md, Paket 3). Alle Rückrufe laufen auf der Queue
/// aus `start(queue:onClosed:)`.
protocol ClaudeGPTRouterClientTransport: AnyObject {
    /// Startet die Verbindung. `onClosed` meldet einen Abbruch der Gegenseite
    /// oder ein `cancel()` (wie `.failed`/`.cancelled` bei `NWConnection`).
    func start(queue: DispatchQueue, onClosed: @escaping () -> Void)
    /// Liest bis zu `maximumLength` Bytes. `isComplete` = Gegenseite hat
    /// geschlossen, `failed` = Lesefehler.
    func receive(
        maximumLength: Int,
        completion: @escaping (_ data: Data?, _ isComplete: Bool, _ failed: Bool) -> Void
    )
    /// Schreibt `data` vollständig; `failed` = Schreibfehler.
    func send(_ data: Data, completion: @escaping (_ failed: Bool) -> Void)
    func cancel()
}

/// Heutiger Weg in der App: genau die Aufrufe, die `ClientConnection` vorher
/// direkt an `NWConnection` gemacht hat.
final class ClaudeGPTRouterNWTransport: ClaudeGPTRouterClientTransport {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue, onClosed: @escaping () -> Void) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { onClosed() }
            if case .cancelled = state { onClosed() }
        }
        connection.start(queue: queue)
    }

    func receive(
        maximumLength: Int,
        completion: @escaping (Data?, Bool, Bool) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
            data, _, isComplete, error in
            completion(data, isComplete, error != nil)
        }
    }

    func send(_ data: Data, completion: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error != nil)
        })
    }

    func cancel() {
        connection.cancel()
    }
}

/// Client-Verbindung auf einem angenommenen BSD-Socket (Router-Dienst).
///
/// Der Deskriptor ist nicht blockierend; Lesen und Schreiben warten über
/// `DispatchSource`. Geschlossen wird er erst, wenn alle Quellen ihren
/// Cancel-Handler durchlaufen haben (sonst könnte kqueue einen schon
/// wiederverwendeten Deskriptor beobachten).
final class ClaudeGPTRouterSocketTransport: ClaudeGPTRouterClientTransport {
    private let fd: Int32
    private var queue: DispatchQueue?
    private var onClosed: (() -> Void)?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    // DispatchSource zählt suspend/resume; die Flags verhindern ein doppeltes
    // resume (Absturz) und ein cancel auf einer angehaltenen Quelle (deren
    // Cancel-Handler liefe nie, der Deskriptor bliebe offen).
    private var readSourceSuspended = true
    private var writeSourceSuspended = true
    private var pendingReceive: (maximumLength: Int, completion: (Data?, Bool, Bool) -> Void)?
    private var outgoing: [(data: Data, offset: Int, completion: (Bool) -> Void)] = []
    private var liveSources = 0
    private var isCancelled = false
    private var isClosed = false
    private var didReportClosed = false

    init(fileDescriptor: Int32) {
        fd = fileDescriptor
        ClaudeGPTRouterSocketTransport.prepare(fileDescriptor)
    }

    deinit {
        if !isClosed, liveSources == 0 {
            Darwin.close(fd)
        }
    }

    /// close-on-exec, nicht blockierend, kein SIGPIPE.
    static func prepare(_ fd: Int32) {
        AgentControlServer.setCloseOnExec(fd)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start(queue: DispatchQueue, onClosed: @escaping () -> Void) {
        self.queue = queue
        self.onClosed = onClosed
    }

    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Bool) -> Void) {
        guard !isCancelled else {
            completion(nil, false, true)
            return
        }
        pendingReceive = (maximumLength, completion)
        attemptRead()
    }

    func send(_ data: Data, completion: @escaping (Bool) -> Void) {
        guard !isCancelled else {
            completion(true)
            return
        }
        outgoing.append((data, 0, completion))
        flush()
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        let failedSends = outgoing
        outgoing.removeAll()
        failedSends.forEach { $0.completion(true) }
        if let pending = pendingReceive {
            pendingReceive = nil
            pending.completion(nil, false, true)
        }
        // Halbes Schließen zuerst: Was im Sendepuffer liegt, geht noch raus.
        shutdown(fd, SHUT_WR)
        if let readSource {
            resumeRead()
            readSource.cancel()
            self.readSource = nil
        }
        if let writeSource {
            resumeWrite()
            writeSource.cancel()
            self.writeSource = nil
        }
        closeIfIdle()
        reportClosed()
    }

    private func reportClosed() {
        guard !didReportClosed else { return }
        didReportClosed = true
        onClosed?()
    }

    private func closeIfIdle() {
        guard isCancelled, !isClosed, liveSources == 0 else { return }
        isClosed = true
        Darwin.close(fd)
    }

    private func attemptRead() {
        guard let pending = pendingReceive, !isCancelled else { return }
        var buffer = [UInt8](repeating: 0, count: max(1, pending.maximumLength))
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            pendingReceive = nil
            suspendRead()
            pending.completion(Data(buffer.prefix(count)), false, false)
        } else if count == 0 {
            pendingReceive = nil
            suspendRead()
            pending.completion(nil, true, false)
        } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            armRead()
        } else {
            pendingReceive = nil
            pending.completion(nil, false, true)
        }
    }

    private func armRead() {
        guard let queue else { return }
        if readSource != nil {
            resumeRead()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.attemptRead() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.liveSources -= 1
            self.closeIfIdle()
        }
        liveSources += 1
        readSource = source
        readSourceSuspended = true
        resumeRead()
    }

    private func flush() {
        while !isCancelled, !outgoing.isEmpty {
            var item = outgoing[0]
            let remaining = item.data.count - item.offset
            if remaining == 0 {
                outgoing.removeFirst()
                item.completion(false)
                continue
            }
            let written = item.data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: item.offset), remaining)
            }
            if written > 0 {
                item.offset += written
                outgoing[0] = item
                continue
            }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                armWrite()
                return
            }
            // Gegenseite weg (EPIPE, ECONNRESET): wie ein Sendefehler bei NWConnection.
            let failed = outgoing
            outgoing.removeAll()
            failed.forEach { $0.completion(true) }
            return
        }
        suspendWrite()
    }

    private func armWrite() {
        guard let queue else { return }
        if writeSource != nil {
            resumeWrite()
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.liveSources -= 1
            self.closeIfIdle()
        }
        liveSources += 1
        writeSource = source
        writeSourceSuspended = true
        resumeWrite()
    }

    private func resumeRead() {
        guard let readSource, readSourceSuspended else { return }
        readSourceSuspended = false
        readSource.resume()
    }

    private func suspendRead() {
        guard let readSource, !readSourceSuspended else { return }
        readSourceSuspended = true
        readSource.suspend()
    }

    private func resumeWrite() {
        guard let writeSource, writeSourceSuspended else { return }
        writeSourceSuspended = false
        writeSource.resume()
    }

    private func suspendWrite() {
        guard let writeSource, !writeSourceSuspended else { return }
        writeSourceSuspended = true
        writeSource.suspend()
    }
}
