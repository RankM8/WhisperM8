import Darwin
import Foundation
import Security

// MARK: - Verbindung (Rahmung, Deskriptoren, Fristen)

enum HandoverWireError: Error, Equatable, CustomStringConvertible {
    case timedOut
    case closed
    case io(Int32)
    case frameTooLarge(Int)
    case payloadTooLarge(Int)
    case decode
    case missingDescriptor
    case unexpected(String)

    var description: String {
        switch self {
        case .timedOut: return "Frist abgelaufen"
        case .closed: return "Gegenseite hat die Verbindung geschlossen"
        case .io(let code): return "E/A-Fehler errno=\(code)"
        case .frameTooLarge(let size): return "Telegramm zu groß (\(size) Byte)"
        case .payloadTooLarge(let size): return "Nutzlast zu groß (\(size) Byte)"
        case .decode: return "Telegramm nicht lesbar"
        case .missingDescriptor: return "Deskriptor angekündigt, aber nicht angekommen"
        case .unexpected(let text): return text
        }
    }
}

/// Empfangenes Telegramm samt Deskriptor und Nutzlast.
struct HandoverReceived {
    var message: HandoverMessage
    /// Gehört ab jetzt dem Empfänger (schließen oder weiterreichen).
    var descriptor: Int32?
    var payload: [UInt8]
}

/// Blockierende Unix-Socket-Verbindung mit Gesamtfristen über `poll`.
/// Nicht thread-sicher: je Verbindung ein Thread.
///
/// Rahmung: `UInt32` Länge big-endian, dann JSON, dann `payloadBytes` rohe
/// Bytes. Ein Deskriptor hängt per `SCM_RIGHTS` am ersten `sendmsg` eines
/// Telegramms; der Empfänger sammelt alle Deskriptoren, die beim Lesen
/// ankommen, und ordnet sie über `hasDescriptor` zu.
final class HandoverConnection {
    let fd: Int32
    private var pendingDescriptors: [Int32] = []
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        HandoverSocket.setCloseOnExec(fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        for descriptor in pendingDescriptors { Darwin.close(descriptor) }
        pendingDescriptors.removeAll()
        Darwin.close(fd)
    }

    // MARK: Senden

    func send(
        _ message: HandoverMessage,
        descriptor: Int32? = nil,
        payload: [UInt8] = [],
        timeout: TimeInterval
    ) throws {
        var message = message
        message.hasDescriptor = descriptor != nil ? true : nil
        message.payloadBytes = payload.isEmpty ? nil : payload.count
        let json = try JSONEncoder().encode(message)
        guard json.count <= HandoverProtocol.maxFrameBytes else { throw HandoverWireError.frameTooLarge(json.count) }
        guard payload.count <= HandoverProtocol.maxPayloadBytes else { throw HandoverWireError.payloadTooLarge(payload.count) }

        var frame = [UInt8]()
        frame.reserveCapacity(4 + json.count)
        let length = UInt32(json.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: json)

        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        if let descriptor {
            offset = try sendWithDescriptor(frame, descriptor: descriptor, deadline: deadline)
        }
        try writeAll(frame, from: offset, deadline: deadline)
        if !payload.isEmpty { try writeAll(payload, from: 0, deadline: deadline) }
    }

