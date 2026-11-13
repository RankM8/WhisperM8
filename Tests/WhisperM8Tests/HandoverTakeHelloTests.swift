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
                // Jede Verbindung eigen: Ein schweigender HELLO darf den
                // nächsten Versuch nicht aufhalten.
                Thread.detachNewThread { [self] in handle(fd) }
            }
        }

        private func handle(_ fd: Int32) {
            do {
                let connection = HandoverConnection(fd: fd)
                guard let received = try? connection.receive(timeout: 5) else { return }
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
        usleep(200_000)   // späte Verbindungs-Threads zählen lassen
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

    /// Vic zu 027dd4e7: Prüft die CLI genau beim Start die Sperre (geteilte
    /// Sperre für einen Augenblick), ist diese App trotzdem zuständig, wenn
    /// „übergeben“ im Marker steht, und übernimmt.
    func testRaceWithCLICheckStillTakesWhenMarkerSaysHandedOver() throws {
        let keeper = try FakeKeeper(path: paths.preferredSocketURL.path, hello: .reject)
        defer { keeper.stop() }
        let cli = open(paths.takeLockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(cli, LOCK_SH | LOCK_NB), 0, "wie isHeld in app handover")
        defer { close(cli) }
        var terminated: [Int32] = []
        _ = takeService(terminated: { terminated.append($0) }).takeAtLaunch()
        XCTAssertEqual(keeper.hellos, 1, "übernommen, nicht übersprungen")
        XCTAssertEqual(terminated, [getpid()])
    }

    /// Eine kurz gehaltene Prüfung der CLI überbrückt schon der zweite Versuch.
    func testShortCLICheckDoesNotBlockTheLock() throws {
        let cli = open(paths.takeLockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(cli, LOCK_SH | LOCK_NB), 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.008) { flock(cli, LOCK_UN); close(cli) }
        guard case .acquired(let fd) = HandoverTakeLock.acquire(paths: paths, attempts: 20) else {
            return XCTFail("Sperre trotz kurzer Prüfung nicht bekommen")
        }
        HandoverTakeLock.release(fd)
    }

    /// Echte zweite Instanz: Der Besitzer des Markers lebt (also kein
    /// „übergeben“ für sie), ein Aufbewahrer ist da, und eine andere Instanz
    /// hält die Sperre. Dann übernimmt und beendet sie nichts.
    func testSecondInstanceWithoutMarkerAndHeldTakeLockDoesNothing() throws {
        let keeper = try FakeKeeper(path: paths.preferredSocketURL.path, hello: .reject)
        defer { keeper.stop() }
        try (paths.preferredSocketURL.path + "\n").write(to: paths.discoveryFileURL, atomically: true, encoding: .utf8)
        let keeperLock = open(paths.lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(keeperLock, LOCK_EX | LOCK_NB), 0, "wie der Aufbewahrer")
        defer { close(keeperLock) }
        let other = open(paths.takeLockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0, "die erste Instanz übernimmt gerade")
        defer { close(other) }

        let markerURL = directory.appendingPathComponent("running-sessions.json")
        let first = AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 100, isProcessAlive: { _ in true })
        _ = first.beginRun()
        var dependencies = HandoverTakeService.Dependencies(
            paths: paths, secretStore: FakeSecretStore(),
            marker: AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: 200, isProcessAlive: { _ in true }),
            sessions: { [] }, adopt: { _, _ in false }, showEnded: { _, _ in }, scheduleResume: { _ in })
        var terminated: [Int32] = []
        dependencies.terminateProcess = { terminated.append($0) }
        let summary = HandoverTakeService(dependencies: dependencies).takeAtLaunch()
        XCTAssertNil(summary.previous.handover)
        XCTAssertEqual(keeper.hellos, 0)
        XCTAssertTrue(terminated.isEmpty, "nichts beendet, auch nicht über terminateKeeper")
    }
}
