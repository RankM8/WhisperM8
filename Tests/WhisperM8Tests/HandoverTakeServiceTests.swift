import Darwin
import Foundation
import XCTest
@testable import WhisperM8

/// Paket 4c: Übernahme beim Start gegen einen echten Aufbewahrer-Prozess.
/// Abgabe wie die alte App (Koordinator + Marker), Übernahme wie die neue
/// (Marker lesen, Geheimnis, TAKE, Bericht). App-Objekte sind Closures.
@MainActor
final class HandoverTakeServiceTests: XCTestCase {
    private var directory: URL!
    private var children: [HandoverPTYChild] = []
    private var adoptedDescriptors: [Int32] = []

    override func setUp() async throws {
        directory = try HandoverTestSupport.makeDirectory()
    }

    override func tearDown() async throws {
        adoptedDescriptors.forEach { close($0) }
        for child in children { child.kill() }
        if let status = HandoverTakeService.status(paths: paths) { kill(status.pid, SIGKILL) }
        try? FileManager.default.removeItem(at: directory)
    }

    private var paths: HandoverPaths { HandoverPaths(directory: directory) }
    private var markerURL: URL { directory.appendingPathComponent("running-sessions.json") }

    private func marker(pid: Int32) -> AgentCrashRecoveryMarker {
        AgentCrashRecoveryMarker(fileURL: markerURL, ownPID: pid, isProcessAlive: { _ in false })
    }

    private func spawn() throws -> FakeDepositSource {
        let child = try HandoverPTYChild.ticking(in: directory)
        children.append(child)
        return FakeDepositSource(child: child, detachable: true)
    }

    private func session(for source: FakeDepositSource, kind: AgentSessionKind = .chat) -> AgentChatSession {
        AgentChatSession(id: source.sessionID, provider: .claude, projectID: UUID(), title: "t",
                         status: .running, kind: kind)
    }

    /// Alte App: abgeben und den Marker auf „übergeben“ setzen.
    private func handOver(_ sources: [FakeDepositSource], secrets: FakeSecretStore) throws -> String {
        let old = marker(pid: 100)
        _ = old.beginRun()
        let coordinator = HandoverDepositCoordinator(dependencies: .init(
            paths: paths, keeperExecutable: try HandoverTestSupport.keeperBinary(),
            appBinaries: [HandoverTestSupport.ownExecutablePath], secretStore: secrets, holdSeconds: 60))
        let outcome = coordinator.deposit(sources.map { source in
            .init(source: source) { _ in source.child.manifest(chatID: source.sessionID.uuidString) }
        })
        guard case let .handedOver(runID, keeperPID, start, chats, _) = outcome else {
            XCTFail("Abgabe gescheitert: \(outcome)")
            return ""
        }
        old.markHandedOver(.init(keeperPID: keeperPID, keeperStartTime: start, runID: runID,
                                 chats: chats.map { .init(sessionID: $0.sessionID, pid: $0.pid, pidStartTime: $0.pidStartTime) }))
        return runID
    }

    private final class Calls {
        var adopted: [UUID] = []
        var ended: [UUID] = []
        var resumed: [UUID] = []
    }

    private func service(secrets: HandoverSecretStoring, sessions: [AgentChatSession], calls: Calls,
                         adoptSucceeds: Bool = true) -> HandoverTakeService {
        HandoverTakeService(dependencies: .init(
            paths: paths, secretStore: secrets, marker: marker(pid: 200),
            sessions: { sessions },
            adopt: { [weak self] taken, session in
                guard adoptSucceeds, let fd = taken.descriptor else { return false }
                self?.adoptedDescriptors.append(fd)
                calls.adopted.append(session.id)
                return true
            },
            showEnded: { _, session in calls.ended.append(session.id) },
            scheduleResume: { calls.resumed.append(contentsOf: $0) },
            gracePeriod: 3))
    }