    private func sendWithDescriptor(_ bytes: [UInt8], descriptor: Int32, deadline: Date) throws -> Int {
        let controlLength = HandoverSocket.cmsgSpace(MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: controlLength)
        var bytes = bytes
        while true {
            try waitFor(events: Int16(POLLOUT), deadline: deadline)
            let sent: Int = bytes.withUnsafeMutableBytes { dataPtr in
                control.withUnsafeMutableBytes { controlPtr in
                    var iov = iovec(iov_base: dataPtr.baseAddress, iov_len: dataPtr.count)
                    return withUnsafeMutablePointer(to: &iov) { iovPtr in
                        var header = msghdr()
                        header.msg_iov = iovPtr
                        header.msg_iovlen = 1
                        header.msg_control = controlPtr.baseAddress
                        header.msg_controllen = socklen_t(controlLength)
                        let cmsg = controlPtr.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                        cmsg.pointee.cmsg_len = socklen_t(HandoverSocket.cmsgLength(MemoryLayout<Int32>.size))
                        cmsg.pointee.cmsg_level = SOL_SOCKET
                        cmsg.pointee.cmsg_type = SCM_RIGHTS
                        let dataStart = controlPtr.baseAddress!.advanced(by: HandoverSocket.cmsgHeaderAligned)
                        dataStart.storeBytes(of: descriptor, as: Int32.self)
                        return sendmsg(fd, &header, 0)
                    }
                }
            }
            if sent < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw HandoverWireError.io(errno)
            }
            return sent
        }
    }

    private func writeAll(_ bytes: [UInt8], from start: Int, deadline: Date) throws {
        var offset = start
        while offset < bytes.count {
            try waitFor(events: Int16(POLLOUT), deadline: deadline)
            let written = bytes.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw HandoverWireError.io(errno)
            }
            offset += written
        }
    }

    // MARK: Empfangen

    /// Liest ein Telegramm. Leitungen nimmt nur an, wer `acceptDescriptor`
    /// setzt (Abgabe beim Aufbewahrer, `CHAT` bei der App); sonst wird jede
    /// mitgeschickte Leitung sofort geschlossen. Ein fremder Prozess kann den
    /// Empfänger so nicht mit Deskriptoren fluten.
    func receive(timeout: TimeInterval, acceptDescriptor: Bool = false) throws -> HandoverReceived {
        let deadline = Date().addingTimeInterval(timeout)
        let header = try readExactly(4, deadline: deadline)
        let length = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
        guard length > 0, length <= HandoverProtocol.maxFrameBytes else { throw HandoverWireError.frameTooLarge(length) }
        let json = try readExactly(length, deadline: deadline)
        guard let message = try? JSONDecoder().decode(HandoverMessage.self, from: Data(json)) else {
            throw HandoverWireError.decode
        }
        let payloadLength = message.payloadBytes ?? 0
        guard payloadLength >= 0, payloadLength <= HandoverProtocol.maxPayloadBytes else {
            throw HandoverWireError.payloadTooLarge(payloadLength)
        }
        let payload = payloadLength > 0 ? try readExactly(payloadLength, deadline: deadline) : []

        var descriptor: Int32?
        if message.hasDescriptor == true {
            guard !pendingDescriptors.isEmpty else { throw HandoverWireError.missingDescriptor }
            descriptor = pendingDescriptors.removeFirst()
            if !acceptDescriptor, let unwanted = descriptor {
                Darwin.close(unwanted)
                descriptor = nil
            }
        }
        // Unangekündigte Deskriptoren nie stillschweigend behalten.
        for extra in pendingDescriptors { Darwin.close(extra) }
        pendingDescriptors.removeAll()
        return HandoverReceived(message: message, descriptor: descriptor, payload: payload)
    }

    private func readExactly(_ count: Int, deadline: Date) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        let controlLength = HandoverSocket.cmsgSpace(MemoryLayout<Int32>.size * 4)
        var control = [UInt8](repeating: 0, count: controlLength)
        while offset < count {
            try waitFor(events: Int16(POLLIN), deadline: deadline)
            var received = 0
            var controlUsed = 0
            buffer.withUnsafeMutableBytes { dataPtr in
                control.withUnsafeMutableBytes { controlPtr in
                    var iov = iovec(iov_base: dataPtr.baseAddress!.advanced(by: offset), iov_len: count - offset)
                    withUnsafeMutablePointer(to: &iov) { iovPtr in
                        var header = msghdr()
                        header.msg_iov = iovPtr
                        header.msg_iovlen = 1
                        header.msg_control = controlPtr.baseAddress
                        header.msg_controllen = socklen_t(controlLength)
                        received = recvmsg(fd, &header, 0)
                        controlUsed = Int(header.msg_controllen)
                    }
                }
            }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw HandoverWireError.io(errno)
            }
            collectDescriptors(control, used: controlUsed)
            if received == 0 { throw HandoverWireError.closed }
            offset += received
        }
        return buffer
    }

    private func collectDescriptors(_ control: [UInt8], used: Int) {
        guard used >= HandoverSocket.cmsgHeaderAligned else { return }
        control.withUnsafeBytes { ptr in
            var position = 0
            while position + MemoryLayout<cmsghdr>.size <= used {
                let cmsg = ptr.baseAddress!.advanced(by: position).loadUnaligned(as: cmsghdr.self)
                let length = Int(cmsg.cmsg_len)
                guard length >= HandoverSocket.cmsgHeaderAligned, position + length <= used else { break }
                if cmsg.cmsg_level == SOL_SOCKET, cmsg.cmsg_type == SCM_RIGHTS {
                    let dataLength = length - HandoverSocket.cmsgHeaderAligned
                    let count = dataLength / MemoryLayout<Int32>.size
                    for index in 0..<count {
                        let descriptor = ptr.baseAddress!
                            .advanced(by: position + HandoverSocket.cmsgHeaderAligned + index * MemoryLayout<Int32>.size)
                            .loadUnaligned(as: Int32.self)
                        // Sofort close-on-exec: Chat-Prozesse der App dürfen fremde
                        // PTY-Master nie erben.
                        HandoverSocket.setCloseOnExec(descriptor)
                        pendingDescriptors.append(descriptor)
                    }
                }
                position += HandoverSocket.align(length)
            }
        }
    }

    private func waitFor(events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HandoverWireError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max))) + 1)
            if ready < 0 {
                if errno == EINTR { continue }
                throw HandoverWireError.io(errno)
            }
            if ready == 0 { continue }
            if descriptor.revents & Int16(POLLNVAL) != 0 { throw HandoverWireError.io(EBADF) }
            // POLLHUP/POLLERR: der folgende read/write liefert den genauen Fehler.
            return
        }
    }
}

