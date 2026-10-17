import Foundation
import XCTest
@testable import WhisperM8

final class ClaudeSessionRegistryTests: XCTestCase {
    private func recordJSON(
        pid: Int = 4711,
        sessionID: String = "sess-1",
        status: String? = "busy",
        waitingFor: String? = nil,
        updatedAt: Double = 1_792_233_246_345,
        socket: String? = "/tmp/cc-socks/4711.sock",
        extra: String = ""
    ) -> Data {
        var fields = [
            "\"pid\": \(pid)",
            "\"sessionId\": \"\(sessionID)\"",
            "\"cwd\": \"/repo\"",
            "\"kind\": \"interactive\"",
            "\"name\": \"repo-ab\"",
            "\"statusUpdatedAt\": \(updatedAt)",
            "\"procStart\": \"Sat Oct 17 10:34:05 2026\"",
            "\"version\": \"2.1.302\"",
        ]
        if let status { fields.append("\"status\": \"\(status)\"") }
        if let waitingFor { fields.append("\"waitingFor\": \"\(waitingFor)\"") }
        if let socket { fields.append("\"messagingSocketPath\": \"\(socket)\"") }
        if !extra.isEmpty { fields.append(extra) }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    // MARK: Parser

    func testParseReadsAllKnownFields() throws {
        let record = try XCTUnwrap(ClaudeSessionRegistry.parse(
            data: recordJSON(status: "waiting", waitingFor: "input needed"), profileName: "ai2"))
        XCTAssertEqual(record.profileName, "ai2")
        XCTAssertEqual(record.pid, 4711)
        XCTAssertEqual(record.sessionID, "sess-1")
        XCTAssertEqual(record.cwd, "/repo")
        XCTAssertEqual(record.kind, "interactive")
        XCTAssertEqual(record.name, "repo-ab")
        XCTAssertEqual(record.status, .waiting)
        XCTAssertEqual(record.waitingFor, "input needed")
        XCTAssertEqual(record.statusUpdatedAt, Date(timeIntervalSince1970: 1_792_233_246.345))
        XCTAssertEqual(record.messagingAddress, "uds:/tmp/cc-socks/4711.sock")
        XCTAssertEqual(record.version, "2.1.302")
        XCTAssertFalse(record.isBackground)
    }

    func testParseIgnoresUnknownFieldsAndKeepsUnknownStatusRaw() throws {
        let record = try XCTUnwrap(ClaudeSessionRegistry.parse(
            data: recordJSON(status: "dreaming", extra: "\"peerFeatures\": [\"x\"], \"tempo\": \"active\""),
            profileName: "main"))
        XCTAssertNil(record.status)
        XCTAssertEqual(record.rawStatus, "dreaming")
        XCTAssertNil(ClaudeSessionRegistry.runtimeStatus(for: record))
    }

    func testParseRejectsBrokenOrIncompleteRecords() {
        XCTAssertNil(ClaudeSessionRegistry.parse(data: Data("{kaputt".utf8), profileName: "main"))
        XCTAssertNil(ClaudeSessionRegistry.parse(data: Data("{\"pid\": 12}".utf8), profileName: "main"))
        XCTAssertNil(ClaudeSessionRegistry.parse(data: Data("{\"sessionId\": \"x\"}".utf8), profileName: "main"))
        XCTAssertNil(ClaudeSessionRegistry.parse(data: Data("[1,2]".utf8), profileName: "main"))
    }

    func testMissingSocketHasNoAddress() throws {
        let record = try XCTUnwrap(ClaudeSessionRegistry.parse(data: recordJSON(socket: nil), profileName: "main"))
        XCTAssertNil(record.messagingAddress)
    }

    func testPIDFromFileNameOnlyAcceptsRegistryFiles() {
        XCTAssertEqual(ClaudeSessionRegistry.pid(fromFileName: "92648.json"), 92648)
        XCTAssertNil(ClaudeSessionRegistry.pid(fromFileName: "92648.1399ab.key"))
        XCTAssertNil(ClaudeSessionRegistry.pid(fromFileName: "abc.json"))
        XCTAssertNil(ClaudeSessionRegistry.pid(fromFileName: ".json"))
        XCTAssertNil(ClaudeSessionRegistry.pid(fromFileName: "92648.json.tmp"))
    }

    // MARK: Abbildung

    func testRuntimeStatusMapping() throws {
        func map(_ status: String) throws -> AgentSessionRuntimeStatus? {
            ClaudeSessionRegistry.runtimeStatus(for: try XCTUnwrap(
                ClaudeSessionRegistry.parse(data: recordJSON(status: status), profileName: "main")))
        }
        XCTAssertEqual(try map("busy"), .working)
        XCTAssertEqual(try map("waiting"), .awaitingInput)
        XCTAssertEqual(try map("idle"), .idle)
        XCTAssertEqual(try map("shell"), .idle)
    }

    // MARK: Scan

    func testScanReadsAllProfilesAndSkipsDeadKeyAndBrokenFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("main", isDirectory: true)
        let ai2 = base.appendingPathComponent("ai2", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ai2, withIntermediateDirectories: true)
        try recordJSON(pid: 100, sessionID: "a").write(to: main.appendingPathComponent("100.json"))
        try recordJSON(pid: 200, sessionID: "b", status: "idle").write(to: ai2.appendingPathComponent("200.json"))
        try recordJSON(pid: 300, sessionID: "dead").write(to: ai2.appendingPathComponent("300.json"))
        try Data("token".utf8).write(to: ai2.appendingPathComponent("200.abcdef.key"))
        try Data("{kaputt".utf8).write(to: ai2.appendingPathComponent("400.json"))

        let records = ClaudeSessionRegistry.scan(
            roots: [.init(profileName: "main", url: main),
                    .init(profileName: "ai2", url: ai2),
                    .init(profileName: "fehlt", url: base.appendingPathComponent("gibtsnicht"))],
            isAlive: { pid, _ in pid != 300 })
        let byID = ClaudeSessionRegistry.indexBySessionID(records)
        XCTAssertEqual(Set(byID.keys), ["a", "b"])
        XCTAssertEqual(byID["a"]?.profileName, "main")
        XCTAssertEqual(byID["b"]?.profileName, "ai2")
        XCTAssertEqual(byID["b"]?.status, .idle)
    }

