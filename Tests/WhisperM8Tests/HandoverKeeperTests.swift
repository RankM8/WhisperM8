import Darwin
import Foundation
import SwiftTerm
import XCTest
@testable import WhisperM8

/// Aufbewahrer im Testprozess: Protokoll, Fristen, Rückfragen, Ende-Status.
/// Die Pflichttests mit eigenem Aufbewahrer-Prozess stehen in
/// `HandoverKeeperProcessTests`.
final class HandoverKeeperTests: XCTestCase {
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
        allowed: [String] = [],
        onFinish: @escaping (HandoverKeeper.FinishReason) -> Void = { _ in }
    ) throws -> HandoverKeeper {
        let keeper = HandoverKeeper(configuration: .init(
            paths: HandoverPaths(directory: directory),
            runID: "test-run",
            holdSeconds: hold,
            depositSeconds: deposit,
            ioTimeout: 10,
            ackTimeout: 10,
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: allowed),
            logToFile: false
        ))
        try keeper.start(onFinish: onFinish)
        keepers.append(keeper)
        return keeper
    }

    private func child(_ make: () throws -> HandoverPTYChild) rethrows -> HandoverPTYChild {
        let child = try make()
        children.append(child)
        return child
    }

    private func connect() throws -> HandoverClient {
        try HandoverClient.connect(paths: HandoverPaths(directory: directory), timeout: 10)
    }

    /// Abgabe wie die alte App: HELLO, je Chat DEPOSIT bis ACK, COMMIT — und
    /// erst nach COMMIT → OK die eigenen Leitungen schließen.
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

    // MARK: Abgabe und Übernahme

    func testDepositThenTakeKeepsChildAliveAndCarriesGapOutput() throws {
        let child = try child { try .ticking(in: directory) }
        _ = try makeKeeper()
        let app = HandoverAppDouble(fd: child.master, image: [])
        app.read(for: 0.2)
        let manifest = child.manifest(chatID: "chat-1")
        try depositAll([(child, manifest)], image: app.image)
        app.fd = -1 // gehört jetzt dem Aufbewahrer, siehe closeMaster

        usleep(400_000) // Lücke: nur der Aufbewahrer liest

        let client = try connect()
        defer { client.close() }
        let hello = try client.helloTake(secret: nil)
        XCTAssertEqual(hello.protocolVersion, 1)
        XCTAssertEqual(hello.runID, "test-run")
        let listed = try client.list()
        XCTAssertEqual(listed.map(\.manifest.chatID), ["chat-1"])
        let taken = try client.take(chatID: "chat-1")
        let fd = try XCTUnwrap(taken.descriptor)
        XCTAssertFalse(taken.exited)
        XCTAssertGreaterThan(taken.gapBytes, 0, "der Aufbewahrer liest in der Lücke mit")
        XCTAssertEqual(taken.manifest, manifest)

        let next = HandoverAppDouble(fd: fd, image: taken.image)
        next.read(for: 0.3)
        let ticks = HandoverTestSupport.ticks(in: next.text)
        XCTAssertTrue(HandoverTestSupport.isContinuous(ticks), "Ausgabe lückenlos: \(ticks)")
        XCTAssertFalse(ticks.isEmpty)
        XCTAssertTrue(child.isAlive)
        XCTAssertFalse(child.marker.contains("HUP"))
        try client.done()
        next.close()
    }

    func testAllTakenAndDoneFinishesKeeper() throws {
        let child = try child { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper { reason = $0; finished.fulfill() }
        try depositAll([(child, child.manifest(chatID: "a"))])
        let client = try connect()
        _ = try client.helloTake(secret: nil)
        let taken = try client.take(chatID: "a")
        try client.done()
        client.close()
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .allTaken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HandoverPaths(directory: directory).socketURL.path))
        XCTAssertTrue(child.isAlive, "die App hält die Leitung")
        if let fd = taken.descriptor { close(fd) }
    }

    func testTakeWithoutAckLeavesChatWithKeeper() throws {
        let child = try child { try .ticking(in: directory) }
        let keeper = try makeKeeper()
        try depositAll([(child, child.manifest(chatID: "a"))])

        let first = try connect()
        _ = try first.helloTake(secret: nil)
        let unacknowledged = try first.take(chatID: "a", acknowledge: false)
        // App stürzt vor dem ACK ab: ihre Kopie und die Verbindung sind weg.
        if let fd = unacknowledged.descriptor { close(fd) }
        first.close()

        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) {
            keeper.queue.sync { keeper.chats["a"].map { !$0.inTransfer } ?? false }
        })
        usleep(200_000)
        XCTAssertTrue(child.isAlive, "die Leitung des Aufbewahrers hält den Chat")
        XCTAssertFalse(child.marker.contains("HUP"))

        let second = try connect()
        defer { second.close() }
        _ = try second.helloTake(secret: nil)
        let taken = try second.take(chatID: "a")
        XCTAssertNotNil(taken.descriptor)
        try second.done()
        if let fd = taken.descriptor { close(fd) }
    }

    func testChatExitInGapIsReportedWithStatus() throws {
        let child = try child { try .spawn(script: "echo bye; sleep 0.2; exit 7", in: directory) }
        let keeper = try makeKeeper()
        try depositAll([(child, child.manifest(chatID: "a"))])
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) {
            keeper.queue.sync { keeper.chats["a"]?.exited ?? false }
        })
        let client = try connect()
        defer { client.close() }
        _ = try client.helloTake(secret: nil)
        let summary = try XCTUnwrap(try client.list().first)
        XCTAssertTrue(summary.exited)
        let taken = try client.take(chatID: "a")
        XCTAssertTrue(taken.exited)
        XCTAssertNil(taken.descriptor, "ein beendeter Chat braucht keine Leitung")
        let status = try XCTUnwrap(taken.exitStatus)
        XCTAssertEqual(status >> 8 & 0xFF, 7, "Exit-Code über kqueue")
        XCTAssertTrue(String(decoding: taken.image, as: UTF8.self).contains("bye"), "letztes Bild bleibt")
        try client.done()
    }

    // MARK: Fristen und Freigabe

    func testHoldDeadlineShutsDownOrderly() throws {
        let tui = try child { try .ticking(in: directory) }
        let attach = try child { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper(hold: 0.5) { reason = $0; finished.fulfill() }
        try depositAll([
            (tui, tui.manifest(chatID: "tui")),
            (attach, attach.manifest(chatID: "attach", kind: "attach", interrupt: false)),
        ])
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .holdExpired)
        XCTAssertNotNil(tui.waitForExit(timeout: 10))
        XCTAssertNotNil(attach.waitForExit(timeout: 10))
        XCTAssertEqual(tui.marker.components(separatedBy: "INT").count - 1, 2, "zweimal Ctrl+C wie heute")
        XCTAssertTrue(tui.marker.contains("HUP"))
        XCTAssertFalse(attach.marker.contains("INT"), "Attach-Clients bekommen kein Ctrl+C")
        XCTAssertTrue(attach.marker.contains("HUP"))
    }

    func testIncompatibleTakeThenReleaseShutsDownOrderly() throws {
        let tui = try child { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper { reason = $0; finished.fulfill() }
        try depositAll([(tui, tui.manifest(chatID: "tui"))])

        let client = try connect()
        defer { client.close() }
        XCTAssertThrowsError(try client.helloTake(range: 2...3, secret: nil)) { error in
            XCTAssertEqual(error as? HandoverClient.ClientError, .incompatible)
        }
        try client.release(secret: nil)
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .released)
        let st = tui.waitForExit(timeout: 10)
        XCTAssertNotNil(st)
        XCTAssertTrue(tui.marker.contains("INT"))
        XCTAssertTrue(tui.marker.contains("HUP"))
    }

    func testAbortReleasesCopiesSilently() throws {
        let child = try child { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper { reason = $0; finished.fulfill() }
        let client = try connect()
        try client.helloDeposit(secret: nil)
        try client.deposit(manifest: child.manifest(chatID: "a"), descriptor: child.master, image: [])
        // Ein späterer Schritt scheitert: die App bricht ab und behält ihre Leitung.
        try client.abort()
        client.close()
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .aborted)
        usleep(200_000)
        XCTAssertTrue(child.isAlive)
        XCTAssertEqual(child.marker, "", "kein Ctrl+C, kein SIGHUP")
    }

    func testLostDepositConnectionReleasesCopiesSilently() throws {
        let child = try child { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper { reason = $0; finished.fulfill() }
        let client = try connect()
        try client.helloDeposit(secret: nil)
        try client.deposit(manifest: child.manifest(chatID: "a"), descriptor: child.master, image: [])
        client.close()
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .depositLost)
        XCTAssertTrue(child.isAlive)
        XCTAssertEqual(child.marker, "")
    }

    func testDepositDeadlineWithoutCommitReleasesSilently() throws {
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper(deposit: 0.3) { reason = $0; finished.fulfill() }
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .depositTimeout)
    }

    func testDoneWithRemainingChatsEndsTheRestOrderly() throws {
        let kept = try child { try .ticking(in: directory) }
        let left = try child { try .ticking(in: directory) }
        let finished = expectation(description: "Ende")
        var reason: HandoverKeeper.FinishReason?
        _ = try makeKeeper { reason = $0; finished.fulfill() }
        try depositAll([(kept, kept.manifest(chatID: "kept")), (left, left.manifest(chatID: "left"))])
        let client = try connect()
        _ = try client.helloTake(secret: nil)
        let taken = try client.take(chatID: "kept")
        try client.done()
        client.close()
        wait(for: [finished], timeout: 15)
        XCTAssertEqual(reason, .doneWithRemaining)
        XCTAssertNotNil(left.waitForExit(timeout: 10))
        XCTAssertTrue(left.marker.contains("HUP"))
        XCTAssertTrue(kept.isAlive)
        if let fd = taken.descriptor { close(fd) }
    }

    // MARK: Schutz

    func testDepositWithForeignStartTimeIsRejected() throws {
        let child = try child { try .ticking(in: directory) }
        _ = try makeKeeper()
        var manifest = child.manifest(chatID: "a")
        manifest.pidStartTime = (manifest.pidStartTime ?? 0) - 3_600
        let client = try connect()
        defer { client.close() }
        try client.helloDeposit(secret: nil)
        XCTAssertThrowsError(try client.deposit(manifest: manifest, descriptor: child.master, image: [])) { error in
            guard case HandoverClient.ClientError.refused(let text)? = error as? HandoverClient.ClientError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(text.contains("Startzeit"))
        }
        XCTAssertTrue(child.isAlive)
    }

    func testSecondKeeperOnSameRootIsBusy() throws {
        _ = try makeKeeper()
        let second = HandoverKeeper(configuration: .init(
            paths: HandoverPaths(directory: directory),
            runID: "second",
            peerPolicy: HandoverPeerPolicy(allowedExecutablePaths: []),
            logToFile: false
        ))
        XCTAssertThrowsError(try second.start(onFinish: { _ in })) { error in
            XCTAssertEqual(error as? HandoverKeeper.StartError, .busy)
        }
    }

    func testForeignBinaryMayReadStatusButNotTakeOrRelease() throws {
        let child = try child { try .ticking(in: directory) }
        // Erlaubt ist nur ein anderes Binary, nicht der Testprozess.
        let keeper = try makeKeeper(allowed: ["/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"])
        // Abgabe direkt im Zustand (die Gegenseite dürfte nicht abgeben).
        let problem = keeper.queue.sync { () -> String? in
            let fd = dup(child.master)
            let result = keeper.addChat(manifest: child.manifest(chatID: "a"), descriptor: fd, image: [])
            keeper.commit()
            return result
        }
        XCTAssertNil(problem)

        let statusClient = try connect()
        XCTAssertEqual(try statusClient.status().chats.map(\.chatID), ["a"])
        statusClient.close()

        let take = try connect()
        XCTAssertThrowsError(try take.helloTake(secret: nil))
        take.close()
        let release = try connect()
        XCTAssertThrowsError(try release.release(secret: nil))
        release.close()
        XCTAssertEqual(keeper.queue.sync { keeper.phase }, .holding)
    }

    func testStatusNeverContainsTokenButListDoes() throws {
        let child = try child { try .ticking(in: directory) }
        _ = try makeKeeper()
        var manifest = child.manifest(chatID: "a")
        manifest.controlToken = "geheim-123"
        try depositAll([(child, manifest)])

        let statusClient = try connect()
        let status = try statusClient.status()
        statusClient.close()
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        XCTAssertFalse(json.contains("geheim-123"))
        XCTAssertEqual(status.phase, "holding")
        XCTAssertNotNil(status.deadline)

        let client = try connect()
        defer { client.close() }
        _ = try client.helloTake(secret: nil)
        XCTAssertEqual(try client.list().first?.manifest.controlToken, "geheim-123")
        let taken = try client.take(chatID: "a")
        try client.done()
        if let fd = taken.descriptor { close(fd) }
    }

    func testAppHandoverStatusCommandReportsKeeper() async throws {
        let child = try child { try .ticking(in: directory) }
        _ = try makeKeeper()
        try depositAll([(child, child.manifest(chatID: "chat-xyz"))])
        let status = try HandoverClient.connect(paths: HandoverPaths(directory: directory)).status()
        let text = AppCLICommand.renderText(status, now: Date())
        XCTAssertTrue(text.contains("Phase holding"))
        XCTAssertTrue(text.contains("chat-xyz".prefix(8)))
        XCTAssertTrue(AppCLICommand.renderJSON(status).contains("\"active\" : true"))
        let code = await AppCLICommand.run(arguments: ["handover-status", "--json"], paths: HandoverPaths(directory: directory))
        XCTAssertEqual(code, 0)
    }

    func testAppHandoverStatusWithoutKeeper() async {
        let code = await AppCLICommand.run(arguments: ["handover-status"], paths: HandoverPaths(directory: directory))
        XCTAssertEqual(code, 0)
        XCTAssertEqual(AppCLICommand.renderText(nil, now: Date()), "Kein Aufbewahrer aktiv.")
        XCTAssertTrue(AppCLICommand.renderJSON(nil).contains("\"active\" : false"))
        let usage = await AppCLICommand.run(arguments: ["handover"], paths: HandoverPaths(directory: directory))
        XCTAssertEqual(usage, 64)
    }
}
