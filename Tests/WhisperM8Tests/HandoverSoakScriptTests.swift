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

    /// Nur Aufrufe, die nie einen echten Lauf starten (kein `run`).
    func testUsageErrorsNeverStartARun() throws {
        XCTAssertEqual(try run([Self.script.path, "gibtsnicht"]).status, 64)
        XCTAssertEqual(try run([Self.script.path, "self-test", "--rounds", "0"]).status, 64)
        XCTAssertEqual(try run([Self.script.path, "self-test", "--bogus"]).status, 64)
    }

    /// Eine relative Wurzel ignoriert die App (`AppInstance.resolveTestRoot`)
    /// und spräche dann die Produktiv-Instanz an.
    func testRelativeTestRootIsRefused() throws {
        let result = try run([Self.script.path, "self-test"], environment: ["WHISPERM8_TEST_ROOT": "~/soak"])
        XCTAssertEqual(result.status, 64, result.output)
        XCTAssertTrue(result.output.contains("absoluter Pfad"), result.output)
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
        // Das Binary direkt nur mit ausdrücklicher Test-Wurzel aufrufen.
        // Dateiprüfungen wie `[[ -x "$BIN" ]]` sind kein Aufruf.
        for line in code.split(separator: "\n") where line.contains("\"$BIN\" ") && !line.contains("-x \"$BIN\"") {
            XCTAssertTrue(line.contains("WHISPERM8_INSTANCE_ROOT=\"$ROOT\""), "Aufruf ohne Test-Wurzel: \(line)")
        }
        XCTAssertNil(code.range(of: #"com\.whisperm8\.app[^.]"#, options: .regularExpression), "Produktiv-Bundle-ID im Skript")
        XCTAssertTrue(code.contains(#"[[ "$ROOT" == /* ]]"#), "Wurzel muss absolut sein")
        // Defaults nur in der Domain der Test-Instanz (Labs-Schalter für die Übergabe).
        XCTAssertTrue(code.contains(#"TEST_DOMAIN="com.whisperm8.app.test""#))
        XCTAssertTrue(code.contains("restartKeepsChatsEnabled -bool YES"), "Labs-Schalter in der Test-Instanz an")
        for line in code.split(separator: "\n") where line.contains("defaults write") || line.contains("defaults delete") {
            XCTAssertTrue(line.contains("\"$TEST_DOMAIN\""), "Defaults außerhalb der Test-Domain: \(line)")
        }
    }

    func testTestInstanceScriptRefusesRelativeRoot() throws {
        let instance = Self.root.appendingPathComponent("scripts/test-instance.sh")
        let result = try run([instance.path, "status"], environment: ["WHISPERM8_TEST_ROOT": "relativ/wurzel"])
        XCTAssertEqual(result.status, 64, result.output)
    }

    func testRootMatchesTestInstanceScript() throws {
        let instance = try String(contentsOf: Self.root.appendingPathComponent("scripts/test-instance.sh"), encoding: .utf8)
        XCTAssertTrue(instance.contains(#"ROOT="${WHISPERM8_TEST_ROOT:-$HOME/.whisperm8-test-instance}""#))
    }

    /// bash 3.2 liest bei `"$name“"` das erste Byte des Unicode-Zeichens als Teil
    /// des Variablennamens („unbound variable“, Lauf vom 13.11.). Deshalb `${name}`.
    func testNoVariableDirectlyBeforeNonASCII() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        let pattern = #"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]"#
        XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                     "Variable direkt vor Nicht-ASCII: ${…} verwenden")
    }

    /// Eine Test-Instanz für alle Chats: Das Skript nimmt die gemeinsame Sperre
    /// und gibt sie am Ende wieder frei (Regel vom 13.11.2026).
    func testScriptTakesAndReleasesTheSharedInstanceLock() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        XCTAssertTrue(text.contains("/private/tmp/whisperm8-testinstanz.lock"))
        XCTAssertTrue(text.contains("take_instance_lock || exit 1"))
        XCTAssertTrue(text.contains("release_instance_lock"))
    }
}