    func testIndexPrefersMostRecentlyUpdatedDuplicate() throws {
        let older = try XCTUnwrap(ClaudeSessionRegistry.parse(
            data: recordJSON(pid: 1, sessionID: "x", status: "busy", updatedAt: 1000), profileName: "main"))
        let newer = try XCTUnwrap(ClaudeSessionRegistry.parse(
            data: recordJSON(pid: 2, sessionID: "x", status: "idle", updatedAt: 2000), profileName: "main"))
        XCTAssertEqual(ClaudeSessionRegistry.indexBySessionID([newer, older])["x"]?.pid, 2)
        XCTAssertEqual(ClaudeSessionRegistry.indexBySessionID([older, newer])["x"]?.pid, 2)
    }

    // MARK: Prozess-Prüfung

    func testOwnProcessIsAliveAndStartTimeMatches() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try XCTUnwrap(ClaudeSessionRegistry.processStartTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        XCTAssertTrue(ClaudeSessionRegistry.isProcessAlive(pid: pid, procStart: formatter.string(from: start)))
        formatter.timeZone = .current
        XCTAssertTrue(ClaudeSessionRegistry.isProcessAlive(pid: pid, procStart: formatter.string(from: start)))
        XCTAssertTrue(ClaudeSessionRegistry.isProcessAlive(pid: pid, procStart: nil))
        // Andere Startzeit = PID wurde wiederverwendet → nicht derselbe Prozess.
        XCTAssertFalse(ClaudeSessionRegistry.isProcessAlive(pid: pid, procStart: "Mon Jan 1 00:00:00 2001"))
    }

    func testDeadPIDIsNotAlive() {
        XCTAssertFalse(ClaudeSessionRegistry.isProcessAlive(pid: 0, procStart: nil))
        XCTAssertFalse(ClaudeSessionRegistry.isProcessAlive(pid: 99_999_999, procStart: nil))
    }

    func testProcStartParserToleratesDoubleSpaces() {
        XCTAssertFalse(ClaudeSessionRegistry.parseProcStartCandidates("Sat Oct  4 09:32:08 2026").isEmpty)
        XCTAssertTrue(ClaudeSessionRegistry.parseProcStartCandidates("gestern").isEmpty)
    }

    // MARK: chats address

    func testAddressLogicOutcomes() throws {
        let record = try XCTUnwrap(ClaudeSessionRegistry.parse(data: recordJSON(sessionID: "ext"), profileName: "ai2"))
        let noSocket = try XCTUnwrap(ClaudeSessionRegistry.parse(
            data: recordJSON(sessionID: "ext2", socket: nil), profileName: "ai2"))
        let registry = ["ext": record, "ext2": noSocket]
        XCTAssertEqual(ChatsAddressLogic.resolve(provider: .claude, externalSessionID: "ext", registry: registry),
                       .address(record))
        XCTAssertEqual(ChatsAddressLogic.resolve(provider: .codex, externalSessionID: "ext", registry: registry),
                       .unavailable(.notClaude))
        XCTAssertEqual(ChatsAddressLogic.resolve(provider: .claude, externalSessionID: nil, registry: registry),
                       .unavailable(.notBound))
        XCTAssertEqual(ChatsAddressLogic.resolve(provider: .claude, externalSessionID: "weg", registry: registry),
                       .unavailable(.notRunning))
        XCTAssertEqual(ChatsAddressLogic.resolve(provider: .claude, externalSessionID: "ext2", registry: registry),
                       .unavailable(.noInbox))
    }

    func testAddressParser() throws {
        XCTAssertEqual(try ChatsAddressCommand.parse(["abc", "--json"]), ChatsAddressOptions(ref: "abc", json: true))
        XCTAssertThrowsError(try ChatsAddressCommand.parse([]))
        XCTAssertThrowsError(try ChatsAddressCommand.parse(["a", "b"]))
        XCTAssertThrowsError(try ChatsAddressCommand.parse(["a", "--wat"]))
    }

    func testProfileNamesListMainFirstWithoutLockDirs() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude-profiles", isDirectory: true)
        for name in ["ai2", "PowerUser", "PowerUser.lock"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("ccs.zsh"))
        let profiles = ClaudeAccountProfiles(homeDirectory: home)
        XCTAssertEqual(profiles.profileNames(), ["main", "PowerUser", "ai2"])
        XCTAssertEqual(ClaudeSessionRegistry.roots(profiles: profiles).map(\.url.lastPathComponent),
                       ["sessions", "sessions", "sessions"])
        XCTAssertEqual(ClaudeSessionRegistry.roots(profiles: profiles).first?.url.path,
                       home.appendingPathComponent(".claude/sessions").path)
    }
}
