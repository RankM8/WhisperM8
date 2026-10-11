import Darwin
import XCTest
@testable import WhisperM8

/// Regression zum Vorfall 23.09.2026: Die App starb an einem SIGPIPE
/// (runningboardd: `(2, 13, 13)`). Ohne Guard beendet der Write unten den
/// Test-Prozess — der Test schlägt dann nicht fehl, sondern der Lauf bricht ab.
final class SigpipeGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SigpipeGuard.installNoOpHandler()
    }

    func testWriteToClosedPipeReturnsEPIPEInsteadOfKillingTheProcess() {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        close(fds[0])
        defer { close(fds[1]) }

        let byte: [UInt8] = [0x41]
        let written = write(fds[1], byte, 1)

        XCTAssertEqual(written, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testHandlerIsCaughtNotIgnoredSoExecResetsItForChildren() {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)

        XCTAssertNotEqual(handler, unsafeBitCast(SIG_IGN, to: Int.self))
        XCTAssertNotEqual(handler, unsafeBitCast(SIG_DFL, to: Int.self))
    }

    /// Wie SwiftTerms `forkpty` + `execve`: ein Spawn ohne Signal-Reset.
    /// Das Kind muss SIGPIPE wieder als Default sehen, sonst liefen die
    /// Shells in den Chat-Terminals mit ignoriertem SIGPIPE.
    func testChildSpawnedWithoutSignalResetSeesDefaultSigpipe() throws {
        var outPipe: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&outPipe), 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])

        let args = ["/usr/bin/perl", "-e", #"print $SIG{PIPE} // "DEFAULT""#]
        var cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, args[0], &actions, nil, &cArgs, environ)
        close(outPipe[1])
        XCTAssertEqual(spawnResult, 0)

        let output = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        XCTAssertEqual(String(decoding: output, as: UTF8.self), "DEFAULT")
    }

    /// Analyse 11.10.2026: Mit `SIG_IGN` für SIGTERM erbten Terminal-Tabs und
    /// alles daraus „SIGTERM ignorieren". Mit leerem Handler muss ein ohne
    /// Signal-Reset gestartetes Kind auf SIGTERM wieder sterben.
    func testChildDiesOnSIGTERMWhenParentUsesNoOpHandler() throws {
        let previous = SigpipeGuard.installNoOpHandler(for: SIGTERM)
        var restore = previous
        defer { sigaction(SIGTERM, &restore, nil) }

        let args = ["/bin/sleep", "30"]
        var cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        XCTAssertEqual(posix_spawn(&pid, args[0], nil, nil, &cArgs, environ), 0)
        usleep(100_000)
        kill(pid, SIGTERM)

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(3)
        var reaped: pid_t = 0
        while reaped == 0, Date() < deadline {
            reaped = waitpid(pid, &status, WNOHANG)
            if reaped == 0 { usleep(20_000) }
        }
        if reaped == 0 { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
        XCTAssertEqual(reaped, pid, "Kind hat SIGTERM ignoriert")
        // WIFSIGNALED/WTERMSIG als Makros nicht verfügbar: Low-Byte = Signal.
        XCTAssertEqual(status & 0x7f, SIGTERM)
    }
}
