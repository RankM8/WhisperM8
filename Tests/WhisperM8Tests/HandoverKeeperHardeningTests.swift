import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Befunde aus dem Review von Paket 2: Abgabefrist, volle Leitung, Ende
/// mitten in der Übergabe, Deskriptoren außerhalb der Abgabe, spätes ACK,
/// Prüfung der Gegenseite über das Audit-Token, Geheimnis auf stdin.
final class HandoverKeeperHardeningTests: XCTestCase {
    private var directory: URL!
    private var children: [HandoverPTYChild] = []
    private var keepers: [HandoverKeeper] = []

    override func setUpWithError() throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() {
        for keeper in keepers { keeper.queue.sync { keeper.finish(.terminated) } }
        for child in children { child.kill() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeKeeper(
        hold: TimeInterval = 30,
        deposit: TimeInterval = 10,
        ack: TimeInterval = 10,
        allowed: [String] = [],
        onFinish: @escaping (HandoverKeeper.FinishReason) -> Void = { _ in }
    ) throws -> HandoverKeeper {
        let keeper = HandoverKeeper(configuration: .init(
            paths: HandoverPaths(directory: directory),
            runID: "hardening",
            holdSeconds: hold,
            depositSeconds: deposit,
            ioTimeout: 10,
            ackTimeout: ack,
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: allowed),
            logToFile: false
        ))
        try keeper.start(onFinish: onFinish)
        keepers.append(keeper)
        return keeper
    }

    private func spawn(_ make: () throws -> HandoverPTYChild) rethrows -> HandoverPTYChild {
        let child = try make()
        children.append(child)
        return child
    }

    private func connect() throws -> HandoverClient {
        try HandoverClient.connect(paths: HandoverPaths(directory: directory), timeout: 10)
    }

    private func depositAll(_ list: [(HandoverPTYChild, HandoverManifest)], image: [UInt8] = []) throws {
        let client = try connect()
        defer { client.close() }
        try client.helloDeposit(secret: nil)
        for (child, manifest) in list {
            try client.deposit(manifest: manifest, descriptor: child.master, image: image)
        }
        try client.commit()
        for (child, _) in list { child.closeMaster() }
    }

    // MARK: 1 – Abgabefrist ab HELLO, je DEPOSIT verlängert

    func testDepositDeadlineCountsFromHelloAndEachDeposit() throws {
        let first = try spawn { try .ticking(in: directory) }
        let second = try spawn { try .ticking(in: directory) }
        let keeper = try makeKeeper(deposit: 2)
        usleep(1_200_000) // ab Start gemessen bliebe jetzt kaum noch Zeit
        let client = try connect()
        defer { client.close() }
        try client.helloDeposit(secret: nil)
        usleep(1_200_000)
        try client.deposit(manifest: first.manifest(chatID: "a"), descriptor: first.master, image: [])
        usleep(1_200_000)
        try client.deposit(manifest: second.manifest(chatID: "b"), descriptor: second.master, image: [])
        usleep(1_200_000)
        try client.commit()
        XCTAssertEqual(keeper.queue.sync { keeper.phase }, .holding)
        first.closeMaster()
        second.closeMaster()
    }

    func testOriginalsStayUsableUntilCommitWhenDepositIsLost() throws {
        let child = try spawn { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        _ = try makeKeeper { _ in finished.fulfill() }
        let client = try connect()
        try client.helloDeposit(secret: nil)
        try client.deposit(manifest: child.manifest(chatID: "a"), descriptor: child.master, image: [])
        client.close() // App stürzt vor COMMIT ab … aber ihre Originale halten den Chat
        wait(for: [finished], timeout: 15)
        usleep(200_000)
        XCTAssertTrue(child.isAlive)
        XCTAssertEqual(child.marker, "")
        // Die Leitung der App funktioniert weiter.
        let app = HandoverAppDouble(fd: child.master, image: [])
        app.read(for: 0.3)
        XCTAssertFalse(HandoverTestSupport.ticks(in: app.text).isEmpty)
    }

    // MARK: 2 – Volle Leitung blockiert den Aufbewahrer nicht

    func testFullInputLineDoesNotBlockKeeper() throws {
        // Das Kind liest seine Eingabe nie, im Raw-Modus wie eine TUI (im
        // kanonischen Modus verwirft das Terminal den Überhang selbst). Jede
        // Rückfrage im Bild erzeugt eine Antwort in die volle Leitung.
        let child = try spawn {
            try .spawn(script: "stty raw -echo; : > \"$READY\"; exec sleep 30", in: directory)
        }
        let keeper = try makeKeeper()
        let queries = Array(String(repeating: "\u{1B}[6n", count: 4_000).utf8)
        let started = Date()
        try depositAll([(child, child.manifest(chatID: "a"))], image: queries)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "Abgabe kommt durch, obwohl die Leitung voll ist")
        XCTAssertGreaterThan(keeper.queue.sync { keeper.chats["a"]?.droppedBytes ?? 0 }, 0, "Überhang verworfen")

        let status = try connect().status()
        XCTAssertEqual(status.chats.map(\.chatID), ["a"], "der Aufbewahrer antwortet weiter")
        let release = try connect()
        try release.release(secret: nil)
        release.close()
        XCTAssertNotNil(child.waitForExit(timeout: 10), "geordnetes Ende trotz voller Leitung")
    }

    // MARK: 3 – Ende mitten in der Übergabe

    func testReleaseDuringTransferSkipsCtrlCAndFinishesAfterAck() throws {
        let child = try spawn { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        let keeper = try makeKeeper { reason = $0; finished.fulfill() }
        try depositAll([(child, child.manifest(chatID: "a"))])

        let take = try connect()
        defer { take.close() }
        _ = try take.helloTake(secret: nil)
        let taken = try take.take(chatID: "a", acknowledge: false)
        let fd = try XCTUnwrap(taken.descriptor)

        let release = try connect()
        try release.release(secret: nil)
        release.close()
        XCTAssertEqual(keeper.queue.sync { keeper.phase }, .closing, "Ende wartet auf die Übergabe")
        XCTAssertFalse(child.marker.contains("INT"), "kein Ctrl+C an einen Chat mitten in der Übergabe")

        try take.confirmTake(chatID: "a")
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .released)
        usleep(200_000)
        XCTAssertTrue(child.isAlive, "die App hält den Chat")
        XCTAssertEqual(child.marker, "")
        close(fd)
    }

    func testTerminateDuringTransferWithoutAckOnlyCloses() throws {
        let child = try spawn { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        let keeper = try makeKeeper { reason = $0; finished.fulfill() }
        try depositAll([(child, child.manifest(chatID: "a"))])

        let take = try connect()
        _ = try take.helloTake(secret: nil)
        let taken = try take.take(chatID: "a", acknowledge: false)
        keeper.terminate()
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { keeper.queue.sync { keeper.phase } == .closing })
        // Die App gibt ohne ACK auf und schließt ihre Kopie.
        if let fd = taken.descriptor { close(fd) }
        take.close()
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .terminated)
        XCTAssertNotNil(child.waitForExit(timeout: 10))
        XCTAssertFalse(child.marker.contains("INT"), "nur geschlossen, kein Ctrl+C")
        XCTAssertTrue(child.marker.contains("HUP"))
    }

