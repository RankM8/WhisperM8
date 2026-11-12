import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Pflichttests aus dem Plan (Paket 2), mit dem Aufbewahrer als eigenem
/// Prozess aus dem gebauten Binary und `/bin/sh`-Kindern über `forkpty`:
/// - Abgabe → Übernahme → Abgabe, zehnmal hintereinander;
/// - Absturz des Aufbewahrers (SIGKILL) → die Kinder bekommen SIGHUP;
/// - unverträgliches Protokoll → `RELEASE`.
/// Der Testprozess spielt die App (alte und neue Instanz).
final class HandoverKeeperProcessTests: XCTestCase {
    private var directory: URL!
    private var children: [HandoverPTYChild] = []
    private var processes: [Process] = []

    override func setUpWithError() throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() {
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for child in children { child.kill() }
        try? FileManager.default.removeItem(at: directory)
    }

    private var paths: HandoverPaths { HandoverPaths(directory: directory) }

    /// Startet einen Aufbewahrer-Prozess, der nur den Testprozess als App gelten lässt.
    private func launchKeeper(run: String, hold: TimeInterval = 60) throws -> Process {
        let process = try HandoverKeeperLauncher.launch(
            executable: try HandoverTestSupport.keeperBinary(),
            arguments: HandoverKeeperLauncher.arguments(
                paths: paths,
                runID: run,
                holdSeconds: hold,
                depositSeconds: 20,
                appBinaries: [HandoverTestSupport.ownExecutablePath]
            )
        )
        processes.append(process)
        return process
    }

    private func connect() throws -> HandoverClient {
        let client = try HandoverClient.connect(paths: paths, timeout: 10)
        client.timeout = 10
        return client
    }

    private func spawnChild() throws -> HandoverPTYChild {
        let child = try HandoverPTYChild.ticking(in: directory)
        children.append(child)
        return child
    }

    // MARK: Zehnmal hintereinander

