import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Router-Dienst im Testprozess: Steuer-Socket, Generationsübergabe mit ACK,
/// Rückfall ohne ACK, Auslaufen. Die Prozess-Variante (echte Generationen,
/// Absturz und Neustart) steht in `ClaudeGPTRouterServiceProcessTests`.
final class ClaudeGPTRouterServiceTests: XCTestCase {
    private var upstream: SlowStreamUpstream!
    private var root: URL!
    private var services: [ClaudeGPTRouterService] = []

    override func setUpWithError() throws {
        upstream = try SlowStreamUpstream(chunkCount: 12, chunkDelay: 0.05)
        root = GPTRouterTestClient.makeRoot()
    }

    override func tearDown() {
        services.forEach { $0.router.stop() }
        services.removeAll()
        upstream.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(port: Int, takeOver: Bool, build: String = "test-build") throws -> (ClaudeGPTRouterService, DispatchSemaphore) {
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url, listenerKind: .bsdSockets)
        let exited = DispatchSemaphore(value: 0)
        var configuration = ClaudeGPTRouterService.Configuration(root: root, port: port, build: build, takeOver: takeOver)
        configuration.drainPollInterval = 0.02
        configuration.handoverAckTimeout = 2
        let service = ClaudeGPTRouterService(configuration: configuration, router: router) { _ in exited.signal() }
        services.append(service)
        try service.start().get()
        return (service, exited)
    }

    func testStatusReportsPortBuildAndServingState() throws {
        let (service, _) = try makeService(port: 0, takeOver: false)
        let status = try XCTUnwrap(ClaudeGPTRouterServiceClient.status(root: root))
        XCTAssertEqual(status.port, service.router.listeningPort)
        XCTAssertEqual(status.build, "test-build")
        XCTAssertEqual(status.state, "serving")
        XCTAssertEqual(status.generation, 1)
        // Socket-Ordner nur für den Besitzer.
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testSecondFreshStartOnSamePortFails() throws {
        let (first, _) = try makeService(port: 0, takeOver: false)
        let port = try XCTUnwrap(first.router.listeningPort)
        let otherRoot = GPTRouterTestClient.makeRoot()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let url = URL(string: "http://127.0.0.1:\(upstream.port)")!
        let router = ClaudeGPTMixRouter(codexProxyURL: url, anthropicURL: url, listenerKind: .bsdSockets)
        let second = ClaudeGPTRouterService(
            configuration: .init(root: otherRoot, port: port, build: "x", takeOver: false),
            router: router
        ) { _ in }
        guard case .failure = second.start() else {
            return XCTFail("Zwei lauschende Sockets auf einem Port dürfen nicht entstehen")
        }
    }

    /// Kern von Paket 3: Generationsübergabe zehnmal hintereinander, jedes Mal
    /// mit einem laufenden Strom durch die alte Generation. Die alte bringt
    /// ihn zu Ende und beendet sich erst danach; Anfragen während der
    /// Übergabe bedient die neue.
    func testTenGenerationHandoversWithRunningStreamLoseNothing() throws {
        var (current, currentExit) = try makeService(port: 0, takeOver: false)
        let port = try XCTUnwrap(current.router.listeningPort)
        let expected = SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount)

        for round in 1...10 {
            let streamDone = expectation(description: "Strom \(round)")
            var result: Result<(status: String, body: Data), Error>?
            DispatchQueue.global().async {
                result = Result { try GPTRouterTestClient.stream(port: port) }
                streamDone.fulfill()
            }
            // Warten, bis der Strom wirklich in der alten Generation läuft.
            let started = Date()
            while current.router.activeConnectionCount == 0, Date().timeIntervalSince(started) < 3 {
                Thread.sleep(forTimeInterval: 0.005)
            }
            XCTAssertEqual(current.router.activeConnectionCount, 1, "Runde \(round): Strom nicht angekommen")

            let (next, nextExit) = try makeService(port: port, takeOver: true)
            XCTAssertEqual(next.generation, round + 1)
            XCTAssertEqual(next.router.listeningPort, port)

            // Während die alte noch ausläuft: neue Anfrage geht an die neue.
            let during = try GPTRouterTestClient.stream(port: port)
            XCTAssertTrue(during.status.hasPrefix("HTTP/1.1 200"), "Runde \(round): \(during.status)")
            XCTAssertEqual(during.body, expected)

            wait(for: [streamDone], timeout: 10)
            XCTAssertEqual(currentExit.wait(timeout: .now() + 5), .success, "Runde \(round): alte Generation endet nicht")
            let streamed = try XCTUnwrap(result).get()
            XCTAssertTrue(streamed.status.hasPrefix("HTTP/1.1 200"), "Runde \(round): \(streamed.status)")
            XCTAssertEqual(streamed.body, expected, "Runde \(round): Strom unvollständig")
            XCTAssertEqual(current.router.activeConnectionCount, 0)

            let status = try XCTUnwrap(ClaudeGPTRouterServiceClient.status(root: root))
            XCTAssertEqual(status.generation, round + 1)
            XCTAssertEqual(status.state, "serving")
            (current, currentExit) = (next, nextExit)
        }
        XCTAssertEqual(upstream.requests, 20)
    }