    // MARK: 4 – Leitungen außerhalb der Abgabe werden geschlossen

    func testDescriptorsOutsideDepositAreClosed() throws {
        let child = try spawn { try .ticking(in: directory) }
        _ = try makeKeeper()
        try depositAll([(child, child.manifest(chatID: "a"))])

        func assertKeeperClosesIt(_ send: (Int32) throws -> Void) throws {
            var fds: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&fds), 0)
            defer { close(fds[0]) }
            try send(fds[1])
            close(fds[1])
            // EOF erst, wenn auch die Kopie beim Aufbewahrer zu ist.
            var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            XCTAssertEqual(poll(&pfd, 1, 5_000), 1, "Aufbewahrer hat die Leitung geschlossen")
            var byte: UInt8 = 0
            XCTAssertEqual(read(fds[0], &byte, 1), 0)
        }

        // STATUS mit angehängter Leitung (vor jedem HELLO).
        try assertKeeperClosesIt { fd in
            let client = try connect()
            defer { client.close() }
            try client.connection.send(HandoverMessage(type: .status), descriptor: fd, timeout: 5)
            XCTAssertEqual(try client.connection.receive(timeout: 5).message.type, .statusResult)
        }
        // LIST mit angehängter Leitung in der Übernahme.
        let take = try connect()
        defer { take.close() }
        _ = try take.helloTake(secret: nil)
        try assertKeeperClosesIt { fd in
            try take.connection.send(HandoverMessage(type: .list), descriptor: fd, timeout: 5)
            XCTAssertEqual(try take.connection.receive(timeout: 5).message.type, .chats)
        }
    }

    // MARK: 6 – Spätes ACK

    func testLateAckGetsNoOkAndChatStaysWithKeeper() throws {
        let child = try spawn { try .ticking(in: directory) }
        let keeper = try makeKeeper(ack: 0.3)
        try depositAll([(child, child.manifest(chatID: "a"))])

        let take = try connect()
        _ = try take.helloTake(secret: nil)
        let taken = try take.take(chatID: "a", acknowledge: false)
        usleep(800_000) // ACK-Frist des Aufbewahrers verstreicht
        XCTAssertThrowsError(try take.confirmTake(chatID: "a"), "kein OK auf ein zu spätes ACK")
        // Ohne OK übernimmt die App nicht: Kopie schließen, kein Ctrl+C.
        if let fd = taken.descriptor { close(fd) }
        take.close()

        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) {
            keeper.queue.sync { keeper.chats["a"].map { !$0.inTransfer } ?? false }
        })
        usleep(300_000)
        XCTAssertTrue(child.isAlive, "der Aufbewahrer hält den Chat weiter")
        XCTAssertEqual(child.marker, "")
        XCTAssertGreaterThan(keeper.queue.sync { keeper.chats["a"]?.gapBytes ?? 0 }, 0)
    }

    // MARK: 5 – Gegenseite über das Audit-Token

    func testOwnProcessIsRecognizedViaAuditToken() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let peer = try XCTUnwrap(HandoverPeer.of(socket: fds[0]))
        XCTAssertEqual(peer.pid, getpid())
        XCTAssertNotNil(peer.code)
        XCTAssertEqual(
            HandoverPeerPolicy.normalized(peer.executablePath ?? ""),
            HandoverPeerPolicy.normalized(HandoverTestSupport.ownExecutablePath)
        )
        XCTAssertTrue(HandoverPeerPolicy(allowedExecutablePaths: [HandoverTestSupport.ownExecutablePath]).isAllowed(peer))
        XCTAssertFalse(HandoverPeerPolicy(allowedExecutablePaths: ["/bin/sleep"]).isAllowed(peer))
    }

    /// Angriff aus dem Review: Ein Kind verbindet sich und lädt danach per
    /// `exec` das erlaubte Binary; der Elternprozess spricht über dieselbe
    /// Verbindung. Nach Pfad und PID sähe das wie die App aus.
    func testPeerThatExecsAllowedBinaryAfterConnectIsNotTrusted() throws {
        let keeper = try makeKeeper(allowed: ["/bin/sleep"])
        let socketURL = HandoverPaths(directory: directory).socketURL

        // Accept zurückhalten, bis das Kind `exec` hinter sich hat.
        let gate = DispatchSemaphore(value: 0)
        keeper.queue.async { gate.wait() }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(sock, 0)
        let address = UnsafeMutablePointer<sockaddr_un>.allocate(capacity: 1)
        defer { address.deallocate() }
        address.initialize(to: try XCTUnwrap(HandoverSocket.makeAddress(socketURL.path)))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("5"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, nil)
        if pid == 0 {
            _ = address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
            argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in _ = execve("/bin/sleep", a.baseAddress, e.baseAddress) }
            }
            _exit(127)
        }
        XCTAssertGreaterThan(pid, 0)
        defer {
            close(master)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) {
            HandoverPeer.executablePath(of: pid).map(HandoverPeerPolicy.normalized) == HandoverPeerPolicy.normalized("/bin/sleep")
        }, "Kind führt das erlaubte Binary aus")
        gate.signal()

        // Der Elternprozess spricht über die Verbindung des Kindes.
        let connection = HandoverConnection(fd: sock)
        defer { connection.close() }
        var hello = HandoverMessage(type: .hello)
        hello.role = .take
        hello.protocolRange = [1, 1]
        try connection.send(hello, timeout: 5)
        let reply = try connection.receive(timeout: 10)
        XCTAssertEqual(reply.message.type, .error)
        XCTAssertTrue(reply.message.message?.contains("nur die App") ?? false, reply.message.message ?? "")
    }

    /// Zweite Variante: Das Kind schickt sein HELLO noch vor dem `exec`, der
    /// Elternprozess will danach die Chats auflisten. Beim HELLO sieht der
    /// Aufbewahrer das erlaubte Binary, beim LIST den Elternprozess.
    func testParentSpeakingAfterChildHelloIsRefused() throws {
        let keeper = try makeKeeper(allowed: ["/bin/sleep"])
        let child = try spawn { try .ticking(in: directory) }
        XCTAssertNil(keeper.queue.sync { () -> String? in
            let problem = keeper.addChat(manifest: child.manifest(chatID: "a"), descriptor: dup(child.master), image: [])
            keeper.commit()
            return problem
        })
        let socketURL = HandoverPaths(directory: directory).socketURL
        let gate = DispatchSemaphore(value: 0)
        keeper.queue.async { gate.wait() }

        var hello = HandoverMessage(type: .hello)
        hello.role = .take
        hello.protocolRange = [1, 1]
        let json = try JSONEncoder().encode(hello)
        var frame = [UInt8]()
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: json)

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        let address = UnsafeMutablePointer<sockaddr_un>.allocate(capacity: 1)
        defer { address.deallocate() }
        address.initialize(to: try XCTUnwrap(HandoverSocket.makeAddress(socketURL.path)))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("5"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        var master: Int32 = -1
        let pid: pid_t = frame.withUnsafeBytes { framePtr in
            let pid = forkpty(&master, nil, nil, nil)
            if pid == 0 {
                _ = address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
                _ = Darwin.write(sock, framePtr.baseAddress, framePtr.count)
                argv.withUnsafeBufferPointer { a in
                    envp.withUnsafeBufferPointer { e in _ = execve("/bin/sleep", a.baseAddress, e.baseAddress) }
                }
                _exit(127)
            }
            return pid
        }
        XCTAssertGreaterThan(pid, 0)
        defer {
            close(master)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) {
            HandoverPeer.executablePath(of: pid).map(HandoverPeerPolicy.normalized) == HandoverPeerPolicy.normalized("/bin/sleep")
        })
        gate.signal()

        let connection = HandoverConnection(fd: sock)
        defer { connection.close() }
        // Ob schon das HELLO des Kindes abgelehnt wird, hängt davon ab, wem der
        // Kernel den Socket gerade zurechnet (gemessen: abgelehnt). Entscheidend
        // ist: Der Elternprozess bekommt nie eine Chatliste.
        let helloReply = try connection.receive(timeout: 10)
        if helloReply.message.type == .ok {
            try connection.send(HandoverMessage(type: .list), timeout: 5)
            let reply = try connection.receive(timeout: 10)
            XCTAssertEqual(reply.message.type, .error, "der Elternprozess bekommt keine Chatliste")
            XCTAssertNil(reply.message.chats)
        } else {
            XCTAssertEqual(helloReply.message.type, .error)
        }
        XCTAssertEqual(keeper.queue.sync { keeper.chats.count }, 1, "Chat bleibt beim Aufbewahrer")
    }

    // MARK: Geheimnis

    func testSecretIsReadFromStdinLine() {
        func read(_ text: String?) -> String? {
            var fds: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&fds), 0)
            defer { close(fds[0]) }
            if let text { _ = text.withCString { Darwin.write(fds[1], $0, strlen($0)) } }
            close(fds[1])
            return HandoverKeeperCommand.readSecret(from: fds[0], timeout: 2)
        }
        let secret = HandoverSecret.make()
        XCTAssertEqual(secret.count, 64)
        XCTAssertEqual(read(secret + "\n"), secret)
        XCTAssertNil(read("kurz\n"))
        XCTAssertNil(read(nil))
        XCTAssertTrue(HandoverSecret.matches(secret, expected: secret))
        XCTAssertFalse(HandoverSecret.matches(HandoverSecret.make(), expected: secret))
        XCTAssertFalse(HandoverSecret.matches(nil, expected: secret))
    }

    func testDepositWithWrongSecretIsRefused() throws {
        let child = try spawn { try .ticking(in: directory) }
        let secret = HandoverSecret.make()
        let keeper = HandoverKeeper(configuration: .init(
            paths: HandoverPaths(directory: directory),
            runID: "secret",
            ioTimeout: 10,
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: []),
            secret: secret,
            logToFile: false
        ))
        try keeper.start(onFinish: { _ in })
        keepers.append(keeper)

        for wrong in [nil, HandoverSecret.make()] {
            let client = try connect()
            XCTAssertThrowsError(try client.helloDeposit(secret: wrong))
            client.close()
        }
        let client = try connect()
        defer { client.close() }
        try client.helloDeposit(secret: secret)
        try client.deposit(manifest: child.manifest(chatID: "a"), descriptor: child.master, image: [])
        try client.commit()
        child.closeMaster()
    }

    // MARK: Zweiter Review

    /// Wer sich zuerst ausweist, bleibt der einzige Absender der Verbindung.
    /// Hier ohne Pfadprüfung (leere Policy): Nur die Absender-Bindung hält
    /// ein Kind auf, das über die geerbte Verbindung LIST schickt.
    func testOtherProcessCannotSpeakOnPinnedConnection() throws {
        let child = try spawn { try .ticking(in: directory) }
        let keeper = try makeKeeper()
        try depositAll([(child, child.manifest(chatID: "a"))])
        let client = try connect()
        defer { client.close() }
        _ = try client.helloTake(secret: nil)

        var list = HandoverMessage(type: .list)
        list.chatID = nil
        let json = try JSONEncoder().encode(list)
        var frame = [UInt8]()
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: json)
        let sock = client.connection.fd
        _ = fcntl(sock, F_SETFD, 0) // das Kind soll die Verbindung erben
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sleep"), strdup("3"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { argv.forEach { free($0) } }
        var master: Int32 = -1
        let pid: pid_t = frame.withUnsafeBytes { framePtr in
            let pid = forkpty(&master, nil, nil, nil)
            if pid == 0 {
                _ = Darwin.write(sock, framePtr.baseAddress, framePtr.count)
                argv.withUnsafeBufferPointer { a in
                    envp.withUnsafeBufferPointer { e in _ = execve("/bin/sleep", a.baseAddress, e.baseAddress) }
                }
                _exit(127)
            }
            return pid
        }
        HandoverSocket.setCloseOnExec(sock)
        XCTAssertGreaterThan(pid, 0)
        defer {
            close(master)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        let reply = try client.connection.receive(timeout: 10)
        XCTAssertEqual(reply.message.type, .error, "fremder Absender auf gebundener Verbindung")
        XCTAssertNil(reply.message.chats)
        XCTAssertEqual(keeper.queue.sync { keeper.chats.count }, 1)
    }

    func testTakeAndReleaseRequireSecret() throws {
        let child = try spawn { try .ticking(in: directory) }
        let secret = HandoverSecret.make()
        let finished = expectation(description: "Ende")
        let keeper = HandoverKeeper(configuration: .init(
            paths: HandoverPaths(directory: directory),
            runID: "secret-take",
            ioTimeout: 10,
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: []),
            secret: secret,
            logToFile: false
        ))
        try keeper.start(onFinish: { _ in finished.fulfill() })
        keepers.append(keeper)
        let deposit = try connect()
        try deposit.helloDeposit(secret: secret)
        try deposit.deposit(manifest: child.manifest(chatID: "a"), descriptor: child.master, image: [])
        try deposit.commit()
        deposit.close()
        child.closeMaster()

        for wrong in [nil, HandoverSecret.make()] {
            let take = try connect()
            XCTAssertThrowsError(try take.helloTake(secret: wrong))
            take.close()
            let release = try connect()
            XCTAssertThrowsError(try release.release(secret: wrong))
            release.close()
        }
        XCTAssertEqual(keeper.queue.sync { keeper.phase }, .holding, "nichts freigegeben")
        XCTAssertTrue(child.isAlive)

        let release = try connect()
        try release.release(secret: secret)
        release.close()
        wait(for: [finished], timeout: 15)
        XCTAssertNotNil(child.waitForExit(timeout: 10))
    }

    /// Kommt das OK auf COMMIT nicht an, bekommt der Aufbewahrer SIGTERM.
    func testFailedCommitSendsSigtermToKeeper() throws {
        let stand = try spawn {
            try .spawn(script: "trap 'echo TERM >> \"$MARKER\"; exit 143' TERM; : > \"$READY\"; while :; do sleep 0.1; done", in: directory)
        }
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let client = HandoverClient(connection: HandoverConnection(fd: fds[0]), timeout: 5)
        let server = HandoverConnection(fd: fds[1])
        defer { client.close(); server.close() }
        client.keeperPID = stand.pid
        DispatchQueue.global().async {
            _ = try? server.receive(timeout: 5) // COMMIT
            server.close() // kein OK
        }
        XCTAssertThrowsError(try client.commit())
        XCTAssertNotNil(stand.waitForExit(timeout: 10))
        XCTAssertTrue(stand.marker.contains("TERM"))
    }

    func testIdleConnectionsDoNotBlockOthers() throws {
        _ = try makeKeeper()
        var idle: [HandoverClient] = []
        for _ in 0..<8 { idle.append(try connect()) }
        defer { idle.forEach { $0.close() } }
        let status = try connect().status()
        XCTAssertEqual(status.runID, "hardening")
    }
}
