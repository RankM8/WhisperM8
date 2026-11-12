import Darwin
import Foundation

/// Steuerleitung des Router-Dienstes: Unix-Socket, je Nachricht 4 Byte Länge
/// (Big Endian) plus JSON-Objekt. Ein Deskriptor reist per `SCM_RIGHTS` am
/// ersten Byte seiner Nachricht mit.
///
/// Harte Regel aus der Fehlersuche (Plan neustart-ohne-chatverlust.md,
/// „Ursache der gescheiterten zweiten Übergabe“): Wer einen Deskriptor
/// verschickt, schließt ihn und beendet sich erst nach dem `ACK` des
/// Empfängers. Sonst kann der Kernel den Deskriptor, der noch im Socket
/// steckt, für verwaist halten und den lauschenden Socket dauerhaft lahmlegen.
enum ClaudeGPTRouterWire {
    enum WireError: Error, Equatable {
        case connectFailed(Int32)
        case pathTooLong
        case writeFailed(Int32)
        case readFailed(Int32)
        case closed
        case timedOut
        case malformed
        case tooLarge
    }

    static let maximumMessageBytes = 64 * 1_024

    // MARK: Verbinden

    static func connect(path: String, timeout: TimeInterval = 2) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WireError.pathTooLong }
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: bytes.count) { pointer in
                bytes.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: bytes.count) }
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.connectFailed(errno) }
        AgentControlServer.setCloseOnExec(fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(fd, timeout)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw WireError.connectFailed(code)
        }
        return fd
    }

    /// Frist für blockierende Lese- und Schreibaufrufe auf `fd`.
    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var value = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - floor(seconds)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Senden

    static func send(_ fd: Int32, _ message: [String: Any], passing descriptor: Int32? = nil) throws {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard body.count <= maximumMessageBytes else { throw WireError.tooLarge }
        var frame = Data()
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)

        var offset = 0
        if let descriptor {
            // Erstes Byte mit dem Deskriptor als Begleitdaten.
            offset = try sendFirstByte(fd, frame, descriptor: descriptor)
        }
        while offset < frame.count {
            let written = frame.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? WireError.timedOut : WireError.writeFailed(errno)
            }
            offset += written
        }
    }

    private static func sendFirstByte(_ fd: Int32, _ frame: Data, descriptor: Int32) throws -> Int {
        let controlLength = cmsgSpace(MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        memset(control, 0, controlLength)
        let header = control.assumingMemoryBound(to: cmsghdr.self)
        header.pointee.cmsg_len = socklen_t(cmsgLength(MemoryLayout<Int32>.size))
        header.pointee.cmsg_level = SOL_SOCKET
        header.pointee.cmsg_type = SCM_RIGHTS
        control.advanced(by: cmsgDataOffset).storeBytes(of: descriptor, as: Int32.self)

        var byte = frame[frame.startIndex]
        while true {
            let sent: Int = withUnsafeMutablePointer(to: &byte) { pointer in
                var vector = iovec(iov_base: UnsafeMutableRawPointer(pointer), iov_len: 1)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = control
                    message.msg_controllen = socklen_t(controlLength)
                    return sendmsg(fd, &message, 0)
                }
            }
            if sent == 1 { return 1 }
            if sent < 0, errno == EINTR { continue }
            throw sent < 0 && errno == EAGAIN ? WireError.timedOut : WireError.writeFailed(errno)
        }
    }

    // MARK: Empfangen

    /// Liest genau eine Nachricht. Ein mitgeschickter Deskriptor bekommt sofort
    /// close-on-exec und gehört dem Aufrufer.
    static func receive(_ fd: Int32) throws -> (message: [String: Any], descriptor: Int32?) {
        var received: [Int32] = []
        var header = Data()
        do {
            while header.count < 4 {
                let (chunk, descriptors) = try receiveChunk(fd, maximum: 4 - header.count)
                received.append(contentsOf: descriptors)
                header.append(chunk)
            }
            let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length <= maximumMessageBytes else { throw WireError.tooLarge }
            var body = Data()
            while body.count < length {
                let (chunk, descriptors) = try receiveChunk(fd, maximum: length - body.count)
                received.append(contentsOf: descriptors)
                body.append(chunk)
            }
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw WireError.malformed
            }
            // Mehr als ein Deskriptor ist nie vorgesehen: überzählige schließen.
            for extra in received.dropFirst() { close(extra) }
            return (object, received.first)
        } catch {
            received.forEach { close($0) }
            throw error
        }
    }

    private static func receiveChunk(_ fd: Int32, maximum: Int) throws -> (Data, [Int32]) {
        let controlLength = cmsgSpace(MemoryLayout<Int32>.size * 4)
        let control = UnsafeMutableRawPointer.allocate(byteCount: controlLength, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { control.deallocate() }
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            var controlUsed = 0
            let count: Int = buffer.withUnsafeMutableBytes { bytes in
                var vector = iovec(iov_base: bytes.baseAddress, iov_len: maximum)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = control
                    message.msg_controllen = socklen_t(controlLength)
                    let result = recvmsg(fd, &message, 0)
                    controlUsed = Int(message.msg_controllen)
                    return result
                }
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? WireError.timedOut : WireError.readFailed(errno)
            }
            let descriptors = extractDescriptors(control, length: controlUsed)
            if count == 0 {
                descriptors.forEach { close($0) }
                throw WireError.closed
            }
            return (Data(buffer.prefix(count)), descriptors)
        }
    }

    private static func extractDescriptors(_ control: UnsafeMutableRawPointer, length: Int) -> [Int32] {
        var descriptors: [Int32] = []
        var offset = 0
        let headerSize = MemoryLayout<cmsghdr>.size
        while offset + headerSize <= length {
            let header = control.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self).pointee
            let messageLength = Int(header.cmsg_len)
            guard messageLength >= headerSize, offset + messageLength <= length else { break }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                let count = (messageLength - cmsgDataOffset) / MemoryLayout<Int32>.size
                for index in 0..<count {
                    let descriptor = control
                        .advanced(by: offset + cmsgDataOffset + index * MemoryLayout<Int32>.size)
                        .loadUnaligned(as: Int32.self)
                    AgentControlServer.setCloseOnExec(descriptor)
                    descriptors.append(descriptor)
                }
            }
            offset += cmsgAlign(messageLength)
        }
        return descriptors
    }

    // MARK: CMSG-Makros (in Swift nicht verfügbar)

    private static func cmsgAlign(_ length: Int) -> Int {
        let alignment = MemoryLayout<UInt32>.size
        return (length + alignment - 1) & ~(alignment - 1)
    }

    private static var cmsgDataOffset: Int { cmsgAlign(MemoryLayout<cmsghdr>.size) }

    private static func cmsgLength(_ length: Int) -> Int { cmsgDataOffset + length }

    private static func cmsgSpace(_ length: Int) -> Int { cmsgDataOffset + cmsgAlign(length) }
}
