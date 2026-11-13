import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Vic zu 0b4697e3: Den Aufbewahrer beendet die App nur bei echter Ablehnung
/// (falsches Geheimnis, fremder Absender). Eine Zeitüberschreitung beim HELLO
/// bekommt genau einen neuen Versuch, „belegt“ beendet nichts. Und eine
/// zweite Instanz, die beim Start die Sperre gehalten findet, tut nichts.
@MainActor
final class HandoverTakeHelloTests: XCTestCase {
    private var directory: URL!
    private var paths: HandoverPaths { HandoverPaths(directory: directory) }

    override func setUp() async throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Schein-Aufbewahrer im Testprozess: antwortet auf STATUS wie ein echter
    /// (PID = Testprozess, damit die Prüfung des Gegenübers passt) und auf
    /// HELLO nach `hello`.
    private final class FakeKeeper: @unchecked Sendable {
        enum Hello { case reject, busy, silent }
        let listenFD: Int32
        let hello: Hello
        private let lock = NSLock()
        private var _hellos = 0
        var hellos: Int { lock.lock(); defer { lock.unlock() }; return _hellos }

        init(path: String, hello: Hello) throws {
            self.hello = hello
            listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
            HandoverSocket.setCloseOnExec(listenFD)
            guard var addr = HandoverSocket.makeAddress(path) else { throw HandoverWireError.io(EINVAL) }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(listenFD, 8) == 0 else { throw HandoverWireError.io(errno) }
            Thread.detachNewThread { [self] in serve() }
        }

        func stop() { Darwin.shutdown(listenFD, SHUT_RDWR); Darwin.close(listenFD) }

        private func serve() {
            while true {
                let fd = Darwin.accept(listenFD, nil, nil)
                guard fd >= 0 else { return }
                let connection = HandoverConnection(fd: fd)
                guard let received = try? connection.receive(timeout: 5) else { continue }
                switch received.message.type {
                case .status:
                    var reply = HandoverMessage(type: .statusResult)
                    reply.status = HandoverKeeperStatus(
                        runID: "r1", pid: getpid(), phase: "holding",
                        protocolRange: [HandoverProtocol.supported.lowerBound, HandoverProtocol.supported.upperBound],
                        build: "test", startedAt: 0, deadline: nil, chats: [])
                    try? connection.send(reply, timeout: 2)
                case .hello:
                    lock.lock(); _hellos += 1; lock.unlock()
                    switch hello {
                    case .reject: try? connection.send(.rejected("ohne gültigen Nachweis", reason: "secret"), timeout: 2)
                    case .busy: try? connection.send(.error("belegt"), timeout: 2)
                    case .silent: usleep(800_000)
                    }
                default:
                    break
                }
                connection.close()
            }
        }
    }

    /// Wie nach einer Abgabe: Marker „übergeben“ mit Lauf r1, Geheimnis da.
    private func takeService(terminated: @escaping (Int32) -> Void) -> HandoverTakeService {
        let markerURL = directory.appendingPathComponent("running-sessions.json")
        let old = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in false })
        _ = old.beginRun()
        old.markHandedOver(.init(keeperPID: getpid(), keeperStartTime: nil, runID: "r1", chats: []))
        let secrets = FakeSecretStore()
        secrets.stored = HandoverSecret.make()
        var dependencies = HandoverTakeService.Dependencies(
            paths: paths, secretStore: secrets,
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in false }),
            sessions: { [] }, adopt: { _, _ in false }, showEnded: { _, _ in }, scheduleResume: { _ in })
        dependencies.ioTimeout = 0.4
        dependencies.terminateProcess = terminated
        dependencies.killProcess = { _ in XCTFail("kein SIGKILL") }
        return HandoverTakeService(dependencies: dependencies)
    }

    private func run(_ hello: FakeKeeper.Hello) throws -> (hellos: Int, terminated: [Int32]) {
        let keeper = try FakeKeeper(path: paths.preferredSocketURL.path, hello: hello)
        defer { keeper.stop() }
        var terminated: [Int32] = []
        _ = takeService(terminated: { terminated.append($0) }).takeAtLaunch()
        return (keeper.hellos, terminated)
    }

    func testRealRejectionEndsTheKeeper() throws {
        let result = try run(.reject)
        XCTAssertEqual(result.hellos, 1)
        XCTAssertEqual(result.terminated, [getpid()])
    }

    func testBusyEndsNothing() throws {
        let result = try run(.busy)
        XCTAssertEqual(result.hellos, 1)
        XCTAssertTrue(result.terminated.isEmpty, "„belegt“ ist keine Ablehnung")
    }

    func testTimeoutIsRetriedOnceAndEndsNothing() throws {
        let result = try run(.silent)
        XCTAssertEqual(result.hellos, 2, "genau ein neuer Versuch")
        XCTAssertTrue(result.terminated.isEmpty)
    }

    /// Zweite Instanz beim Start: Hält eine andere die Sperre, wird weder
    /// übernommen noch beendet, und der Marker bleibt für die erste stehen.
    func testSecondInstanceWithHeldTakeLockDoesNothing() throws {
        let keeper = try FakeKeeper(path: paths.preferredSocketURL.path, hello: .reject)
        defer { keeper.stop() }
        let other = open(paths.takeLockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        defer { close(other) }
        var terminated: [Int32] = []
        let summary = takeService(terminated: { terminated.append($0) }).takeAtLaunch()
        XCTAssertEqual(keeper.hellos, 0, "keine Übernahme")
        XCTAssertTrue(terminated.isEmpty, "nichts beendet")
        XCTAssertTrue(summary.handled.isEmpty)
    }
}
