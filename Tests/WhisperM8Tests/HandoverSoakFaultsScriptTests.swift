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

    /// Unbekannter Befehl, unbekanntes Szenario und relative Wurzel brechen ab,
    /// bevor irgendetwas an der Test-Instanz passiert.
    func testUsageErrorsNeverStartARun() throws {
        XCTAssertEqual(try run([Self.script.path, "gibtsnicht"]).status, 64)
        let unknown = try run([Self.script.path, "run", "--only", "gibtsnicht"])
        XCTAssertEqual(unknown.status, 64, unknown.output)
        XCTAssertTrue(unknown.output.contains("unbekanntes Szenario"), unknown.output)
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
        // Signale nur in drei bekannten Formen: kill_keeper (prüft vorher die
        // Kommandozeile), der eigene Wächter-Prozess und der Selbsttest-Prozess.
        // `kill -0` prüft nur, ob ein Prozess lebt.
        let allowed = [#"kill "-$2" "$1""#, #"kill "$SAMPLER_PID""#, #"kill "$stranger""#, "kill -0 "]
        for line in code.split(separator: "\n") where line.range(of: #"(^|[\s;(&|])kill\s"#, options: .regularExpression) != nil {
            XCTAssertTrue(allowed.contains { line.contains($0) }, "unbekannter kill-Aufruf: \(line)")
        }
        XCTAssertTrue(code.contains(#"[[ "$command" == *"handover-keeper --root $HANDOVER_DIR "* ]]"#))
        // rsync --delete nur auf das Test-Bundle dieses Arbeitsordners.
        XCTAssertTrue(code.contains(#"APP="$REPO/.build-test/WhisperM8Test.app""#))
        for line in code.split(separator: "\n") where line.contains("rsync") {
            XCTAssertTrue(line.contains(#""$APP/""#), "rsync mit anderem Ziel: \(line)")
        }
    }

    /// Umsigniert wird nur das Test-Bundle oder seine Arbeitskopie, und nur in den
    /// beiden Arten, die es wirklich gibt: Dev-Zertifikat (`make dev`) und ad hoc
    /// (Release-Pipeline, also alle Brew-Nutzer).
    func testSigningOnlyTouchesTheTestBundle() throws {
        let code = try code()
        let signing = code.split(separator: "\n").filter { $0.contains("codesign --force") }
        XCTAssertEqual(signing.count, 1, "codesign --force nur in sign_bundle")
        XCTAssertTrue(signing.first?.contains(#"--sign "$id""#) == true)
        for line in code.split(separator: "\n") where line.range(of: #"\bsign_bundle ""#, options: .regularExpression) != nil {
            XCTAssertTrue(line.contains(#"sign_bundle "$APP""#) || line.contains(#"sign_bundle "$copy""#),
                          "sign_bundle mit anderem Ziel: \(line)")
        }
        XCTAssertTrue(code.contains(#"[[ -z "$SIGNING" || "$SIGNING" == dev || "$SIGNING" == adhoc ]]"#))
        let usage = try run([Self.script.path, "run", "--signing", "apple"],
                            environment: ["WHISPERM8_TEST_ROOT": "/private/tmp/whisperm8-test-guard"])
        XCTAssertEqual(usage.status, 64, usage.output)
    }

    func testFaultScriptReusesTheSoakLibrary() throws {
        let code = try code()
        XCTAssertTrue(code.contains("source \"$(cd \"$(dirname \"$0\")\" && pwd)/handover-soak.sh\""))
        let soak = try String(contentsOf: Self.root.appendingPathComponent("scripts/handover-soak.sh"), encoding: .utf8)
        XCTAssertTrue(soak.contains(#"if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then"#), "handover-soak.sh als Bibliothek ladbar")
    }

    /// bash 3.2 liest bei `"$name“"` das erste Byte des Unicode-Zeichens als Teil
    /// des Variablennamens („unbound variable“, Lauf vom 13.11.). Deshalb `${name}`.
    func testNoVariableDirectlyBeforeNonASCII() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        let pattern = #"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]"#
        XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                     "Variable direkt vor Nicht-ASCII: ${…} verwenden")
    }
}
