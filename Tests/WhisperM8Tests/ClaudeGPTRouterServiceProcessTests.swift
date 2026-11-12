import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Router-Dienst als echter Prozess (`WhisperM8 gpt-router` aus dem
/// Build-Ordner, feste Test-Upstreams, eigene Ports und Ordner unter /tmp —
/// nie der Router der laufenden App). Prüft, was im Testprozess nicht geht:
/// Generationen in getrennten Prozessen, die sich nach der Übergabe beenden
/// (Fehlerbild „zweite Übergabe scheitert“), Absturz und Neustart.
final class ClaudeGPTRouterServiceProcessTests: XCTestCase {
    private var upstream: SlowStreamUpstream!
    private var root: URL!
    private var processes: [Process] = []

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("WhisperM8")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "WhisperM8-Binary fehlt im Build-Ordner")
        upstream = try SlowStreamUpstream(chunkCount: 15, chunkDelay: 0.05)
        root = GPTRouterTestClient.makeRoot()
    }

    override func tearDown() {
        for process in processes where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(process, timeout: 5)
        }
        processes.removeAll()
        // Generationen, die nicht dieser Prozess gestartet hat (Aufsicht).
        if let status = ClaudeGPTRouterServiceClient.status(root: root) {
            kill(status.pid, SIGKILL)
        }
        upstream?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func testFlags() -> [String] {
        let url = "http://127.0.0.1:\(upstream.port)"
        return ["--codex-url", url, "--anthropic-url", url]
    }

    @discardableResult
    private func spawn(_ arguments: [String], executable: URL? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executable ?? binary
        process.arguments = arguments + testFlags()
        process.environment = ClaudeGPTRouterServiceSupervisor.serviceEnvironment(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        return process
    }

    private func waitForServing(pid: Int32, timeout: TimeInterval = 10) -> ClaudeGPTRouterServiceStatus? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = ClaudeGPTRouterServiceClient.status(root: root), status.pid == pid, status.state == "serving" {
                return status
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// Wie `waitUntilExit`, aber mit Frist: Ein hängender Dienst macht den
    /// Test rot statt die ganze Suite anzuhalten.
    private func waitForExit(_ process: Process, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return !process.isRunning
    }

    private func waitForActive(_ minimum: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = ClaudeGPTRouterServiceClient.status(root: root), status.active >= minimum { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// Pflichttest aus dem Plan: Generationsübergabe zehnmal hintereinander
    /// mit laufendem Strom, jede Generation ein eigener Prozess, der sich
    /// nach dem Auslaufen selbst beendet.
    func testTenProcessGenerationsWithRunningStream() throws {
        let port = GPTRouterTestClient.freePort()
        var current = try spawn(["gpt-router", "--root", root.path, "--port", String(port)])
        XCTAssertNotNil(waitForServing(pid: current.processIdentifier), "erste Generation startet nicht")
        let expected = SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount)

        for round in 1...10 {
            let streamDone = expectation(description: "Strom \(round)")
            var streamed: Result<(status: String, body: Data), Error>?
            DispatchQueue.global().async {
                streamed = Result { try GPTRouterTestClient.stream(port: port) }
                streamDone.fulfill()
            }
            XCTAssertTrue(waitForActive(1), "Runde \(round): Strom läuft nicht")

            let next = try spawn(["gpt-router", "--root", root.path, "--port", String(port), "--take-over"])
            let status = waitForServing(pid: next.processIdentifier)
            XCTAssertEqual(status?.generation, round + 1, "Runde \(round): Übernahme gescheitert")

            // Anfrage mitten im Auslaufen der alten Generation.
            let during = try GPTRouterTestClient.stream(port: port)
            XCTAssertTrue(during.status.hasPrefix("HTTP/1.1 200"), "Runde \(round): \(during.status)")
            XCTAssertEqual(during.body, expected)

            wait(for: [streamDone], timeout: 15)
            let result = try XCTUnwrap(streamed).get()
            XCTAssertEqual(result.body, expected, "Runde \(round): Strom durch die alte Generation unvollständig")

            XCTAssertTrue(waitForExit(current), "Runde \(round): alte Generation endet nicht")
            XCTAssertEqual(current.isRunning ? -1 : current.terminationStatus, 0, "Runde \(round): alte Generation endete nicht sauber")
            current = next
        }
        // Nach zehn Übergaben nimmt der Socket weiter an (kein „toter“ Socket).
        for _ in 0..<5 {
            XCTAssertEqual(try GPTRouterTestClient.stream(port: port).body, expected)
        }
    }

    /// Update unter dem laufenden Dienst (make dev, brew): Die Programmdatei
    /// wird ersetzt, bevor die neue Generation übernimmt. Die alte muss ihre
    /// Signatur-Anforderung beim Start gelesen haben, sonst scheitert die
    /// Übergabe an der ersetzten Datei.
    func testTakeOverAfterBinaryWasReplacedOnDisk() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/wm8bin-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let installed = folder.appendingPathComponent("WhisperM8")
        try FileManager.default.copyItem(at: binary, to: installed)

        let port = GPTRouterTestClient.freePort()
        let old = try spawn(["gpt-router", "--root", root.path, "--port", String(port)], executable: installed)
        XCTAssertNotNil(waitForServing(pid: old.processIdentifier))

        // Wie rsync/brew: neue Datei daneben, dann per rename an den Platz.
        let staged = folder.appendingPathComponent(".WhisperM8.new")
        try FileManager.default.copyItem(at: binary, to: staged)
        XCTAssertEqual(rename(staged.path, installed.path), 0)

        let new = try spawn(["gpt-router", "--root", root.path, "--port", String(port), "--take-over"], executable: installed)
        XCTAssertEqual(waitForServing(pid: new.processIdentifier)?.generation, 2, "Übernahme nach Austausch der Datei gescheitert")
        XCTAssertTrue(waitForExit(old), "alte Generation endet nicht")
        XCTAssertEqual(try GPTRouterTestClient.stream(port: port).body, SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount))
    }

    /// SIGTERM (z. B. `make kill` ohne Ausnahme) heißt: auslaufen, nicht abbrechen.
    func testSigtermDrainsRunningStreamThenExits() throws {
        let port = GPTRouterTestClient.freePort()
        let service = try spawn(["gpt-router", "--root", root.path, "--port", String(port)])
        XCTAssertNotNil(waitForServing(pid: service.processIdentifier))
        let streamDone = expectation(description: "Strom")
        var streamed: Result<(status: String, body: Data), Error>?
        DispatchQueue.global().async {
            streamed = Result { try GPTRouterTestClient.stream(port: port) }
            streamDone.fulfill()
        }
        XCTAssertTrue(waitForActive(1))
        kill(service.processIdentifier, SIGTERM)
        wait(for: [streamDone], timeout: 15)
        XCTAssertEqual(try XCTUnwrap(streamed).get().body, SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount))
        XCTAssertTrue(waitForExit(service), "Dienst endet nach SIGTERM nicht")
        XCTAssertEqual(service.isRunning ? -1 : service.terminationStatus, 0)
    }

    private func makeSupervisor(build: String) -> ClaudeGPTRouterServiceSupervisor {
        ClaudeGPTRouterServiceSupervisor(
            root: root,
            build: build,
            spawner: { [unowned self] arguments in try self.spawn(arguments).processIdentifier },
            readyTimeout: 10,
            restartDelays: [0.1, 0.2],
            // Wie in der App: Aufsicht und Dienst sind dasselbe Programm.
            ownExecutable: binary.path
        )
    }

    /// Absturz des Dienstes: Die Aufsicht merkt das Ende per kqueue und startet
    /// neu; danach werden Anfragen wieder bedient.
    func testSupervisorRestartsCrashedService() throws {
        let port = GPTRouterTestClient.freePort()
        let probe = try spawn(["gpt-router", "--root", root.path, "--port", String(port)])
        let build = try XCTUnwrap(waitForServing(pid: probe.processIdentifier)).build
        let supervisor = makeSupervisor(build: build)
        try supervisor.ensureRunning(port: port).get()
        XCTAssertEqual(supervisor.currentPID, probe.processIdentifier, "gleicher Build: laufenden Dienst übernehmen, nicht neu starten")

        kill(probe.processIdentifier, SIGKILL)
        XCTAssertTrue(waitForExit(probe))
        let crashedAt = Date()
        var restarted: ClaudeGPTRouterServiceStatus?
        while Date().timeIntervalSince(crashedAt) < 10 {
            if let status = ClaudeGPTRouterServiceClient.status(root: root), status.pid != probe.processIdentifier, status.state == "serving" {
                restarted = status
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let status = try XCTUnwrap(restarted, "kein Neustart nach Absturz")
        XCTAssertEqual(status.port, port)
        XCTAssertEqual(supervisor.currentPID, status.pid)
        XCTAssertEqual(try GPTRouterTestClient.stream(port: port).body, SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount))
        supervisor.stop()
    }

    /// Neuer App-Build: Die Aufsicht startet eine neue Generation, die den
    /// Socket übernimmt; ein laufender Strom der alten reißt nicht ab.
    func testSupervisorTakesOverServiceFromOlderBuild() throws {
        let port = GPTRouterTestClient.freePort()
        let old = try spawn(["gpt-router", "--root", root.path, "--port", String(port)])
        XCTAssertNotNil(waitForServing(pid: old.processIdentifier))
        let streamDone = expectation(description: "Strom")
        var streamed: Result<(status: String, body: Data), Error>?
        DispatchQueue.global().async {
            streamed = Result { try GPTRouterTestClient.stream(port: port) }
            streamDone.fulfill()
        }
        XCTAssertTrue(waitForActive(1))

        let supervisor = makeSupervisor(build: "newer-build")
        try supervisor.ensureRunning(port: port).get()
        XCTAssertNotEqual(supervisor.currentPID, old.processIdentifier)
        XCTAssertEqual(ClaudeGPTRouterServiceClient.status(root: root)?.generation, 2)

        wait(for: [streamDone], timeout: 15)
        XCTAssertEqual(try XCTUnwrap(streamed).get().body, SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount))
        XCTAssertTrue(waitForExit(old), "alte Generation endet nicht")
        XCTAssertEqual(old.isRunning ? -1 : old.terminationStatus, 0)
        // Das Ende der alten Generation löst keinen Neustart aus.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(ClaudeGPTRouterServiceClient.status(root: root)?.generation, 2)

        supervisor.stop()
        let deadline = Date().addingTimeInterval(5)
        while !ClaudeCodeProxyManager.isPortFree(port), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertTrue(ClaudeCodeProxyManager.isPortFree(port), "stop() gibt den Port nicht frei")
    }
}
