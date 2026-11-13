import Foundation
import XCTest

/// Wächter für `scripts/handover-soak-faults.sh` (Fehler-Szenarien der
/// Rückfall-Wege). Der echte Lauf braucht Paket 4 und die Test-Instanz; hier
/// nur, was ohne App prüfbar ist, und dass das Skript nichts außerhalb der
/// Test-Instanz anfasst — es tötet Prozesse und schreibt Defaults.
final class HandoverSoakFaultsScriptTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var script: URL { root.appendingPathComponent("scripts/handover-soak-faults.sh") }

    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func code() throws -> String {
        try String(contentsOf: Self.script, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
    }

    func testScriptIsExecutableAndParses() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.script.path))
        let result = try run(["-n", Self.script.path])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testCheckFunctionsPassSelfTest() throws {
        let result = try run([Self.script.path, "self-test"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("self-test: alles ok"), result.output)
        XCTAssertFalse(result.output.contains("FAIL"), result.output)
    }

    /// Unbekanntes Szenario und relative Wurzel brechen ab, bevor irgendetwas
    /// an der Test-Instanz passiert.
    func testUsageErrorsNeverStartARun() throws {
        XCTAssertEqual(try run([Self.script.path, "gibtsnicht"]).status, 64)
        XCTAssertEqual(try run([Self.script.path, "self-test", "--bogus"]).status, 64)
        let relative = try run([Self.script.path, "self-test"], environment: ["WHISPERM8_TEST_ROOT": "~/soak"])
        XCTAssertEqual(relative.status, 64, relative.output)
    }

    func testScriptOnlyTouchesTheTestInstance() throws {
        let code = try code()
        for forbidden in ["make dev", "make kill", "make run", "make install", "make clean-install",
                          "pkill", "killall", "claude --bg", "claude attach", "/Applications/WhisperM8.app",
                          "git stash", "git push", "security delete", "security add"] {
            XCTAssertFalse(code.contains(forbidden), "verboten im Skript: \(forbidden)")
        }
        XCTAssertNil(code.range(of: #"com\.whisperm8\.app[^.]"#, options: .regularExpression), "Produktiv-Defaults-Domain")
        XCTAssertTrue(code.contains(#"TEST_DOMAIN="com.whisperm8.app.test""#))
        // Defaults nur in der Domain der Test-Instanz.
        for line in code.split(separator: "\n") where line.contains("defaults write") || line.contains("defaults delete") {
            XCTAssertTrue(line.contains("\"$TEST_DOMAIN\""), "Defaults außerhalb der Test-Domain: \(line)")
        }
        // Das Binary nur mit ausdrücklicher Test-Wurzel.
        for line in code.split(separator: "\n") where line.contains("\"$BIN\" ") && !line.contains("-x \"$BIN\"") {
            XCTAssertTrue(line.contains("WHISPERM8_INSTANCE_ROOT=\"$ROOT\""), "Aufruf ohne Test-Wurzel: \(line)")
        }
        // SIGKILL nur über kill_keeper, das die Kommandozeile prüft.
        // (`kill -0` prüft nur, ob ein Prozess lebt, und sendet nichts.)
        let killLines = code.split(separator: "\n").filter {
            ($0.contains("kill -") && !$0.contains("kill -0")) || $0.contains("kill \"-")
        }
        XCTAssertEqual(killLines.count, 1, "nur kill_keeper sendet Signale: \(killLines)")
        XCTAssertTrue(code.contains(#"[[ "$command" == *"handover-keeper --root $ROOT"* ]]"#))
    }

    func testFaultScriptReusesTheSoakLibrary() throws {
        let code = try code()
        XCTAssertTrue(code.contains("source \"$(cd \"$(dirname \"$0\")\" && pwd)/handover-soak.sh\""))
        let soak = try String(contentsOf: Self.root.appendingPathComponent("scripts/handover-soak.sh"), encoding: .utf8)
        XCTAssertTrue(soak.contains(#"if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then"#), "handover-soak.sh als Bibliothek ladbar")
    }
}
