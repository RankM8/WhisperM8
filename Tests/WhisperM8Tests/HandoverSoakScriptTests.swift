import Foundation
import XCTest

/// Wächter für `scripts/handover-soak.sh` (Dauerlauf „Neustart ohne
/// Chatverlust“, Paket 6). Der echte Lauf braucht die Test-Instanz und echte
/// Chats; hier geht es nur um das, was ohne App prüfbar ist: Syntax, die
/// Prüf-Funktionen (`self-test`) und dass das Skript nie die Produktiv-App
/// oder laufende Chats anfasst.
final class HandoverSoakScriptTests: XCTestCase {
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var script: URL { root.appendingPathComponent("scripts/handover-soak.sh") }

    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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

    func testUnknownCommandIsUsageError() throws {
        XCTAssertEqual(try run([Self.script.path, "gibtsnicht"]).status, 64)
        XCTAssertEqual(try run([Self.script.path, "run", "--rounds", "0"]).status, 64)
    }

    /// Ein Chat, der das Skript startet, darf weder die App beenden noch
    /// fremde Prozesse oder echte Sitzungen treffen.
    func testScriptNeverTouchesProductionAppOrRealSessions() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        for forbidden in ["make dev", "make kill", "make run", "make install", "make clean-install",
                          "pkill", "killall", "claude --bg", "claude attach", "/Applications/WhisperM8.app",
                          "git stash", "git push"] {
            XCTAssertFalse(code.contains(forbidden), "verboten im Skript: \(forbidden)")
        }
        // App-Befehle nur über die Test-Instanz: kein nacktes `whisperm8 …`.
        XCTAssertNil(code.range(of: #"(^|[\s;(])whisperm8 "#, options: .regularExpression), "nacktes whisperm8 im Skript")
        XCTAssertTrue(code.contains(#"TI="$REPO/scripts/test-instance.sh""#))
        XCTAssertTrue(code.contains(#"ROOT="${WHISPERM8_TEST_ROOT:-$HOME/.whisperm8-test-instance}""#),
                      "gleiche Wurzel wie scripts/test-instance.sh")
        XCTAssertTrue(code.contains("check_for_update_on_startup = false"), "Codex-Update-Dialog abgeschaltet")
    }

    func testRootMatchesTestInstanceScript() throws {
        let instance = try String(contentsOf: Self.root.appendingPathComponent("scripts/test-instance.sh"), encoding: .utf8)
        XCTAssertTrue(instance.contains(#"ROOT="${WHISPERM8_TEST_ROOT:-$HOME/.whisperm8-test-instance}""#))
    }
}
