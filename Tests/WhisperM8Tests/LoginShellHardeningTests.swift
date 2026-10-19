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
        XCTAssertEqual(child["NO_PROXY"], "intern", "geerbter Wert der App gewinnt")
        XCTAssertNil(child["ANTHROPIC_API_KEY"])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
