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
    /// Geheimnis je gestartetem Aufbewahrer (nur im Speicher, wie die App).
    private var secrets: [pid_t: String] = [:]

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
        let secret = HandoverSecret.make()
        let process = try HandoverKeeperLauncher.launch(
            executable: try HandoverTestSupport.keeperBinary(),
            arguments: HandoverKeeperLauncher.arguments(
                paths: paths,
                runID: run,
                holdSeconds: hold,
                depositSeconds: 20,
                appBinaries: [HandoverTestSupport.ownExecutablePath]
            ),
            secret: secret
        )
        processes.append(process)
        secrets[process.processIdentifier] = secret
        return process
    }

    /// HELLO der Abgabe wie die App: mit Geheimnis, runID und PID geprüft.
    private func helloDeposit(_ client: HandoverClient, keeper: Process, run: String) throws {
        try client.helloDeposit(
            secret: secrets[keeper.processIdentifier],
            expectedRunID: run,
            expectedPID: keeper.processIdentifier
        )
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
        var lastTick = HandoverTestSupport.ticks(in: app.text).last ?? 0
        let started = Date()

        for round in 1...10 {
            // Alte App gibt ab und schließt ihre Leitung erst nach COMMIT → OK.
            let keeper = try launchKeeper(run: "round-\(round)")
            let deposit = try connect()
            try helloDeposit(deposit, keeper: keeper, run: "round-\(round)")
            try deposit.deposit(manifest: manifest, descriptor: app.fd, image: app.image)
            try deposit.commit()
            app.close()
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
            // Fortschritt je Runde statt einer festen Tick-Zahl: unter Last
            // tickt das Kind langsamer, aber es muss in jeder Runde weiterlaufen.
            XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) {
                app.read(for: 0.05)
                return (HandoverTestSupport.ticks(in: app.text).last ?? 0) > lastTick
            }, "Runde \(round): Kind tickt weiter")
            lastTick = HandoverTestSupport.ticks(in: app.text).last ?? lastTick
            previousKeeper = keeper
        }

        app.read(for: 0.2)
        let ticks = HandoverTestSupport.ticks(in: app.text)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(HandoverTestSupport.isContinuous(ticks), "Ausgabe über zehn Übergaben (\(Int(elapsed)) s) lückenlos: \(ticks.prefix(5))…\(ticks.suffix(5))")
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
        try helloDeposit(client, keeper: keeper, run: "crash")
        for (child, id) in [(first, "a"), (second, "b")] {
            try client.deposit(manifest: child.manifest(chatID: id), descriptor: child.master, image: [])
        }
        try client.commit()
        first.closeMaster()
        second.closeMaster()
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
        try helloDeposit(deposit, keeper: keeper, run: "incompatible")
        try deposit.deposit(manifest: tui.manifest(chatID: "tui"), descriptor: tui.master, image: [])
        try deposit.deposit(manifest: attach.manifest(chatID: "attach", kind: "attach", interrupt: false), descriptor: attach.master, image: [])
        try deposit.commit()
        tui.closeMaster()
        attach.closeMaster()
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
        try helloDeposit(client, keeper: keeper, run: "first")
        var manifest = child.manifest(chatID: "a")
        manifest.controlToken = "token-xyz"
        try client.deposit(manifest: manifest, descriptor: child.master, image: [])
        try client.commit()
        child.closeMaster()
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

    // MARK: Nachweis der App

    func testKeeperWithoutSecretOnStdinRefusesToStart() throws {
        let process = Process()
        process.executableURL = try HandoverTestSupport.keeperBinary()
        process.arguments = HandoverKeeperLauncher.arguments(paths: paths, runID: "no-secret")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        XCTAssertTrue(HandoverTestSupport.waitForExit(process, timeout: 15))
        XCTAssertEqual(process.terminationStatus, 64)
    }

    func testDepositWithWrongSecretOrRunIsRefused() throws {
        let child = try spawnChild()
        let keeper = try launchKeeper(run: "secret")

        let wrong = try connect()
        XCTAssertThrowsError(try wrong.helloDeposit(secret: HandoverSecret.make()))
        wrong.close()

        // PID wird vor dem HELLO geprüft; der Aufbewahrer merkt davon nichts.
        let otherPID = try connect()
        XCTAssertThrowsError(try otherPID.helloDeposit(
            secret: secrets[keeper.processIdentifier], expectedPID: getpid()
        )) { XCTAssertEqual($0 as? HandoverClient.VerificationError, .wrongPID) }
        otherPID.close()

        // Falscher Lauf: erst nach dem HELLO erkennbar, die App bricht ab.
        let otherRun = try connect()
        XCTAssertThrowsError(try otherRun.helloDeposit(
            secret: secrets[keeper.processIdentifier], expectedRunID: "anderer-lauf"
        )) { XCTAssertEqual($0 as? HandoverClient.VerificationError, .wrongRunID) }
        otherRun.close()
        XCTAssertTrue(child.isAlive)
    }
}
