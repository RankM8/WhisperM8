import Darwin
import Foundation
import SwiftTerm
import XCTest
@testable import WhisperM8

/// Rahmung, Deskriptor-Übergabe, Aushandeln, Terminal ohne Fenster, CLI-Argumente.
final class HandoverProtocolTests: XCTestCase {
    private func socketPair() -> (HandoverConnection, HandoverConnection) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (HandoverConnection(fd: fds[0]), HandoverConnection(fd: fds[1]))
    }

    // MARK: Rahmung

    func testFrameWithDescriptorAndPayloadRoundTrips() throws {
        let (a, b) = socketPair()
        defer { a.close(); b.close() }
        var pipeFDs: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&pipeFDs), 0)
        defer { close(pipeFDs[0]) }

        var message = HandoverMessage(type: .deposit)
        message.manifest = HandoverManifest(chatID: "x", kind: "codex", pid: 42, cols: 120, rows: 40, sendsInterruptOnStop: true)
        let payload = Array(repeating: UInt8(0x41), count: 300_000)
        // Senden auf eigenem Thread: die Nutzlast ist größer als der Socket-Puffer.
        let sent = expectation(description: "gesendet")
        DispatchQueue.global().async {
            do { try a.send(message, descriptor: pipeFDs[1], payload: payload, timeout: 5) } catch { XCTFail("\(error)") }
            sent.fulfill()
        }
        let received = try b.receive(timeout: 5, acceptAttachments: true)
        wait(for: [sent], timeout: 5)
        close(pipeFDs[1]) // erst nach dem Empfang (ACK-Regel)

        XCTAssertEqual(received.message.type, .deposit)
        XCTAssertEqual(received.message.manifest?.cols, 120)
        XCTAssertEqual(received.payload.count, payload.count)
        let fd = try XCTUnwrap(received.descriptor)
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0, "empfangene Leitungen sind close-on-exec")
        // Der empfangene Deskriptor ist dieselbe Leitung.
        XCTAssertEqual(Darwin.write(fd, "hi", 2), 2)
        var buffer = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(read(pipeFDs[0], &buffer, 2), 2)
        XCTAssertEqual(buffer, Array("hi".utf8))
        close(fd)
    }

    func testReceiveClosesDescriptorUnlessAccepted() throws {
        let (a, b) = socketPair()
        defer { a.close(); b.close() }
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        defer { close(fds[0]) }
        try a.send(HandoverMessage(type: .list), descriptor: fds[1], timeout: 2)
        close(fds[1])
        let received = try b.receive(timeout: 2)
        XCTAssertNil(received.descriptor)
        var byte: UInt8 = 0
        XCTAssertEqual(read(fds[0], &byte, 1), 0, "letzte Kopie zu → EOF")
    }

    func testPayloadIsRejectedBeforeReadingUnlessAccepted() throws {
        let (a, b) = socketPair()
        defer { a.close(); b.close() }
        // Nur der Kopf mit angekündigter Nutzlast, die Nutzlast selbst fehlt:
        // abgelehnt wird sofort, nicht erst nach dem Lesen.
        var message = HandoverMessage(type: .take)
        message.chatID = "a"
        message.payloadBytes = 10
        let json = try JSONEncoder().encode(message)
        var frame = [UInt8]()
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: json)
        XCTAssertEqual(frame.withUnsafeBytes { Darwin.write(a.fd, $0.baseAddress, $0.count) }, frame.count)
        let started = Date()
        XCTAssertThrowsError(try b.receive(timeout: 3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "keine Wartezeit auf die Nutzlast")
    }

    func testOversizedFrameIsRejected() throws {
        let (a, b) = socketPair()
        defer { a.close(); b.close() }
        var header = UInt32(HandoverProtocol.maxFrameBytes + 1).bigEndian
        XCTAssertEqual(Darwin.write(a.fd, &header, 4), 4)
        XCTAssertThrowsError(try b.receive(timeout: 1)) { error in
            XCTAssertEqual(error as? HandoverWireError, .frameTooLarge(HandoverProtocol.maxFrameBytes + 1))
        }
    }

    func testReceiveTimesOutAndReportsClose() throws {
        let (a, b) = socketPair()
        XCTAssertThrowsError(try b.receive(timeout: 0.1)) { XCTAssertEqual($0 as? HandoverWireError, .timedOut) }
        a.close()
        XCTAssertThrowsError(try b.receive(timeout: 1)) { XCTAssertEqual($0 as? HandoverWireError, .closed) }
        b.close()
    }

    // MARK: Aushandeln und Manifest

    func testNegotiationPicksHighestCommonVersion() {
        XCTAssertEqual(HandoverProtocol.negotiate(keeper: 1...1, client: 1...2), 1)
        XCTAssertEqual(HandoverProtocol.negotiate(keeper: 1...2, client: 1...2), 2)
        XCTAssertEqual(HandoverProtocol.negotiate(keeper: 2...3, client: 1...2), 2)
        XCTAssertNil(HandoverProtocol.negotiate(keeper: 1...1, client: 2...3))
        XCTAssertNil(HandoverProtocol.negotiate(keeper: 3...4, client: 1...2))
    }

    func testManifestRoundTripsWithOpaqueParts() throws {
        var manifest = HandoverManifest(chatID: "c", kind: "claude", pid: 7, pidStartTime: 1.5, cols: 100, rows: 30, sendsInterruptOnStop: true)
        manifest.launchCommand = .object([
            "executablePath": .string("/usr/local/bin/claude"),
            "arguments": .array([.string("--resume"), .string("abc")]),
            "isBackgroundAttachFallback": .bool(false),
        ])
        manifest.pendingAccountSwitch = .object(["target": .string("work"), "since": .number(12)])
        manifest.hasComposerDraft = nil
        manifest.terminalColors = HandoverTerminalColors(foreground: "#e0e0e0", background: "#1e1e1e")
        let decoded = try JSONDecoder().decode(HandoverManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
    }

    func testMessageTypesKeepTheirWireNames() {
        // Nachrichtennamen sind Protokoll: nur ergänzen, nie umbenennen.
        let names = [HandoverMessageType.hello, .ok, .incompatible, .deposit, .ack, .commit, .abort,
                     .list, .chats, .take, .chat, .done, .release, .status, .statusResult, .error].map(\.rawValue)
        XCTAssertEqual(names, ["HELLO", "OK", "INCOMPATIBLE", "DEPOSIT", "ACK", "COMMIT", "ABORT",
                               "LIST", "CHATS", "TAKE", "CHAT", "DONE", "RELEASE", "STATUS", "STATUS_RESULT", "ERROR"])
    }

    // MARK: Pfade

    func testSocketPathFallsBackWhenTooLong() {
        let short = HandoverPaths(directory: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(short.socketURL.path, "/tmp/x/keeper.sock")
        let long = HandoverPaths(directory: URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120)))
        XCTAssertTrue(long.socketURL.path.hasPrefix("/private/tmp/whisperm8-\(getuid())-h"))
        XCTAssertTrue(ChatsControlProtocol.socketPathFits(long.socketURL))
        XCTAssertEqual(HandoverPaths.defaultDirectory().lastPathComponent, "handover")
    }

    func testPeerPolicyComparesResolvedPaths() {
        // /tmp ist ein Symlink auf /private/tmp: beide Schreibweisen gelten als gleich.
        let policy = HandoverPeerPolicy(allowedExecutablePaths: ["/tmp/../tmp"])
        XCTAssertTrue(policy.isAllowed(executablePath: "/private/tmp"))
        XCTAssertFalse(policy.isAllowed(executablePath: "/private/var"))
        XCTAssertFalse(policy.isAllowed(executablePath: nil))
        XCTAssertTrue(HandoverPeerPolicy(allowedExecutablePaths: []).isAllowed(executablePath: nil))
    }

    // MARK: Terminal ohne Fenster

    private func makeScreen(colors: HandoverTerminalColors? = nil) -> (HandoverHeadlessTerminal, () -> String) {
        var written = [UInt8]()
        let screen = HandoverHeadlessTerminal(cols: 80, rows: 24, scrollback: nil, colors: colors) { written += $0 }
        return (screen, { String(decoding: written, as: UTF8.self) })
    }

    func testAnswersCursorPositionQuery() {
        let (screen, output) = makeScreen()
        screen.feed(Array("abc\u{1B}[6n".utf8))
        XCTAssertEqual(output(), "\u{1B}[1;4R")
    }

    func testAnswersDeviceAttributes() {
        let (screen, output) = makeScreen()
        screen.feed(Array("\u{1B}[c".utf8))
        XCTAssertTrue(output().hasPrefix("\u{1B}[?"), "DA-Antwort: \(output().debugDescription)")
    }

    func testDeniesClipboardReadViaOSC52() {
        let (screen, output) = makeScreen()
        screen.feed(Array("\u{1B}]52;c;?\u{07}".utf8))
        XCTAssertEqual(output(), "", "keine Zwischenablage an die TUI")
        XCTAssertEqual(screen.deniedClipboardReads, 1)
    }

    func testReportsManifestColorsOnOSC11() {
        let (screen, output) = makeScreen(colors: HandoverTerminalColors(foreground: "#ffffff", background: "#102030"))
        screen.feed(Array("\u{1B}]11;?\u{07}".utf8))
        XCTAssertTrue(output().contains("rgb:1010/2020/3030"), output().debugDescription)
    }

    func testPlainTextSerializerRestoresTextAndCursor() {
        let (source, _) = makeScreen()
        source.feed(Array((1...40).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        source.feed(Array("\r\nprompt> ab".utf8))
        let image = HandoverPlainTextSerializer().serialize(source.terminal)

        let (restored, _) = makeScreen()
        restored.feed(image)
        XCTAssertEqual(restored.terminal.getBufferAsData(), source.terminal.getBufferAsData())
        XCTAssertEqual(restored.terminal.getCursorLocation().x, source.terminal.getCursorLocation().x)
        XCTAssertEqual(restored.terminal.getCursorLocation().y, source.terminal.getCursorLocation().y)
    }

    // MARK: CLI

    func testKeeperOptionsParseAndCapHoldAtTenMinutes() throws {
        let parsed = try HandoverKeeperCommand.parse([
            "--root", "/tmp/r", "--run", "abc", "--hold-seconds", "3600", "--deposit-seconds", "5",
            "--app-binary", "/Applications/WhisperM8.app/Contents/MacOS/WhisperM8",
        ]).get()
        XCTAssertEqual(parsed.root.path, "/tmp/r")
        XCTAssertEqual(parsed.runID, "abc")
        XCTAssertEqual(parsed.holdSeconds, 600, "Entscheidung 2: höchstens 10 Minuten")
        XCTAssertEqual(parsed.depositSeconds, 5)
        XCTAssertEqual(parsed.appBinaries.count, 1)
        XCTAssertEqual(HandoverKeeperCommand.Options().holdSeconds, 600)
        if case .success = HandoverKeeperCommand.parse(["--root", "relativ"]) { XCTFail("relativer Pfad") }
        if case .success = HandoverKeeperCommand.parse(["--bogus"]) { XCTFail("unbekanntes Argument") }
    }

    func testLauncherArgumentsMatchParser() throws {
        let paths = HandoverPaths(directory: URL(fileURLWithPath: "/tmp/h"))
        let args = HandoverKeeperLauncher.arguments(paths: paths, runID: "r1", holdSeconds: 12, depositSeconds: 3, appBinaries: ["/x/WhisperM8"])
        XCTAssertEqual(args.first, "handover-keeper")
        let parsed = try HandoverKeeperCommand.parse(Array(args.dropFirst())).get()
        XCTAssertEqual(parsed.root.path, "/tmp/h")
        XCTAssertEqual(parsed.holdSeconds, 12)
        XCTAssertEqual(parsed.appBinaries, ["/x/WhisperM8"])
    }

    func testKeeperAndAppAreCLICommands() {
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/Applications/WhisperM8.app/Contents/MacOS/WhisperM8", "handover-keeper", "--run", "x"]))
        XCTAssertTrue(CLIModeDetector.shouldRunCLI(["/usr/local/bin/whisperm8", "app", "handover-status"]))
        XCTAssertFalse(CLIModeDetector.shouldRunCLI(["/Applications/WhisperM8.app/Contents/MacOS/WhisperM8"]))
    }
}
