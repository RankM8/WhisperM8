import Darwin
import Foundation

// MARK: - Client (App-Seite und CLI)

/// Gegenstück zum Aufbewahrer. Die App nutzt es ab Paket 4 (Abgabe beim
/// Beenden, Übernahme beim Start), die CLI für `app handover-status`.
///
/// Regeln für den Aufrufer:
/// - **Abgabe:** Die App hält ihre eigenen Leitungen, bis `commit()` ohne
///   Fehler zurückkam (COMMIT → OK). Erst dann schließt sie sie. Scheitert
///   vorher irgendetwas, schließt der Aufbewahrer seine Kopien still, und die
///   App beendet sich auf dem heutigen Weg — ihre Originale halten die Chats.
/// - **Übernahme:** `take` liefert eine Leitung erst, wenn der Aufbewahrer
///   nach dem ACK mit `OK {chatID}` bestätigt hat, dass seine Kopie zu ist.
///   Kommt das OK nicht, schließt `take` die empfangene Kopie selbst, ohne
///   Ctrl+C — der Chat bleibt beim Aufbewahrer. Nie zwei Leser.
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

    enum VerificationError: Error, Equatable {
        case wrongRunID
        case wrongPID
        case untrustedServer
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

    /// Prüft, ob am anderen Ende wirklich der Aufbewahrer sitzt, den die App
    /// gestartet hat (PID) bzw. der aus dem erlaubten Binary läuft (Policy).
    func verifyServer(expectedPID: pid_t? = nil, policy: HandoverPeerPolicy? = nil) throws {
        guard let peer = HandoverPeer.of(socket: connection.fd), peer.uid == getuid() else {
            throw VerificationError.untrustedServer
        }
        if let expectedPID, peer.pid != expectedPID { throw VerificationError.wrongPID }
        if let policy, !policy.isAllowed(peer) { throw VerificationError.untrustedServer }
    }

    /// HELLO der Abgabe mit dem Geheimnis, das die App dem Aufbewahrer beim
    /// Start gegeben hat. Mit `expectedRunID`/`expectedPID` prüft die App, dass
    /// sie mit genau ihrem Aufbewahrer spricht.
    @discardableResult
    func helloDeposit(
        secret: String?,
        expectedRunID: String? = nil,
        expectedPID: pid_t? = nil,
        appPid: Int32 = getpid(),
        protocolVersion: Int = HandoverProtocol.current
    ) throws -> String? {
        if let expectedPID {
            try verifyServer(expectedPID: expectedPID)
            keeperPID = expectedPID
            keeperStartTime = ProcessStartTime.of(pid: expectedPID)
        }
        var hello = HandoverMessage(type: .hello)
        hello.role = .deposit
        hello.protocolVersion = protocolVersion
        hello.appPid = appPid
        hello.build = HandoverProtocol.buildIdentifier
        hello.secret = secret
        let reply = try roundTrip(hello)
        if reply.message.type == .incompatible { throw ClientError.incompatible }
        guard reply.message.type == .ok else { throw ClientError.unexpected("OK erwartet") }
        if let expectedRunID, reply.message.runID != expectedRunID { throw VerificationError.wrongRunID }
        return reply.message.runID
    }

    /// Gibt einen Chat ab und wartet auf das ACK. Die eigene Kopie der
    /// Leitung bleibt trotzdem offen, bis `commit()` zurückkam.
    func deposit(manifest: HandoverManifest, descriptor: Int32, image: [UInt8]) throws {
        var message = HandoverMessage(type: .deposit)
        message.manifest = manifest
        let reply = try roundTrip(message, descriptor: descriptor, payload: image)
        guard reply.message.type == .ack, reply.message.chatID == manifest.chatID else {
            throw ClientError.unexpected("ACK erwartet für \(manifest.chatID)")
        }
    }

    /// PID des Aufbewahrers, sobald `helloDeposit(expectedPID:)` sie geprüft hat,
    /// samt Startzeit gegen eine inzwischen neu vergebene PID.
    var keeperPID: pid_t?
    var keeperStartTime: Date?

    /// Nach Rückkehr ohne Fehler hält der Aufbewahrer alle Chats; erst jetzt
    /// darf die App ihre Originale schließen.
    ///
    /// Scheitert `commit`, ist unklar, ob der Aufbewahrer schon hält (das OK
    /// kann unterwegs verloren gegangen sein). Damit dann keine Kopie die
    /// Chats weiter hält, während die App auf dem heutigen Weg endet, bekommt
    /// der Aufbewahrer SIGTERM: vor COMMIT schließt er still, danach geordnet.
    func commit() throws {
        do {
            let reply = try roundTrip(HandoverMessage(type: .commit))
            guard reply.message.type == .ok else { throw ClientError.unexpected("OK erwartet") }
        } catch {
            terminateKeeperIfStillTheSame()
            throw error
        }
    }

    /// SIGTERM nur, wenn unter der PID noch derselbe Prozess läuft: Hat der
    /// Aufbewahrer sich schon beendet, kann die PID einem anderen gehören.
    func terminateKeeperIfStillTheSame() {
        guard let keeperPID, keeperPID > 1 else { return }
        if let expected = keeperStartTime {
            guard let current = ProcessStartTime.of(pid: keeperPID),
                  abs(current.timeIntervalSince(expected)) < 0.001 else { return }
        }
        kill(keeperPID, SIGTERM)
    }

    func abort() throws {
        _ = try roundTrip(HandoverMessage(type: .abort))
    }

    // MARK: Übernahme

    /// HELLO der Übernahme. `secret` ist das Geheimnis, das die alte App dem
    /// Aufbewahrer gegeben hat; die neue App bekommt es von ihr über den
    /// Schlüsselbund (Paket 4).
    func helloTake(range: ClosedRange<Int> = HandoverProtocol.supported, secret: String?) throws -> TakeHello {
        var hello = HandoverMessage(type: .hello)
        hello.role = .take
        hello.secret = secret
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

    /// Holt einen Chat: CHAT empfangen, ACK senden, auf `OK {chatID}` warten.
    /// Erst mit dem OK gehört die Leitung der App. Ohne OK schließt `take` die
    /// empfangene Kopie wieder (ohne Ctrl+C) und wirft.
    ///
    /// `acknowledge: false` nur für Tests: liefert die Leitung ohne ACK.
    func take(chatID: String, acknowledge: Bool = true) throws -> TakenChat {
        var message = HandoverMessage(type: .take)
        message.chatID = chatID
        try connection.send(message, timeout: timeout)
        let reply = try connection.receive(timeout: timeout, acceptAttachments: true)
        if reply.message.type == .error {
            if let fd = reply.descriptor { Darwin.close(fd) }
            throw ClientError.refused(reply.message.message ?? "ohne Grund")
        }
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
        guard acknowledge else { return taken }
        do {
            try confirmTake(chatID: chatID)
        } catch {
            // Im Zweifel nur schließen: der Aufbewahrer hält den Chat weiter.
            if let fd = taken.descriptor { Darwin.close(fd) }
            throw error
        }
        return taken
    }

    /// ACK senden und auf das OK des Aufbewahrers warten. Die Wartezeit ist
    /// länger als seine ACK-Frist, damit ein knappes ACK nicht beide Seiten
    /// ohne Leitung zurücklässt.
    func confirmTake(chatID: String) throws {
        var ack = HandoverMessage(type: .ack)
        ack.chatID = chatID
        try connection.send(ack, timeout: timeout)
        let reply = try connection.receive(timeout: timeout * 2)
        guard reply.message.type == .ok, reply.message.chatID == chatID else {
            throw ClientError.unexpected("OK erwartet für \(chatID)")
        }
    }

    func done() throws {
        _ = try roundTrip(HandoverMessage(type: .done))
    }

    /// Unverträglich oder Übernahme gescheitert: der Aufbewahrer beendet
    /// geordnet, die App setzt danach per `--resume` fort.
    /// Mit Geheimnis, wenn `RELEASE` die erste Nachricht der Verbindung ist.
    /// Nach einem HELLO (auch nach `INCOMPATIBLE`) ist die Verbindung schon
    /// ausgewiesen; das Feld schadet dann nicht.
    func release(secret: String?) throws {
        var message = HandoverMessage(type: .release)
        message.secret = secret
        _ = try roundTrip(message)
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

    /// Startet den Aufbewahrer und gibt ihm das Geheimnis über stdin (nie als
    /// Argument: das stünde in `ps`). Die App merkt sich Geheimnis, runID und
    /// PID (`process.processIdentifier`) nur im Speicher.
    static func launch(executable: URL, arguments: [String], secret: String) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let writer = input.fileHandleForWriting
        // Stirbt der Aufbewahrer sofort, darf das Schreiben kein SIGPIPE auslösen.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data((secret + "\n").utf8))
        return process
    }
}
