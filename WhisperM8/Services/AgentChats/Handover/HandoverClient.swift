import Darwin
import Foundation

// MARK: - Client (App-Seite und CLI)

/// Gegenstück zum Aufbewahrer. Die App nutzt es ab Paket 4 (Abgabe beim
/// Beenden, Übernahme beim Start), die CLI für `app handover-status`.
///
/// Regel für den Aufrufer: Nach `deposit` hält die App ihre eigene Leitung
/// noch; schließen darf sie sie erst, wenn `deposit` ohne Fehler
/// zurückkam (dann liegt das ACK vor).
final class HandoverClient {
    enum ClientError: Error, Equatable, CustomStringConvertible {
        case refused(String)
        case incompatible
        case unexpected(String)

        var description: String {
            switch self {
            case .refused(let text): return "abgelehnt: \(text)"
            case .incompatible: return "Protokoll unverträglich"
            case .unexpected(let text): return text
            }
        }
    }

    struct TakeHello: Equatable {
        var protocolVersion: Int
        var runID: String?
        var build: String?
    }

    struct TakenChat {
        var manifest: HandoverManifest
        /// `nil`, wenn der Chat in der Lücke beendet wurde.
        var descriptor: Int32?
        /// ANSI-Strom; in ein frisches Terminal derselben Größe füttern.
        var image: [UInt8]
        var exited: Bool
        var exitStatus: Int32?
        var gapBytes: Int
    }

    let connection: HandoverConnection
    var timeout: TimeInterval

    init(connection: HandoverConnection, timeout: TimeInterval = 10) {
        self.connection = connection
        self.timeout = timeout
    }

    static func connect(paths: HandoverPaths = .default, timeout: TimeInterval = 5) throws -> HandoverClient {
        HandoverClient(connection: try HandoverSocket.connect(to: paths.resolvedSocketURL(), timeout: timeout))
    }

    func close() { connection.close() }

    private func roundTrip(_ message: HandoverMessage, descriptor: Int32? = nil, payload: [UInt8] = []) throws -> HandoverReceived {
        try connection.send(message, descriptor: descriptor, payload: payload, timeout: timeout)
        let reply = try connection.receive(timeout: timeout)
        if reply.message.type == .error {
            if let fd = reply.descriptor { Darwin.close(fd) }
            throw ClientError.refused(reply.message.message ?? "ohne Grund")
        }
        return reply
    }

    // MARK: Abgabe

    @discardableResult
    func helloDeposit(appPid: Int32 = getpid(), protocolVersion: Int = HandoverProtocol.current) throws -> String? {
        var hello = HandoverMessage(type: .hello)
        hello.role = .deposit
        hello.protocolVersion = protocolVersion
        hello.appPid = appPid
        hello.build = HandoverProtocol.buildIdentifier
        let reply = try roundTrip(hello)
        if reply.message.type == .incompatible { throw ClientError.incompatible }
        guard reply.message.type == .ok else { throw ClientError.unexpected("OK erwartet") }
        return reply.message.runID
    }

    /// Gibt einen Chat ab und wartet auf das ACK. Erst danach darf der
    /// Aufrufer seine eigene Kopie der Leitung schließen.
    func deposit(manifest: HandoverManifest, descriptor: Int32, image: [UInt8]) throws {
        var message = HandoverMessage(type: .deposit)
        message.manifest = manifest
        let reply = try roundTrip(message, descriptor: descriptor, payload: image)
        guard reply.message.type == .ack, reply.message.chatID == manifest.chatID else {
            throw ClientError.unexpected("ACK erwartet für \(manifest.chatID)")
        }
    }

    func commit() throws {
        let reply = try roundTrip(HandoverMessage(type: .commit))
        guard reply.message.type == .ok else { throw ClientError.unexpected("OK erwartet") }
    }

    func abort() throws {
        _ = try roundTrip(HandoverMessage(type: .abort))
    }