    /// ACK-Regel: Bestätigt die neue Generation nicht, behält die alte ihren
    /// Socket, nimmt wieder an und ist über den Steuer-Socket erreichbar.
    func testHandoverWithoutAckRollsBackAndKeepsServing() throws {
        let (service, _) = try makeService(port: 0, takeOver: false)
        let port = try XCTUnwrap(service.router.listeningPort)
        let socketPath = ClaudeGPTRouterService.socketURL(root: root).path

        let fd = try ClaudeGPTRouterWire.connect(path: socketPath)
        try ClaudeGPTRouterWire.send(fd, ["op": "handover", "protocol": ClaudeGPTRouterService.protocolVersion, "build": "y", "pid": 1, "instanceRoot": AppInstance.testRoot?.path ?? "", "testUpstreams": false])
        let reply = try ClaudeGPTRouterWire.receive(fd)
        let passed = try XCTUnwrap(reply.descriptor, "Deskriptor fehlt")
        XCTAssertEqual(ClaudeGPTRouterSocketListener.listeningPort(of: passed), port)
        XCTAssertEqual(service.currentState, .handingOver)
        close(passed)
        close(fd) // kein ack

        let deadline = Date().addingTimeInterval(5)
        while service.currentState != .serving, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(service.currentState, .serving)
        let response = try GPTRouterTestClient.stream(port: port)
        XCTAssertTrue(response.status.hasPrefix("HTTP/1.1 200"))
        XCTAssertNotNil(ClaudeGPTRouterServiceClient.status(root: root), "Steuer-Socket nach Rückfall weg")
    }