    func testDepositTakeDepositTenTimesInARow() throws {
        let child = try spawnChild()
        let manifest = child.manifest(chatID: "chat-1")
        var app = HandoverAppDouble(fd: child.master, image: [])
        app.read(for: 0.2)
        var previousKeeper: Process?

        for round in 1...10 {
            // Alte App gibt ab.
            let keeper = try launchKeeper(run: "round-\(round)")
            let deposit = try connect()
            let runID = try deposit.helloDeposit()
            XCTAssertEqual(runID, "round-\(round)")
            try deposit.deposit(manifest: manifest, descriptor: app.fd, image: app.image)
            app.close() // erst nach dem ACK (harte Regel)
            try deposit.commit()
            deposit.close()

            usleep(150_000) // Lücke: nur der Aufbewahrer liest

            // Neue App übernimmt.
            let take = try connect()
            let hello = try take.helloTake()
            XCTAssertEqual(hello.runID, "round-\(round)")
            XCTAssertEqual(try take.list().map(\.manifest.chatID), ["chat-1"])
            let taken = try take.take(chatID: "chat-1")
            XCTAssertFalse(taken.exited, "Runde \(round)")
            XCTAssertEqual(taken.manifest.pid, child.pid)
            try take.done()
            take.close()
            XCTAssertTrue(HandoverTestSupport.waitForExit(keeper, timeout: 15), "Aufbewahrer \(round) endet nach DONE")
            XCTAssertEqual(keeper.terminationStatus, 0)

            app = HandoverAppDouble(fd: try XCTUnwrap(taken.descriptor), image: taken.image)
            app.read(for: 0.15)
            XCTAssertTrue(child.isAlive, "Runde \(round): Kind lebt")
            XCTAssertFalse(child.marker.contains("HUP"), "Runde \(round): kein SIGHUP")
            previousKeeper = keeper
        }

        app.read(for: 0.2)
        let ticks = HandoverTestSupport.ticks(in: app.text)
        XCTAssertTrue(HandoverTestSupport.isContinuous(ticks), "Ausgabe über zehn Übergaben lückenlos: \(ticks.prefix(5))…\(ticks.suffix(5))")
        XCTAssertGreaterThan(ticks.count, 50)
        XCTAssertEqual(child.marker, "", "weder Ctrl+C noch SIGHUP")
        XCTAssertFalse(previousKeeper?.isRunning ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socketURL.path), "Socket aufgeräumt")
        app.close()
    }

    // MARK: Absturz

    func testKeeperCrashSendsSighupToChildren() throws {
        let first = try spawnChild()
        let second = try spawnChild()
        let keeper = try launchKeeper(run: "crash")
        let client = try connect()
        try client.helloDeposit()
        for (child, id) in [(first, "a"), (second, "b")] {
            try client.deposit(manifest: child.manifest(chatID: id), descriptor: child.master, image: [])
            child.closeMaster()
        }
        try client.commit()
        client.close()

        usleep(300_000)
        XCTAssertTrue(first.isAlive && second.isAlive, "der Aufbewahrer hält die Leitungen")

        kill(keeper.processIdentifier, SIGKILL)
        XCTAssertTrue(HandoverTestSupport.waitForExit(keeper, timeout: 15))
        for child in [first, second] {
            let status = try XCTUnwrap(child.waitForExit(timeout: 10), "Kind endet nach dem Absturz")
            XCTAssertTrue(child.marker.contains("HUP"), "SIGHUP angekommen")
            XCTAssertFalse(child.marker.contains("INT"), "ein Absturz schickt kein Ctrl+C")
            XCTAssertEqual(status >> 8 & 0xFF, 129)
        }
    }

    // MARK: Unverträgliches Protokoll

    func testIncompatibleProtocolLeadsToRelease() throws {
        let tui = try spawnChild()
        let attach = try spawnChild()
        let keeper = try launchKeeper(run: "incompatible")
        let deposit = try connect()
        try deposit.helloDeposit()
        try deposit.deposit(manifest: tui.manifest(chatID: "tui"), descriptor: tui.master, image: [])
        tui.closeMaster()
        try deposit.deposit(manifest: attach.manifest(chatID: "attach", kind: "attach", interrupt: false), descriptor: attach.master, image: [])
        attach.closeMaster()
        try deposit.commit()
        deposit.close()

        // Eine „neue App“, die nur Version 2 und 3 spricht.
        let take = try connect()
        XCTAssertThrowsError(try take.helloTake(range: 2...3)) { error in
            XCTAssertEqual(error as? HandoverClient.ClientError, .incompatible)
        }
        try take.release()
        take.close()

        XCTAssertTrue(HandoverTestSupport.waitForExit(keeper, timeout: 15), "Aufbewahrer endet nach RELEASE")
        XCTAssertNotNil(tui.waitForExit(timeout: 10))
        XCTAssertNotNil(attach.waitForExit(timeout: 10))
        XCTAssertEqual(tui.marker.components(separatedBy: "INT").count - 1, 2, "geordnet: zweimal Ctrl+C")
        XCTAssertTrue(tui.marker.contains("HUP"))
        XCTAssertFalse(attach.marker.contains("INT"))
        XCTAssertTrue(attach.marker.contains("HUP"))
    }

    // MARK: Lock und Status über Prozessgrenzen

    func testSecondKeeperProcessIsBusyAndStatusWorksFromOutside() throws {
        let child = try spawnChild()
        let keeper = try launchKeeper(run: "first")
        let client = try connect()
        try client.helloDeposit()
        var manifest = child.manifest(chatID: "a")
        manifest.controlToken = "token-xyz"
        try client.deposit(manifest: manifest, descriptor: child.master, image: [])
        child.closeMaster()
        try client.commit()
        client.close()

        let second = try launchKeeper(run: "second")
        XCTAssertTrue(HandoverTestSupport.waitForExit(second, timeout: 15))
        XCTAssertEqual(second.terminationStatus, HandoverKeeperCommand.busyExitCode)

        let status = try connect().status()
        XCTAssertEqual(status.runID, "first")
        XCTAssertEqual(status.pid, keeper.processIdentifier)
        XCTAssertEqual(status.chats.map(\.chatID), ["a"])
        XCTAssertFalse(AppCLICommand.renderJSON(status).contains("token-xyz"))

        // SIGTERM wie Fristende: geordnet beenden.
        kill(keeper.processIdentifier, SIGTERM)
        XCTAssertTrue(HandoverTestSupport.waitForExit(keeper, timeout: 15))
        XCTAssertNotNil(child.waitForExit(timeout: 10))
        XCTAssertTrue(child.marker.contains("INT"))
        XCTAssertTrue(child.marker.contains("HUP"))
    }
}
