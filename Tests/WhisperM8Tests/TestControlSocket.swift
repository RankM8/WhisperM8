import Foundation
import Darwin
@testable import WhisperM8

/// Minimaler In-Process-UDS-Server + -Client für Tests. Nutzt exakt die
/// Produktions-Codec-Pfade (`ChatsControlCodec`) und die echten Protokoll-
/// Typen, aber einen eigenen, injizierbaren Socket-Pfad (der echte
/// `AgentControlServer` ist ein Singleton mit festem Pfad).
enum TestControlSocket {
    final class Server {
        private let fd: Int32
        private let source: DispatchSourceRead
        private let socketPath: String
        private let queue = DispatchQueue(label: "test-control-server")

        init(fd: Int32, source: DispatchSourceRead, socketPath: String) {
            self.fd = fd
            self.source = source
            self.socketPath = socketPath
        }

        func stop() {
            source.cancel()
            close(fd)
            unlink(socketPath)
        }
    }

    static func listen(at url: URL, handler: AgentControlRequestHandling) throws -> Server {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError.socketFailed }
        unlink(url.path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    destPtr.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bindResult == 0 else { close(fd); throw TestError.bindFailed }
        guard Darwin.listen(fd, 8) == 0 else { close(fd); throw TestError.listenFailed }

        let queue = DispatchQueue(label: "test-control-accept")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else { return }
            queue.async {
                defer { close(clientFD) }
                guard let line = readLine(clientFD),
                      let request = try? ChatsControlCodec.decode(ChatsControlRequest.self, from: line) else {
                    return
                }
                let semaphore = DispatchSemaphore(value: 0)
                var response = ChatsControlResponse.failure(requestID: request.requestID, code: .internalError, message: "x")
                Task {
                    response = await handler.handle(request)
                    semaphore.signal()
                }
                semaphore.wait()
                if let data = try? ChatsControlCodec.encodeLine(response) {
                    data.withUnsafeBytes { _ = write(clientFD, $0.baseAddress, $0.count) }
                }
            }
        }
        source.resume()
        return Server(fd: fd, source: source, socketPath: url.path)
    }

    static func sendRequest(_ request: ChatsControlRequest, to url: URL) throws -> ChatsControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError.socketFailed }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = url.path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    destPtr.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Kurzer Retry, falls der accept-Handler noch nicht armiert ist.
        var connected = false
        for _ in 0..<50 {
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
            }
            if result == 0 { connected = true; break }
            usleep(20_000)
        }
        guard connected else { throw TestError.connectFailed }

        let line = try ChatsControlCodec.encodeLine(request)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { throw TestError.writeFailed }
                offset += n
            }
        }
        guard let responseLine = readLine(fd) else { throw TestError.noResponse }
        return try ChatsControlCodec.decode(ChatsControlResponse.self, from: responseLine)
    }

    private static func readLine(_ fd: Int32) -> Data? {
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

    enum TestError: Error {
        case socketFailed, bindFailed, listenFailed, connectFailed, writeFailed, noResponse
    }
}