    /// Den lauschenden Socket bekommt nur dasselbe Programm: Ein fremder
    /// Prozess des Nutzers könnte sonst den Router-Port übernehmen.
    func testHandoverRefusesForeignBinary() throws {
        let (service, _) = try makeService(port: 0, takeOver: false)
        let script = """
        import json, socket, struct, sys
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sys.argv[1])
        body = json.dumps({"op": "handover", "protocol": 1, "build": "x", "pid": 1, "instanceRoot": "", "testUpstreams": False}).encode()
        s.sendall(struct.pack(">I", len(body)) + body)
        msg, anc, flags, addr = s.recvmsg(65536, socket.CMSG_SPACE(4))
        print(json.loads(msg[4:]).get("error"), len(anc))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script, ClaudeGPTRouterService.socketURL(root: root).path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "binary 0")
        XCTAssertEqual(service.currentState, .serving)
    }

    func testHandoverRefusesForeignProtocol() throws {
        _ = try makeService(port: 0, takeOver: false)
        let fd = try ClaudeGPTRouterWire.connect(path: ClaudeGPTRouterService.socketURL(root: root).path)
        defer { close(fd) }
        try ClaudeGPTRouterWire.send(fd, ["op": "handover", "protocol": 99, "build": "y", "pid": 1])
        let reply = try ClaudeGPTRouterWire.receive(fd)
        XCTAssertNil(reply.descriptor)
        XCTAssertEqual(reply.message["ok"] as? Bool, false)
    }

    /// Beenden: Port sofort frei, der laufende Strom kommt vollständig an,
    /// erst dann endet der Dienst.
    func testShutdownFreesPortAndDrainsRunningStream() throws {
        let (service, exited) = try makeService(port: 0, takeOver: false)
        let port = try XCTUnwrap(service.router.listeningPort)
        let streamDone = expectation(description: "Strom")
        var result: Result<(status: String, body: Data), Error>?
        DispatchQueue.global().async {
            result = Result { try GPTRouterTestClient.stream(port: port) }
            streamDone.fulfill()
        }
        while service.router.activeConnectionCount == 0 { Thread.sleep(forTimeInterval: 0.005) }

        XCTAssertTrue(ClaudeGPTRouterServiceClient.shutdown(root: root))
        let deadline = Date().addingTimeInterval(2)
        while !ClaudeCodeProxyManager.isPortFree(port), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(ClaudeCodeProxyManager.isPortFree(port), "Port nach shutdown nicht frei")
        XCTAssertNil(ClaudeGPTRouterServiceClient.status(root: root))

        wait(for: [streamDone], timeout: 10)
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "Dienst endet nach dem Auslaufen nicht")
        XCTAssertEqual(try XCTUnwrap(result).get().body, SlowStreamUpstream.expectedBody(chunkCount: upstream.chunkCount))
    }

    func testCommandLineParsing() {
        XCTAssertEqual(
            GPTRouterCommand.parse(["--root", "/tmp/r", "--port", "18766", "--take-over"]),
            .init(root: URL(fileURLWithPath: "/tmp/r", isDirectory: true), port: 18766, takeOver: true, codexURL: nil, anthropicURL: nil)
        )
        XCTAssertNil(GPTRouterCommand.parse(["--port", "1"]), "ohne --root")
        XCTAssertNil(GPTRouterCommand.parse(["--root", "relativ", "--port", "1"]))
        XCTAssertNil(GPTRouterCommand.parse(["--root", "/tmp/r", "--port", "70000"]))
        XCTAssertNil(GPTRouterCommand.parse(["--root", "/tmp/r", "--port", "1", "--codex-url", "http://x"]), "Test-Upstreams nur paarweise")
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/Applications/WhisperM8.app/Contents/MacOS/WhisperM8", "gpt-router"]))
    }

    func testServiceEnvironmentKeepsOnlyWhatTheServiceNeeds() {
        let environment = ClaudeGPTRouterServiceSupervisor.serviceEnvironment([
            "HOME": "/Users/x", "PATH": "/usr/bin", AppInstance.rootEnvironmentKey: "/tmp/t",
            "WHISPERM8_SESSION_ID": "abc", "ANTHROPIC_CUSTOM_HEADERS": "secret", "CLAUDE_CONFIG_DIR": "/c",
        ])
        XCTAssertEqual(Set(environment.keys), ["HOME", "PATH", AppInstance.rootEnvironmentKey])
    }

    /// `make kill`/`make dev` und `test-instance.sh stop` treffen die App, nie
    /// den Router-Dienst (gleiches Binary, Argument `gpt-router`).
    func testKillFiltersSpareRouterService() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let makefile = try String(contentsOf: repo.appendingPathComponent("Makefile"), encoding: .utf8)
        let makeLine = try XCTUnwrap(makefile.components(separatedBy: "\n").first { $0.hasPrefix("GUI_PIDS = ") })
        let makeAwk = try XCTUnwrap(makeLine.range(of: "awk '").map { String(makeLine[$0.upperBound...].dropLast()) })
            .replacingOccurrences(of: "$$", with: "$")
            .replacingOccurrences(of: "$(APP_NAME)", with: "WhisperM8")
        let app = "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"
        let lines = [
            "101 \(app)",
            "102 \(app) gpt-router --root /x --port 18766",
            "103 \(app) agent-supervise abc",
            "104 \(app) handover-keeper --root /x --run r",
        ].joined(separator: "\n")
        XCTAssertEqual(try awk(makeAwk, lines), ["101"])

        let script = try String(contentsOf: repo.appendingPathComponent("scripts/test-instance.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("!~ / gpt-router /"), "test-instance.sh nimmt den Router-Dienst nicht aus")
        let testApp = "/tmp/WhisperM8Test.app/Contents/MacOS/WhisperM8"
        let testAwk = #"$2 ~ /\/WhisperM8Test\.app\/Contents\/MacOS\/WhisperM8$/ && $0 !~ / gpt-router / && $0 !~ / handover-keeper / {print $1}"#
        XCTAssertTrue(script.contains(testAwk))
        XCTAssertEqual(try awk(testAwk, "201 \(testApp)\n202 \(testApp) gpt-router --root /y --port 28766\n203 \(testApp) handover-keeper --root /y --run r"), ["201"])
    }

    private func awk(_ program: String, _ input: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        process.arguments = [program]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").map(String.init)
    }

    func testBuildIdentifierChangesWithExecutable() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bin-\(UUID().uuidString)")
        try Data("a".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let info: [String: Any] = ["CFBundleShortVersionString": "2.25.0", "CFBundleVersion": "225"]
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        let first = ClaudeGPTRouterBuild.identifier(executable: file, info: info)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: file.path)
        XCTAssertEqual(first, "2.25.0+225@1000")
        XCTAssertNotEqual(first, ClaudeGPTRouterBuild.identifier(executable: file, info: info))
    }
}