    func testNewAppAdoptsAllChatsAndClearsHandoverState() throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn(), try spawn()]
        let runID = try handOver(sources, secrets: secrets)
        let calls = Calls()

        let summary = service(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()

        XCTAssertEqual(Set(summary.adopted), Set(sources.map(\.sessionID)))
        XCTAssertTrue(summary.fallback.isEmpty)
        XCTAssertEqual(Set(calls.adopted), Set(sources.map(\.sessionID)))
        XCTAssertEqual(summary.handled, Set(sources.map(\.sessionID)))
        XCTAssertEqual(secrets.load(), .missing, "Geheimnis nach der Übernahme gelöscht")
        let report = try XCTUnwrap(HandoverTakeReport.read(paths: paths))
        XCTAssertEqual(report.runID, runID)
        XCTAssertTrue(report.isComplete)
        XCTAssertNil(marker(pid: 300).beginRunDetailed().handover, "Marker ohne „übergeben“")
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { HandoverTakeService.status(paths: self.paths) == nil },
                      "Aufbewahrer endet nach DONE")
        for source in sources {
            XCTAssertTrue(source.child.isAlive)
            XCTAssertFalse(source.child.marker.contains("HUP"))
        }
    }

    func testChatEndedInGapIsShownAsEnded() throws {
        let secrets = FakeSecretStore()
        let alive = try spawn(), ending = try spawn()
        _ = try handOver([alive, ending], secrets: secrets)
        ending.child.kill(SIGTERM)
        // Der Aufbewahrer vermerkt das Ende über kqueue.
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 5) {
            HandoverTakeService.status(paths: self.paths)?.chats.contains { $0.exited } == true
        })
        let calls = Calls()
        let summary = service(secrets: secrets, sessions: [session(for: alive), session(for: ending)], calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.adopted, [alive.sessionID])
        XCTAssertEqual(summary.endedInGap, [ending.sessionID])
        XCTAssertEqual(calls.ended, [ending.sessionID])
        XCTAssertTrue(calls.resumed.isEmpty, "in der Lücke beendet wird nicht automatisch neu gestartet")
    }

    /// Anders signierter Build: kein Geheimnis. Der Aufbewahrer wird beendet,
    /// die Chats enden mit ihm, erst danach kommt `--resume`.
    func testWithoutSecretKeeperIsEndedAndChatsResumeAfterTheirEnd() async throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()

        XCTAssertTrue(summary.adopted.isEmpty)
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertTrue(calls.resumed.isEmpty, "nicht fortsetzen, solange der Prozess lebt")
        let end = Date().addingTimeInterval(15)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID))
        XCTAssertFalse(sources[0].child.isAlive, "Prozess ist weg, bevor fortgesetzt wird")
        XCTAssertFalse(HandoverTakeReport.read(paths: paths)?.isComplete ?? true)
    }

    func testFailedAdoptionClosesLineAndResumesAfterExit() async throws {
        let secrets = FakeSecretStore()
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: secrets)
        let calls = Calls()
        let summary = service(secrets: secrets, sessions: sources.map { session(for: $0) }, calls: calls,
                              adoptSucceeds: false).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        let end = Date().addingTimeInterval(15)
        while calls.resumed.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID))
        XCTAssertFalse(sources[0].child.isAlive)
    }

    func testTerminalTabIsEndedButNotResumed() async throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: [session(for: sources[0], kind: .terminal)],
                              calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 15) { !sources[0].child.isAlive })
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(calls.resumed.isEmpty)
    }

    func testNormalStartWithoutHandoverDoesNothing() {
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: [], calls: calls).takeAtLaunch()
        XCTAssertNil(summary.previous.handover)
        XCTAssertTrue(summary.handled.isEmpty)
        XCTAssertNil(HandoverTakeReport.read(paths: paths))
    }

    /// Abgegeben, aber der Aufbewahrer ist inzwischen weg (abgestürzt): Die
    /// Chats bekamen SIGHUP; die neue App setzt sie fort.
    func testKeeperGoneMeansResume() throws {
        let sources = [try spawn()]
        _ = try handOver(sources, secrets: FakeSecretStore())
        let status = try XCTUnwrap(HandoverTakeService.status(paths: paths))
        kill(status.pid, SIGKILL)
        XCTAssertTrue(HandoverTestSupport.waitUntil(timeout: 10) { !sources[0].child.isAlive })
        let calls = Calls()
        let summary = service(secrets: FakeSecretStore(), sessions: sources.map { session(for: $0) }, calls: calls).takeAtLaunch()
        XCTAssertEqual(summary.fallback, sources.map(\.sessionID))
        XCTAssertEqual(calls.resumed, sources.map(\.sessionID), "tot: sofort fortsetzen")
    }
}
