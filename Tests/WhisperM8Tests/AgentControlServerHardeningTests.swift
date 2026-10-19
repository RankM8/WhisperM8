import XCTest
import Darwin
@testable import WhisperM8

/// Socket-Härtung (LR-CLI-006): Gesamtfrist je Verbindung, Eigentümerprüfung des
/// /tmp-Fallbackordners, Peer-Prüfung im Client.
final class AgentControlServerHardeningTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ctl-hard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testDripFeedingClientIsCutOffByTotalDeadline() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let (server, client) = (fds[0], fds[1])
        defer { close(server); close(client) }

        let writer = Thread {
            // 1 Byte alle 0,3 s, nie ein Zeilenende: jedes einzelne read wäre im Timeout.
            for _ in 0..<20 {
                var byte: UInt8 = 0x41
                if write(client, &byte, 1) != 1 { return }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        writer.start()

        let start = Date()
        let line = AgentControlServer.readRequestLine(server, deadline: 1.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(line)
        XCTAssertLessThan(elapsed, 2.0, "Gesamtfrist muss greifen, nicht erst nach 20 Bytes")
    }

    func testNormalRequestLineIsReadCompletely() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let payload = Data("{\"a\":1}\n".utf8)
        _ = payload.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }

        XCTAssertEqual(AgentControlServer.readRequestLine(fds[0], deadline: 1), Data("{\"a\":1}".utf8))
    }

    func testPrepareOwnedDirectoryCreatesAndTightens() throws {
        let dir = tmp.appendingPathComponent("neu")
        XCTAssertTrue(AgentControlServer.prepareOwnedDirectory(at: dir))
        var st = stat()
        lstat(dir.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)

        let loose = tmp.appendingPathComponent("lose")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(AgentControlServer.prepareOwnedDirectory(at: loose))
        lstat(loose.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func testPrepareOwnedDirectoryRejectsSymlinkAndForeignOwner() throws {
        let real = tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertFalse(AgentControlServer.prepareOwnedDirectory(at: link))
        // Fremder Eigentümer: wir behaupten, die erwartete UID sei eine andere.
        XCTAssertFalse(AgentControlServer.prepareOwnedDirectory(at: real, uid: getuid() &+ 1))
    }

    func testClientAcceptsOwnPeerUID() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        XCTAssertTrue(ChatsControlClient.isPeerCurrentUser(fds[0]))
        XCTAssertFalse(ChatsControlClient.isPeerCurrentUser(-1))
    }
}
