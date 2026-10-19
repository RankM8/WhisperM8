import XCTest
@testable import WhisperM8

/// LR-SH-007: Die Login-Shell-Abfrage wartete ohne Frist, las stderr nie und
/// konnte so einen Chatstart auf dem Main Thread unbegrenzt blockieren.
/// LR-SH-012: Proxy- und Zertifikats-Variablen aus der Login-Shell fehlten.
final class LoginShellHardeningTests: XCTestCase {
    func testHangingShellReturnsNilWithinDeadline() {
        let start = Date()
        let snapshot = LoginShellEnvironment.queryLoginShell(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], deadline: 0.5)
        XCTAssertNil(snapshot)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testChattyStderrDoesNotBlock() throws {
        // Mehr als ein Pipe-Puffer (64 KiB) auf stderr, danach die Umgebung.
        let script = "yes x | head -c 300000 >&2; env -0"
        let snapshot = try XCTUnwrap(LoginShellEnvironment.queryLoginShell(
            executable: "/bin/sh", arguments: ["-c", script], deadline: 10))
        XCTAssertNotNil(snapshot.path)
    }

    func testParallelCallersShareOneLoad() {
        let counter = Counter()
        let env = LoginShellEnvironment(snapshotLoader: {
            counter.increment()
            Thread.sleep(forTimeInterval: 0.3)
            return LoginShellSnapshot(path: "/usr/bin", variables: [:])
        })
        let group = DispatchGroup()
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async { _ = env.path; group.leave() }
        }
        group.wait()
        XCTAssertEqual(counter.value, 1)
    }

    func testAllowlistedNetworkVariablesArePassedButNoSecrets() {
        let output = ["PATH=/opt/homebrew/bin:/usr/bin", "HTTPS_PROXY=http://proxy:8080",
                      "no_proxy=localhost", "NODE_EXTRA_CA_CERTS=/etc/ca.pem",
                      "ANTHROPIC_API_KEY=sk-geheim", "AWS_SECRET_ACCESS_KEY=x"].joined(separator: "\0") + "\0"
        let snapshot = LoginShellSnapshot.parse(envZeroOutput: Data(output.utf8))
        XCTAssertEqual(snapshot.path, "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(snapshot.variables["HTTPS_PROXY"], "http://proxy:8080")
        XCTAssertEqual(snapshot.variables["no_proxy"], "localhost")
        XCTAssertEqual(snapshot.variables["NODE_EXTRA_CA_CERTS"], "/etc/ca.pem")
        XCTAssertNil(snapshot.variables["ANTHROPIC_API_KEY"])
        XCTAssertNil(snapshot.variables["AWS_SECRET_ACCESS_KEY"])

        let env = LoginShellEnvironment(snapshotLoader: { snapshot })
        let child = env.processEnvironment(base: ["HOME": "/Users/x", "NO_PROXY": "intern"])
        XCTAssertEqual(child["HTTPS_PROXY"], "http://proxy:8080")
        XCTAssertEqual(child["NODE_EXTRA_CA_CERTS"], "/etc/ca.pem")
        XCTAssertEqual(child["NO_PROXY"], "intern,127.0.0.1,localhost,::1", "geerbter Wert gewinnt, lokale Ziele werden ergänzt")
        XCTAssertNil(child["ANTHROPIC_API_KEY"])
    }
}

extension LoginShellHardeningTests {
    func testFailedQueryIsNotCachedForever() {
        let clock = TestClock()
        let counter = Counter()
        let results = ResultSequence([nil, LoginShellSnapshot(path: "/custom/bin", variables: [:])])
        let env = LoginShellEnvironment(retryInterval: 60, now: { clock.date }, snapshotLoader: {
            counter.increment()
            return results.next()
        })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
        XCTAssertEqual(counter.value, 1, "innerhalb der Sperrfrist keine neue Abfrage")
        clock.advance(61)
        XCTAssertTrue(env.path.hasPrefix("/custom/bin"), "nach der Frist erneuter Versuch")
        XCTAssertEqual(counter.value, 2)
    }

    func testInvalidateRetriesImmediatelyAfterFailure() {
        let results = ResultSequence([nil, LoginShellSnapshot(path: "/neu/bin", variables: [:])])
        let env = LoginShellEnvironment(snapshotLoader: { results.next() })
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
        env.invalidate()
        XCTAssertTrue(env.path.hasPrefix("/neu/bin"))
    }

    func testMainThreadDoesNotWaitForSlowQuery() {
        let release = DispatchSemaphore(value: 0)
        let env = LoginShellEnvironment(isMainThread: { true }, snapshotLoader: {
            _ = release.wait(timeout: .now() + 5)
            return LoginShellSnapshot(path: "/spaet/bin", variables: [:])
        })
        let start = Date()
        XCTAssertEqual(env.path, LoginShellEnvironment.fallbackPath)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while !env.path.hasPrefix("/spaet/bin"), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(env.path.hasPrefix("/spaet/bin"), "Ergebnis der Hintergrundabfrage wird danach genutzt")
    }

    func testEnvZeroFailureFallsBackToEchoPath() throws {
        let snapshot = try XCTUnwrap(LoginShellEnvironment.queryLoginShell(
            executable: "/bin/sh", arguments: ["-c", "exit 3"],
            fallbackArguments: ["-c", "echo /x/bin:/usr/bin"], deadline: 5))
        XCTAssertEqual(snapshot.path, "/x/bin:/usr/bin")
    }

    func testNoProxyIsExtendedNotReplaced() {
        var env = ["HTTPS_PROXY": "http://p:1", "no_proxy": "corp.local, localhost"]
        LoginShellEnvironment.appendLocalNoProxy(&env)
        XCTAssertEqual(env["no_proxy"], "corp.local,localhost,127.0.0.1,::1")
        XCTAssertEqual(env["NO_PROXY"], "127.0.0.1,localhost,::1")
        var none = ["HOME": "/x"]
        LoginShellEnvironment.appendLocalNoProxy(&none)
        XCTAssertNil(none["NO_PROXY"], "ohne Proxy bleibt alles unverändert")
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
}

private final class ResultSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LoginShellSnapshot?]
    init(_ items: [LoginShellSnapshot?]) { self.items = items }
    func next() -> LoginShellSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
