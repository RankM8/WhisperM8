import Foundation
import XCTest
@testable import WhisperM8

/// Phase-3 Test-Seam: deckt das Status-/Version-Parsing von CodexStatusProbe ab,
/// indem CLI-Auflösung und -Ausführung per Closure gefaket werden (kein echtes
/// `codex`-Binary nötig).
final class CodexStatusProbeTests: XCTestCase {
    private func probe(path: String? = "/usr/bin/codex", output: String = "") -> CodexStatusProbe {
        CodexStatusProbe(
            commandResolver: { _ in path },
            commandRunner: { _, _ in output }
        )
    }

    func testStatusNotInstalledWhenCommandMissing() {
        XCTAssertEqual(probe(path: nil).status(), .notInstalled)
    }

    func testStatusSignedInIsCaseInsensitive() {
        XCTAssertEqual(probe(output: "Logged in using ChatGPT (Plus)").status(), .signedIn)
    }

    func testStatusNotSignedInVariants() {
        XCTAssertEqual(probe(output: "Not logged in").status(), .notSignedIn)
        XCTAssertEqual(probe(output: "error: not authenticated").status(), .notSignedIn)
        XCTAssertEqual(probe(output: "You are logged out.").status(), .notSignedIn)
    }

    func testStatusInstalledWhenOutputUnrecognized() {
        XCTAssertEqual(probe(output: "codex 1.0.0 — some banner").status(), .installed)
    }

    func testVersionTrimsOutput() {
        XCTAssertEqual(probe(output: "codex-cli 1.2.3\n  ").version(), "codex-cli 1.2.3")
    }

    func testVersionNotInstalledWhenCommandMissing() {
        XCTAssertEqual(probe(path: nil).version(), "Not installed")
    }

    /// Regression für den node-Wrapper-Bug: `runProcess` MUSS das übergebene
    /// (bzw. per Default das Login-Shell-)Environment an den Subprozess geben.
    /// Vorher lief die Probe mit dem rohen GUI-Env — ein npm-installiertes
    /// `codex` (node-Shebang) scheiterte mit "env: node: No such file or
    /// directory" und alle Diktier-Modi verweigerten wegen Status .installed.
    func testRunProcessPassesEnvironmentToSubprocess() {
        let output = CodexStatusProbe.runProcess(
            "/bin/sh",
            arguments: ["-c", "echo $WHISPERM8_ENV_CHECK"],
            environment: ["WHISPERM8_ENV_CHECK": "probe-env-ok", "PATH": "/usr/bin:/bin"]
        )
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "probe-env-ok")
    }

    /// Das Default-Environment ist das Login-Shell-Env — es enthält die
    /// Homebrew-/User-Pfade, in denen node & codex liegen.
    func testRunProcessDefaultEnvironmentIsLoginShellEnvironment() {
        let output = CodexStatusProbe.runProcess("/bin/sh", arguments: ["-c", "echo $PATH"])
        let expected = LoginShellEnvironment.shared.processEnvironment()["PATH"] ?? ""
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), expected)
    }
}