// MARK: - Socket-Hilfen

enum HandoverSocket {
    static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    // CMSG_*-Makros sind in Swift nicht verfügbar; Darwin richtet auf 4 Byte aus.
    static func align(_ length: Int) -> Int { (length + 3) & ~3 }
    static var cmsgHeaderAligned: Int { align(MemoryLayout<cmsghdr>.size) }
    static func cmsgLength(_ dataLength: Int) -> Int { cmsgHeaderAligned + dataLength }
    static func cmsgSpace(_ dataLength: Int) -> Int { cmsgHeaderAligned + align(dataLength) }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { dest in
            dest.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destPtr in
                bytes.withUnsafeBufferPointer { src in destPtr.update(from: src.baseAddress!, count: bytes.count) }
            }
        }
        return addr
    }

    /// Verbindet mit Wiederholen, bis `timeout` abgelaufen ist (der Aufbewahrer
    /// bindet seinen Socket erst kurz nach dem Start).
    static func connect(to url: URL, timeout: TimeInterval) throws -> HandoverConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Int32 = ENOENT
        repeat {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HandoverWireError.io(errno) }
            setCloseOnExec(fd)
            guard var addr = makeAddress(url.path) else {
                Darwin.close(fd)
                throw HandoverWireError.unexpected("Socket-Pfad zu lang")
            }
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return HandoverConnection(fd: fd) }
            lastError = errno
            Darwin.close(fd)
            if Date() >= deadline { break }
            usleep(20_000)
        } while Date() < deadline
        throw HandoverWireError.io(lastError)
    }
}

// MARK: - Gegenseite prüfen