    // MARK: Übernahme

    func helloTake(range: ClosedRange<Int> = HandoverProtocol.supported) throws -> TakeHello {
        var hello = HandoverMessage(type: .hello)
        hello.role = .take
        hello.protocolRange = [range.lowerBound, range.upperBound]
        hello.build = HandoverProtocol.buildIdentifier
        hello.appPid = getpid()
        let reply = try roundTrip(hello)
        if reply.message.type == .incompatible { throw ClientError.incompatible }
        guard reply.message.type == .ok, let version = reply.message.protocolVersion else {
            throw ClientError.unexpected("OK erwartet")
        }
        return TakeHello(protocolVersion: version, runID: reply.message.runID, build: reply.message.build)
    }

    func list() throws -> [HandoverChatSummary] {
        let reply = try roundTrip(HandoverMessage(type: .list))
        guard reply.message.type == .chats else { throw ClientError.unexpected("CHATS erwartet") }
        return reply.message.chats ?? []
    }

    /// Holt einen Chat. Mit `acknowledge` (Standard) geht das ACK sofort
    /// hinaus, sobald die Leitung in diesem Prozess angekommen ist.
    func take(chatID: String, acknowledge: Bool = true) throws -> TakenChat {
        var message = HandoverMessage(type: .take)
        message.chatID = chatID
        let reply = try roundTrip(message)
        guard reply.message.type == .chat, reply.message.chatID == chatID, let manifest = reply.message.manifest else {
            if let fd = reply.descriptor { Darwin.close(fd) }
            throw ClientError.unexpected("CHAT erwartet für \(chatID)")
        }
        let exited = reply.message.exited ?? false
        if !exited, reply.descriptor == nil { throw HandoverWireError.missingDescriptor }
        let taken = TakenChat(
            manifest: manifest,
            descriptor: reply.descriptor,
            image: reply.payload,
            exited: exited,
            exitStatus: reply.message.exitStatus,
            gapBytes: reply.message.gapBytes ?? 0
        )
        if acknowledge { try self.acknowledge(chatID: chatID) }
        return taken
    }

    func acknowledge(chatID: String) throws {
        var ack = HandoverMessage(type: .ack)
        ack.chatID = chatID
        try connection.send(ack, timeout: timeout)
    }

    func done() throws {
        _ = try roundTrip(HandoverMessage(type: .done))
    }

    /// Unverträglich oder Übernahme gescheitert: der Aufbewahrer beendet
    /// geordnet, die App setzt danach per `--resume` fort.
    func release() throws {
        _ = try roundTrip(HandoverMessage(type: .release))
    }

    // MARK: Status

    func status() throws -> HandoverKeeperStatus {
        let reply = try roundTrip(HandoverMessage(type: .status))
        guard reply.message.type == .statusResult, let status = reply.message.status else {
            throw ClientError.unexpected("STATUS_RESULT erwartet")
        }
        return status
    }
}

// MARK: - Starter

/// Startet den Aufbewahrer als eigenen Prozess aus dem App-Binary. `Process`
/// nutzt posix_spawn mit close-on-exec als Standard; der Aufbewahrer löst sich
/// selbst per `setsid()` vom Starter. Aufrufer ist ab Paket 4 die App.
enum HandoverKeeperLauncher {
    static func arguments(
        paths: HandoverPaths,
        runID: String,
        holdSeconds: TimeInterval? = nil,
        depositSeconds: TimeInterval? = nil,
        appBinaries: [String] = []
    ) -> [String] {
        var args = ["handover-keeper", "--root", paths.directory.path, "--run", runID]
        if let holdSeconds { args += ["--hold-seconds", String(holdSeconds)] }
        if let depositSeconds { args += ["--deposit-seconds", String(depositSeconds)] }
        for binary in appBinaries { args += ["--app-binary", binary] }
        return args
    }

    static func launch(executable: URL, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