/// Wer darf was? `STATUS` darf jeder Prozess desselben Nutzers (enthält weder
/// Tokens noch Inhalte). Abgeben, Übernehmen und Freigeben nur ein Prozess
/// aus dem erlaubten Binary, dessen Code zum Audit-Token passt.
///
/// Achtung, gemessen 12.11.2026: `LOCAL_PEERTOKEN`/`LOCAL_PEERPID` nennen
/// den Prozess, der den Socket zuletzt benutzt hat, und zwar in seinem
/// jetzigen Zustand — nicht den vom `connect`. Eine Prüfung nur beim
/// `accept` lässt sich mit „verbinden, dann `exec` des App-Binarys“
/// umgehen. Der Aufbewahrer prüft deshalb jedes Telegramm einzeln
/// (`HandoverKeeper.receiveChecked`).
struct HandoverPeerPolicy {
    /// Erlaubte Pfade des Binarys der Gegenseite. Leer = keine Pfadprüfung
    /// (nur für Tests im selben Prozess).
    var allowedExecutablePaths: [String]
    /// Code-Anforderung (Designated Requirement der App). `nil` = keine
    /// Signaturprüfung, etwa bei ad hoc signierten Builds.
    var requirement: SecRequirement?

    init(allowedExecutablePaths: [String], requirement: SecRequirement? = nil) {
        self.allowedExecutablePaths = allowedExecutablePaths
        self.requirement = requirement
    }

    /// `realpath`, sonst der bereinigte Pfad. Nicht `resolvingSymlinksInPath`:
    /// das schneidet `/private` ab und vergliche dann Äpfel mit Birnen.
    static func normalized(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return (path as NSString).standardizingPath
    }

    func isAllowed(executablePath: String?) -> Bool {
        guard !allowedExecutablePaths.isEmpty else { return true }
        guard let executablePath else { return false }
        let candidate = Self.normalized(executablePath)
        return allowedExecutablePaths.contains { Self.normalized($0) == candidate }
    }

    func isAllowed(_ peer: HandoverPeer) -> Bool {
        if allowedExecutablePaths.isEmpty && requirement == nil { return true }
        // Ohne gültigen Code zum Audit-Token (Prozess hat seitdem `exec`
        // ausgeführt oder ist weg) kein Vertrauen.
        guard let code = peer.code else { return false }
        guard isAllowed(executablePath: peer.executablePath) else { return false }
        if let requirement {
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        return true
    }

    /// Anforderung für den Aufbewahrer der App: ihr eigenes Designated
    /// Requirement, sofern sie mit einem Zertifikat signiert ist. `make dev`
    /// signiert mit „WhisperM8 Local Dev“ (Kennung plus Zertifikat, stabil
    /// über Neubauten). Ad hoc signierte oder unsignierte Builds: `nil`, dann
    /// gilt nur der Pfad samt Audit-Token.
    static func ownRequirement() -> SecRequirement? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let certificates = dict[kSecCodeInfoCertificates as String] as? [Any] ?? []
        guard !isAdhoc, !certificates.isEmpty else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}

struct HandoverPeer {
    var uid: uid_t
    var pid: pid_t?
    /// Code des Prozesses hinter dem Audit-Token (zuletzt am Socket tätig).
    /// `nil`, wenn er nicht mehr zu finden ist.
    var code: SecCode?
    var executablePath: String?

    static func of(socket fd: Int32) -> HandoverPeer? {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else { return nil }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            return HandoverPeer(uid: euid, pid: nil, code: nil, executablePath: nil)
        }
        // audit_token_t: val[5] ist die PID.
        let pid = pid_t(bitPattern: token.val.5)
        let code = Self.code(for: token)
        return HandoverPeer(uid: euid, pid: pid, code: code, executablePath: code.flatMap(Self.path(of:)))
    }

    static func code(for token: audit_token_t) -> SecCode? {
        var token = token
        let data = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// Pfad des Haupt-Binarys. `SecCodeCopyPath` nennt bei Bundles nur den
    /// `.app`-Ordner, deshalb zuerst `kSecCodeInfoMainExecutable`.
    static func path(of code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
           let dict = info as? [String: Any],
           let main = dict[kSecCodeInfoMainExecutable as String] as? URL {
            return main.path
        }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return (url as URL).path
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
